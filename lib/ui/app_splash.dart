import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:duanju_app/core/app_build.dart';
import 'package:duanju_app/platform/desktop_title_bar.dart';
import 'package:duanju_app/ui/splash_scene.dart';

/// 开屏页（启动画面）。
///
/// 解决的问题：进入软件后，首页要等原生核心初始化 + 拉取第一批视频
/// 才显示内容，中间这段时间是空白等待。
///
/// 做法：先用开屏页盖住，等首页真正"有视频可播"再淡出，
/// 用户感知上就是"一点开就有画面"，而不是"进去后干等"。
///
/// ## 0.7.52：从「图标淡入」改为「月下孤岛」动态画面
///
/// 0.7.34 那版是四段静态入场（logo 淡入 + 字标 + 标语），气氛对但画面是死的。
/// 这一版把 `assets/branding/logo.png` 里的画面**本身**拆成图层重画，
/// 让它一直在动：星野呼吸、月晕脉动、海面流动、倒影明灭、偶发流星。
/// 具体分层见 [SplashScene]。
///
/// 入场时间轴固定在 [splashIntroDuration]（1600ms）内，之后场景继续循环：
///
/// | 时间 | 内容 |
/// | --- | --- |
/// | 0–100ms | 纯底色，遮住宿主白底 |
/// | 0–600ms | 星野自左下向右上逐颗点亮（按星序错峰 0–540ms） |
/// | 90–930ms | 月牙自右上滑入并提亮，两层月晕展开 |
/// | 320–1150ms | 海平线从画面中心向两侧展开 |
/// | 380–1340ms | 孤岛从海面下升起 4% 屏高并淡入 |
/// | 450–1300ms | 海面波纹淡入，月光倒影开始抖动 |
/// | 990–1440ms | 字标「果屿」上浮 12px 淡入，字距从 0.40em 收到 0.18em |
/// | 1250–1600ms | 标语淡入 |
/// | 全程 | 星闪 / 水波 / 月晕 / 流星 9 秒一轮 |
///
/// 设计约束（与旧版一致，没有放宽）：
/// - 不阻塞启动：只做视觉遮挡，初始化逻辑仍在后台并行进行。
/// - **最多停留 3 秒**：3 秒后无论如何都进入首页，首页自己显示骨架屏。
/// - 动画没播完就淡出会"闪一下"，所以最短展示时长与入场动画对齐。
/// - 淡出 240ms 后整块移除，不留下透明层挡住点击。
/// - 系统开启「减少动态效果」时，场景直接定格完成态。
///
/// ## 0.7.54：开屏改为播放视频
///
/// 传入 [videoLayer] / [videoDone]（由 `LaunchVideo` 提供，media_kit
/// 相关代码全部隔离在那边）时，开屏在视频首帧就绪后把它淡入盖住
/// 绘制场景；**视频播完或失败**（videoDone）才允许淡出进首页，所以
/// 最短展示约束自动对齐视频时长，超时上限也放宽到 8 秒兜底。
/// 不传这两个参数则保持纯绘制场景路径，widget 测试走的正是它。
class AppSplash extends StatefulWidget {
  const AppSplash({
    super.key,
    required this.child,
    required this.ready,
    this.videoLayer,
    this.videoDone,
    this.minimumDuration = splashIntroDuration,
    this.timeout = const Duration(seconds: 3),
  });

  /// 真正的主界面。
  final Widget child;

  /// 主界面是否已经准备好（例如首页已拉到第一批视频）。
  final ValueListenable<bool> ready;

  /// 开屏视频层（可渲染后非空）；就绪前用绘制场景兜底。
  final ValueListenable<Widget?>? videoLayer;

  /// 视频已了结（播放完成 / 加载失败）——true 后开屏才可放行。
  final ValueListenable<bool>? videoDone;

  /// 开屏页最短展示时间，避免"闪一下就没了"。
  final Duration minimumDuration;

  /// 最长等待时间，超过则强制放行。
  final Duration timeout;

  @override
  State<AppSplash> createState() => _AppSplashState();
}

/// 淡出时长：短到不拖沓，长到不"啪"一下消失。
const _fadeDuration = Duration(milliseconds: 240);

class _AppSplashState extends State<AppSplash> {
  /// 顶栏隐藏的持有者标识（`TitleBarSlot.setHidden` 用）。
  static const _titleBarOwner = 'app-splash';

  bool _fading = false;
  bool _removed = false;
  bool _minimumElapsed = false;
  bool _waiting = false;

  /// 视频：就绪后淡入盖住场景；**放完（或失败）才放行首页**。
  /// 信号由 `LaunchVideo` 提供，这里不接触播放器本身。
  Widget? _videoLayer;
  bool _videoSettled = false;

