/// 「阅读 / Legado」书源规则解释器（子集）。
///
/// 支持：
/// - CSS 选择器：`class.xxx` / `tag.a` / `id.x` / `.x` / `#x` / `[attr=v]` / `@css:`
/// - JSON 路径：`$.data.list[*].name`、`$..name`、`@json:`
/// - 取值：`@text` `@ownText` `@textNodes` `@html` `@all` `@href` `@src` 及任意属性
/// - 组合：`a&&b`（接续处理）、`a||b`（取第一个有结果的）
/// - 后处理：`##正则##替换`（`$1` 引用分组）
/// - 变量：`{{key}}`、`{{page}}`，以及简单算术 `{{(page - 1) * 10}}`
///
/// 不支持：`@js:`、`<js>`、`@xpath:`、`java.*`（导入时会标成不可用）。
library;

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 规则用到了本地引擎不支持的能力。
class UnsupportedRule implements Exception {
  UnsupportedRule(this.rule, this.reason);

  final String rule;
  final String reason;

  @override
  String toString() => 'UnsupportedRule($reason): $rule';
}

/// 一次抓取的上下文：页面正文 + 当前地址 + 变量。
class RuleContext {
  RuleContext({
    required this.body,
    this.url = '',
    Map<String, String>? vars,
    dom.Element? root,
    dom.Document? document,
  }) : vars = {...?vars} {
    _root = root;
    _document = document;
  }

  factory RuleContext.child(dom.Element element, RuleContext parent) =>
      RuleContext(
        body: parent.body,
        url: parent.url,
        vars: parent.vars,
        root: element,
        document: parent._document,
      );

  /// 原始正文（HTML 或 JSON 文本）。
  final String body;

  /// 抓取地址，用于把相对链接转绝对。
  String url;

  /// 模板变量：`{{key}}`、`{{page}}` 等。
  final Map<String, String> vars;

  dom.Element? _root;
  dom.Document? _document;
  Object? _json;
  bool _jsonTried = false;

  dom.Element get root => _root ?? document.documentElement!;

  /// 当前上下文的原文：元素上下文是它的 outerHTML，页面上下文是整页正文。
  /// Legado 里脚本的 `result` 默认就是这个。
  String get currentText => _root?.outerHtml ?? body;

  dom.Document get document => _document ??= html_parser.parse(body);

  /// 正文能当 JSON 用时返回解析结果，否则返回 null。
  Object? get json {
    if (_jsonTried) return _json;
    _jsonTried = true;
    final text = body.trimLeft();
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      _json = jsonDecode(body);
    } catch (_) {
      _json = null;
    }
    return _json;
  }

  RuleContext child(dom.Element element) => RuleContext.child(element, this);

  RuleContext copyWith({String? url, Map<String, String>? vars}) => RuleContext(
    body: body,
    url: url ?? this.url,
    vars: vars ?? this.vars,
    root: _root,
    document: _document,
  );
}

/// 规则解释器。
class RuleEngine {
  const RuleEngine._();

  static final RegExp _unsupportedPrefix = RegExp(r'^\s*(@js:|<js>|@xpath:)');
  static final RegExp _templateRe = RegExp(r'\{\{([^}]+)\}\}');

  /// 把 `{{...}}` 换成实际值（支持简单算术）。
  static String expandTemplate(String text, RuleContext ctx) {
    if (!text.contains('{{')) return text;
    return text.replaceAllMapped(_templateRe, (m) {
      final expr = m.group(1)!.trim();
      for (final entry in ctx.vars.entries) {
        if (expr == entry.key) return entry.value;
      }
      final number = _evalArithmetic(expr, ctx.vars);
      if (number != null) return '$number';
      return '';
    });
  }

  /// 只支持整数与 + - * / 及括号，够 `{{(page - 1) * 10}}` 用。
  static int? _evalArithmetic(String expr, Map<String, String> vars) {
    final source = expr.replaceAllMapped(RegExp(r'[A-Za-z_][A-Za-z0-9_]*'), (m) {
      final v = vars[m.group(0)];
      return v ?? '';
    });
    if (source.trim().isEmpty) return null;
    if (!RegExp(r'^[0-9+\-*/() ]+$').hasMatch(source)) return null;
    try {
      return _Arith(source).parse();
    } catch (_) {
      return null;
    }
  }

  /// 求出一组节点（bookList / chapterList 用）。
  static List<dom.Element> selectNodes(String rule, RuleContext ctx) {
    final out = <dom.Element>[];
    for (final value in _eval(rule, ctx)) {
      if (value is dom.Element) out.add(value);
    }
    return out;
  }

