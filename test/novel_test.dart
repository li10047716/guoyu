import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';
import 'package:duanju_app/novel/booksource/book_source_store.dart';
import 'package:duanju_app/novel/booksource/novel_gateway.dart';
import 'package:duanju_app/novel/novel_detail_screen.dart';
import 'package:duanju_app/novel/novel_home_screen.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_reader_screen.dart';
import 'package:duanju_app/novel/novel_store.dart';

import 'fixtures.dart';

/// 书架 / 进度 / 分组这些纯 store 测试只需要一个稳定的 key，
/// 具体 id 长什么样无所谓；带 `bs.` 前缀是自定义书源书的形态。
const _novel = Novel(
  id: 'bs.test.book',
  source: 'bs:test',
  title: '合成小说',
  author: '合成作者',
  category: '玄幻',
  status: '连载中',
  chapters: 3,
);

const _chapters = [
  NovelChapterItem(index: 0, id: '100', title: '第1章 开局'),
  NovelChapterItem(index: 1, id: '101', title: '第2章 出手'),
  NovelChapterItem(index: 2, id: '102', title: '第3章 收网'),
];

/// 小说相关的合成仓库：短剧部分沿用 [FixtureRepository] 的空实现。
///
/// 0.7.85 起网文全部走自定义书源的规则引擎（[BookSourceEngine]），
/// 仓库只剩本地书那几个接口。
class _NovelRepository extends FixtureRepository {
  int localContentCalls = 0;
  int localChapterCalls = 0;

  @override
  Future<List<NovelChapterItem>> localNovelChapters(
    String libraryDir,
    String bookId,
  ) async {
    localChapterCalls++;
    return _chapters;
  }

  @override
  Future<NovelText> localNovelText(
    String libraryDir,
    String bookId,
    String chapterId,
  ) async {
    localContentCalls++;
    return NovelText(
      bookId: bookId,
      chapterId: chapterId,
      title: '第1章 开局',
      paragraphs: const ['本地正文文案'],
    );
  }
}

/// 规则引擎的替身：不联网，直接返回合成的书。
class _FakeEngine extends BookSourceEngine {
  _FakeEngine();

  /// 详情返回的目录，默认用常量那份（widget 测试里会替换成编码后的 id）。
  List<NovelChapterItem> toc = _chapters;

  /// 详情返回的书；测试里换成带真实 `bs.` id 的那本，否则阅读器解不出章节地址。
  Novel? book;

  /// 正文段落；分页测试里换成长文本以撑出多页。
  List<String> paragraphs = const ['第一段正文文案', '第二段正文文案'];

  int searches = 0;
  int detailCalls = 0;
  int contentCalls = 0;
  String lastQuery = '';

  @override
  Future<List<Novel>> search(
    BookSource source,
    String query, {
    int page = 1,
  }) async {
    searches++;
    lastQuery = query;
    return const [_novel];
  }

  @override
  Future<NovelBook> detail(BookSource source, String bookUrl) async {
    // ignore: avoid_print
    detailCalls++;
    return NovelBook(novel: book ?? _novel, chapters: toc);
  }

  @override
  Future<List<Novel>> explore(
    BookSource source,
    String entryUrl, {
    int page = 1,
  }) async => const [];

