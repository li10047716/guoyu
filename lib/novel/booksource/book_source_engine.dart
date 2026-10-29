/// 用「阅读」书源规则真的去抓书：搜索 / 详情 / 目录 / 正文。
///
/// 规则求值分两段：没有 `@js:` 的走本地 [RuleEngine]（同步），
/// 带 `@js:` 的交给原生核心的 goja 运行时（见 [BookSourceRules]）。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/novel_models.dart';
import 'book_source.dart';
import 'book_source_http.dart';
import 'book_source_rules.dart';
import 'rule_engine.dart';

/// 书籍 / 章节 ID 的编解码。
///
/// 形如 `bs.<源key>.<url 的 base64url>`，这样只拿到一个 id 也能找回源和地址。
class BookSourceIds {
  const BookSourceIds._();

  static const String prefix = 'bs.';

  static String encode(String sourceKey, String url) =>
      '$prefix$sourceKey.${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

  static bool looksLikeBookSource(String id) => id.startsWith(prefix);

  static ({String key, String url})? decode(String id) {
    if (!id.startsWith(prefix)) return null;
    final rest = id.substring(prefix.length);
    final dot = rest.indexOf('.');
    if (dot <= 0) return null;
    final key = rest.substring(0, dot);
    var payload = rest.substring(dot + 1);
    final pad = payload.length % 4;
    if (pad > 0) payload = payload.padRight(payload.length + 4 - pad, '=');
    try {
      return (key: key, url: utf8.decode(base64Url.decode(payload)));
    } catch (_) {
      return null;
    }
  }
}

/// 一次搜索请求的解析结果。
class _SearchRequest {
  const _SearchRequest({
    required this.url,
    required this.method,
    required this.body,
    required this.charset,
    required this.headers,
  });

  final String url;
  final String method;
  final String? body;
  final String charset;
  final Map<String, String> headers;
}

/// 书源执行器。
class BookSourceEngine {
  const BookSourceEngine();

  /// 搜索。
  Future<List<Novel>> search(
    BookSource source,
    String query, {
    int page = 1,
  }) async {
    if (source.searchUrl.trim().isEmpty) {
      throw FetchFailure('这个源没有配置搜索地址');
    }
    final request = await _searchRequest(source, query, page);
    final result = await BookSourceHttp.fetch(
      request.url,
      method: request.method,
      body: request.body,
      headers: {..._headers(source), ...request.headers},
      charset: request.charset.isNotEmpty ? request.charset : source.charset,
    );
    if (!result.ok) {
      throw FetchFailure('搜索失败（HTTP ${result.status}）', status: result.status);
    }

    final ctx = RuleContext(
      body: result.body,
      url: result.url,
      vars: {'key': query, 'page': '$page'},
    );
    final listRule = source.searchRules['bookList'];
    if (listRule == null || listRule.trim().isEmpty) {
      throw FetchFailure('这个源没有配置书籍列表规则');
    }

    final items = await _listItems(
      listRule,
      ctx,
      source,
      key: query,
      page: page,
    );
    final out = <Novel>[];
    final seen = <String>{};
    for (final item in items) {
      final name = await BookSourceRules.one(
        source.searchRules['name'],
        item,
        source: source,
        fallbackRule: '@text',
        key: query,
        page: page,
      );
      final bookUrl = RuleEngine.resolveUrl(
        result.url,
        await BookSourceRules.one(
          source.searchRules['bookUrl'],
          item,
          source: source,
          fallbackRule: '@href',
          key: query,
          page: page,
        ),
      );
      if (name.isEmpty || bookUrl.isEmpty) continue;
      if (!seen.add(bookUrl)) continue;
      out.add(
        Novel(
          id: BookSourceIds.encode(source.key, bookUrl),
          source: source.sourceTag,
          title: name,
          author: await BookSourceRules.one(
            source.searchRules['author'],
            item,
            source: source,
            key: query,
            page: page,
          ),
          category: await BookSourceRules.one(
            source.searchRules['kind'],
            item,
            source: source,
            key: query,
            page: page,
          ),
          description: await BookSourceRules.one(
            source.searchRules['intro'],
            item,
            source: source,
            key: query,
            page: page,
          ),
          cover: RuleEngine.resolveUrl(
            result.url,
            await BookSourceRules.one(
              source.searchRules['coverUrl'],
              item,
              source: source,
              key: query,
              page: page,
            ),
          ),
          latest: await BookSourceRules.one(
            source.searchRules['lastChapter'],
            item,
            source: source,
            key: query,
            page: page,
          ),
        ),
      );
    }
    return out;
  }

