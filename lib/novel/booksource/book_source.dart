/// 自定义书源（「阅读 / Legado」格式）。
///
/// 0.7.68 新增：支持导入开源阅读（Legado 3.x）格式的书源 JSON，
/// 用规则子集解释器跑纯网站规则源。
///
/// 说明：`@js:` 规则依赖 JS 引擎 + Java 类模拟，本项目暂不实现，
/// 这类源导入后会被标记为「需要 JS」，可以在列表里看到但不能用。
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
    return source.copyWith(
      status: probe.$1,
      statusDetail: probe.$2,
      raw: json,
    );
  }

  /// key 规则：优先按地址生成，地址为空时退化到名称。
  static String keyOf(String url, String name) {
    final seed = url.isEmpty ? 'name:$name' : url;
    return sha1.convert(utf8.encode(seed)).toString().substring(0, 12);
  }

  /// 检测这个源能不能被本地引擎跑起来。
  ///
  /// - XPath 规则：本地没实现，不可用
  /// - `Packages.java.*` / `Java.type`：要真 JVM 类库，不可用
  /// - `@js:`：交给原生 goja 运行时，可用
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

    // Java 类依赖：脚本里直接 new Java 对象，必须真 JVM
    final jsLib = _str(raw['jsLib']);
    if (_usesJavaClasses(jsLib)) {
      return (
        BookSourceStatus.needsJava,
        'jsLib 里用了 Java 类（Packages.java.*），本地跑不了',
      );
    }
    for (final entry in <String, String>{
      ...{'搜索地址': searchUrl},
      ...searchRules,
      ...bookInfoRules,
      ...tocRules,
      ...contentRules,
    }.entries) {
      if (_usesJavaClasses(entry.value)) {
        return (
          BookSourceStatus.needsJava,
          '${entry.key}用了 Java 类：${_clip(entry.value)}',
        );
      }
    }

    final hasSearch =
        searchUrl.trim().isNotEmpty && searchRules['bookList'] != null;
    final hasExplore = exploreUrl.trim().isNotEmpty;
    if (!hasSearch && !hasExplore) {
      return (BookSourceStatus.incomplete, '缺少 searchUrl/bookList，也没有 exploreUrl');
    }
    if (tocRules['chapterList'] == null || contentRules['content'] == null) {
      return (BookSourceStatus.incomplete, '缺少目录或正文规则');
    }
    return (BookSourceStatus.ready, '');
  }

  static bool _usesJavaClasses(String rule) =>
      rule.contains('Packages.') || rule.contains('Java.type');

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
