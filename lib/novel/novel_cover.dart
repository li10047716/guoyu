import 'package:flutter/material.dart';

/// 小说封面（0.7.88）。
///
/// 之前只有书架和发现页有封面，搜索结果一直是 `menu_book` 图标。抽成一处后
/// 书架 / 发现 / 搜索 / 详情共用同一套加载与兜底逻辑：
/// - **Referer**：小说站普遍给封面做了防盗链白名单，不带来源直接请求会 403，
///   表现是「有封面 URL 却永远显示占位图标」。这里用同源地址当 Referer。
/// - **占位图**：URL 为空 / 加载中 / 失败都落回同一个书本图标，不会闪空白。
class NovelCover extends StatelessWidget {
  const NovelCover({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.radius = 6,
    this.iconSize,
  });

  final String url;
  final double? width;
  final double? height;
  final double radius;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? _placeholder(colors)
            : Image.network(
                url,
                fit: BoxFit.cover,
                headers: _headers(url),
                errorBuilder: (_, _, _) => _placeholder(colors),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _placeholder(colors),
              ),
      ),
    );
  }

  Widget _placeholder(ColorScheme colors) => ColoredBox(
    color: colors.surfaceContainerHighest,
    child: Center(
      child: Icon(
        Icons.menu_book_rounded,
        size: iconSize,
        color: colors.onSurfaceVariant.withValues(alpha: .45),
      ),
    ),
  );

  static Map<String, String>? _headers(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.authority.isEmpty) return null;
    return {'Referer': '${uri.scheme}://${uri.authority}/'};
  }
}
