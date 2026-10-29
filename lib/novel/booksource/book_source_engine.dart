/// 用「阅读」书源规则真的去抓书：搜索 / 详情 / 目录 / 正文。
///
/// 只跑规则子集（见 [RuleEngine]）；命中 `@js:` 的规则会抛 [UnsupportedRule]，
/// 这类源在导入时就已经被标成不可用了。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/novel_models.dart';
import 'book_source.dart';
import 'book_source_http.dart';
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
    final request = _searchRequest(source, query, page);
    final result = await BookSourceHttp.fetch(
      request.url,
      method: request.method,
      body: request.body,
      headers: _headers(source),
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

    final nodes = RuleEngine.selectNodes(listRule, ctx);
    final out = <Novel>[];
    final seen = <String>{};
    for (final node in nodes) {
      final item = RuleContext.child(node, ctx);
      final name = _pick(source.searchRules['name'], item, fallbackRule: '@text');
      final bookUrl = _pick(
        source.searchRules['bookUrl'],
        item,
        fallbackRule: '@href',
      );
      if (name.isEmpty || bookUrl.isEmpty) continue;
      if (!seen.add(bookUrl)) continue;
      out.add(
        Novel(
          id: BookSourceIds.encode(source.key, bookUrl),
          source: source.sourceTag,
          title: name,
          author: _pick(source.searchRules['author'], item),
          category: _pick(source.searchRules['kind'], item),
          description: _pick(source.searchRules['intro'], item),
          cover: _pick(source.searchRules['coverUrl'], item),
          latest: _pick(source.searchRules['lastChapter'], item),
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

    final name = _pick(rules['name'], ctx, fallbackRule: '@text');
    final author = _pick(rules['author'], ctx);
    final kind = _pick(rules['kind'], ctx);
    final intro = _pick(rules['intro'], ctx);
    final cover = _pick(rules['coverUrl'], ctx);
    final latest = _pick(rules['lastChapter'], ctx);

    var tocUrl = _pick(rules['tocUrl'], ctx);
    if (tocUrl.isEmpty) tocUrl = detailResult.url;

    final chapters = await this.chapters(source, tocUrl);

    return NovelBook(
      novel: Novel(
        id: BookSourceIds.encode(source.key, detailResult.url),
        source: source.sourceTag,
        title: name.isEmpty ? _hostOf(bookUrl) : name,
        author: author,
        category: kind,
        description: intro,
        cover: cover,
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
    final nodes = RuleEngine.selectNodes(listRule, ctx);
    final out = <NovelChapterItem>[];
    final seen = <String>{};
    for (final node in nodes) {
      final item = RuleContext.child(node, ctx);
      final title = _pick(rules['chapterName'], item, fallbackRule: '@text');
      final url = _pick(rules['chapterUrl'], item, fallbackRule: '@href');
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
      buffer.addAll(RuleEngine.selectStrings(rule, ctx));
      final nextRule = source.contentRules['nextContentUrl'];
      if (nextRule == null || nextRule.trim().isEmpty) break;
      final next = RuleEngine.selectOne(nextRule, ctx);
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

  // ---------------------------------------------------------------- 工具

  String _pick(
    String? rule,
    RuleContext ctx, {
    String fallbackRule = '',
  }) {
    final actual = (rule == null || rule.trim().isEmpty) ? fallbackRule : rule;
    if (actual.isEmpty) return '';
    try {
      return RuleEngine.selectOne(actual, ctx);
    } on UnsupportedRule {
      return '';
    }
  }

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

  ({String url, String method, String? body, String charset}) _searchRequest(
    BookSource source,
    String query,
    int page,
  ) {
    var template = source.searchUrl.trim();
    var method = 'GET';
    String? postBody;
    var charset = '';

    // 阅读允许 `url,{"method":"POST","body":"...","charset":"gbk"}` 这种写法
    final optionsAt = template.lastIndexOf(',{');
    if (optionsAt > 0 && template.endsWith('}')) {
      final optionsText = template.substring(optionsAt + 1);
      template = template.substring(0, optionsAt).trim();
      try {
        final options = jsonDecode(optionsText);
        if (options is Map) {
          method = '${options['method'] ?? 'GET'}'.toUpperCase();
          postBody = options['body']?.toString();
          charset = '${options['charset'] ?? ''}';
        }
      } catch (_) {}
    }

    final variables = {'key': query, 'page': '$page'};
    final url = _expand(template, variables, encodeKey: true, charset: charset);
    if (postBody != null) {
      postBody = _expand(postBody, variables, encodeKey: false, charset: charset);
    }
    return (url: url, method: method, body: postBody, charset: charset);
  }

  /// 展开 `{{...}}`；`{{key}}` 在 URL 里要按目标站编码转义。
  String _expand(
    String template,
    Map<String, String> vars, {
    required bool encodeKey,
    required String charset,
  }) {
    final pattern = RegExp(r'\{\{([^}]+)\}\}');
    return template.replaceAllMapped(pattern, (m) {
      final expr = m.group(1)!.trim();
      if (expr == 'key' && encodeKey) {
        return _percentEncode(vars['key'] ?? '', charset);
      }
      final direct = vars[expr];
      if (direct != null) return direct;
      final number = RuleEngine.expandTemplate('{{$expr}}', RuleContext(
        body: '',
        vars: vars,
      ));
      return number;
    });
  }

  String _percentEncode(String text, String charset) {
    final isGbk = charset.toLowerCase().contains('gbk') ||
        charset.toLowerCase().contains('gb2312');
    final bytes = isGbk
        ? _gbkBytes(text)
        : utf8.encode(text);
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
