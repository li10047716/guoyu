import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一页正文在整章排版结果里的窗口。
class NovelPageSlice {
  const NovelPageSlice({required this.top, required this.height});

  /// 该页第一行的顶部相对整章文本起点的偏移。
  final double top;

  /// 该页实际占用的高度（不会超过页容量）。
  final double height;
}

/// 章节分页：整章一次性排版，再按真实行高切成若干页。
///
/// 为什么不用「字数估算」（0.7.85 之前的做法）：中文正文里标点、数字、
/// 中英混排的字符宽度都不一样，按 `可用宽度 / 字号` 估每行字数会在长段落上
/// 不断累积误差，结果要么一页溢出去半行被裁掉、要么一页只剩两行大片留白；
/// 而且旧实现不拆段，一段超过一页就整段塞进去直接溢出。
///
/// 这里改成：把整章拼成一段富文本交给 [TextPainter] 排版一次，用它返回的
/// [TextPainter.computeLineMetrics] 拿到每一行的真实高度，逐行累加到页容量
/// 就断页。好处是——
/// - 分页边界永远落在行边界，不会切断汉字；
/// - 长段落自然跨页；
/// - 整章只排版一次，翻页时只是平移画布，不重排，滑动不卡。
class NovelPagination {
  NovelPagination._({
    required this.painter,
    required this.slices,
    required this.titleInset,
    required this.width,
  });

  /// 整章排版结果，画某一页时只需按 [NovelPageSlice.top] 平移。
  final TextPainter painter;

  final List<NovelPageSlice> slices;

  /// 首页给章节标题预留的高度；其余页为 0。
  final double titleInset;

  final double width;

  int get pageCount => slices.length;

  /// 段落之间的缩进（两个全角空格，中文排版惯例）。
  static const String indent = '\u3000\u3000';

  static NovelPagination build({
    required List<String> paragraphs,
    required double width,
    required double height,
    required double fontSize,
    required double lineHeight,
    String? fontFamily,
    required Color color,
    double titleInset = 0,
    TextAlign textAlign = TextAlign.left,
  }) {
    final buffer = StringBuffer();
    for (final raw in paragraphs) {
      // 站点正文里常混进不间断空格 / 全角空格，先归一再判断是否空段。
      final value = raw.replaceAll('\u00a0', ' ').replaceAll('\u3000', ' ').trim();
      if (value.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(indent);
      buffer.write(value);
    }

    final painter = TextPainter(
      text: TextSpan(
        text: buffer.isEmpty ? '\u3000' : buffer.toString(),
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          height: lineHeight,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    )..layout(maxWidth: math.max(80, width));

    final metrics = painter.computeLineMetrics();
    final slices = <NovelPageSlice>[];
    if (metrics.isEmpty) {
      slices.add(const NovelPageSlice(top: 0, height: 0));
      return NovelPagination._(
        painter: painter,
        slices: slices,
        titleInset: titleInset,
        width: width,
      );
    }

    // 每一行的顶部偏移：累加前面所有行的高度。
    var cursor = 0.0;
    var index = 0;
    while (index < metrics.length) {
      // 首页被标题占掉一块，可用高度更少。
      final capacity = slices.isEmpty
          ? math.max(metrics[index].height, height - titleInset)
          : height;
      final start = cursor;
      var used = 0.0;
      while (index < metrics.length &&
          used + metrics[index].height <= capacity + 0.5) {
        used += metrics[index].height;
        cursor += metrics[index].height;
        index++;
      }
      if (used <= 0) {
        // 页高连一行都放不下（窗口被拉得极扁）：兜底放一行，避免死循环。
        used = metrics[index].height;
        cursor += metrics[index].height;
        index++;
      }
      slices.add(NovelPageSlice(top: start, height: used));
    }

    return NovelPagination._(
      painter: painter,
      slices: slices,
      titleInset: titleInset,
      width: width,
    );
  }

  void dispose() => painter.dispose();
}

/// 把整章排版结果的某一段窗口画到画布上。
class NovelPagePainter extends CustomPainter {
  const NovelPagePainter({required this.painter, required this.top});

  final TextPainter painter;

  /// 该页第一行的顶部偏移；绘制时整体上移这么多。
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    if (top <= 0) {
      painter.paint(canvas, Offset.zero);
      return;
    }
    canvas.save();
    canvas.translate(0, -top);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(NovelPagePainter oldDelegate) =>
      oldDelegate.painter != painter || oldDelegate.top != top;
}