  /// 详情（含完整目录）。
  Future<NovelBook> detail(BookSource source, String bookUrl) async {
    final detailResult = await BookSourceHttp.fetch(
      bookUrl,
      headers: _headers(source),
      charset: source.charset,
    );
    if (!detailResult.ok) {
      throw FetchFailure('详情页打开失败（HTTP ${detailResult.status}）',
          status: detailResult.status);
    }
    final ctx = RuleContext(body: detailResult.body, url: detailResult.url);
    final rules = source.bookInfoRules;

    final name = await BookSourceRules.one(
      rules['name'],
      ctx,
      source: source,
      fallbackRule: '@text',
    );
    final author = await BookSourceRules.one(rules['author'], ctx, source: source);
    final kind = await BookSourceRules.one(rules['kind'], ctx, source: source);
    final intro = await BookSourceRules.one(rules['intro'], ctx, source: source);
    final cover = await BookSourceRules.one(rules['coverUrl'], ctx, source: source);
    final latest = await BookSourceRules.one(rules['lastChapter'], ctx, source: source);

    var tocUrl = await BookSourceRules.one(rules['tocUrl'], ctx, source: source);
    if (tocUrl.isEmpty) {
      tocUrl = detailResult.url;
    } else {
      tocUrl = RuleEngine.resolveUrl(detailResult.url, tocUrl);
    }

    final chapters = await this.chapters(source, tocUrl);

    return NovelBook(
      novel: Novel(
        id: BookSourceIds.encode(source.key, detailResult.url),
        source: source.sourceTag,
        title: name.isEmpty ? _hostOf(bookUrl) : name,
        author: author,
        category: kind,
        description: intro,
        cover: RuleEngine.resolveUrl(detailResult.url, cover),
        latest: latest,
        chapters: chapters.length,
      ),
      chapters: chapters,
    );
  }

  /// 目录。
  Future<List<NovelChapterItem>> chapters(
    BookSource source,
    String tocUrl,
  ) async {
    final rules = source.tocRules;
    final listRule = rules['chapterList'];
    if (listRule == null || listRule.trim().isEmpty) {
      throw FetchFailure('这个源没有配置目录规则');
    }
    final result = await BookSourceHttp.fetch(
      tocUrl,
      headers: _headers(source),
      charset: source.charset,
    );
    if (!result.ok) {
      throw FetchFailure('目录打开失败（HTTP ${result.status}）',
          status: result.status);
    }

    final ctx = RuleContext(body: result.body, url: result.url);
    final items = await _listItems(listRule, ctx, source);

    final out = <NovelChapterItem>[];
    final seen = <String>{};
    for (final item in items) {
      final title = await BookSourceRules.one(
        rules['chapterName'],
        item,
        source: source,
        fallbackRule: '@text',
      );
      final url = RuleEngine.resolveUrl(
        result.url,
        await BookSourceRules.one(
          rules['chapterUrl'],
          item,
          source: source,
          fallbackRule: '@href',
        ),
      );
      if (title.isEmpty || url.isEmpty) continue;
      if (!seen.add(url)) continue;
      out.add(
        NovelChapterItem(
          index: out.length,
          id: BookSourceIds.encode(source.key, url),
          title: title,
        ),
      );
    }
    return out;
  }

  /// 正文。
  Future<NovelText> content(
    BookSource source,
    String bookId,
    String chapterUrl,
  ) async {
    final rule = source.contentRules['content'];
    if (rule == null || rule.trim().isEmpty) {
      throw FetchFailure('这个源没有配置正文规则');
    }
    final buffer = <String>[];
    var current = chapterUrl;
    var title = '';
    for (var page = 0; page < 4; page++) {
      final result = await BookSourceHttp.fetch(
        current,
        headers: _headers(source),
        charset: source.charset,
      );
      if (!result.ok) {
        throw FetchFailure('正文打开失败（HTTP ${result.status}）',
            status: result.status);
      }
      final ctx = RuleContext(body: result.body, url: result.url);
      if (page == 0) {
        title = _pageTitle(result.body);
      }
      buffer.addAll(await BookSourceRules.strings(rule, ctx, source: source));
      final nextRule = source.contentRules['nextContentUrl'];
      if (nextRule == null || nextRule.trim().isEmpty) break;
      final next = await BookSourceRules.one(nextRule, ctx, source: source);
      if (next.isEmpty || next == current) break;
      current = RuleEngine.resolveUrl(result.url, next);
    }

    final paragraphs = _toParagraphs(buffer.join('\n'));
    return NovelText(
      bookId: bookId,
      chapterId: chapterUrl,
      title: title,
      paragraphs: paragraphs,
    );
  }

