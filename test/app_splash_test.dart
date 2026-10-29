import 'package:duanju_app/ui/app_splash.dart';
import 'package:duanju_app/ui/splash_scene.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ValueListenable<bool> ready) => MaterialApp(
  home: AppSplash(ready: ready, child: const Text('MAIN')),
);

/// 0.7.60：口号是两行题字卡（小字行 + 鎏金主行），按两段文本断言。
List<Finder> get _sloganFinders => [
  find.text('你的娱乐宇宙'),
  find.text('自成一岛'),
];

void main() {
  testWidgets('首页始终未就绪时，超过 timeout 必须强制淡出', (tester) async {
    final ready = ValueNotifier<bool>(false);
    await tester.pumpWidget(_wrap(ready));

    for (final f in _sloganFinders) {
      expect(f, findsOneWidget);
    }

    await tester.pump(const Duration(milliseconds: 2900));
    for (final f in _sloganFinders) {
      expect(f, findsOneWidget, reason: '未到 3 秒仍应停留在开屏页');
    }

    // 3000ms 触发淡出，还要等 240ms 淡完才整块移除。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    for (final f in _sloganFinders) {
      expect(
        f,
        findsNothing,
        reason: '首页一条剧都没拉回来时，也必须在超时后放行，否则用户永远进不去',
      );
    }
    expect(find.text('MAIN'), findsOneWidget);
    ready.dispose();
  });

  testWidgets('入场动画没播完不淡出，播完后立即让位', (tester) async {
    final ready = ValueNotifier<bool>(false);
    await tester.pumpWidget(_wrap(ready));

    ready.value = true;
    // 最短展示时长与入场动画对齐，否则用户只看到半截动画（0.7.52：1600ms）。
    await tester.pump(const Duration(milliseconds: 800));
    for (final f in _sloganFinders) {
      expect(f, findsOneWidget, reason: '动画进行中不能淡出');
    }

    await tester.pump(splashIntroDuration);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    for (final f in _sloganFinders) {
      expect(f, findsNothing);
    }
    ready.dispose();
  });

  testWidgets('首帧就尚未就绪时，停留段之后才补出进度环', (tester) async {
    final ready = ValueNotifier<bool>(false);
    await tester.pumpWidget(_wrap(ready));

    final progress = find.byKey(const ValueKey('splash-progress'));
    expect(progress, findsOneWidget);
    expect(
      tester.widget<AnimatedOpacity>(progress).opacity,
      0,
      reason: '入场时不显示进度环，避免破坏节奏',
    );

    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.widget<AnimatedOpacity>(progress).opacity,
      1,
      reason: '入场播完还没就绪，要让用户看到"在等"',
    );
    ready.dispose();
  });
}
