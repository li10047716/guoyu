import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 标题栏左侧内容槽（0.7.45，用户要求）。
///
/// 首页把「品牌 + 站源胶囊」交给窗口标题栏渲染，让它们和最小化 / 最大化 / 关闭
/// 排在同一行（标题栏左侧）。标题栏挂在 `MaterialApp.builder` 上，位于
/// Navigator 之上，拿不到首页的 State，所以用这个全局槽把 Widget 递上来。
class TitleBarSlot {
  TitleBarSlot._();

  static final TitleBarSlot instance = TitleBarSlot._();

  /// 供标题栏监听的重建信号。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Widget? _content;

  /// 当前要显示在标题栏左侧的内容（首页每次 build 塞进来）。
  Widget? get content => _content;

  /// 0.7.47：申请隐藏整条标题栏的持有者集合（播放页等沉浸式场景）。
  ///
  /// 用「持有者」而不是布尔开关：连播 / 全屏路由等场景下可能有多个页面
  /// 叠在同一栈里，任一页面退出时不该把其它页面的隐藏状态一起清掉。
  final Set<Object> _hiddenOwners = <Object>{};

  /// 是否应整条隐藏（播放页进入后 / 系统全屏时）。
  bool get hidden => _hiddenOwners.isNotEmpty;

  /// 在首页 build 期间调用：只换内容，通知延后到本帧结束——
  /// 直接在 build 阶段通知会触发「markNeedsBuild called during build」。
  void put(Widget? content) {
    if (identical(_content, content)) return;
    _content = content;
    _notify();
  }

  /// 0.7.47：进入 / 退出「隐藏标题栏」状态。
  ///
  /// 播放页 `initState` 传 true、`dispose` 传 false。延后一帧通知，
  /// 既避免在 initState / dispose 期间直接 markNeedsBuild，也刚好落在
  /// 页面切换动画里，看不出跳变。
  void setHidden(Object owner, bool hidden) {
    final changed = hidden
        ? _hiddenOwners.add(owner)
        : _hiddenOwners.remove(owner);
    if (!changed) return;
    _notify();
  }

  void _notify() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      revision.value = revision.value + 1;
    });
  }
}

/// 标题栏左侧可拖动小块（0.7.45）。
///
/// 首页的品牌区（logo + 应用名）用它包一下：按住拖动窗口、双击切换最大化。
/// 不给整条标题栏挂双击手势，否则会让站源胶囊的单次点击多等一个
/// 双击判定窗口（约 300ms）。
class TitleBarDragHandle extends StatelessWidget {
  const TitleBarDragHandle({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => windowManager.startDragging(),
    onDoubleTap: () async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    },
    child: child,
  );
}

/// Windows 自定义标题栏（0.7.43）。
///
/// 系统窗口标题栏已在 `main.dart` 里用 `TitleBarStyle.hidden` 隐藏，
/// 最小化 / 最大化 / 关闭改为应用内按钮（放到窗口右上角）。
/// - 左侧留空时可拖动窗口，双击切换最大化；
/// - 0.7.45 起左侧由首页填充「品牌 + 站源胶囊」，与窗口按钮同一行；
/// - 播放器把窗口切成系统全屏时，整条标题栏自动隐藏，退出后恢复。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key, this.title});
  final String? title;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar>
    with WindowListener {
  bool _maximized = false;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refresh();
    // 0.7.43 实测：启动早期（窗口尚未显示时）应用的 TitleBarStyle.hidden
    // 不会触发 WM_NCCALCSIZE，系统标题栏会一直留着，直到首次拖动窗口大小。
    // 这里等窗口可见后重新应用一次，并做 1px 尺寸抖动强制刷新边框（幂等）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyHiddenFrame());
  }

  Future<void> _applyHiddenFrame() async {
    try {
      for (var i = 0; i < 50; i++) {
        if (await windowManager.isVisible()) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // 窗口可见后重新应用一次；此时句柄已就绪，插件内部的
      // SetWindowPos(SWP_FRAMECHANGED) 会触发 WM_NCCALCSIZE 真正去掉边框。
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    } catch (_) {
      // 个别环境下窗口管理器不可用，忽略即可（下次改变窗口大小后同样生效）。
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final maximized = await windowManager.isMaximized();
    final fullscreen = await windowManager.isFullScreen();
    if (!mounted) return;
    if (maximized != _maximized || fullscreen != _fullscreen) {
      setState(() {
        _maximized = maximized;
        _fullscreen = fullscreen;
      });
    }
  }

  @override
  void onWindowMaximize() => _refresh();

  @override
  void onWindowUnmaximize() => _refresh();

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _fullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) setState(() => _fullscreen = false);
  }

  void _toggleMaximize() => _maximized
      ? windowManager.unmaximize()
      : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: TitleBarSlot.instance.revision,
      builder: (context, _) {
        // 0.7.47（用户要求）：播放页进入后、以及系统全屏时，整条标题栏
        // 一起隐藏——之前的实现只判断 `_fullscreen`，而桌面全屏走的是
        // 应用内全屏路由，`onWindowEnterFullScreen` 不一定触发，
        // 导致「进入播放」和「全屏」两种情况下顶行都还留着。
        if (_fullscreen || TitleBarSlot.instance.hidden) {
          return const SizedBox.shrink();
        }
        final leading = TitleBarSlot.instance.content;
        return Container(
          height: 40,
          // 0.7.45（用户要求）：去掉标题栏下方的分隔线，让顶栏和内容连成一片。
          color: theme.scaffoldBackgroundColor,
          child: Row(
            children: [
              Expanded(
                child: leading == null
                    ? _dragArea(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: widget.title == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: Text(
                                    widget.title!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                        ),
                      )
                    : GestureDetector(
                        // 拖动窗口：胶囊是 InkWell，点击事件由它自己处理，
                        // 空白处按住拖动仍然交给窗口管理器。
                        behavior: HitTestBehavior.translucent,
                        onPanStart: (_) => windowManager.startDragging(),
                        child: Material(
                          type: MaterialType.transparency,
                          child: leading,
                        ),
                      ),
              ),
              _WindowButton(
                icon: Icons.minimize_rounded,
                tooltip: '最小化',
                onTap: windowManager.minimize,
              ),
              _WindowButton(
                icon: _maximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                tooltip: _maximized ? '还原' : '最大化',
                onTap: _toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close_rounded,
                tooltip: '关闭',
                danger: true,
                onTap: windowManager.close,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 空标题栏时的拖动区：按住拖动窗口、双击切换最大化。
  Widget _dragArea({required Widget child}) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => windowManager.startDragging(),
    onDoubleTap: _toggleMaximize,
    child: child,
  );
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = !_hover
        ? null
        : widget.danger
        ? const Color(0xFFE81123)
        : colors.onSurface.withValues(alpha: 0.08);
    final foreground = _hover && widget.danger
        ? Colors.white
        : colors.onSurfaceVariant;
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: double.infinity,
          color: background,
          child: Icon(widget.icon, size: 17, color: foreground),
        ),
      ),
    );
    // 0.7.48：自定义标题栏位于 MaterialApp 的 Overlay 之上，而新版 Flutter
    // 的 Tooltip 在 build 阶段就要求存在 Overlay 祖先，否则直接抛
    // 「No Overlay widget found」。窗口按钮本身不依赖提示气泡，没有
    // Overlay 时退化成只带语义标签的按钮。
    if (Overlay.maybeOf(context, rootOverlay: true) == null) {
      return Semantics(label: widget.tooltip, button: true, child: button);
    }
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: button,
    );
  }
}
