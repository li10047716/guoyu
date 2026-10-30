/// 自定义书源（「阅读 / Legado」格式）。
///
/// 0.7.68 新增：支持导入开源阅读（Legado 3.x）格式的书源 JSON，
/// 用规则子集解释器跑纯网站规则源。
///
/// 0.7.69 起 `@js:` / `<js>` 规则交给原生核心里的 goja 运行时执行
/// （见 `legado_script.dart`）；只有依赖 XPath、或脚本里直接实例化
/// Java 类（`Packages.java.*`）的源才算不可用。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 书源的可用状态。
enum BookSourceStatus {
  /// 规则只用了 CSS / JSONPath / 正则，本地引擎能跑。
  ready,

  /// 规则里有 `@js:` / `<js>`，需要 JS 引擎。
  ///
  /// 0.7.69 起由原生核心的 goja 运行时处理，不再算不可用；
  /// 保留枚举是为了兼容旧存档里写下的 _status。
  needsJs,

  /// 规则里直接实例化了 Java 类（`Packages.java.*` / `Java.type`），
  /// 这些依赖真正的 JVM 类库，本地 JS 引擎跑不了。
  needsJava,

  /// 规则里有 `@xpath:` 或 `//` 开头的 XPath。
  needsXPath,

  /// 缺少必要规则（比如没有 searchUrl 也没有 exploreUrl）。
  incomplete,
}

extension BookSourceStatusLabel on BookSourceStatus {
  String get label => switch (this) {
    BookSourceStatus.ready => '可用',
    BookSourceStatus.needsJs => '可用',
    BookSourceStatus.needsJava => '需要 Java',
    BookSourceStatus.needsXPath => '需要 XPath',
    BookSourceStatus.incomplete => '规则不全',
  };

  /// `needsJs` 现在由原生 JS 运行时接管，同样算可用。
  bool get usable =>
      this == BookSourceStatus.ready || this == BookSourceStatus.needsJs;
}

/// `exploreUrl` 里的一条发现条目。
///
/// Legado 的写法是一段多行文本，每行 `名称::地址`（可带第三段样式），
/// 地址留空的那行是**分组标题**：
///
/// ```
/// 📊 排行榜::
/// 🔥 推荐榜::https://example.com?t=rank&algo=101
/// ```
class BookSourceExploreEntry {
  const BookSourceExploreEntry({
    required this.name,
    required this.url,
    this.group = '',
  });

  final String name;
  final String url;

  /// 所属分组（分组标题之前的最近一个标题）。
  final String group;

  /// 分组标题本身（不可点，只用来分隔）。
  bool get isHeader => url.trim().isEmpty;