  /// 求出一组字符串。
  static List<String> selectStrings(String rule, RuleContext ctx) {
    final out = <String>[];
    for (final value in _eval(rule, ctx)) {
      final text = value is dom.Element ? value.text.trim() : '$value'.trim();
      if (text.isNotEmpty) out.add(text);
    }
    return out;
  }

  /// 求出一个字符串（取第一个非空）。
  static String selectOne(String rule, RuleContext ctx, {String fallback = ''}) {
    final list = selectStrings(rule, ctx);
    return list.isEmpty ? fallback : list.first;
  }

  // ---------------------------------------------------------------- 内部实现

  static List<Object> _eval(String rule, RuleContext ctx) {
    final trimmed = rule.trim();
    if (trimmed.isEmpty) return const [];
    if (_unsupportedPrefix.hasMatch(trimmed) || trimmed.startsWith('<js>')) {
      throw UnsupportedRule(trimmed, '本地引擎不支持 JS / XPath 规则');
    }

    // ##正则##替换 后处理：第一段是主规则，后面成对出现
    final parts = trimmed.split('##');
    final mainRule = parts.first;
    final transforms = <(String, String)>[];
    for (var i = 1; i < parts.length; i += 2) {
      final pattern = parts[i];
      final replacement = i + 1 < parts.length ? parts[i + 1] : '';
      if (pattern.isEmpty) continue;
      transforms.add((pattern, replacement));
    }

    var values = _evalAlternatives(mainRule, ctx);
    if (transforms.isEmpty) return values;

    final result = <Object>[];
    for (final value in values) {
      final text = value is dom.Element ? value.text : '$value';
      var output = text;
      for (final (pattern, replacement) in transforms) {
        try {
          output = output.replaceAll(RegExp(pattern, multiLine: true), replacement);
        } catch (_) {
          // 正则不合法就跳过这一步
        }
      }
      if (output.trim().isNotEmpty) result.add(output.trim());
    }
    return result;
  }

  /// `a||b||c`：取第一个有结果的。
  static List<Object> _evalAlternatives(String rule, RuleContext ctx) {
    final branches = _splitTop(rule, '||');
    for (final branch in branches) {
      final values = _evalChain(branch, ctx);
      if (values.isNotEmpty) return values;
    }
    return const [];
  }

