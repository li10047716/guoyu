import 'dart:async';

import 'package:flutter/material.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/booksource/novel_gateway.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_reader_screen.dart';
import 'package:duanju_app/novel/novel_store.dart';

/// 小说详情页（0.7.61）：封面 / 作者 / 分类 / 简介 / 目录 / 开始阅读。
///
/// 0.7.67 起：本地导入的书走 [AppRepository.localNovelChapters]（不联网），
/// 远端书多一个「缓存整本」入口——缓存过的章节下次打开直接读磁盘。
class NovelDetailScreen extends StatefulWidget {
  const NovelDetailScreen({
    super.key,
    required this.novel,
    required this.repository,
    this.gateway,
  });

  final Novel novel;
  final AppRepository repository;

  /// 测试注入用；生产环境留空，自己建一个。
  final NovelGateway? gateway;

  @override
  State<NovelDetailScreen> createState() => _NovelDetailScreenState();
}

class _NovelDetailScreenState extends State<NovelDetailScreen> {
  late final NovelGateway _gateway = widget.gateway ?? NovelGateway();

  NovelBook? _book;
  String? _error;
  bool _loading = true;

  /// 章节缓存状态（只对远端书有意义）。
  int _cachedCount = 0;
  int _cachedBytes = 0;
  bool _caching = false;
  bool _cacheCancelled = false;
  int _cacheDone = 0;

  @override
  void initState() {
    super.initState();
    // 书架/进度是异步读盘的：订阅变更，加载完成后「续读 · 第 N 章」
    // 与「已在书架」才会正确显示。
    NovelStore.instance.addListener(_onStoreChanged);
    NovelStore.instance.ensureLoaded();
    _load();
    unawaited(_refreshCache());
  }