  /// 解析整段 `exploreUrl`。
  ///
  /// 兼容四种常见写法：
  /// - `名称::地址`
  /// - `名称::地址::样式`（第三段忽略）
  /// - 单行只有地址（名称取地址本身）
  /// - 多条挤在一行、用 `&&` 分隔（不少导出的源这么写，0.7.82 支持）
  /// - **JSON 数组** `[{"title":"玄幻","url":"..."}]`（0.7.83 支持）
  ///
  /// 脚本写法（`@js:` / `<js>`）这里返回空，交给 [NovelGateway.exploreEntries]
  /// 异步求值——同步解析拿不到脚本结果。
  static List<BookSourceExploreEntry> parseList(String raw) {
    final out = <BookSourceExploreEntry>[];
    final text0 = raw.trim();
    if (text0.isEmpty) return out;
    if (isScript(text0)) return out;

    // JSON 数组写法：条目里带 title/url（可能还带 style，忽略）。
    if (text0.startsWith('[') || text0.startsWith('{')) {
      final decoded = _decodeJson(text0);
      if (decoded != null) return _fromJson(decoded);
      return out;
    }

    var group = '';
    // 0.7.82：有些源的 exploreUrl 把多条压成一行用 `&&` 连接
    // （例如「玄幻::https://a/1.html&&修真::https://a/2.html」）。
    // 以前只按换行切分，整段会被当成一条，地址里混入 `&&名称`，
    // 请求出去就是 HTTP 404——发现页「打开失败」的根因。
    for (final line in text0.split(RegExp(r'&&|\r?\n'))) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final parts = text.split('::');
      if (parts.length == 1) {
        // 只有地址：当作一条无分组的条目
        if (text.contains('://') || text.startsWith('/')) {
          out.add(BookSourceExploreEntry(name: _labelOfUrl(text), url: text));
        }
        continue;
      }
      final name = parts[0].trim();
      final url = parts[1].trim();
      if (url.isEmpty) {
        group = name;
        out.add(BookSourceExploreEntry(name: name, url: '', group: group));
        continue;
      }
      out.add(
        BookSourceExploreEntry(
          name: name.isEmpty ? _labelOfUrl(url) : name,
          url: url,
          group: group,
        ),
      );
    }
    return out;
  }

  /// `exploreUrl` 是否以脚本形式书写（`@js:` 或 `<js>…</js>`）。
  ///
  /// Legado 允许整段 `exploreUrl` 用脚本生成条目，例如返回
  /// `[{title:'玄幻', url:'https://…'}]`。这种写法必须异步求值。
  static bool isScript(String raw) {
    final text = raw.trim();
    return text.startsWith('@js:') || text.startsWith('<js>');
  }

  /// 从脚本形式的 `exploreUrl` 里剥出可执行的代码。
  static String scriptCode(String raw) {
    var text = raw.trim();
    if (text.startsWith('@js:')) text = text.substring(4);
    if (text.startsWith('<js>')) text = text.substring(4);
    if (text.endsWith('</js>')) {
      text = text.substring(0, text.length - 5);
    }
    return text.trim();
  }

  /// 把脚本求值结果（JSON 数组 / 文本列表）解析成条目。
  static List<BookSourceExploreEntry> parseResolved(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];
    if (text.startsWith('[') || text.startsWith('{')) {
      final decoded = _decodeJson(text);
      if (decoded != null) {
        final fromJson = _fromJson(decoded);
        if (fromJson.isNotEmpty) return fromJson;
      }
    }
    return parseList(text);
  }

  static Object? _decodeJson(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// `[{title:'x', url:'y'}]` → 条目；也兼容带分组的 `{title, url}` 映射。
  static List<BookSourceExploreEntry> _fromJson(Object? decoded) {
    final out = <BookSourceExploreEntry>[];
    void take(Object? row, {String group = ''}) {
      if (row is String) {
        final text = row.trim();
        if (text.isEmpty) return;
        if (text.contains('::')) {
          out.addAll(parseList(text));
        } else if (text.contains('://')) {
          out.add(BookSourceExploreEntry(name: _labelOfUrl(text), url: text));
        }
        return;
      }
      if (row is! Map) return;
      final title =
          (row['title'] ?? row['name'] ?? row['group'] ?? '').toString().trim();
      final url = (row['url'] ?? row['link'] ?? '').toString().trim();
      if (url.isEmpty) {
        // 只有标题 = 分组标题
        if (title.isNotEmpty) {
          out.add(BookSourceExploreEntry(name: title, url: '', group: title));
        }
        return;
      }
      out.add(
        BookSourceExploreEntry(
          name: title.isEmpty ? _labelOfUrl(url) : title,
          url: url,
          group: group,
        ),
      );
    }

    if (decoded is List) {
      for (final row in decoded) {
        take(row);
      }
      return out;
    }
    if (decoded is Map) {
      // `{ '分组名': [{title,url}], ... }` 或单个 `{title,url}`
      if (decoded.containsKey('url') || decoded.containsKey('title')) {
        take(decoded);
        return out;
      }
      decoded.forEach((key, value) {
        if (value is List) {
          for (final row in value) {
            take(row, group: '$key');
          }
        } else {
          take(value, group: '$key');
        }
      });
    }
    return out;
  }

  static String _labelOfUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.query.isEmpty ? uri.path : '${uri.host}${uri.path}';
  }
}

/// 一个书源。
class BookSource {
  const BookSource({
    required this.key,
    required this.name,
    required this.url,
    this.group = '',
    this.comment = '',
    this.type = 0,
    this.enabled = true,
    this.order = 0,
    this.charset = '',
    this.searchUrl = '',
    this.exploreUrl = '',
    this.header = '',
    this.searchRules = const {},
    this.bookInfoRules = const {},
    this.tocRules = const {},
    this.contentRules = const {},
    this.status = BookSourceStatus.ready,
    this.statusDetail = '',
    this.raw = const {},
    this.variables = const {},
  });

  /// 稳定 ID：书源地址的 sha1 前 12 位（同一地址重复导入算同一个源）。
  final String key;
  final String name;

  /// bookSourceUrl，书源的主域名。
  final String url;
  final String group;
  final String comment;

  /// 0 = 文本，1 = 音频，2 = 图片，3 = 文件。
  final int type;
  final bool enabled;
  final int order;

  /// 站点编码，空表示 UTF-8。
  final String charset;

  /// 搜索地址模板，含 `{{key}}` / `{{page}}`。
  final String searchUrl;