  /// `a&&b`：把前一环的结果作为后一环的输入。
  static List<Object> _evalChain(String rule, RuleContext ctx) {
    final steps = _splitTop(rule, '&&');
    List<Object> current = _evalSingle(steps.first, ctx);
    for (var i = 1; i < steps.length; i++) {
      final next = <Object>[];
      for (final value in current) {
        if (value is dom.Element) {
          next.addAll(_evalSingle(steps[i], RuleContext.child(value, ctx)));
        }
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  /// 单条规则：JSON 路径 或 CSS 链。
  static List<Object> _evalSingle(String rule, RuleContext ctx) {
    var text = rule.trim();
    if (text.isEmpty) return const [];

    if (text.startsWith('@json:')) {
      text = text.substring(6).trim();
      return _jsonValues(text, ctx);
    }
    if (text.startsWith(r'$')) {
      return _jsonValues(text, ctx);
    }
    if (text.startsWith('@css:')) {
      text = text.substring(5).trim();
    }

    // 按 @ 切成「选择器 → 选择器 → ... → 取值器」
    final segments = _splitSelectors(text);
    if (segments.isEmpty) return const [];

    var nodes = <dom.Element>[ctx.root];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.isEmpty) continue;

      if (_isGetter(segment)) {
        return _applyGetter(nodes, segment, ctx);
      }

      final (selector, index) = _parseSelector(segment);
      final matched = <dom.Element>[];
      for (final node in nodes) {
        matched.addAll(_query(node, selector));
      }
      nodes = index == null ? matched : _pick(matched, index);
      if (i == segments.length - 1) return nodes;
      if (nodes.isEmpty) return const [];
    }
    return nodes;
  }

  static List<dom.Element> _query(dom.Element node, String selector) {
    if (selector.isEmpty) return [node];
    try {
      return node.querySelectorAll(selector);
    } catch (_) {
      return const [];
    }
  }

  static List<dom.Element> _pick(List<dom.Element> nodes, int index) {
    final real = index < 0 ? nodes.length + index : index;
    if (real < 0 || real >= nodes.length) return const [];
    return [nodes[real]];
  }

  /// 常见属性取值（`@href` / `@src` / `@data-src` …）。
  static const Set<String> _attrGetters = {
    'href',
    'src',
    'content',
    'value',
    'title',
    'alt',
    'class',
    'id',
  };

  static bool _isGetter(String segment) {
    const getters = {
      'text',
      'textNodes',
      'ownText',
      'html',
      'all',
      'string',
    };
    if (getters.contains(segment)) return true;
    if (segment.startsWith('abs:')) return true;
    if (_attrGetters.contains(segment)) return true;
    // 带连字符的属性（data-src / data-original…）只可能是取值
    return segment.contains('-') &&
        RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(segment);
  }

  static List<Object> _applyGetter(
    List<dom.Element> nodes,
    String getter,
    RuleContext ctx,
  ) {
    final out = <Object>[];
    var name = getter;
    if (name.startsWith('abs:')) name = name.substring(4);
    for (final node in nodes) {
      switch (name) {
        case 'text':
          final t = node.text.trim();
          if (t.isNotEmpty) out.add(t);
        case 'ownText':
          final t = node.nodes
              .whereType<dom.Text>()
              .map((n) => n.text)
              .join()
              .trim();
          if (t.isNotEmpty) out.add(t);
        case 'textNodes':
          for (final n in node.nodes.whereType<dom.Text>()) {
            final t = n.text.trim();
            if (t.isNotEmpty) out.add(t);
          }
        case 'html':
        case 'all':
          if (node.innerHtml.trim().isNotEmpty) out.add(node.innerHtml.trim());
        case 'string':
          final t = node.text.trim();
          if (t.isNotEmpty) out.add(t);
        default:
          final raw = node.attributes[name];
          if (raw != null && raw.trim().isNotEmpty) {
            out.add(resolveUrl(ctx.url, raw.trim()));
          }
      }
    }
    return out;
  }

  /// `class.list@tag.a@text` / `class.list!0` / `class.list.2`
  static List<String> _splitSelectors(String text) {
    // 用 @ 切分，但跳过 @css: / @json: 这类前缀（已在上层剥掉）
    return text
        .split('@')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static (String, int?) _parseSelector(String segment) {
    var s = segment.trim();
    int? index;

    // 结尾的 !n / [-n] 作为索引
    final bang = RegExp(r'!(-?\d+)$').firstMatch(s);
    if (bang != null) {
      index = int.tryParse(bang.group(1)!);
      s = s.substring(0, bang.start);
    }
    final bracket = RegExp(r'^(-?\d+)$').firstMatch(s.split('.').last);
    if (index == null && bracket != null && s.contains('.')) {
      final parts = s.split('.');
      final last = int.tryParse(parts.last);
      if (last != null) {
        index = last;
        s = parts.sublist(0, parts.length - 1).join('.');
      }
    }

    return (_toCss(s), index);
  }

  /// 把「阅读」的简化写法转成标准 CSS。
  static String _toCss(String selector) {
    var s = selector.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('class.')) return '.${s.substring(6)}';
    if (s.startsWith('id.')) return '#${s.substring(3)}';
    if (s.startsWith('tag.')) return s.substring(4);
    if (s.startsWith('text.')) {
      // 按文本找元素：CSS 没有 :contains，退化成“所有元素里文本包含”
      return '*';
    }
    return s;
  }

  /// 把相对地址补成绝对地址。
  static String resolveUrl(String base, String link) {
    if (link.isEmpty) return link;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(link)) return link;
    if (link.startsWith('//')) {
      final scheme = base.startsWith('http://') ? 'http:' : 'https:';
      return '$scheme$link';
    }
    final anchor = Uri.tryParse(base);
    if (anchor == null) return link;
    try {
      return anchor.resolve(link).toString();
    } catch (_) {
      return link;
    }
  }

  // ------------------------------------------------------------ JSON 路径

  static List<Object> _jsonValues(String path, RuleContext ctx) {
    final data = ctx.json;
    if (data == null) return const [];
    final values = jsonPath(data, path);
    return [
      for (final v in values)
        if (v != null) v is String ? v : '$v',
    ];
  }

