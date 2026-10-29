import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/main.dart';

import 'fixtures.dart';

/// 0.7.63（用户要求）：页面底端加一行「看剧 / 小说 / 听歌」，
/// 点按钮切换到对应模块的整屏界面。
///
/// 切换条是三个模块**唯一**的入口，所以它必须常驻：
/// 进小说/听歌之后不能像 0.7.62 那样连底端一起消失，否则只能靠 ← 返回。
Future<void> _pumpApp(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final local = LocalStore(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    DuanjuApp(repository: FixtureRepository(), store: local),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('桌面：底端切换条切到小说，侧栏收起，切回看剧恢复', (tester) async {
    await _pumpApp(tester, const Size(1280, 800));

    // 看剧界面：左侧栏在（榜单入口是侧栏独有的 key），底端切换条也在。
    expect(find.byKey(const ValueKey('open-rankings')), findsOneWidget);
    expect(find.byKey(const ValueKey('module-watch')), findsOneWidget);
    expect(find.byKey(const ValueKey('module-novel')), findsOneWidget);
    expect(find.byKey(const ValueKey('module-music')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('module-novel')));
    await tester.pumpAndSettle();

    expect(find.text('书架还是空的'), findsOneWidget);
    // 侧栏整体收起——看剧的导航不留在小说界面上。
    expect(find.byKey(const ValueKey('open-rankings')), findsNothing);
    expect(find.byKey(const ValueKey('rail-sources')), findsNothing);
    // 但模块切换条还在（这是三个模块唯一的切换入口）。
    expect(find.byKey(const ValueKey('module-watch')), findsOneWidget);
    // 0.7.64（用户要求）：模块页不放返回按钮，切换只认底端这三个。
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await tester.tap(find.byKey(const ValueKey('module-watch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('open-rankings')), findsOneWidget);
  });

  testWidgets('手机：切换条在底栏下方，切小说后底栏收起，切回看剧恢复', (tester) async {
    await _pumpApp(tester, const Size(390, 844));

    expect(find.byKey(const ValueKey('bottom-nav-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('module-novel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('module-novel')));
    await tester.pumpAndSettle();

    expect(find.text('书架还是空的'), findsOneWidget);
    // 看剧的 5 格底栏收起，模块切换条留下。
    expect(find.byKey(const ValueKey('bottom-nav-0')), findsNothing);
    expect(find.byKey(const ValueKey('module-watch')), findsOneWidget);

    // 0.7.65（用户要求）：模块里按系统返回键不再回看剧，等于没反应。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('书架还是空的'), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-nav-0')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('module-watch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bottom-nav-0')), findsOneWidget);
  });

  testWidgets('手机：听歌是独立屏，能切回看剧', (tester) async {
    await _pumpApp(tester, const Size(390, 844));

    await tester.tap(find.byKey(const ValueKey('module-music')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('music-placeholder')), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-nav-0')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('module-watch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bottom-nav-0')), findsOneWidget);
  });

  testWidgets('从「找剧」进小说，切回看剧仍停在找剧', (tester) async {
    await _pumpApp(tester, const Size(1280, 800));

    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    // 找剧页的搜索按钮（key 只在这一页出现）。
    expect(find.byKey(const ValueKey('find-submit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('module-novel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('module-watch')));
    await tester.pumpAndSettle();

    // 回到进入前的标签，而不是固定跳回推荐页。
    expect(find.byKey(const ValueKey('find-submit')), findsOneWidget);
  });
}