  Timer? _minimumTimer;
  Timer? _timeoutTimer;
  Timer? _waitingTimer;
  Timer? _fadeTimer;

  @override
  void initState() {
    super.initState();
    // 0.7.54：开屏期间整条隐藏桌面顶栏，让开屏画面占满窗口
    // （与播放器全屏同一套持有者机制）。淡出开始时恢复。
    TitleBarSlot.instance.setHidden(_titleBarOwner, true);
    _minimumTimer = Timer(widget.minimumDuration, () {
      if (!mounted) return;
      _minimumElapsed = true;
      _maybeDismiss();
    });
    // 动画播完还没就绪时，才补一个很轻的进度环：让用户知道在等，而不是卡住了。
    // 一开始就显示会破坏入场节奏，所以延后到入场结束之后。
    _waitingTimer = Timer(
      widget.minimumDuration + const Duration(milliseconds: 200),
      () {
        if (!mounted || _fading) return;
        setState(() => _waiting = true);
      },
    );
    // 0.7.16：超时**无条件**放行。
    // 原先这里只置 `_minimumElapsed`，仍要求 `ready` 为真才淡出，
    // 于是只要首屏一条剧都拉不回来（站源故障 / 无网络 / 空列表），
    // 开屏页就永久盖住首页，用户看不到也点不到首页自带的错误与重试按钮。
    // 视频模式下放宽到 8 秒：视频本身就有 5 秒多，3 秒兜底会把片尾切掉。
    _timeoutTimer = Timer(
      widget.videoDone != null
          ? const Duration(seconds: 8)
          : widget.timeout,
      () {
        if (!mounted) return;
        _videoSettled = true;
        _dismiss();
      },
    );
    widget.ready.addListener(_maybeDismiss);
    widget.videoDone?.addListener(_onVideoSettled);
    widget.videoLayer?.addListener(_onVideoLayer);
    _videoSettled = widget.videoDone?.value ?? true;
    _videoLayer = widget.videoLayer?.value;
    _maybeDismiss();
  }

  void _onVideoSettled() {
    if (!mounted) return;
    _videoSettled = true;
    _maybeDismiss();
  }

  void _onVideoLayer() {
    if (!mounted) return;
    setState(() => _videoLayer = widget.videoLayer?.value);
  }

  @override
  void didUpdateWidget(covariant AppSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ready != widget.ready) {
      oldWidget.ready.removeListener(_maybeDismiss);
      widget.ready.addListener(_maybeDismiss);
    }
  }

  @override
  void dispose() {
    _minimumTimer?.cancel();
    _timeoutTimer?.cancel();
    _waitingTimer?.cancel();
    _fadeTimer?.cancel();
    widget.ready.removeListener(_maybeDismiss);
    widget.videoDone?.removeListener(_onVideoSettled);
    widget.videoLayer?.removeListener(_onVideoLayer);
    // 兜底：无论以何种方式离场，顶栏都必须恢复。
    TitleBarSlot.instance.setHidden(_titleBarOwner, false);
    super.dispose();
  }

  void _dismiss() {
    if (!mounted || _fading) return;
    setState(() => _fading = true);
    // 淡出一开始就把顶栏放回来，窗口立刻恢复可拖动/可关闭。
    TitleBarSlot.instance.setHidden(_titleBarOwner, false);
    _waitingTimer?.cancel();
    _fadeTimer = Timer(_fadeDuration + const Duration(milliseconds: 20), () {
      if (mounted) setState(() => _removed = true);
    });
  }

  void _maybeDismiss() {
    if (!mounted || _fading) return;
    if (!_minimumElapsed || !widget.ready.value) return;
    // 视频没放完（且没失败）就继续等，首屏就绪也不能提前切走。
    if (!_videoSettled) return;
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_removed)
          IgnorePointer(
            ignoring: _fading,
            child: AnimatedOpacity(
              opacity: _fading ? 0 : 1,
              duration: _fadeDuration,
              curve: Curves.easeOut,
              child: _SplashSurface(waiting: _waiting, video: _videoLayer),
            ),
          ),
      ],
    );
  }
}

class _SplashSurface extends StatefulWidget {
  const _SplashSurface({required this.waiting, this.video});

  /// 是否已经开始等首屏数据（控制进度环）。
  final bool waiting;

  /// 开屏视频（已可渲染时非空），盖在场景与字标之上，200ms 淡入。
  final Widget? video;

  @override
  State<_SplashSurface> createState() => _SplashSurfaceState();
}