  /// 求「列表规则」，返回可继续取值的上下文列表。
  ///
  /// 列表规则有三种形态：
  /// - CSS / JSONPath → 直接选节点
  /// - `@js:` 返回 JSON 数组（每项是对象或 JSON 字符串）→ 每项一个上下文
  /// - `@js:` 返回 HTML 片段 → 当作页面继续解析
  Future<List<RuleContext>> _listItems(
    String rule,
    RuleContext ctx,
    BookSource source, {
    String key = '',
    int page = 1,
  }) async {
    if (!BookSourceRules.hasJs(rule)) {
      return [
        for (final node in RuleEngine.selectNodes(rule, ctx))
          RuleContext.child(node, ctx),
      ];
    }

    final rendered = await BookSourceRules.strings(
      rule,
      ctx,
      source: source,
      key: key,
      page: page,
    );
    if (rendered.isEmpty) return const [];
    final text = rendered.join('\n').trim();
    if (text.isEmpty) return const [];

    Object? decoded;
    if (text.startsWith('[') || text.startsWith('{')) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
    }
    if (decoded is List) {
      final out = <RuleContext>[];
      for (final row in decoded) {
        if (row is String) {
          if (row.trim().isNotEmpty) {
            out.add(RuleContext(body: row, url: ctx.url, vars: ctx.vars));
          }
        } else if (row != null) {
          out.add(
            RuleContext(
              body: jsonEncode(row),
              url: ctx.url,
              vars: ctx.vars,
            ),
          );
        }
      }
      return out;
    }
    if (decoded is Map) {
      return [RuleContext(body: jsonEncode(decoded), url: ctx.url, vars: ctx.vars)];
    }

