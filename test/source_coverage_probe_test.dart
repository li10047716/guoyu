/// 书源站点「支持度」批量探测（临时工具，不进交付）。
///
/// 用法：
///   DUANJU_CORE_DLL=E:/download/guoyu/windows/runner/duanju_core.dll \
///   PROBE_DIR=E:/download/guoyu/.workbuddy/srcs/yck PROBE_LABEL=yck \
///   PROBE_LIMIT=30 PROBE_CONCURRENCY=5 \
///   flutter test test/source_coverage_probe_test.dart
///
/// 每个源跑：解析状态 → 搜索 → 详情 → 目录 → 正文 → 发现，
/// 结果写成 markdown 到 `PROBE_DIR/../probe_<label>.md`，并打印汇总。
library;

import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';
import 'package:duanju_app/novel/booksource/book_source_parser.dart';
import 'package:duanju_app/novel/booksource/book_source_store.dart';
import 'package:duanju_app/novel/booksource/legado_script.dart';
import 'package:flutter_test/flutter_test.dart';

const _keywords = ['诡秘之主', '斗破苍穹', '大奉打更人'];

/// 单个源的探测结果。
class ProbeRow {
  ProbeRow(this.file, this.name, this.url);

  final String file;
  final String name;
  final String url;

  String status = '';
  bool usable = false;

  /// 搜索或发现拿到的第一本书（用来继续测详情/目录/正文）。
  Novel? hit;

  String search = '-';
  String detail = '-';
  String toc = '-';
  String content = '-';
  String explore = '-';

  String failStage = '';
  String failReason = '';
  int ms = 0;

  /// 是否「能读到正文」。
  bool get fullOk => content != '-' && !content.startsWith('×');

  Map<String, Object?> toJson() => {
    'file': file,
    'name': name,
    'url': url,
    'status': status,
    'usable': usable,
    'search': search,
    'detail': detail,
    'toc': toc,
    'content': content,
    'explore': explore,
    'failStage': failStage,
    'failReason': failReason,
    'ms': ms,
  };
}

String _short(Object error) {
  var text = '$error';
  text = text
      .replaceFirst('FetchFailure: ', '')
      .replaceFirst('AppFailure: ', '')
      .replaceFirst('UnsupportedRule: ', '')
      .replaceAll('\n', ' ');
  return text.length > 90 ? '${text.substring(0, 90)}…' : text;
}

