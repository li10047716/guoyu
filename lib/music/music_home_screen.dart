import 'package:flutter/material.dart';

/// 听歌模块（0.7.63，用户要求）：按钮先落地，能力随后补。
///
/// 页面形态和小说一致——[embedded] 为 true（Windows 桌面，窗口标题栏已经
/// 显示模块名）时直接铺满内容区；否则自带 AppBar。
/// **没有返回按钮**（0.7.64 用户要求）：看剧 / 小说 / 听歌是三个平级模块，
/// 切换只走页面底端那条按钮行。
///
/// 目前只有一版「筹备中」的界面：模块入口、返回路径、布局宽度都已经
/// 定好，等接入播放内核（media_kit 已经在播放器里用起来了）后，
/// 把中间这块换成播放页 + 歌单即可，不用再动主框架。
class MusicHomeScreen extends StatelessWidget {
  const MusicHomeScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('听歌'),
      ),
      body: body,
    );
  }

  Widget _body(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽屏别把内容摊满：居中限宽，和阅读器 760 的取法保持一致。
        final wide = constraints.maxWidth >= 760;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 760 : double.infinity),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 30),
              children: [
                Center(child: _disc(colors)),
                const SizedBox(height: 18),
                Text(
                  '听歌',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '音乐模块正在筹备，先把入口占上',
                  key: const ValueKey('music-placeholder'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 26),
                for (final entry in const [
                  (Icons.folder_open_rounded, '本地音乐', '扫描本机音频，不联网也能听'),
                  (Icons.queue_music_rounded, '在线歌单', '按心情/风格建歌单，一键连播'),
                  (Icons.headphones_rounded, '后台播放', '锁屏与通知栏控制，切歌不断'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _plannedRow(colors, entry.$1, entry.$2, entry.$3),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 顶部那枚唱片：两层同心圆 + 中心齿轮样的小圆，纯绘制，不依赖图片资源。
  Widget _disc(ColorScheme colors) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: .95),
            colors.primary.withValues(alpha: .45),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: .25),
            blurRadius: 26,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.surface.withValues(alpha: .85),
          ),
          child: Icon(
            Icons.music_note_rounded,
            size: 22,
            color: colors.primary,
          ),
        ),
      ),
    );
  }

  Widget _plannedRow(
    ColorScheme colors,
    IconData glyph,
    String title,
    String subtitle,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(glyph, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant.withValues(alpha: .85),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '即将上线',
              style: TextStyle(fontSize: 10.5, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