  @override
  Future<NovelText> content(
    BookSource source,
    String bookId,
    String chapterUrl,
  ) async {
    contentCalls++;
    return NovelText(
      bookId: bookId,
      chapterId: chapterUrl,
      title: '第1章 开局',
      paragraphs: paragraphs,
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  // 加载态有无限循环的进度圈，不能用 pumpAndSettle。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 一个最小可用的自定义书源（带发现入口），测试里注册后 key 由地址算出来。
const String _testSourceJson =
    '[{"bookSourceName":"🧪测试源","bookSourceUrl":"https://example.com",'
    '"searchUrl":"/search?q={{key}}",'
    '"ruleSearch":{"bookList":"ul.list li","name":"@text",'
    '"bookUrl":"a@href"},'
    '"exploreUrl":"📊 榜单::\\n🔥 推荐榜::https://example.com?t=rank",'
    '"ruleToc":{"chapterList":"dl dd","chapterName":"@text",'
    '"chapterUrl":"a@href"},'
    '"ruleContent":{"content":"#txt"}}]';

Future<BookSource> _seedSource() async {
  await BookSourceStore.instance.importText(_testSourceJson);
  return BookSourceStore.instance.usableSources.single;
}

/// 自定义书源的章节 id 也是 `bs.` 编码的（规则引擎把每章地址编进 id），
/// widget 测试里要按同样的形态造目录，否则网关解不出章节地址。
List<NovelChapterItem> _chaptersOf(BookSource source) => [
  for (var index = 0; index < _chapters.length; index++)
    NovelChapterItem(
      index: index,
      id: BookSourceIds.encode(
        source.key,
        'https://example.com/book/1/${_chapters[index].id}.html',
      ),
      title: _chapters[index].title,
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NovelStore.instance.debugReset();
    // widget 测试里没有 path_provider 也没有真实文件 IO 的事件循环，
    // 把章节缓存整体关掉——正文直接走仓库，缓存相关逻辑由 Go 侧测。
    NovelLibrary.debugSetDir(null);
    // 书源清单同样不落盘，每个用例从空开始。
    BookSourceStore.instance.debugSetDir(null);
  });

  test('书架与阅读进度落盘后能恢复', () async {
    await NovelStore.instance.ensureLoaded();
    await NovelStore.instance.addToShelf(_novel);
    expect(NovelStore.instance.inShelf(_novel.key), isTrue);

    await NovelStore.instance.saveProgress(
      _novel,
      NovelProgress(
        chapterId: '101',
        chapterIndex: 1,
        offset: 128,
        updatedAt: DateTime(2026, 10, 29),
      ),
    );
    expect(NovelStore.instance.progressOf(_novel.key)!.chapterIndex, 1);

    // 冷启动：内存清空，重新从磁盘读。
    NovelStore.instance.debugReset();
    await NovelStore.instance.ensureLoaded();
    expect(NovelStore.instance.shelf, hasLength(1));
    final progress = NovelStore.instance.progressOf(_novel.key);
    expect(progress!.chapterId, '101');
    expect(progress.offset, 128);

    await NovelStore.instance.removeFromShelf(_novel.key);
    expect(NovelStore.instance.inShelf(_novel.key), isFalse);
  });

  test('阅读设置独立持久化', () async {
    await NovelStore.instance.ensureLoaded();
    await NovelStore.instance.saveSettings(
      NovelStore.instance.settings.copyWith(
        fontScale: 1.4,
        lineHeight: 2,
        theme: NovelReaderTheme.paper,
      ),
    );
    NovelStore.instance.debugReset();
    await NovelStore.instance.ensureLoaded();
    expect(NovelStore.instance.settings.fontScale, 1.4);
    expect(NovelStore.instance.settings.theme, NovelReaderTheme.paper);
  });

  testWidgets('小说界面：书架 → 右上搜索 → 结果列表，没有返回按钮', (tester) async {
    final repository = _NovelRepository();
    await _seedSource();
    final engine = _FakeEngine();
    await tester.pumpWidget(
      MaterialApp(
        // 0.7.64：模块页不放返回；0.7.66：二级导航改成四个分区，
        // 搜索收进右上角的放大镜，页头不再重复写模块名。
        home: NovelHomeScreen(
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('书架'), findsWidgets);
    expect(find.text('书架还是空的'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await tester.tap(find.byKey(const ValueKey('novel-search-open')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('novel-search-field')),
      '合成',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);

    expect(engine.searches, 1);
    expect(engine.lastQuery, '合成');
    expect(find.text('合成小说'), findsOneWidget);
  });

  testWidgets('搜索面板：没有书源时拦住搜索并提示去导入', (tester) async {
    final repository = _NovelRepository();
    final engine = _FakeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelHomeScreen(
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('novel-search-open')));
    await _settle(tester);

    // 0.7.85：内置源移除后，一个源都没有时只剩这句提示。
    expect(find.byKey(const ValueKey('novel-search-source-native')), findsNothing);
    expect(find.text('还没有可用的书源，先到「我的 → 书源」导入'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('novel-search-field')),
      '合成',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);

    // 没有可用源时不该发请求，而是提示先导入。
    expect(engine.searches, 0);
    expect(find.text('还没有可用的书源，先在「我的 → 书源」里导入'), findsOneWidget);
  });

  testWidgets('搜索面板：有自定义源时列出源胶囊', (tester) async {
    final repository = _NovelRepository();
    final source = await _seedSource();
    final engine = _FakeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelHomeScreen(
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('novel-search-open')));
    await _settle(tester);
    expect(
      find.byKey(ValueKey('novel-search-source-${source.key}')),
      findsOneWidget,
    );
    expect(find.text('当前搜索范围：1 个自定义源'), findsOneWidget);
  });

  testWidgets('发现页能列出带发现规则的自定义书源', (tester) async {
    final source = await _seedSource();

    final repository = _NovelRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelHomeScreen(
          repository: repository,
          gateway: NovelGateway(engine: _FakeEngine()),
        ),
      ),
    );
    await _settle(tester);

    // 窄屏走顶部胶囊，宽屏走左侧导航栏，两种 key 都认。
    final tab = find.byKey(const ValueKey('novel-section-discover-chip'));
    await tester.tap(
      tab.evaluate().isNotEmpty
          ? tab
          : find.byKey(const ValueKey('novel-section-discover')),
    );
    await _settle(tester);

    // 0.7.85：内置源已移除，切源条上只剩自定义源。
    expect(find.byKey(const ValueKey('discover-source-native')), findsNothing);
    // 只有一个源时不出切源条，但源名会作为分区标题出现。
    expect(find.text('🧪测试源 · 发现'), findsOneWidget);
    expect(source.name, '🧪测试源');
  });

  testWidgets('详情页显示目录，点「开始阅读」进阅读器', (tester) async {
    final repository = _NovelRepository();
    // 0.7.85：网文走自定义书源，id 得带 `bs.` 前缀才能解出源和地址。
    final source = await _seedSource();
    final novel = Novel(
      id: BookSourceIds.encode(source.key, 'https://example.com/book/1'),
      source: source.sourceTag,
      title: '合成小说',
      author: '合成作者',
      chapters: 3,
    );
    final engine = _FakeEngine();
    engine.toc = _chaptersOf(source);
    engine.book = novel;
    final gateway = NovelGateway(engine: engine);
    await tester.pumpWidget(
      MaterialApp(
        home: NovelDetailScreen(
          novel: novel,
          repository: repository,
          gateway: gateway,
        ),
      ),
    );
    await _settle(tester);

    expect(engine.detailCalls, 1);
    expect(find.text('共 3 章'), findsOneWidget);
    expect(find.text('第2章 出手'), findsOneWidget);

    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _settle(tester);

    // ignore: avoid_print
    expect(engine.contentCalls, 1);
    // 0.7.86：正文改成 CustomPaint 按行窗口绘制（精确分页），不再是 Text，
    // 所以这里验证分页容器 + 底栏的章节进度文案。
    expect(find.byKey(const ValueKey('novel-page-view')), findsOneWidget);
    expect(find.textContaining('第 1 章'), findsOneWidget);
  });

  testWidgets('阅读器：下一章切换章节并推进进度', (tester) async {
    final repository = _NovelRepository();
    final source = await _seedSource();
    final engine = _FakeEngine();
    final chapters = _chaptersOf(source);
    final novel = Novel(
      id: BookSourceIds.encode(source.key, 'https://example.com/book/1'),
      source: source.sourceTag,
      title: '合成小说',
      chapters: 3,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: novel,
          chapters: chapters,
          repository: repository,
          initialIndex: 0,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byKey(const ValueKey('novel-page-view')), findsOneWidget);
    // 0.7.86：进入阅读页就是沉浸态，先点屏幕中间呼出底栏。
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('novel-page-view'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一章').last);
    await _settle(tester);

    expect(engine.contentCalls, 2);
    expect(find.textContaining('第 2 章'), findsOneWidget);
    expect(NovelStore.instance.progressOf(novel.key)!.chapterIndex, 1);
  });
  testWidgets('分页阅读：点右侧翻下一页，点左侧翻回上一页', (tester) async {
    final repository = _NovelRepository();
    final source = await _seedSource();
    final engine = _FakeEngine()
      ..paragraphs = List.generate(
        30,
        (i) => '这是第 $i 段正文，长度足够把一章撑成好几页。' * 3,
      );
    final chapters = _chaptersOf(source);
    final novel = Novel(
      id: BookSourceIds.encode(source.key, 'https://example.com/book/1'),
      source: source.sourceTag,
      title: '合成小说',
      chapters: 3,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: novel,
          chapters: chapters,
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    String barLabel() {
      final widget = tester.widget<Text>(find.textContaining('页 · 第'));
      return widget.data ?? '';
    }

    // 默认就是分页模式，底栏显示「1/N 页 · 第 1 章」。
    expect(barLabel(), startsWith('1/'));
    expect(barLabel(), endsWith('第 1 章'));

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    // 点右侧三分之一：下一页。
    await tester.tapAt(Offset(size.width * .85, size.height * .4));
    await tester.pumpAndSettle();
    expect(barLabel(), startsWith('2/'));

    // 点左侧三分之一：回上一页。
    await tester.tapAt(Offset(size.width * .1, size.height * .4));
    await tester.pumpAndSettle();
    expect(barLabel(), startsWith('1/'));
  });

  testWidgets('手机竖屏 360x780 下分页正常，无布局溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _NovelRepository();
    final source = await _seedSource();
    final engine = _FakeEngine()
      ..paragraphs = List.generate(
        20,
        (i) => '这是手机上用来验证分页的第 $i 段正文，长度足够跨好几页。' * 4,
      );
    final chapters = _chaptersOf(source);
    final novel = Novel(
      id: BookSourceIds.encode(source.key, 'https://example.com/book/1'),
      source: source.sourceTag,
      title: '合成小说',
      chapters: 3,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: novel,
          chapters: chapters,
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    // 窄屏上必定排成多页；有 RenderFlex 溢出会在这里抛出来。
    expect(tester.takeException(), isNull);
    final label = tester
        .widget<Text>(find.textContaining('页 · 第'))
        .data!;
    final pages = RegExp(r'/(\d+) 页').firstMatch(label)!.group(1)!;
    expect(int.parse(pages), greaterThan(1));
    expect(label, endsWith('第 1 章'));
  });

  test('老阅读设置自动升级为左右翻页，带版本号后尊重用户选择', () {
    // 0.7.85 之前的存档：没有 layoutVersion，pageMode=scroll。
    final legacy = NovelReaderSettings.fromJson({
      'fontScale': 1.2,
      'pageMode': 'scroll',
    });
    expect(legacy.pageMode, NovelPageMode.slide);
    expect(legacy.fontScale, closeTo(1.2, .001), reason: '其余设置要保留');

    // 已经是新版结构：用户手动选回滚动就照办。
    final current = NovelReaderSettings.fromJson({
      'pageMode': 'scroll',
      'layoutVersion': NovelReaderSettings.layoutVersion,
    });
    expect(current.pageMode, NovelPageMode.scroll);
  });

  test('自定义分组：归档、删除分组后书回到全部', () async {
    final store = NovelStore.instance;
    await store.ensureLoaded();
    await store.addToShelf(_novel);
    final group = await store.createGroup('在追');
    expect(store.groups, hasLength(1));
    expect(group.name, '在追');

    await store.addToGroup(_novel.key, group.id);
    expect(store.entriesInGroup(group.id), hasLength(1));

    // 重命名
    await store.renameGroup(group.id, '追更中');
    expect(store.groups.single.name, '追更中');

    // 删分组不删书
    await store.removeGroup(group.id);
    expect(store.groups, isEmpty);
    expect(store.shelf, hasLength(1));
    expect(store.entryOf(_novel.key)!.groups, isEmpty);
  });

  test('新章红点：章节变多点亮，看过详情后熄灭', () async {
    final store = NovelStore.instance;
    await store.ensureLoaded();
    await store.addToShelf(_novel);
    expect(store.entryOf(_novel.key)!.knownChapters, 3);
    expect(store.entryOf(_novel.key)!.hasUpdates, isFalse);

    // 站点多了一章，但用户还没看详情页。
    await store.markChapters(_novel.key, 4);
    final entry = store.entryOf(_novel.key)!;
    expect(entry.novel.chapters, 4);
    expect(entry.hasUpdates, isTrue);

    // 打开过详情页：红点消失。
    await store.markChapters(_novel.key, 4, seen: true);
    expect(store.entryOf(_novel.key)!.hasUpdates, isFalse);

    // 批量移除
    await store.removeMany([_novel.key]);
    expect(store.shelf, isEmpty);
  });

  test('阅读设置新增字段（翻页 / 字体 / 亮度）能持久化', () async {
    final store = NovelStore.instance;
    await store.ensureLoaded();
    await store.saveSettings(
      store.settings.copyWith(
        pageMode: NovelPageMode.slide,
        fontFamily: NovelFontFamily.kai,
        brightness: .6,
        backgroundImage: '/tmp/bg.jpg',
      ),
    );
    store.debugReset();
    await store.ensureLoaded();
    final settings = store.settings;
    expect(settings.pageMode, NovelPageMode.slide);
    expect(settings.fontFamily, NovelFontFamily.kai);
    expect(settings.brightness, closeTo(.6, .001));
    expect(settings.backgroundImage, '/tmp/bg.jpg');

    // 清背景图
    await store.saveSettings(settings.copyWith(clearBackgroundImage: true));
    expect(store.settings.backgroundImage, isNull);
  });

  testWidgets('本地书：正文走本地读取，不走网络', (tester) async {
    const local = Novel(
      id: 'abc123',
      source: 'local',
      title: '本地小说',
      chapters: 3,
    );
    final repository = _NovelRepository();
    final engine = _FakeEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: local,
          chapters: _chapters,
          repository: repository,
          gateway: NovelGateway(engine: engine),
        ),
      ),
    );
    await _settle(tester);

    expect(repository.localContentCalls, 1);
    // 本地书不碰规则引擎。
    expect(engine.contentCalls, 0);
    expect(find.byKey(const ValueKey('novel-page-view')), findsOneWidget);
  });
}