Future<void> main() async {
  final env = Platform.environment;
  final dir = env['PROBE_DIR'] ?? '';
  final label = env['PROBE_LABEL'] ?? 'probe';
  final limit = int.tryParse(env['PROBE_LIMIT'] ?? '') ?? 0;
  final concurrency = int.tryParse(env['PROBE_CONCURRENCY'] ?? '') ?? 5;
  BookSourceStore.instance.debugSetDir(null);

  test(
    '批量探测书源支持度：$label',
    () async {
      final files =
          Directory(dir)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final picked = limit > 0 && files.length > limit
          ? files.sublist(0, limit)
          : files;

      final rows = <ProbeRow>[];
      var cursor = 0;
      const engine = BookSourceEngine();

      Future<void> worker() async {
        while (true) {
          final index = cursor++;
          if (index >= picked.length) return;
          final file = picked[index];
          final parsed = parseBookSources(
            file.readAsStringSync(),
            existing: const [],
          );
          for (final source in parsed.parsed) {
            final row = ProbeRow(
              file.path.split(RegExp(r'[/\\]')).last,
              source.name,
              source.url,
            );
            rows.add(row);
            row.status = source.status.label;
            row.usable = source.status.usable;
            if (!row.usable) {
              row.failStage = '解析';
              row.failReason = source.statusDetail.isEmpty
                  ? source.status.label
                  : source.statusDetail;
              continue;
            }
            final watch = Stopwatch()..start();
            try {
              await _probe(engine, source, row);
            } catch (error) {
              row.failStage = row.failStage.isEmpty ? '未知' : row.failStage;
              row.failReason = _short(error);
            } finally {
              watch.stop();
              row.ms = watch.elapsedMilliseconds;
            }
          }
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);

      rows.sort((a, b) => a.name.compareTo(b.name));
      final full = rows.where((r) => r.fullOk).toList();
      final partial = rows
          .where((r) => !r.fullOk && (r.search != '-' || r.explore != '-'))
          .toList();
      final blocked = rows.where((r) => !r.usable).toList();
      final dead = rows
          .where((r) => r.usable && r.search == '-' && r.explore == '-')
          .toList();

      final buffer = StringBuffer()
        ..writeln('# 书源探测：$label')
        ..writeln()
        ..writeln('样本 ${rows.length} 个源（目录 `$dir`）')
        ..writeln()
        ..writeln(
          '- 读到正文：${full.length}\n'
          '- 部分可用（能出书 / 能发现但正文没拿到）：${partial.length}\n'
          '- 解析即不可用：${blocked.length}\n'
          '- 完全跑不通：${dead.length}',
        )
        ..writeln()
        ..writeln(
          '| 源 | 域名 | 状态 | 搜索 | 详情 | 目录 | 正文 | 发现 | 耗时 | 失败原因 |',
        )
        ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
      for (final row in rows) {
        buffer.writeln(
          '| ${row.name} | ${Uri.tryParse(row.url)?.host ?? row.url} | '
          '${row.status} | ${row.search} | ${row.detail} | ${row.toc} | '
          '${row.content} | ${row.explore} | ${(row.ms / 1000).toStringAsFixed(1)}s | '
          '${row.failStage.isEmpty ? '' : '${row.failStage}：'}${row.failReason} |',
        );
      }

      final out = File('$dir/../probe_$label.md');
      out.writeAsStringSync(buffer.toString());
      // ignore: avoid_print
      print(
        '\n===== $label =====\n'
        '样本 ${rows.length}：正文可用 ${full.length} / 部分 ${partial.length} / '
        '解析拦下 ${blocked.length} / 跑不通 ${dead.length}\n'
        '报告：${out.path}',
      );
      // ignore: avoid_print
      print(
        jsonEncode([for (final row in rows) row.toJson()]),
      );
    },
    timeout: const Timeout(Duration(minutes: 60)),
    skip: dir.isEmpty ? '需要 PROBE_DIR（书源 JSON 目录）' : false,
  );
}

Future<void> _probe(BookSourceEngine engine, BookSource source, ProbeRow row) async {
  const stage = Duration(seconds: 22);

  // 1) 发现（第一条分类）。先跑它，拿到站内真实书名，搜索无结果时用它回搜，
  //    避免「源可用、只是抽的关键词站里没有」被误判。
  String? sampleTitle;
  List<BookSourceExploreEntry> entries = const [];
  try {
    // 0.7.83：`exploreUrl` 写成脚本的源要先求值才有条目。
    entries = source.exploreIsScript
        ? BookSourceExploreEntry.parseResolved(
            (await LegadoScript.run(
              source,
              BookSourceExploreEntry.scriptCode(source.exploreUrl),
              baseUrl: source.url,
            ).timeout(stage)).value,
          )
        : source.exploreEntries;
    entries = entries.where((e) => !e.isHeader).toList();
  } catch (error) {
    row.explore = '× 脚本求值 ${_short(error)}';
  }
  if (entries.isNotEmpty) {
    try {
      final books = await engine
          .explore(source, entries.first.url)
          .timeout(stage);
      row.explore = '${books.length} 本';
      if (books.isNotEmpty) sampleTitle = books.first.title;
      if (books.isNotEmpty && row.hit == null) row.hit = books.first;
    } catch (error) {
      row.explore = '× ${_short(error)}';
      row.failStage = row.failStage.isEmpty ? '发现' : row.failStage;
      row.failReason = row.failReason.isEmpty ? _short(error) : row.failReason;
    }
  }

  // 2) 搜索：先试固定热门词，全都 0 结果时用站内书名回搜。
  for (final keyword in [..._keywords, ?sampleTitle]) {
    try {
      final books = await engine.search(source, keyword).timeout(stage);
      if (books.isNotEmpty) {
        row.search = '${books.length} 本（$keyword）';
        row.hit = books.first;
        break;
      }
      row.search = '0 本（$keyword）';
    } catch (error) {
      row.search = '× ${_short(error)}';
      if (row.failStage.isEmpty) {
        row.failStage = '搜索';
        row.failReason = _short(error);
      }
      break;
    }
  }

  final hit = row.hit;
  if (hit == null) return;

  // 3) 详情 + 目录
  try {
    final target = BookSourceIds.decode(hit.id);
    if (target == null) {
      row.detail = '× 书籍 ID 解不出来';
      return;
    }
    final book = await engine.detail(source, target.url).timeout(stage);
    row.detail = 'ok';
    row.toc = '${book.chapters.length} 章';
    if (book.chapters.isEmpty) {
      row.failStage = row.failStage.isEmpty ? '目录' : row.failStage;
      row.failReason = row.failReason.isEmpty ? '目录为空' : row.failReason;
      return;
    }
    // 4) 正文
    final chapter = BookSourceIds.decode(book.chapters.first.id);
    if (chapter == null) {
      row.content = '× 章节 ID 解不出来';
      return;
    }
    final text = await engine
        .content(source, book.novel.id, chapter.url)
        .timeout(stage);
    row.content = '${text.paragraphs.length} 段';
    if (text.paragraphs.isEmpty) {
      row.failStage = row.failStage.isEmpty ? '正文' : row.failStage;
      row.failReason = row.failReason.isEmpty ? '正文为空' : row.failReason;
    }
  } catch (error) {
    row.detail = row.detail == '-' ? '× ${_short(error)}' : row.detail;
    row.failStage = row.failStage.isEmpty ? '详情' : row.failStage;
    row.failReason = row.failReason.isEmpty ? _short(error) : row.failReason;
  }
}