class _SplashSurfaceState extends State<_SplashSurface>
    with TickerProviderStateMixin {
  /// 入场：只跑一次。
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: splashIntroDuration,
  )..forward();

  /// 环境动效：9 秒一轮，一直循环到被移除。
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  /// 0.7.59：口号叠在视频上层、片尾才淡入（视频约 5.2s，3.7s 起字）。
  /// 计时器只在视频真的可渲染后才开始——测试走纯绘制路径，不产生挂起计时器。
  bool _sloganUp = false;
  Timer? _sloganTimer;

  @override
  void didUpdateWidget(covariant _SplashSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureSloganTimer();
  }

  void _ensureSloganTimer() {
    if (_sloganTimer != null || widget.video == null) return;
    _sloganTimer = Timer(const Duration(milliseconds: 3700), () {
      if (mounted) setState(() => _sloganUp = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统要求「减少动态效果」时，循环动效直接停掉，场景定格在完成态。
    if (MediaQuery.of(context).disableAnimations) {
      _ambient.stop();
      if (_intro.status != AnimationStatus.completed) {
        _intro.value = 1;
      }
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _ambient.dispose();
    _sloganTimer?.cancel();
    super.dispose();
  }

  /// 取入场动画在 [start, end] 区间内的进度（0~1，已 easeOutCubic）。
  double _segment(double start, double end) {
    if (MediaQuery.of(context).disableAnimations) return 1;
    final v = _intro.value;
    if (v <= start) return 0;
    if (v >= end) return 1;
    return Curves.easeOutCubic.transform((v - start) / (end - start));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final shortest = size.shortestSide;
    final wordSize = (shortest * 0.115).clamp(40.0, 112.0);
    final sloganSize = (shortest * 0.0215).clamp(12.5, 20.0);
    final wordGap = (wordSize * 0.20).clamp(10.0, 24.0);
    final ringGap = (shortest * 0.045).clamp(22.0, 46.0);

    final surface = ColoredBox(
      color: splashSky,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SplashScene(intro: _intro, ambient: _ambient),
          // 字标位置补一个小范围的暗斑。
          // 整条海面的压暗放在 [SplashScene] 里，画在月光带之前；
          // 放在这一层会把那条白光压成灰带。
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, 0.74),
                  radius: 0.58,
                  colors: const [
                    Color(0x2E030A1E),
                    Color(0x00030A1E),
                  ],
                  stops: const [0, 1],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: size.height * 0.075,
            child: AnimatedBuilder(
              animation: _intro,
              builder: (context, _) {
                final wordP = _segment(0.62, 0.90);
                final sloganP = _segment(0.78, 1.0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 字标：上浮 + 淡入 + 字距收拢，品牌出现的经典三件套。
                    Opacity(
                      opacity: wordP,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - wordP)),
                        child: Text(
                          appName,
                          style: TextStyle(
                            color: const Color(0xFFF2F5FA),
                            fontSize: wordSize,
                            fontWeight: FontWeight.w700,
                            // 0.40em → 0.18em：字距收紧比单纯放大更"高级"。
                            letterSpacing: wordSize * (0.40 - 0.22 * wordP),
                            height: 1.05,
                            // 显式关掉装饰线：某些环境会把默认文本样式里的
                            // underline 带进来，在画面里是一条扎眼的黄线。
                            decoration: TextDecoration.none,
                            decorationColor: Colors.transparent,
                            shadows: [
                              Shadow(
                                color: const Color(0xCC000000),
                                blurRadius: wordSize * 0.40,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: wordGap * 0.62),
                    // 0.7.60：口号改为电影片头式两行题字卡（小字银行 + 细金线
                    // 菱形星 + 大号鎏金渐变行），纯绘制路径随 sloganP 入场。
                    _SloganLockup(size: sloganSize, progress: sloganP),
                    SizedBox(height: ringGap),
                    // 进度环占位始终存在（用透明度切换），避免它出现时把整体顶上去。
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: AnimatedOpacity(
                        key: const ValueKey('splash-progress'),
                        opacity: widget.waiting ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Color(0x66FFFFFF),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );

    // 视频就绪后盖住整个场景（含字标），200ms 淡入避免和场景硬切。
    // 0.7.59：口号不再只留在绘制层——叠在视频上层、片尾淡入，
    // 并配一条底部渐变压暗保证任何画面下都可读。
    final video = widget.video;
    if (video != null) {
      // 0.7.54：视频左上角有生成工具烙的「AI生成」角标（约左 6.5% × 上 5.2%
      // 的范围）。没有 ffmpeg 可用，就在渲染层解决：放大 1.08 倍并以右下角
      // 为锚点，把左上角推出窗口外——构图基本不变，画质损失肉眼不可见。
      final cropped = ClipRect(
        child: Transform.scale(
          scale: 1.08,
          alignment: Alignment(1, 1),
          child: video,
        ),
      );
      final settled = MediaQuery.of(context).disableAnimations || _sloganUp;
      return Stack(
        fit: StackFit.expand,
        children: [
          surface,
          // 淡入盖住场景：视频出现时场景正在播，硬切会很跳。
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            builder: (context, value, child) =>
                Opacity(opacity: value, child: child),
            child: cropped,
          ),
          // 底部压暗 + 口号：_videoSloganUp 翻真后 900ms 缓入。
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: settled ? 1 : 0),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: size.height * 0.30,
                    child: Opacity(
                      opacity: v * 0.72,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00030A1E), Color(0xB4030A1E)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: size.height * 0.075,
                    child: _SloganLockup(size: sloganSize, progress: v),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return surface;
  }
}

/// 0.7.60（用户要求，替代 0.7.59 单行版）：口号的电影片头式**两行题字卡**。
///
/// 把 [appSlogan] 按逗号拆成两行，做成高级影片开场的题字排版：
///
/// ```
/// ─── ✦  你 的 娱 乐 宇 宙  ✦ ───     ← 小字·银白·超宽字距，两侧细线向外展开
///        自 成 一 岛                  ← 大号·w800·鎏金渐变·辉光
/// ```
///
/// - **主次倒置**——前半句退为衬托（小、银、宽字距），「自成一岛」升为
///   主标（大、金、重），比单行平铺更有标题感；
/// - **鎏金渐变**——主行用 ShaderMask 做上浅下深的金属金字，
///   配暖金辉光，呼应画面里的月光与岛；
/// - **装饰线展开**——两侧细金线从中心向外生长（scaleX），菱形星 ✦ 点缀，
///   入场像帷幕拉开；
/// - **错峰入场**——小字行先现（0~55%），金行后起（35%~100%）并上浮，
///   [progress] 由外部驱动（绘制路径用入场动画，视频路径用片尾计时）。
class _SloganLockup extends StatelessWidget {
  const _SloganLockup({required this.size, required this.progress});

  /// 基准字号（外层已按屏宽收敛）。
  final double size;

  /// 入场进度 0~1（内部再拆段：小字行 → 装饰线 → 金行）。
  final double progress;

  /// [start, end] 区间内的缓出进度。
  static double _seg(double start, double end, double p) {
    if (p <= start) return 0;
    if (p >= end) return 1;
    return Curves.easeOutCubic.transform((p - start) / (end - start));
  }

  @override
  Widget build(BuildContext context) {
    final parts = appSlogan.split('，');
    final small = parts.first;
    final big = parts.length > 1 ? parts.last : '';

    final pSmall = _seg(0, 0.55, progress);
    final pRule = _seg(0.15, 0.70, progress);
    final pBig = _seg(0.35, 1.0, progress);

    final smallSize = size * 0.82;
    final bigSize = size * 1.72;

    Widget rule(double factor) => Container(
      width: 34 * factor,
      height: 1,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0x00C9A96A), Color(0xFFC9A96A)],
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 上行：细线 ✦ 小字银行 ✦ 细线（线从中心向外生长）。
        Opacity(
          opacity: pSmall,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.flip(flipX: true, child: rule(pRule)),
              _star(pRule, smallSize),
              Text(
                small,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xFFB9C6DD),
                  fontSize: smallSize,
                  fontWeight: FontWeight.w500,
                  // 0.85em → 0.42em：超宽字距收拢，片头字幕的经典呼吸。
                  letterSpacing: smallSize * (0.85 - 0.43 * pSmall),
                  height: 1.2,
                  decoration: TextDecoration.none,
                  decorationColor: Colors.transparent,
                  shadows: const [
                    Shadow(color: Color(0x99000000), blurRadius: 8),
                  ],
                ),
              ),
              _star(pRule, smallSize),
              rule(pRule),
            ],
          ),
        ),
        SizedBox(height: size * 1.05),
        // 下行：鎏金渐变主标「自成一岛」。
        Opacity(
          opacity: pBig,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - pBig)),
            child: ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFF3D0), Color(0xFFE3BC6A)],
              ).createShader(bounds),
              child: Text(
                big,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: bigSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: bigSize * (0.50 - 0.24 * pBig),
                  height: 1.1,
                  decoration: TextDecoration.none,
                  decorationColor: Colors.transparent,
                  shadows: const [
                    Shadow(color: Color(0xAA000000), blurRadius: 12, offset: Offset(0, 2)),
                    Shadow(color: Color(0x55E3BC6A), blurRadius: 22),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 菱形星 ✦：随装饰线一起长出来，比线晚半拍更有细节感。
  Widget _star(double p, double size) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size * 0.55),
      child: Opacity(
        opacity: _seg(0.3, 0.8, p),
        child: Text(
          '✦',
          style: TextStyle(
            color: const Color(0xFFC9A96A),
            fontSize: size * 0.72,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
