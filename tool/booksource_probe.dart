/// 书源调试工具（开发用）。
///
/// 用法：
///   dart run tool/booksource_probe.dart <书源.json> <关键词>
///
/// 依次跑「搜索 → 详情 → 目录 → 第一页正文」，把每一步的结果打印出来，
/// 用来验证规则写得对不对（相当于轻悦时光那个 HTTP 调试接口的命令行版）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法：dart run tool/booksource_probe.dart <书源.json> <关键词>');
    exit(64);
  }
  final raw = File(args[0]).readAsStringSync();
  final decoded = jsonDecode(raw);
  final rows = decoded is List ? decoded : [decoded];
  final source = BookSource.fromLegado(
    Map<String, dynamic>.from(rows.first as Map),
  );

  stdout.writeln('书源：${source.name}');
  stdout.writeln('状态：${source.status.label} ${source.statusDetail}');
  if (!source.status.usable) {
    stdout.writeln('这个源本地引擎跑不了，退出。');
    exit(1);
  }

  const engine = BookSourceEngine();
  final keyword = args[1];

  stdout.writeln('\n=== 搜索「$keyword」===');
  final results = await engine.search(source, keyword);
  stdout.writeln('命中 ${results.length} 本');
  for (final novel in results.take(5)) {
    stdout.writeln(
      '  ${novel.title} | ${novel.author} | ${novel.category} | '
      '${novel.latest} | ${novel.id.substring(0, 24)}…',
    );
  }
  if (results.isEmpty) exit(1);

  final first = results.first;
  stdout.writeln('\n=== 详情 ===');
  final book = await engine.detail(
    source,
    BookSourceIds.decode(first.id)!.url,
  );
  stdout.writeln('书名：${book.novel.title}');
  stdout.writeln('作者：${book.novel.author}');
  stdout.writeln('分类：${book.novel.category}');
  stdout.writeln('封面：${book.novel.cover}');
  stdout.writeln('简介：${_clip(book.novel.description, 80)}');
  stdout.writeln('目录：${book.chapters.length} 章');
  if (book.chapters.isNotEmpty) {
    stdout.writeln('  首章：${book.chapters.first.title}');
    stdout.writeln('  末章：${book.chapters.last.title}');
  }
  if (book.chapters.isEmpty) exit(1);

  stdout.writeln('\n=== 正文 ===');
  final text = await engine.content(
    source,
    book.novel.id,
    BookSourceIds.decode(book.chapters.first.id)!.url,
  );
  stdout.writeln('标题：${text.title}');
  stdout.writeln('段落：${text.paragraphs.length}');
  for (final paragraph in text.paragraphs.take(3)) {
    stdout.writeln('  ${_clip(paragraph, 70)}');
  }
  stdout.writeln('\n全部通过。');
}

String _clip(String text, int max) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}
