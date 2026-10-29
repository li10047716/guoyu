/// 书源 JS 规则的执行入口（0.7.69）。
///
/// 真正的解释器在 Go 核心（`legado_script.go`，用 goja 跑 ES）。
/// 这里只负责把书源信息、上下文变量打包过去，再把结果拿回来。
///
/// 之所以放在原生侧：Legado 的脚本语义是同步的（`java.ajax` 直接返回正文），
/// Go 的 http 天然同步，而 Dart 侧要绕异步，代价太大。
library;

import '../../core/core_bridge.dart';
import 'book_source.dart';

/// 一次脚本执行的结果。
class LegadoScriptResult {
  const LegadoScriptResult({
    required this.value,
    this.variables = const {},
  });

  final String value;

  /// 脚本里用 put/setVariable 写下的变量，调用方负责持久化。
  final Map<String, String> variables;
}

/// 书源脚本执行器。
class LegadoScript {
  const LegadoScript._();

  /// 执行 [code]（已经去掉 `@js:` 前缀）。
  ///
  /// [result] 对应脚本里的 `result`，[extraVars] 会作为额外全局变量注入。
  ///
  /// [resultIsElement] 为真表示 [result] 是一段 HTML：脚本里拿到的
  /// `result` 会是带 `select()/attr()/text()` 的元素对象（jsoup 语义）。
  static Future<LegadoScriptResult> run(
    BookSource source,
    String code, {
    String result = '',
    bool resultIsElement = false,
    String key = '',
    int page = 1,
    String baseUrl = '',
    Map<String, String> extraVars = const {},
    String bookName = '',
    String bookUrl = '',
    String bookAuthor = '',
  }) async {
    if (code.trim().isEmpty) return const LegadoScriptResult(value: '');

    // jsLib 可能很大（番茄源的库有 1.4MB），同一份只发一次，
    // 之后只发缓存键，由原生侧按 key 取回。
    final jsLib = _jsLibOf(source);
    final jsLibKey = jsLib.isEmpty ? '' : _jsLibKeyOf(source, jsLib);
    final sendLib = jsLib.isNotEmpty && _sentJsLib[source.key] != jsLibKey;
    if (sendLib) _sentJsLib[source.key] = jsLibKey;

    final payload = <String, dynamic>{
      'code': code,
      'jsLib': sendLib ? jsLib : '',
      'jsLibKey': jsLibKey,
      'key': key,
      'page': page,
      'baseUrl': baseUrl.isEmpty ? source.url : baseUrl,
      'result': result,
      'resultElement': resultIsElement,
      'extras': extraVars,
      'source': {
        'key': source.key,
        'name': source.name,
        'url': source.url,
        'header': source.header,
        'variables': source.variables,
      },
      'book': {
        'name': bookName,
        'author': bookAuthor,
        'url': bookUrl,
        'vars': const <String, String>{},
      },
    };

    Map<String, dynamic> data;
    try {
      data = await evalLegadoScript(payload);
    } on AppFailure catch (error) {
      // 原生侧的缓存被淘汰了（只发了键），补发整库重试一次。
      if (!error.message.contains('jsLib-missing') || jsLib.isEmpty) rethrow;
      _sentJsLib.remove(source.key);
      payload['jsLib'] = jsLib;
      data = await evalLegadoScript(payload);
      _sentJsLib[source.key] = jsLibKey;
    }
    final variables = <String, String>{};
    final rawVars = data['variables'];
    if (rawVars is Map) {
      rawVars.forEach((k, v) {
        if (v == null) return;
        variables['$k'] = '$v';
      });
    }
    return LegadoScriptResult(
      value: '${data['value'] ?? ''}',
      variables: variables,
    );
  }

  /// 书源里以 `@js:` 开头的规则。
  static bool looksLikeJs(String rule) => rule.trimLeft().startsWith('@js:');

  /// 去掉 `@js:` 前缀。
  static String codeOf(String rule) {
    final trimmed = rule.trimLeft();
    if (!trimmed.startsWith('@js:')) return trimmed;
    return trimmed.substring(4);
  }

  static String _jsLibOf(BookSource source) {
    final raw = source.raw['jsLib'];
    return raw is String ? raw : '';
  }

  /// 已经发过 jsLib 的书源（sourceKey → 指纹），同进程内不重复传大字符串。
  static final Map<String, String> _sentJsLib = {};

  static String _jsLibKeyOf(BookSource source, String jsLib) =>
      '${source.key}:${jsLib.length}:${jsLib.hashCode}';
}
