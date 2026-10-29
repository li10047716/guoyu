/// 书源导入：把「阅读」书源 JSON / 链接解析成 [BookSource]。
///
/// 支持的输入：
/// - 书源 JSON 文本（数组或单个对象，可带 BOM）
/// - `yuedu://booksource/importonline?src=<url>` 一键导入链接
/// - 直接的书源 JSON 地址（http/https）
library;

import 'dart:convert';

import 'book_source.dart';

/// 解析结果。
class BookSourceImport {
  BookSourceImport({
    required this.parsed,
    required this.duplicated,
    required this.skipped,
    required this.warnings,
  });

  /// 成功解析出来的源（已去重、已算好可用性）。
  final List<BookSource> parsed;

  /// 与已有书源重复、被跳过的条数。
  final int duplicated;

  /// JSON 结构不对被跳过的条数。
  final int skipped;

  /// 给用户看的提示（不可用原因汇总等）。
  final List<String> warnings;

  int get usableCount => parsed.where((s) => s.status.usable).length;
  int get blockedCount => parsed.where((s) => !s.status.usable).length;
  bool get isEmpty => parsed.isEmpty;

  String get summary {
    final parts = <String>['新增 ${parsed.length} 个'];
    if (duplicated > 0) parts.add('重复 $duplicated 个');
    if (skipped > 0) parts.add('跳过 $skipped 条');
    if (blockedCount > 0) parts.add('其中 $blockedCount 个不可用');
    return parts.join('，');
  }
}

/// 从各种输入里认出「要去下载的书源地址」。
///
/// - `yuedu://booksource/importonline?src=https%3A%2F%2F...` → 取出 src
/// - `https://.../xxx.json` → 原样返回
/// - 其它（含纯 JSON 文本）→ 返回 null
String? extractSourceUrl(String text) {
  var input = text.trim();
  if (input.isEmpty) return null;

  // 去掉剪贴板里常见的包裹字符
  if ((input.startsWith('"') && input.endsWith('"')) ||
      (input.startsWith("'") && input.endsWith("'"))) {
    input = input.substring(1, input.length - 1).trim();
  }

  final lower = input.toLowerCase();
  if (lower.startsWith('yuedu://') || lower.startsWith('legado://')) {
    final uri = Uri.tryParse(input.replaceFirst(RegExp(r'^(yuedu|legado)://'), 'https://'));
    if (uri == null) return null;
    final src = uri.queryParameters['src'] ?? uri.queryParameters['url'];
    if (src == null || src.isEmpty) return null;
    final decoded = Uri.decodeComponent(src);
    if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
      return decoded;
    }
    return null;
  }

  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    if (lower.contains('\n')) return null;
    return input;
  }
  return null;
}

/// 解析书源 JSON 文本。
///
/// [existing] 用来去重：地址相同的视为同一个源。
/// [overwriteExisting] 为 true 时，重复的源用新导入的规则覆盖（保留启用状态）。
BookSourceImport parseBookSources(
  String text, {
  List<BookSource> existing = const [],
  bool overwriteExisting = false,
}) {
  var body = text;
  if (body.startsWith('\uFEFF')) body = body.substring(1);
  body = body.trim();

  // 允许「地址里再套一层 JSON」的情况：先看是不是 http 链接
  final remote = extractSourceUrl(body);
  if (remote != null && remote != body) body = remote;

  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    return BookSourceImport(
      parsed: const [],
      duplicated: 0,
      skipped: 0,
      warnings: ['不是合法的 JSON：${_short(e)}'],
    );
  }

  final rows = <Map<String, dynamic>>[];
  if (decoded is List) {
    for (final item in decoded) {
      if (item is Map) {
        rows.add(Map<String, dynamic>.from(item));
      }
    }
  } else if (decoded is Map) {
    // 兼容 {booksources:[...]} / {data:[...]} 这类包装
    final list = decoded['booksources'] ?? decoded['data'] ?? decoded['list'];
    if (list is List) {
      for (final item in list) {
        if (item is Map) rows.add(Map<String, dynamic>.from(item));
      }
    } else {
      rows.add(Map<String, dynamic>.from(decoded));
    }
  } else {
    return BookSourceImport(
      parsed: const [],
      duplicated: 0,
      skipped: 0,
      warnings: ['JSON 顶层既不是数组也不是对象'],
    );
  }

  final skipped = (decoded is List ? decoded.length : rows.length) - rows.length;
  final seenKeys = <String>{
    for (final s in existing) s.key,
  };
  final out = <BookSource>[];
  var duplicated = 0;
  final blocked = <String, int>{};

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final url = '${row['bookSourceUrl'] ?? ''}'.trim();
    final name = '${row['bookSourceName'] ?? ''}'.trim();
    if (url.isEmpty && name.isEmpty) {
      continue;
    }
    final source = BookSource.fromLegado(row, order: i);
    if (seenKeys.contains(source.key)) {
      if (!overwriteExisting) {
        duplicated++;
        continue;
      }
      out.removeWhere((s) => s.key == source.key);
    }
    seenKeys.add(source.key);
    out.add(source);
    if (!source.status.usable) {
      final label = source.status.label;
      blocked[label] = (blocked[label] ?? 0) + 1;
    }
  }

  final warnings = <String>[
    for (final entry in blocked.entries)
      '${entry.value} 个源${entry.key}（规则里用到本地引擎不支持的能力）',
  ];

  return BookSourceImport(
    parsed: out,
    duplicated: duplicated,
    skipped: skipped < 0 ? 0 : skipped,
    warnings: warnings,
  );
}

String _short(Object e) {
  final s = '$e';
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}