  @override
  void dispose() {
    _cacheCancelled = true;
    NovelStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final book = widget.novel.isLocal
          ? await _loadLocalBook()
          : await _gateway.detail(widget.novel.id);
      if (!mounted) return;
      setState(() {
        _book = book;
        _loading = false;
      });
      // 用户已经看过这一版目录，书架上的新章红点可以消掉。
      unawaited(
        NovelStore.instance.markChapters(
          book.novel.key,
          book.chapters.length,
          seen: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error'.replaceFirst('AppFailure: ', '');
        _loading = false;
      });
    }
  }

  /// 本地书：目录来自落盘的索引，不进网络。
  Future<NovelBook> _loadLocalBook() async {
    final dir = await NovelLibrary.localDir();
    final chapters = await widget.repository.localNovelChapters(
      dir,
      widget.novel.id,
    );
    return NovelBook(
      novel: widget.novel.copyWith(chapters: chapters.length),
      chapters: chapters,
    );
  }

  Future<void> _refreshCache() async {
    if (widget.novel.isLocal) return;
    final count = await NovelCache.count(widget.novel.key);
    final bytes = await NovelCache.size(widget.novel.key);
    if (!mounted) return;
    setState(() {
      _cachedCount = count;
      _cachedBytes = bytes;
    });
  }

  /// 缓存整本：三路并发逐章抓，随时可以停。
  ///
  /// 站点有限流，并发再高反而更容易被拦；3 路已经能把 1000 章压到
  /// 几分钟量级，同时保住每章的成功率。
  Future<void> _cacheAll() async {
    final book = _book;
    if (book == null || widget.novel.isLocal || _caching) return;
    setState(() {
      _caching = true;
      _cacheCancelled = false;
      _cacheDone = 0;
    });
    final chapters = book.chapters;
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor;
        cursor++;
        if (index >= chapters.length || _cacheCancelled || !mounted) return;
        final chapter = chapters[index];
        try {
          if (!await NovelCache.has(_novel.key, chapter.id)) {
            final text = await _gateway.content(
              widget.novel.id,
              chapter.id,
            );
            await NovelCache.write(_novel.key, text);
          }
        } catch (_) {
          // 单章失败不打断整本缓存，用户重跑时会补上。
        }
        if (!mounted || _cacheCancelled) return;
        setState(() => _cacheDone++);
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
    if (!mounted) return;
    setState(() => _caching = false);
    await _refreshCache();
  }

  Future<void> _clearCache() async {
    await NovelCache.clear(widget.novel.key);
    await _refreshCache();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('已清理这本书的缓存')));
  }

  Novel get _novel => _book?.novel ?? widget.novel;

  Future<void> _openReader(int index) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final target = index.clamp(0, book.chapters.length - 1);
    final progress = NovelStore.instance.progressOf(_novel.key);
    // 点了「继续阅读」就回到上次的章内位置。
    final resume = progress != null && progress.chapterIndex == target;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NovelReaderScreen(
          novel: _novel,
          chapters: book.chapters,
          repository: widget.repository,
          initialIndex: target,
          initialOffset: resume ? progress.offset : 0,
          gateway: _gateway,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleShelf() async {
    final store = NovelStore.instance;
    await store.ensureLoaded();
    if (store.inShelf(_novel.key)) {
      await store.removeFromShelf(_novel.key);
    } else {
      await store.addToShelf(_novel);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_novel.title, maxLines: 1)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 14),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _cover(colors),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _novel.title,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _novel.author.isEmpty ? '佚名' : _novel.author,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (_novel.isLocal)
                                _chip('本地导入', colors)
                              else if (_novel.category.isNotEmpty)
                                _chip(_novel.category, colors),
                              if (!_novel.isLocal && _novel.status.isNotEmpty)
                                _chip(_novel.status, colors),
                              _chip(
                                '${_book?.chapters.length ?? _novel.chapters} 章',
                                colors,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _actionRow(colors),
                if (!_novel.isLocal) ...[
                  const SizedBox(height: 10),
                  _cacheBar(colors),
                ],
                if (_novel.description.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text(
                    '简介',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  _Description(text: _novel.description),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    const Text(
                      '目录',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '共 ${_book?.chapters.length ?? 0} 章',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _openCatalog,
                      child: const Text('全部目录'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final chapter in (_book?.chapters ?? const []).take(30))
                      _chapterTile(chapter, colors),
                  ],
                ),
              ],
            ),
    );
  }

  /// 缓存整本的入口 + 进度（只对远端书显示）。
  Widget _cacheBar(ColorScheme colors) {
    final total = _book?.chapters.length ?? 0;
    final full = total > 0 && _cachedCount >= total;
    final label = _caching
        ? '正在缓存 $_cacheDone / $total 章'
        : full
        ? '已缓存全部 $total 章'
        : '已缓存 $_cachedCount / $total 章'
              '${_cachedBytes > 0 ? ' · ${_formatBytes(_cachedBytes)}' : ''}';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            full ? Icons.offline_pin_rounded : Icons.cloud_download_outlined,
            size: 18,
            color: full ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_caching) ...[
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total == 0 ? null : _cacheDone / total,
                      minHeight: 5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (_caching)
            TextButton(
              key: const ValueKey('novel-cache-stop'),
              onPressed: () => setState(() => _cacheCancelled = true),
              child: const Text('停止'),
            )
          else ...[
            TextButton(
              key: const ValueKey('novel-cache-all'),
              onPressed: total == 0 || full ? null : _cacheAll,
              child: Text(full ? '已完成' : '缓存整本'),
            ),
            if (_cachedCount > 0)
              IconButton(
                key: const ValueKey('novel-cache-clear'),
                tooltip: '清理缓存',
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                onPressed: _clearCache,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1 << 20) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Widget _cover(ColorScheme colors) {    final url = _novel.cover;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 108,
        height: 144,
        child: url.isEmpty
            ? _coverPlaceholder(colors)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _coverPlaceholder(colors),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _coverPlaceholder(colors),
              ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme colors) => Container(
    color: colors.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(
      Icons.menu_book_rounded,
      color: colors.onSurfaceVariant.withValues(alpha: .5),
    ),
  );

  Widget _chip(String label, ColorScheme colors) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
    ),
  );

  Widget _actionRow(ColorScheme colors) {
    final book = _book;
    final chapters = book?.chapters ?? const <NovelChapterItem>[];
    final progress = NovelStore.instance.progressOf(_novel.key);
    final hasProgress = progress != null && chapters.isNotEmpty;
    final resumeIndex = hasProgress
        ? progress.chapterIndex.clamp(0, chapters.length - 1)
        : 0;
    final inShelf = NovelStore.instance.inShelf(_novel.key);
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: chapters.isEmpty ? null : () => _openReader(resumeIndex),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              hasProgress
                  ? '续读 · 第 ${resumeIndex + 1} 章'
                  : '开始阅读',
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _toggleShelf,
          icon: Icon(
            inShelf ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          label: Text(inShelf ? '已在书架' : '加入书架'),
          style: OutlinedButton.styleFrom(
            foregroundColor: inShelf ? colors.primary : null,
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
          ),
        ),
      ],
    );
  }

  Widget _chapterTile(NovelChapterItem chapter, ColorScheme colors) {
    return SizedBox(
      width: 168,
      child: InkWell(
        onTap: () => _openReader(chapter.index),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            chapter.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }

  Future<void> _openCatalog() async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    final chapter = await showModalBottomSheet<NovelChapterItem>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '目录 · ${book.chapters.length} 章',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: book.chapters.length,
                  itemBuilder: (context, index) => ListTile(
                    dense: true,
                    title: Text(
                      book.chapters[index].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(
                      book.chapters[index],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chapter == null || !mounted) return;
    await _openReader(chapter.index);
  }
}

/// 简介：超过 4 行折叠，点「展开」看全文。
class _Description extends StatefulWidget {
  const _Description({required this.text});

  final String text;

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.7,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _expanded ? '收起' : '展开',
            style: TextStyle(fontSize: 12, color: colors.primary),
          ),
        ],
      ),
    );
  }
}
