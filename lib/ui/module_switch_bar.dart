import 'package:flutter/material.dart';

/// 一级模块（0.7.63，用户要求）：看剧 / 小说 / 听歌。
///
/// 三者是**平级的整屏界面**，切换入口固定在页面最底部一条胶囊里，
/// 手机、桌面、电视都常驻——所以在小说/听歌里不需要「返回」也能回看剧。
enum AppModule {
  watch('看剧', Icons.live_tv_outlined, Icons.live_tv_rounded),
  novel('小说', Icons.auto_stories_outlined, Icons.auto_stories_rounded),
  music('听歌', Icons.music_note_outlined, Icons.music_note_rounded);

  const AppModule(this.label, this.glyph, this.selectedGlyph);

  final String label;
  final IconData glyph;
  final IconData selectedGlyph;

  String get key => 'module-$name';
}

/// 页面底端的模块切换条。
///
/// 造型沿用底栏的「悬浮胶囊」：外层一枚描边胶囊，内部三段，
/// 选中段是实心主色胶囊——和 [AppBottomNavigation] 同一套语言，
/// 但高度更矮（36），叠在底栏下面也不会显得臃肿。
class ModuleSwitchBar extends StatelessWidget {
  const ModuleSwitchBar({
    super.key,
    required this.current,
    required this.onChanged,
  }) : _compact = false;

  /// 顶栏用的紧凑版（0.7.74，用户要求）：手机端底栏只留一排，
  /// 切换条挪进顶栏——选中的段显示「图标 + 文字」，未选中只留图标，
  /// 整条宽度约 110px，和站源胶囊、搜索按钮同排不挤。
  const ModuleSwitchBar.compact({
    super.key,
    required this.current,
    required this.onChanged,
  }) : _compact = true;

  final AppModule current;
  final ValueChanged<AppModule> onChanged;

  /// 是否用顶栏紧凑形态（见 [ModuleSwitchBar.compact]）。
  final bool _compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final module in AppModule.values)
            _compactSegment(context, module),
        ],
      );
    }
    return Padding(
      // 手机端这条下面是系统手势区，交给外层 SafeArea 统一处理，
      // 这里只留一点视觉间距。
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final module in AppModule.values)
                  _segment(context, module),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 紧凑段：选中的「图标+文字」实心胶囊，未选中的纯图标按钮。
  Widget _compactSegment(BuildContext context, AppModule module) {
    final colors = Theme.of(context).colorScheme;
    final selected = module == current;
    final radius = BorderRadius.circular(17);
    final child = selected
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(module.selectedGlyph, size: 16, color: colors.onPrimary),
                const SizedBox(width: 4),
                Text(
                  module.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.onPrimary,
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(module.glyph, size: 19, color: colors.onSurfaceVariant),
          );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: module.label,
      child: Material(
        color: selected ? colors.primary : Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Tooltip(
          message: module.label,
          child: InkWell(
            key: ValueKey('${module.key}-compact'),
            borderRadius: radius,
            onTap: selected ? null : () => onChanged(module),
            child: SizedBox(height: 34, child: child),
          ),
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, AppModule module) {
    final colors = Theme.of(context).colorScheme;
    final selected = module == current;
    final foreground = selected ? colors.onPrimary : colors.onSurfaceVariant;
    final radius = BorderRadius.circular(20);
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? colors.primary : Colors.transparent,
          borderRadius: radius,
        ),
        // 水波纹必须画在自己这层 Material 上：底栏外层那块 Material 在
        // 胶囊底色之下，直接给 InkWell 的话涟漪会被整个胶囊挡住（看不见）。
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey(module.key),
            borderRadius: radius,
            // 已选中的段不响应点击，避免切换时白跑一次 setState。
            onTap: selected ? null : () => onChanged(module),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? module.selectedGlyph : module.glyph,
                    size: 17,
                    color: foreground,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    module.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
