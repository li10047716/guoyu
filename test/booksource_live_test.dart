/// 真实站点端到端验证（默认跳过，避免 CI 依赖外网）。
///
/// 单个书源：
///   LEGADO_LIVE=1 LEGADO_SOURCE=/tmp/yc/7574.json \
///   DUANJU_CORE_DLL=E:/download/guoyu/windows/runner/duanju_core.dll \
///   flutter test test/booksource_live_test.dart
///
/// 整个目录（逐个跑「搜索 → 详情 → 目录 → 正文」，最后打印通过清单）：
///   LEGADO_LIVE=1 LEGADO_DIR=/tmp/yc LEGADO_KEYWORD=诡秘之主 \
///   DUANJU_CORE_DLL=E:/download/guoyu/windows/runner/duanju_core.dll \
///   flutter test test/booksource_live_test.dart
///
/// 用来确认「Dart 规则引擎 + Go goja 运行时」配合起来是通的。
library;

import 'dart:io';

import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';
import 'package:duanju_app/novel/booksource/book_source_parser.dart';
import 'package:duanju_app/novel/booksource/book_source_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final single = env['LEGADO_SOURCE'] ?? '';
  final dir = env['LEGADO_DIR'] ?? '';
  final keyword = env['LEGADO_KEYWORD'] ?? '诡秘之主';
  final live = env['LEGADO_LIVE'] == '1';
  BookSourceStore.instance.debugSetDir(null);

  /// 跑一遍完整链路，返回失败原因（成功返回 null）。
  Future<String?> runFlow(BookSource source) async {
    const engine = BookSourceEngine();
    final hits = await engine.search(source, keyword);
    if (hits.isEmpty) return '搜索无结果';
    final book = await engine.detail(
      source,
      BookSourceIds.decode(hits.first.id)!.url,
    );
    if (book.chapters.isEmpty) return '目录为空';
    final text = await engine.content(
      source,
      book.novel.id,
      BookSourceIds.decode(book.chapters.first.id)!.url,
    );
    if (text.paragraphs.isEmpty) return '正文为空';
    // ignore: avoid_print
    print(
      '  OK  ${source.name}：${hits.length} 本 → ${book.chapters.length} 章'
      ' → ${text.paragraphs.length} 段',
    );
    return null;
  }

  test(
    '自定义书源可以搜索、看目录、读正文',
    () async {
      if (!File(single).existsSync()) return;
      final parsed = parseBookSources(
        File(single).readAsStringSync(),
        existing: const [],
      );
      expect(parsed.parsed, isNotEmpty);
      final source = parsed.parsed.first;
      expect(
        source.status.usable,
        isTrue,
        reason: '源不可用：${source.statusDetail}',
      );
      final failure = await runFlow(source);
      expect(failure, isNull, reason: failure ?? '');
    },
    skip: live && single.isNotEmpty
        ? false
        : '需要 LEGADO_LIVE=1 与 LEGADO_SOURCE',
  );

  test(
    '发现页：exploreUrl 的条目能拉出书单',
    () async {
      if (!File(single).existsSync()) return;
      final parsed = parseBookSources(
        File(single).readAsStringSync(),
        existing: const [],
      );
      final source = parsed.parsed.first;
      final entries = source.exploreEntries.where((e) => !e.isHeader).toList();
      expect(entries, isNotEmpty, reason: '这个源没有 exploreUrl');

      const engine = BookSourceEngine();
      final first = entries.first;
      final books = await engine.explore(source, first.url);
      // ignore: avoid_print
      print(
        '  发现「${first.name}」：${books.length} 本'
        '（${books.take(5).map((b) => b.title).join('、')}）',
      );
      expect(books, isNotEmpty);

      // 拉出来的书要能接着打开目录读正文。
      final book = await engine.detail(
        source,
        BookSourceIds.decode(books.first.id)!.url,
      );
      expect(book.chapters, isNotEmpty);
      final text = await engine.content(
        source,
        book.novel.id,
        BookSourceIds.decode(book.chapters.first.id)!.url,
      );
      expect(text.paragraphs, isNotEmpty);
      // ignore: avoid_print
      print(
        '  首本《${book.novel.title}》→ ${book.chapters.length} 章'
        ' → ${text.paragraphs.length} 段',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: live && single.isNotEmpty
        ? false
        : '需要 LEGADO_LIVE=1 与 LEGADO_SOURCE',
  );

  test(
    '整个目录的书源逐个实测',
    () async {
      final files =
          Directory(dir)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      final passed = <String>[];
      final blocked = <String>[];
      final failed = <String>[];

      for (final file in files) {
        final parsed = parseBookSources(
          file.readAsStringSync(),
          existing: const [],
        );
        for (final source in parsed.parsed) {
          if (!source.status.usable) {
            blocked.add('${source.name}（${source.status.label}）');
            continue;
          }
          try {
            final failure = await runFlow(source);
            if (failure == null) {
              passed.add(source.name);
            } else {
              failed.add('${source.name}：$failure');
            }
          } catch (e) {
            failed.add('${source.name}：$e');
          }
        }
      }

      // ignore: avoid_print
      print(
        '\n===== 结果 =====\n'
        '通过 ${passed.length}：${passed.join('、')}\n'
        '不可用 ${blocked.length}：${blocked.join('、')}\n'
        '跑不通 ${failed.length}：\n  ${failed.join('\n  ')}',
      );
      expect(passed, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: live && dir.isNotEmpty ? false : '需要 LEGADO_LIVE=1 与 LEGADO_DIR',
  );
}
