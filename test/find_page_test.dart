import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/core/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 「找剧」页（0.7.31）的合成站源：三部剧分别覆盖
/// 连载中 + 新上架、已完结 + 老片、无上线日期三种情况。
class FindRepository extends FixtureRepository {
  static const urban = Drama(
    id: 'hongguo:find:urban',
    source: 'hongguo',
    title: '都市一哥',
    episodes: 46,
    category: '都市',
    views: '997万',
    onlineDate: '2026-10-25',
    releaseStatus: 'ongoing',
    tags: ['逆袭', '战神'],
  );
  static const costume = Drama(
    id: 'hongguo:find:costume',
    source: 'hongguo',
    title: '古装千金',
    episodes: 82,
    category: '古装',
    views: '2531万',
    onlineDate: '2026-06-01',
    releaseStatus: 'completed',
    tags: ['古装', '复仇'],
  );
  static const undated = Drama(
    id: 'hongguo:find:undated',
    source: 'hongguo',
    title: '无日期剧',
    episodes: 12,
    releaseStatus: 'ongoing',
    tags: ['逆袭'],
  );

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage([]);

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory.all,
    CatalogCategory('urban', '都市'),
    CatalogCategory('costume', '古装'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage([urban, costume, undated], page: page);
}

void main() {
  Future<LocalStore> mount(
    WidgetTester tester,
    FindRepository repository, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setSource('hongguo');
    await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> openFind(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
  }

  testWidgets('find page shows its own title, submit button and collapsed '
      'filter summary', (tester) async {
    await mount(tester, FindRepository());
    await openFind(tester);
    // 标题 + 底部标签各一处（0.7.33：找剧升级成和「追剧」平级的标签页）。
    expect(find.text('找剧'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('find-submit')), findsOneWidget);
    expect(find.text('筛选：'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('展开筛选'), findsOneWidget);
    // 未展开时面板不存在。
    expect(find.byKey(const ValueKey('find-filters')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toggle-filters')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-filters')), findsOneWidget);
    // 只摆站源真有的维度：体裁 / 推荐 / 状态 / 时间 / 标签。
    for (final label in ['体裁', '状态', '时间', '标签']) {
      expect(find.text(label), findsOneWidget);
    }
    // 「推荐」同时是底部导航的标签名，这里只要求至少出现两次。
    expect(find.text('推荐'), findsWidgets);
    expect(find.text('收起'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('find page is standalone: recommendation header is gone, back '
      'returns to recommendation', (tester) async {
    await mount(tester, FindRepository());
    await openFind(tester);
    // 独立页面：推荐页顶栏那一排（排序 / 榜单 / 搜索图标）必须整体消失，
    // 否则视觉上就是「推荐页上加了一个搜索框」。
    expect(find.byKey(const ValueKey('catalog-sort')), findsNothing);
    expect(find.byKey(const ValueKey('open-rankings')), findsNothing);
    expect(find.byKey(const ValueKey('toggle-search')), findsNothing);
    // 页面自己带返回。
    expect(find.byKey(const ValueKey('find-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('find-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-submit')), findsNothing);
    expect(find.text('展开筛选'), findsNothing);
    expect(find.byKey(const ValueKey('toggle-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('find page behaves like any other tab', (tester) async {
    await mount(tester, FindRepository());
    // 底部导航里占一个位置，和「追剧」同级（0.7.33）。
    expect(find.text('找剧'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-submit')), findsOneWidget);
    // 切走再切回来：搜索词不残留（与返回按钮同一套清理）。
    await tester.enterText(find.byType(TextField).first, '都市');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom-nav-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-submit')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bottom-nav-1')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('status, recency and tag facets narrow the grid', (tester) async {
    await mount(tester, FindRepository());
    await openFind(tester);
    await tester.tap(find.byKey(const ValueKey('toggle-filters')));
    await tester.pumpAndSettle();
    expect(find.text('都市一哥'), findsOneWidget);
    expect(find.text('古装千金'), findsOneWidget);
    expect(find.text('无日期剧'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('facet-状态-finished')));
    await tester.pumpAndSettle();
    expect(find.text('古装千金'), findsOneWidget);
    expect(find.text('都市一哥'), findsNothing);
    expect(find.text('无日期剧'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('facet-状态-all')));
    await tester.pumpAndSettle();
    expect(find.text('都市一哥'), findsOneWidget);

    // 7 天内上新：没有上线日期的剧必须被排除，而不是混进来。
    await tester.tap(find.byKey(const ValueKey('facet-时间-7')));
    await tester.pumpAndSettle();
    expect(find.text('都市一哥'), findsOneWidget);
    expect(find.text('古装千金'), findsNothing);
    expect(find.text('无日期剧'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('facet-时间-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('facet-标签-复仇')));
    await tester.pumpAndSettle();
    expect(find.text('古装千金'), findsOneWidget);
    expect(find.text('都市一哥'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('find cards carry view and episode badges, recommend cards do not', (
    tester,
  ) async {
    await mount(tester, FindRepository());
    expect(find.text('共46集'), findsNothing);
    await openFind(tester);
    expect(find.text('997万'), findsOneWidget);
    expect(find.text('共46集'), findsOneWidget);
    expect(find.text('共82集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recommend entry is labelled 推荐 instead of 发现', (tester) async {
    await mount(tester, FindRepository());
    expect(find.text('推荐'), findsWidgets);
    expect(find.text('发现'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
