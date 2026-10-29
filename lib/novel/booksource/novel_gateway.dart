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

  /// 搜索：内置站源 + 所有启用的自定义书源。
  Future<List<Novel>> search(String query, {bool includeCustom = true}) async {
    lastFailures.clear();
    final results = <Novel>[];

    try {
      results.addAll(await native.novelSearch(query));
    } catch (error) {
      debugPrint('内置源搜索失败：$error');
    }

    if (includeCustom) {
      await store.ensureLoaded();
      final sources = store.usableSources;
      if (sources.isNotEmpty) {
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

  Future<BookSource> _require(String key) async {
    await store.ensureLoaded();
    final source = store.byKey(key);
    if (source == null) {
      throw AppFailure('书源已被删除，无法打开这本书');
    }
    if (!source.status.usable) {
      throw AppFailure('这个书源需要 JS 引擎，当前版本跑不了');
    }
    return source;
  }

  String _short(Object error) {
    final text = '$error';
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }
}
