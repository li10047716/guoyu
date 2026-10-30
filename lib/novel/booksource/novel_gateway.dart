/// 小说数据入口：内置站源走 Go 核心，自定义书源走本地规则引擎（0.7.68）。
///
/// 书籍 ID 以 `bs.` 开头时说明是自定义书源的书，其余一律转给原仓库。
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
  NovelGateway(
    this.native, {
    BookSourceStore? store,
    this.engine = const BookSourceEngine(),
  }) : store = store ?? BookSourceStore.instance;

  final AppRepository native;
  final BookSourceStore store;
  final BookSourceEngine engine;

  /// 最近一次搜索里失败的书源，便于界面提示「某些源没返回」。
  final List<BookSourceFailure> lastFailures = [];

  /// 最近一次搜索实际用到的书源名（内置 + 自定义），界面用来提示「搜了哪些源」。
  final List<String> lastSources = [];

  /// 搜索：内置站源 + 选中的自定义书源。
  ///
  /// [includeNative] 为假时不打内置源；[customKeys] 为 null 表示所有启用且可用的
  /// 自定义源，否则只搜其中这些 key。
  Future<List<Novel>> search(
    String query, {
    bool includeCustom = true,
    bool includeNative = true,
    Set<String>? customKeys,
  }) async {
    lastFailures.clear();
    lastSources.clear();
    final results = <Novel>[];

    if (includeNative) {
      lastSources.add('内置');
      try {
        results.addAll(await native.novelSearch(query));
      } catch (error) {
        debugPrint('内置源搜索失败：$error');
      }
    }

    if (includeCustom) {
      await store.ensureLoaded();
      final sources = store.usableSources
          .where(
            (source) => customKeys == null || customKeys.contains(source.key),
          )
          .toList(growable: false);
      if (sources.isNotEmpty) {
        lastSources.addAll(sources.map((source) => source.name));
        final batches = await Future.wait([
          for (final source in sources) _searchOne(source, query),
        ]);
        for (final batch in batches) {
          results.addAll(batch);
        }
      }
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
    if (target == null) return native.novelDetail(id);
    final source = await _require(target.key);
    return engine.detail(source, target.url);
  }

  /// 目录。
  Future<List<NovelChapterItem>> chapters(String id) async {
    final target = BookSourceIds.decode(id);
    if (target == null) return native.novelChapters(id);
    final source = await _require(target.key);
    final book = await engine.detail(source, target.url);
    return book.chapters;
  }

  /// 正文。
  Future<NovelText> content(String bookId, String chapterId) async {
    final target = BookSourceIds.decode(chapterId);
    if (target == null) return native.novelContent(bookId, chapterId);
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