  /// 发现/分类地址，形如 `分组::url\n分组2::url2`。
  final String exploreUrl;

  /// 请求头，JSON 字符串。
  final String header;

  final Map<String, String> searchRules;
  final Map<String, String> bookInfoRules;
  final Map<String, String> tocRules;
  final Map<String, String> contentRules;

  final BookSourceStatus status;

  /// 不可用原因（命中的具体规则片段），用于界面提示。
  final String statusDetail;

  /// 原始 JSON（编辑/导出用）。
  final Map<String, dynamic> raw;

  /// 书源变量（脚本里 `source.setVariable` / `java.put` 写下的值）。
  final Map<String, String> variables;

  bool get usable => status.usable && enabled;

  /// 搜索链路里用的源标识，书籍 id 会以 `bs:` 前缀带上它。
  String get sourceTag => 'bs:$key';

  /// 发现（探索）规则。
  ///
  /// 单独写 `ruleExplore` 的源按它走；很多源省略了它，
  /// 但字段名和 `ruleSearch` 完全一致，所以缺的项用搜索规则兜底。
  Map<String, String> get exploreRules {
    final own = _rules(raw['ruleExplore']);
    if (own.isEmpty) return searchRules;
    return {...searchRules, ...own};
  }

  /// `exploreUrl` 解析出来的发现条目（含分组标题）。
  ///
  /// 只覆盖「纯文本」写法；`exploreUrl` 是脚本（`@js:` / `<js>`）时这里
  /// 返回空列表，要拿条目得走 [NovelGateway.exploreEntries]（异步求值）。
  List<BookSourceExploreEntry> get exploreEntries =>
      BookSourceExploreEntry.parseList(exploreUrl);

  /// `exploreUrl` 是不是一段脚本（Legado 允许整段走 JS 生成条目）。
  bool get exploreIsScript => BookSourceExploreEntry.isScript(exploreUrl);

  BookSource copyWith({
    String? name,
    String? group,
    String? comment,
    bool? enabled,
    int? order,
    String? charset,
    String? searchUrl,
    String? exploreUrl,
    String? header,
    Map<String, String>? searchRules,
    Map<String, String>? bookInfoRules,
    Map<String, String>? tocRules,
    Map<String, String>? contentRules,
    BookSourceStatus? status,
    String? statusDetail,
    Map<String, dynamic>? raw,
    Map<String, String>? variables,
  }) => BookSource(
    key: key,
    name: name ?? this.name,
    url: url,
    group: group ?? this.group,
    comment: comment ?? this.comment,
    type: type,
    enabled: enabled ?? this.enabled,
    order: order ?? this.order,
    charset: charset ?? this.charset,
    searchUrl: searchUrl ?? this.searchUrl,
    exploreUrl: exploreUrl ?? this.exploreUrl,
    header: header ?? this.header,
    searchRules: searchRules ?? this.searchRules,
    bookInfoRules: bookInfoRules ?? this.bookInfoRules,
    tocRules: tocRules ?? this.tocRules,
    contentRules: contentRules ?? this.contentRules,
    status: status ?? this.status,
    statusDetail: statusDetail ?? this.statusDetail,
    raw: raw ?? this.raw,
    variables: variables ?? this.variables,
  );

