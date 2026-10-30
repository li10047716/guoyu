import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/novel/novel_pagination.dart';

/// 临时工具：把分页结果渲染成 PNG，人工核对字形 / 行距 / 切页是否正确。
/// 用法：flutter test test/reader_preview_test.dart，然后看 build/reader_preview.png
const List<String> _sample = [
  '　　天色暗下来的时候，巷子口那盏路灯还没亮。他靠在墙边，把手里的塑料袋换了个手，抬眼看了看表。',
  '　　“你确定是这儿？”身后的人压着嗓子问。',
  '　　他没回头，只是抬了抬下巴，示意前面那扇半开的铁门。门缝里透出一点橘黄色的光，像是有人在里面抽烟，烟味混着潮湿的霉味飘出来。',
  '　　“第三回了。”他说，“前两回都是我先进去。”',
  '　　对方没接话。风从巷子另一头灌进来，卷起地上的碎纸片，贴在墙根打了个转又落下。远处有无轨电车经过的声响，很轻，像谁在很远的地方叹了口气。',
  '　　他把塑料袋放在台阶上，蹲下去系鞋带。其实鞋带没松，他只是想再给彼此十秒钟。',
  '　　十秒之后，铁门里面传来椅子挪动的声音。',
];

void main() {
  testWidgets('导出一页分页渲染结果', (tester) async {
    final fontFile = File(r'C:\Windows\Fonts\simhei.ttf');
    if (!fontFile.existsSync()) {
      // 只是人工核对的工具，没有这个字体就跳过。
      return;
    }
    final raw = fontFile.readAsBytesSync();
    final loader = FontLoader('PreviewHei')
      ..addFont(Future.value(ByteData.sublistView(raw)));
    await loader.load();

    final paging = NovelPagination.build(
      paragraphs: _sample,
      width: 320,
      height: 500,
      fontSize: 17,
      lineHeight: 1.75,
      fontFamily: 'PreviewHei',
      color: const Color(0xFFE6EBF2),
    );

    const pageWidth = 320.0;
    const pageHeight = 500.0;
    const gap = 20.0;
    final shown = paging.slices.take(2).toList();
    const width = 20 * 2 + pageWidth * 2 + gap;
    const height = 24 * 2 + pageHeight;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFF0A0D12),
    );
    for (var i = 0; i < shown.length; i++) {
      final slice = shown[i];
      final left = 20 + i * (pageWidth + gap);
      canvas.drawRect(
        Rect.fromLTWH(left, 24, pageWidth, pageHeight),
        Paint()..color = const Color(0xFF11151C),
      );
      canvas.save();
      canvas.translate(left, 24);
      // 关键：按本页实际高度裁剪，和阅读页里的 SizedBox(height: slice.height) 一致。
      canvas.clipRect(Rect.fromLTWH(0, 0, pageWidth, slice.height));
      canvas.translate(0, -slice.top);
      paging.painter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    final image = await tester.runAsync(() async {
      final shot = await recorder.endRecording().toImage(
        width.toInt(),
        height.toInt(),
      );
      final png = await shot.toByteData(format: ui.ImageByteFormat.png);
      final out = File('build/reader_preview.png');
      out.createSync(recursive: true);
      out.writeAsBytesSync(png!.buffer.asUint8List());
      return out;
    });

    // ignore: avoid_print
    print('PREVIEW=${image!.absolute.path} pages=${paging.pageCount} '
        'height=${paging.painter.height.toStringAsFixed(1)}');
    paging.dispose();
  });
}
