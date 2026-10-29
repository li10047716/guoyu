import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:duanju_app/ui/app_splash.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试环境默认字体是 Ahem（所有字都画成方块），
/// 预览图里的「果屿」会变成两个黑方块，所以把系统黑体挂进来。
Future<void> _loadCjkFont() async {
  const candidates = [
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\Deng.ttf',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader('SplashCJK')..addFont(
      Future<ByteData>.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
      ),
    );
    await loader.load();
    return;
  }
}

/// 把开屏动画逐帧导出成 raw RGBA，用于合成 GIF 预览。
///
/// 用法：
///   flutter test tool/splash_gif_frames.dart --no-pub
///   python build/gif_encode.py build/splash_gif build/splash-preview.gif
///
/// 放在 tool/ 而不是 test/：它每次跑会写几十 MB 原始帧，
/// 不该混进常规 `flutter test`。
void main() {
  testWidgets('dump splash frames for gif', (tester) async {
    await _loadCjkFont();
    const width = 640;
    const height = 360;
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final outDir = Directory('build/splash_gif');
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    outDir.createSync(recursive: true);

    final key = GlobalKey();
    final ready = ValueNotifier<bool>(false);
    addTearDown(ready.dispose);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Theme(
          data: ThemeData(fontFamily: 'SplashCJK'),
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'SplashCJK', color: Colors.white),
            child: RepaintBoundary(
              key: key,
              child: AppSplash(
                ready: ready,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    var index = 0;
    Future<void> dump(int delayMs) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final bytes = data!.buffer.asUint8List();
      final header = BytesBuilder()
        ..add(const [0x47, 0x59, 0x46, 0x52]) // GYFR
        ..add((ByteData(4)..setUint32(0, width, Endian.little)).buffer.asUint8List())
        ..add((ByteData(4)..setUint32(0, height, Endian.little)).buffer.asUint8List())
        ..add((ByteData(4)..setUint32(0, delayMs, Endian.little)).buffer.asUint8List());
      final file = File('${outDir.path}/f_${index.toString().padLeft(3, '0')}.raw');
      file.writeAsBytesSync(header.toBytes() + bytes);
      index++;
    }

    // 入场：每 50ms 一帧，铺满 0–1600ms。
    await dump(50);
    var elapsed = 0;
    for (var t = 50; t <= 1600; t += 50) {
      await tester.pump(Duration(milliseconds: t - elapsed));
      elapsed = t;
      await dump(50);
    }
    // 环境动效：每 150ms 一帧，看水波与星闪。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
      await dump(150);
    }
    // ignore: avoid_print
    print('dumped $index frames');
  });
}