  /// 从「阅读」书源 JSON 构造。
  factory BookSource.fromLegado(Map<String, dynamic> json, {int order = 0}) {
    final url = _str(json['bookSourceUrl']).trim();
    final name = _str(json['bookSourceName']).trim();
    final search = _rules(json['ruleSearch']);
    final bookInfo = _rules(json['ruleBookInfo']);
    final toc = _rules(json['ruleToc']);
    final content = _rules(json['ruleContent']);
    final source = BookSource(
      key: keyOf(url, name),
      name: name.isEmpty ? url : name,
      url: url,
      group: _str(json['bookSourceGroup']).trim(),
      comment: _str(json['bookSourceComment']),
      type: (json['bookSourceType'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      order: (json['customOrder'] as num?)?.toInt() ?? order,
      charset: _str(json['charset']),
      searchUrl: _str(json['searchUrl']),
      exploreUrl: _str(json['exploreUrl']),
      header: _headerOf(json),
      searchRules: search,
      bookInfoRules: bookInfo,
      tocRules: toc,
      contentRules: content,
      raw: json,
      variables: _varsOf(json),
    );
    final probe = source._probeStatus();
    return source.copyWith(status: probe.$1, statusDetail: probe.$2, raw: json);
  }

  /// key 规则：优先按地址生成，地址为空时退化到名称。
  static String keyOf(String url, String name) {
    final seed = url.isEmpty ? 'name:$name' : url;
    return sha1.convert(utf8.encode(seed)).toString().substring(0, 12);
  }

  /// 检测这个源能不能被本地引擎跑起来。
  ///
  /// - XPath 规则：本地没实现，不可用
  /// - 规则不全（缺目录/正文）：不可用
  /// - `@js:` / `<js>` / `Packages.java.*`：都交给原生 goja 运行时，
  ///   Java 类库已实现常用子集（见 `legado_java.go`），因此不再预先判死，
  ///   真正跑不跑得通由实测决定。
  (BookSourceStatus, String) _probeStatus() {
    final critical = <String, String>{
      '搜索地址': searchUrl,
      '搜索列表': searchRules['bookList'] ?? '',
      '搜索书址': searchRules['bookUrl'] ?? '',
      '目录地址': bookInfoRules['tocUrl'] ?? '',
      '目录列表': tocRules['chapterList'] ?? '',
      '目录章节名': tocRules['chapterName'] ?? '',
      '目录章节址': tocRules['chapterUrl'] ?? '',
      '正文': contentRules['content'] ?? '',
    };

    for (final entry in critical.entries) {
      final rule = entry.value.trim();
      if (rule.isEmpty) continue;
      if (rule.startsWith('@xpath:') || rule.startsWith('//')) {
        return (
          BookSourceStatus.needsXPath,
          '${entry.key}用了 XPath：${_clip(rule)}',
        );
      }
    }

    final hasSearch =
        searchUrl.trim().isNotEmpty && searchRules['bookList'] != null;
    final hasExplore = exploreUrl.trim().isNotEmpty;
    if (!hasSearch && !hasExplore) {
      return (
        BookSourceStatus.incomplete,
        '缺少 searchUrl/bookList，也没有 exploreUrl',
      );
    }
    if (tocRules['chapterList'] == null || contentRules['content'] == null) {
      return (BookSourceStatus.incomplete, '缺少目录或正文规则');
    }
    return (BookSourceStatus.ready, '');
  }

  static String _clip(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length > 60 ? '${flat.substring(0, 60)}…' : flat;
  }

  /// 落盘用（保持「阅读」字段名，方便再导出）。
  Map<String, dynamic> toJson() => {
    ...raw,
    'bookSourceName': name,
    'bookSourceUrl': url,
    'bookSourceGroup': group,
    'bookSourceType': type,
    'enabled': enabled,
    'customOrder': order,
    if (charset.isNotEmpty) 'charset': charset,
    'searchUrl': searchUrl,
    if (exploreUrl.isNotEmpty) 'exploreUrl': exploreUrl,
    if (header.isNotEmpty) 'header': header,
    'ruleSearch': searchRules,
    'ruleBookInfo': bookInfoRules,
    'ruleToc': tocRules,
    'ruleContent': contentRules,
    // 本项目私有字段：跨版本保留可用性判定结果，避免每次启动重算。
    '_status': status.name,
    '_statusDetail': statusDetail,
    if (variables.isNotEmpty) '_vars': variables,
  };

  factory BookSource.fromJson(Map<String, dynamic> json) {
    final base = BookSource.fromLegado(json);
    final saved = json['_status'];
    if (saved is String) {
      final status = BookSourceStatus.values.firstWhere(
        (v) => v.name == saved,
        orElse: () => base.status,
      );
      return base.copyWith(
        status: status,
        statusDetail: _str(json['_statusDetail']),
      );
    }
    return base;
  }

  static BookSourceStatus statusFromName(String name) =>
      BookSourceStatus.values.firstWhere(
        (v) => v.name == name,
        orElse: () => BookSourceStatus.incomplete,
      );

  static Map<String, String> _rules(Object? value) {
    if (value is! Map) return const {};
    final out = <String, String>{};
    value.forEach((k, v) {
      if (v == null) return;
      final text = v is String ? v : jsonEncode(v);
      if (text.trim().isEmpty) return;
      out['$k'] = text;
    });
    return out;
  }

  static String _headerOf(Map<String, dynamic> json) {
    final raw = json['header'];
    if (raw is String) return raw.trim();
    if (raw is Map && raw.isNotEmpty) return jsonEncode(raw);
    return '';
  }

  static Map<String, String> _varsOf(Map<String, dynamic> json) {
    final raw = json['_vars'];
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((k, v) {
      if (v == null) return;
      out['$k'] = '$v';
    });
    return out;
  }

  static String _str(Object? v) => v == null ? '' : '$v';
}
