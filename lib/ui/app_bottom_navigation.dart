import 'package:flutter/material.dart';

/// 手机端底部导航（0.7.35 Glass Noir 改版）。
///
/// 预览稿 01 屏的样式：**悬浮胶囊底栏**——不再是一条通栏 + 顶部分隔线，
/// 而是一枚圆角 36 的深空卡色胶囊浮在页面底部；选中项是实心主色胶囊，
/// 未选中项图标 + 文字弱化。
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.onDestinationDoubleTap,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  /// 双击某个标签时的回调。
  final ValueChanged<int>? onDestinationDoubleTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Material(
          color: Colors.transparent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: colors.outlineVariant, width: 1),
            ),
          child: Row(
            children: [
              for (final (index, destination) in destinations.indexed)
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    selected: index == selectedIndex,
                    child: Tooltip(
                      message: destination.label,
                      excludeFromSemantics: true,
                      child: InkWell(
                        key: ValueKey('bottom-nav-$index'),
                        onTap: () => onDestinationSelected(index),
                        onDoubleTap: onDestinationDoubleTap == null
                            ? null
                            : () => onDestinationDoubleTap!(index),
                        borderRadius: BorderRadius.circular(28),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 7,
                          ),
                          height: 50,
                          decoration: BoxDecoration(
                            color: index == selectedIndex
                                ? colors.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconTheme(
                                data: IconThemeData(
                                  size: 22,
                                  color: index == selectedIndex
                                      ? colors.onPrimary
                                      : colors.onSurfaceVariant,
                                ),
                                child: index == selectedIndex
                                    ? destination.selectedIcon ??
                                          destination.icon
                                    : destination.icon,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                destination.label,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.1,
                                  fontWeight: index == selectedIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: index == selectedIndex
                                      ? colors.onPrimary
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
