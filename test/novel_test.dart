import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/novel_detail_screen.dart';
import 'package:duanju_app/novel/novel_home_screen.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_reader_screen.dart';
import 'package:duanju_app/novel/novel_store.dart';

import 'fixtures.dart';

const _novel = Novel(
  id: '1234',
  source: 'biquge365',
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
class _NovelRepository extends FixtureRepository {
  int searches = 0;
  int detailRequests = 0;
  int contentCalls = 0;
  String lastQuery = '';

  @override
  Future<List<Novel>> novelSearch(String query) async {
    searches++;
    lastQuery = query;
    return const [_novel];
  }

  @override
  Future<NovelBook> novelDetail(String id) async {
    detailRequests++;
    return const NovelBook(novel: _novel, chapters: _chapters);
  }

  int localContentCalls = 0;
  int localChapterCalls = 0;

  @override
  Future<List<NovelChapterItem>> novelChapters(String id) async => _chapters;

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

  @override
  Future<NovelText> novelContent(String bookId, String chapterId) async {
    contentCalls++;
    return NovelText(
      bookId: bookId,
      chapterId: chapterId,
      title: '第1章 开局',
      paragraphs: const ['第一段正文文案', '第二段正文文案'],
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  // 加载态有无限循环的进度圈，不能用 pumpAndSettle。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NovelStore.instance.debugReset();
    // widget 测试里没有 path_provider 也没有真实文件 IO 的事件循环，
    // 把章节缓存整体关掉——正文直接走仓库，缓存相关逻辑由 Go 侧测。
    NovelLibrary.debugSetDir(null);
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
    await tester.pumpWidget(
      MaterialApp(
        // 0.7.64：模块页不放返回；0.7.66：二级导航改成四个分区，
        // 搜索收进右上角的放大镜，页头不再重复写模块名。
        home: NovelHomeScreen(repository: repository),
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

    expect(repository.searches, 1);
    expect(repository.lastQuery, '合成');
    expect(find.text('合成小说'), findsOneWidget);
  });

  testWidgets('详情页显示目录，点「开始阅读」进阅读器', (tester) async {
    final repository = _NovelRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelDetailScreen(novel: _novel, repository: repository),
      ),
    );
    await _settle(tester);

    expect(repository.detailRequests, 1);
    expect(find.text('共 3 章'), findsOneWidget);
    expect(find.text('第2章 出手'), findsOneWidget);

    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _settle(tester);

    expect(repository.contentCalls, 1);
    expect(find.text('第一段正文文案'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('阅读器：下一章切换章节并推进进度', (tester) async {
    final repository = _NovelRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: _novel,
          chapters: _chapters,
          repository: repository,
          initialIndex: 0,
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('第一段正文文案'), findsOneWidget);
    // 控件默认可见，底栏有「下一章」。
    await tester.tap(find.text('下一章').last);
    await _settle(tester);

    expect(repository.contentCalls, 2);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(NovelStore.instance.progressOf(_novel.key)!.chapterIndex, 1);
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
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderScreen(
          novel: local,
          chapters: _chapters,
          repository: repository,
        ),
      ),
    );
    await _settle(tester);

    expect(repository.localContentCalls, 1);
    expect(repository.contentCalls, 0);
    expect(find.text('本地正文文案'), findsOneWidget);
  });
}