    // 返回的是 HTML：当作新页面，让后续规则在上面选
    final doc = html_parser.parse(text);
    final anchors = doc.querySelectorAll('a');
    if (anchors.isNotEmpty) {
      final page = RuleContext(body: text, url: ctx.url, vars: ctx.vars);
      return [for (final node in anchors) RuleContext.child(node, page)];
    }
    return [RuleContext(body: text, url: ctx.url, vars: ctx.vars)];
  }

  // ---------------------------------------------------------------- 搜索地址

  Future<_SearchRequest> _searchRequest(
    BookSource source,
    String query,
    int page,
  ) async {
    final template = source.searchUrl.trim();

    // 整条 searchUrl 是脚本：让它返回 `url` 或 `url,{options}`
    final scriptPart = BookSourceRules.splitJs(template);
    if (scriptPart != null && scriptPart.prefix.trim().isEmpty) {
      final value = await BookSourceRules.script(
        source,
        scriptPart.code,
        key: query,
        page: page,
      );
      if (value.isEmpty) {
        throw FetchFailure('搜索地址脚本没有返回结果');
      }
      final parsed = _splitOptions(value);
      var address = parsed.url;
      if (!address.contains('://')) {
        address = RuleEngine.resolveUrl(source.url, address);
      }
      return _SearchRequest(
        url: address,
        method: parsed.method,
        body: parsed.body,
        charset: parsed.charset,
        headers: parsed.headers,
      );
    }

    var body = template;
    var method = 'GET';
    String? postBody;
    var charset = '';
    var headers = const <String, String>{};

    final optionsAt = body.lastIndexOf(',{');
    if (optionsAt > 0 && body.endsWith('}')) {
      final optionsText = body.substring(optionsAt + 1);
      body = body.substring(0, optionsAt).trim();
      try {
        final options = jsonDecode(optionsText);
        if (options is Map) {
          method = '${options['method'] ?? 'GET'}'.toUpperCase();
          postBody = options['body']?.toString();
          charset = '${options['charset'] ?? ''}';
          final rawHeaders = options['headers'];
          if (rawHeaders is Map) {
            headers = {
              for (final entry in rawHeaders.entries)
                '${entry.key}': '${entry.value}',
            };
          }
        }
      } catch (_) {}
    }

    final variables = {'key': query, 'page': '$page'};
    var url = _expand(body, variables, charset: charset);
    url = RuleEngine.resolveUrl(source.url, url);
    if (postBody != null) {
      postBody = _expand(postBody, variables, charset: charset);
    }
    return _SearchRequest(
      url: url,
      method: method,
      body: postBody,
      charset: charset,
      headers: headers,
    );
  }

  /// 拆 `url,{method,body,charset,headers}`。
  _SearchRequest _splitOptions(String raw) {
    final text = raw.trim();
    var address = text;
    var method = 'GET';
    String? body;
    var charset = '';
    var headers = const <String, String>{};

    final optionsAt = text.lastIndexOf(',{');
    if (optionsAt > 0 && text.endsWith('}')) {
      final optionsText = text.substring(optionsAt + 1);
      try {
        final options = jsonDecode(optionsText);
        if (options is Map) {
          address = text.substring(0, optionsAt).trim();
          method = '${options['method'] ?? 'GET'}'.toUpperCase();
          body = options['body']?.toString();
          charset = '${options['charset'] ?? ''}';
          final rawHeaders = options['headers'];
          if (rawHeaders is Map) {
            headers = {
              for (final entry in rawHeaders.entries)
                '${entry.key}': '${entry.value}',
            };
          }
        }
      } catch (_) {}
    }
    return _SearchRequest(
      url: address,
      method: method,
      body: body,
      charset: charset,
      headers: headers,
    );
  }

  // ---------------------------------------------------------------- 工具

  Map<String, String> _headers(BookSource source) {
    final raw = source.header.trim();
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            '${entry.key}': '${entry.value}',
        };
      }
    } catch (_) {
      // 不是 JSON 就当没写
    }
    return const {};
  }

  /// 展开 `{{...}}`；`{{key}}` 要按目标站编码转义。
  String _expand(
    String template,
    Map<String, String> vars, {
    required String charset,
  }) {
    final pattern = RegExp(r'\{\{([^}]+)\}\}');
    return template.replaceAllMapped(pattern, (m) {
      final expr = m.group(1)!.trim();
      if (expr == 'key') {
        return _percentEncode(vars['key'] ?? '', charset);
      }
      // 阅读里常见的 `{{java.encodeURI(key)}}` / `{{java.encodeURIComponent(key)}}`
      final encodeCall = RegExp(
        r'^java\.encodeURI(?:Component)?\(\s*(.+?)\s*\)$',
      ).firstMatch(expr);
      if (encodeCall != null) {
        final arg = encodeCall.group(1)!;
        final value =
            vars[arg] ?? arg.replaceAll(RegExp(r'''^['"]|['"]$'''), '');
        return _percentEncode(value, charset);
      }
      final direct = vars[expr];
      if (direct != null) return direct;
      return RuleEngine.expandTemplate(
        '{{$expr}}',
        RuleContext(body: '', vars: vars),
      );
    });
  }

  String _percentEncode(String text, String charset) {
    final lower = charset.toLowerCase();
    final isGbk = lower.contains('gbk') || lower.contains('gb2312');
    final bytes = isGbk ? _gbkBytes(text) : utf8.encode(text);
    final out = StringBuffer();
    for (final byte in bytes) {
      if ((byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          byte == 0x2D ||
          byte == 0x2E ||
          byte == 0x5F ||
          byte == 0x7E) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  List<int> _gbkBytes(String text) {
    try {
      return gbk.encode(text);
    } catch (_) {
      return utf8.encode(text);
    }
  }

  String _pageTitle(String body) {
    final doc = html_parser.parse(body);
    final h1 = doc.querySelector('h1')?.text.trim();
    if (h1 != null && h1.isNotEmpty) return h1;
    final title = doc.querySelector('title')?.text.trim() ?? '';
    return title.split(RegExp(r'[_\-|]')).first.trim();
  }

  /// 把规则取到的片段整理成段落。
  List<String> _toParagraphs(String raw) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 规则给的是 HTML 时把 <br> / <p> 转换行，其余标签去掉
    if (text.contains('<')) {
      text = text
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), '');
      text = _unescape(text);
    }
    final junk = RegExp(
      r'(本章未完|请收藏|最新网址|最快更新|一秒记住|无弹窗|加入书签|章节错误|求月票'
      r'|上一章|下一章|https?://|www\.|\.(com|net|org|cc)(/|\b))',
      caseSensitive: false,
    );
    final out = <String>[];
    for (final line in text.split('\n')) {
      final cleaned = line.replaceAll('\u3000', ' ').trim();
      if (cleaned.isEmpty) continue;
      if (cleaned.length < 100 && junk.hasMatch(cleaned)) continue;
      out.add(cleaned);
    }
    return out;
  }

  String _unescape(String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  String _hostOf(String url) {
    final uri = Uri.tryParse(url);
    return uri?.host ?? url;
  }
}