  /// 迷你 JSONPath：`$.a.b`、`$.a[*].b`、`$.a[0]`、`$..name`。
  static List<Object?> jsonPath(Object? root, String path) {
    var p = path.trim();
    if (p.startsWith('@json:')) p = p.substring(6).trim();
    if (p == r'$') return [root];
    // 只剥掉最前面的 `$`，`..key` 这种递归写法要原样留给后面解析
    if (p.startsWith(r'$')) {
      p = p.substring(1);
    }

    var current = <Object?>[root];
    var i = 0;
    while (i < p.length) {
      if (p[i] == '[') {
        final end = p.indexOf(']', i);
        if (end < 0) break;
        final inner = p.substring(i + 1, end).trim();
        i = end + 1;
        if (inner == '*' || inner == r'*') {
          current = [
            for (final v in current)
              if (v is List) ...v,
          ];
        } else {
          final cleaned = inner.replaceAll(RegExp(r'''^['"]|['"]$'''), '');
          final idx = int.tryParse(cleaned);
          if (idx != null) {
            current = [
              for (final v in current)
                if (v is List && idx >= 0 && idx < v.length)
                  v[idx]
                else if (v is List && idx < 0 && v.length + idx >= 0)
                  v[v.length + idx],
            ];
          } else {
            current = [
              for (final v in current)
                if (v is Map && v.containsKey(cleaned)) v[cleaned],
            ];
          }
        }
        continue;
      }

      // 读一段 key（可带前导 `.` 或 `..`）
      final recursive = p[i] == '.' && i + 1 < p.length && p[i + 1] == '.';
      if (p[i] == '.') i += recursive ? 2 : 1;
      final start = i;
      while (i < p.length && p[i] != '.' && p[i] != '[') {
        i++;
      }
      final key = p.substring(start, i);
      if (key.isEmpty) continue;
      current = recursive
          ? _descend(current, key)
          : [
              for (final v in current)
                if (v is Map && v.containsKey(key)) v[key],
            ];
    }
    return current;
  }

  static List<Object?> _descend(List<Object?> nodes, String key) {
    final out = <Object?>[];
    void walk(Object? node) {
      if (node is Map) {
        if (node.containsKey(key)) out.add(node[key]);
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    for (final n in nodes) {
      walk(n);
    }
    return out;
  }

  /// 按顶层 `||` / `&&` 切分，跳过正则段里的分隔符。
  static List<String> _splitTop(String rule, String token) {
    final parts = <String>[];
    var depth = 0;
    var buffer = StringBuffer();
    var i = 0;
    var inRegex = false;
    while (i < rule.length) {
      if (rule.startsWith('##', i)) {
        inRegex = !inRegex;
        buffer.write('##');
        i += 2;
        continue;
      }
      if (!inRegex) {
        if (rule[i] == '(' || rule[i] == '[') depth++;
        if (rule[i] == ')' || rule[i] == ']') depth--;
        if (depth <= 0 && rule.startsWith(token, i)) {
          parts.add(buffer.toString());
          buffer = StringBuffer();
          i += token.length;
          continue;
        }
      }
      buffer.write(rule[i]);
      i++;
    }
    parts.add(buffer.toString());
    return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
}

/// 极简整数四则运算。
class _Arith {
  _Arith(this.source);

  final String source;
  int _pos = 0;

  int parse() {
    final value = _expr();
    _skipSpace();
    if (_pos != source.length) throw FormatException('多余字符');
    return value;
  }

  int _expr() {
    var value = _term();
    while (true) {
      _skipSpace();
      if (_pos < source.length && (source[_pos] == '+' || source[_pos] == '-')) {
        final op = source[_pos++];
        final right = _term();
        value = op == '+' ? value + right : value - right;
      } else {
        return value;
      }
    }
  }

  int _term() {
    var value = _factor();
    while (true) {
      _skipSpace();
      if (_pos < source.length && (source[_pos] == '*' || source[_pos] == '/')) {
        final op = source[_pos++];
        final right = _factor();
        value = op == '*' ? value * right : (right == 0 ? 0 : value ~/ right);
      } else {
        return value;
      }
    }
  }

  int _factor() {
    _skipSpace();
    if (_pos < source.length && source[_pos] == '(') {
      _pos++;
      final value = _expr();
      _skipSpace();
      if (_pos < source.length && source[_pos] == ')') _pos++;
      return value;
    }
    if (_pos < source.length && source[_pos] == '-') {
      _pos++;
      return -_factor();
    }
    final start = _pos;
    while (_pos < source.length && RegExp(r'[0-9]').hasMatch(source[_pos])) {
      _pos++;
    }
    if (start == _pos) throw FormatException('缺数字');
    return int.parse(source.substring(start, _pos));
  }

  void _skipSpace() {
    while (_pos < source.length && source[_pos] == ' ') {
      _pos++;
    }
  }
}
