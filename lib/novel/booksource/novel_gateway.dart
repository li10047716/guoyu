/// 小说数据入口：网文全部走自定义书源的本地规则引擎（0.7.85）。
///
/// 书籍 ID 以 `bs.` 开头时说明来自自定义书源；不带这个前缀的旧 ID 属于
/// 0.7.85 之前的内置笔趣阁源，那个源已经整体移除，所以这里直接报「已失效」
/// 而不是再去请求网络。本地导入的书不走这个类（由详情页直接读核心的索引）。
library;

import 'package:flutter/foundation.dart';

import '../../core/core_bridge.dart';
import '../../core/novel_models.dart';
import 'book_source.dart';
import 'book_source_engine.dart';
import 'book_source_store.dart';
import 'legado_script.dart';

/// 搜索结果里来自某个书源的失败信息（界面可选展示）。
class BookSourceFailure {
  const BookSourceFailure(this.sourceName, this.message);

  final String sourceName;
  final String message;
}

class NovelGateway {
  NovelGateway({
    BookSourceStore? store,
    this.engine = const BookSourceEngine(),
  }) : store = store ?? BookSourceStore.instance;

  final BookSourceStore store;
  final BookSourceEngine engine;

  /// 最近一次搜索里失败的书源，便于界面提示「某些源没返回」。
  final List<BookSourceFailure> lastFailures = [];

  /// 最近一次搜索实际用到的书源名，界面用来提示「搜了哪些源」。
  final List<String> lastSources = [];

  /// 内置源移除后，旧书架/旧搜索结果里残留的书会走到这里。
  static const String removedNativeHint =
      '这本书来自已移除的内置书源，请用自定义书源重新搜索一次';

  /// 搜索：只搜自定义书源。
  ///
  /// [customKeys] 为 null 表示所有启用且可用的源，否则只搜其中这些 key。
  Future<List<Novel>> search(String query, {Set<String>? customKeys}) async {
    lastFailures.clear();
    lastSources.clear();
    final results = <Novel>[];

    await store.ensureLoaded();
    final sources = store.usableSources
        .where((source) => customKeys == null || customKeys.contains(source.key))
        .toList(growable: false);
    if (sources.isEmpty) return results;

    lastSources.addAll(sources.map((source) => source.name));
    final batches = await Future.wait([
      for (final source in sources) _searchOne(source, query),
    ]);
    for (final batch in batches) {
      results.addAll(batch);
    }
    return results;
  }

  Future<List<Novel>> _searchOne(BookSource source, String query) async {
    try {
      return await engine
          .search(source, query)
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      lastFailures.add(BookSourceFailure(source.name, _short(error)));
      return const [];
    }
  }

  /// 详情（含目录）。
  Future<NovelBook> detail(String id) async {
    final target = BookSourceIds.decode(id);
    if (target == null) throw AppFailure(removedNativeHint);
    final source = await _require(target.key);
    return engine.detail(source, target.url);
  }

  /// 目录。
  Future<List<NovelChapterItem>> chapters(String id) async {
    final target = BookSourceIds.decode(id);
    if (target == null) throw AppFailure(removedNativeHint);
    final source = await _require(target.key);
    final book = await engine.detail(source, target.url);
    return book.chapters;
  }

  /// 正文。
  Future<NovelText> content(String bookId, String chapterId) async {
    final target = BookSourceIds.decode(chapterId);
    if (target == null) throw AppFailure(removedNativeHint);
    final source = await _require(target.key);
    return engine.content(source, bookId, target.url);
  }

  /// 发现：按自定义书源 `exploreUrl` 的某个条目拉一页书。
  Future<List<Novel>> explore(
    String sourceKey,
    String entryUrl, {
    int page = 1,
  }) async {
    final source = await _require(sourceKey);
    return engine
        .explore(source, entryUrl, page: page)
        .timeout(const Duration(seconds: 25));
  }

  /// 自定义书源里带「发现」入口的（可用于发现页的源切换）。
  ///
  /// 0.7.83：`exploreUrl` 写成脚本的源也算——它虽然同步解析不出条目，
  /// 但求值后能拿到分类，不该被排除在发现源之外。
  Future<List<BookSource>> exploreSources() async {
    await store.ensureLoaded();
    return store.usableSources
        .where(
          (source) =>
              source.exploreIsScript ||
              source.exploreEntries.any((e) => !e.isHeader),
        )
        .toList(growable: false);
  }

  /// 取某个源的发现条目。
  ///
  /// 纯文本 `exploreUrl` 直接同步解析；脚本形式（`@js:` / `<js>`）交给
  /// 原生 JS 运行时求值，再把返回的 JSON 数组 / 文本列表转成条目。
  Future<List<BookSourceExploreEntry>> exploreEntries(
    BookSource source,
  ) async {
    if (!source.exploreIsScript) return source.exploreEntries;
    final code = BookSourceExploreEntry.scriptCode(source.exploreUrl);
    if (code.isEmpty) return const [];
    try {
      final result = await LegadoScript.run(
        source,
        code,
        baseUrl: source.url,
      );
      return BookSourceExploreEntry.parseResolved(result.value);
    } catch (error) {
      debugPrint('发现页脚本求值失败（${source.name}）：$error');
      return const [];
    }
  }

  Future<BookSource> _require(String key) async {
    await store.ensureLoaded();
    final source = store.byKey(key);
    if (source == null) {
      throw AppFailure('书源已被删除，无法打开这本书');
    }
    if (!source.status.usable) {
      throw AppFailure('这个书源当前不可用：${source.statusDetail}');
    }
    return source;
  }

  String _short(Object error) {
    final text = '$error';
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }
}
