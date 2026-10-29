/// 真实站点端到端验证（默认跳过，避免 CI 依赖外网）。
///
/// 运行：
///   LEGADO_LIVE=1 LEGADO_SOURCE=/tmp/yc/7574.json \
///   DUANJU_CORE_DLL=E:/download/guoyu/windows/runner/duanju_core.dll \
///   flutter test test/booksource_live_test.dart
///
/// 这条用例会真的去搜索、打开详情、抓一章正文，
/// 用来确保「Dart 规则引擎 + Go goja 运行时」配合起来是通的。
library;

import 'dart:io';

import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';
import 'package:duanju_app/novel/booksource/book_source_parser.dart';
import 'package:duanju_app/novel/booksource/book_source_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final env = Platform.environment;
  final path = env['LEGADO_SOURCE'] ?? '';
  final live = env['LEGADO_LIVE'] == '1' && path.isNotEmpty && File(path).existsSync();

  test('自定义书源可以搜索、看目录、读正文', () async {
    BookSourceStore.instance.debugSetDir(null);
    final parsed = parseBookSources(
      File(path).readAsStringSync(),
      existing: const [],
    );
    expect(parsed.parsed, isNotEmpty);
    final source = parsed.parsed.first;
    expect(source.status.usable, isTrue,
        reason: '源不可用：${source.statusDetail}');

    const engine = BookSourceEngine();
    final hits = await engine.search(source, '诡秘之主');
    expect(hits, isNotEmpty, reason: '搜索没有结果');

    final book = await engine.detail(
      source,
      BookSourceIds.decode(hits.first.id)!.url,
    );
    expect(book.chapters, isNotEmpty, reason: '目录为空');

    final text = await engine.content(
      source,
      book.novel.id,
      BookSourceIds.decode(book.chapters.first.id)!.url,
    );
    expect(text.paragraphs, isNotEmpty, reason: '正文为空');
  }, skip: live ? false : '需要 LEGADO_LIVE=1 与 LEGADO_SOURCE 才跑真实站点');
}
