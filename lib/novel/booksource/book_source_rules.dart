/// 带 JS 支持的规则求值（0.7.69）。
///
/// [RuleEngine] 只认 CSS / JSONPath / 正则，遇到 `@js:` 直接抛错；
/// 这一层在它的前面加了一道分流：
///
/// - 规则里没有 `@js:` → 原样交给 [RuleEngine]（同步，零开销）
/// - 规则里有 `@js:` → 先把 `@js:` 前面的部分同步算成 `result`，
///   再交给原生核心的 goja 执行，脚本里的 `result` 就是前半段的结果
///
/// 这也正是 Legado 的规则语义：`规则@js:代码`，代码里用 `result` 拿上一步的值。
library;

import 'book_source.dart';
import 'book_source_store.dart';
import 'legado_script.dart';
import 'rule_engine.dart';

/// 规则求值（带 JS）。
class BookSourceRules {
  const BookSourceRules._();

  static const String _jsMark = '@js:';
  static const String _jsOpen = '<js>';

  /// 规则里是否带 JS 段。
  static bool hasJs(String? rule) =>
      rule != null && (rule.contains(_jsMark) || rule.contains(_jsOpen));

  /// 拆分「前缀规则 + 脚本」。
  ///
  /// Legado 有两种写法，都要认：
  /// - `规则@js:代码`（行内）
  /// - `规则<js>代码</js>`（块状，块后面的内容忽略）
  ///
  /// 前缀为空表示整条规则就是脚本。
  static ({String prefix, String code})? splitJs(String rule) {
    final open = rule.indexOf(_jsOpen);
    if (open >= 0) {
      final close = rule.indexOf('</js>', open + _jsOpen.length);
      final code = close < 0
          ? rule.substring(open + _jsOpen.length)
          : rule.substring(open + _jsOpen.length, close);
      return (prefix: rule.substring(0, open), code: code);
    }
    final index = rule.indexOf(_jsMark);
    if (index < 0) return null;
    return (
      prefix: rule.substring(0, index),
      code: rule.substring(index + _jsMark.length),
    );
  }

  /// 求一个字符串。
  static Future<String> one(
    String? rule,
    RuleContext ctx, {
    required BookSource source,
    String fallbackRule = '',
    String key = '',
    int page = 1,
    Map<String, String> extraVars = const {},
  }) async {
    final actual = (rule == null || rule.trim().isEmpty) ? fallbackRule : rule;
    if (actual.isEmpty) return '';
    if (!hasJs(actual)) {
      try {
        return RuleEngine.selectOne(actual, ctx);
      } on UnsupportedRule {
        return '';
      }
    }
    final values = await strings(
      actual,
      ctx,
      source: source,
      key: key,
      page: page,
      extraVars: extraVars,
    );
    return values.isEmpty ? '' : values.first;
  }

  /// 求一组字符串。
  static Future<List<String>> strings(
    String? rule,
    RuleContext ctx, {
    required BookSource source,
    String key = '',
    int page = 1,
    Map<String, String> extraVars = const {},
  }) async {
    if (rule == null || rule.trim().isEmpty) return const [];
    if (!hasJs(rule)) {
      try {
        return RuleEngine.selectStrings(rule, ctx);
      } on UnsupportedRule {
        return const [];
      }
    }

    final split = splitJs(rule)!;
    final prefix = split.prefix;
    final code = split.code;

    // 没有前置规则时，`result` 就是当前上下文的原文（整页或元素 HTML），
    // 这和 Legado 的语义一致 —— 脚本里经常直接 JSON.parse(result)。
    var prev = ctx.currentText;
    if (prefix.trim().isNotEmpty) {
      try {
        prev = RuleEngine.selectOne(prefix, ctx);
      } on UnsupportedRule {
        prev = '';
      }
    }

    final result = await LegadoScript.run(
      source,
      code,
      result: prev,
      key: key,
      page: page,
      baseUrl: ctx.url,
      extraVars: extraVars,
      bookName: ctx.vars['bookName'] ?? '',
      bookUrl: ctx.vars['bookUrl'] ?? '',
      bookAuthor: ctx.vars['bookAuthor'] ?? '',
    );
    if (result.variables.isNotEmpty) {
      BookSourceStore.instance.mergeVariables(source.key, result.variables);
    }
    final text = result.value.trim();
    return text.isEmpty ? const [] : [text];
  }

  /// 执行一段独立的脚本（搜索地址这类不是取值规则的场景）。
  static Future<String> script(
    BookSource source,
    String code, {
    String key = '',
    int page = 1,
    String baseUrl = '',
  }) async {
    final result = await LegadoScript.run(
      source,
      code,
      key: key,
      page: page,
      baseUrl: baseUrl.isEmpty ? source.url : baseUrl,
    );
    if (result.variables.isNotEmpty) {
      BookSourceStore.instance.mergeVariables(source.key, result.variables);
    }
    return result.value.trim();
  }
}
