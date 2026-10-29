/// 书源的网络层：dart:io HttpClient + 编码嗅探（UTF-8 / GBK）。
///
/// 不用第三方 http 包，避免再多一个依赖；书源抓取需要的能力这里够用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 一次抓取的结果。
class FetchResult {
  const FetchResult({
    required this.body,
    required this.url,
    required this.status,
  });

  final String body;

  /// 跟随重定向之后的最终地址（相对链接要按这个解析）。
  final String url;
  final int status;

  bool get ok => status >= 200 && status < 300;
}

/// 抓取失败。
class FetchFailure implements Exception {
  FetchFailure(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => message;
}

/// 书源抓取器。
class BookSourceHttp {
  BookSourceHttp._();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 单次响应上限，防止书源指向大文件把内存吃满。
  static const int maxBytes = 8 << 20;

  static final Map<String, String> _defaultHeaders = {
    'User-Agent': defaultUserAgent,
    'Accept': 'text/html,application/json,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// GET / POST 抓取。
  ///
  /// [charset] 传 `gbk` / `gb2312` 时按 GBK 解码，否则先试 UTF-8。
  ///
  /// 重定向自己跟：Dart 只对 GET/HEAD 自动跟随，书源的搜索多是 POST，
  /// 站点一个 301 跳到补斜杠的地址就会把请求晾在那里。
  static Future<FetchResult> fetch(
    String url, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
    String charset = '',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var currentUrl = url;
    var currentMethod = method.toUpperCase();
    var currentBody = body;

    for (var hop = 0; hop <= 6; hop++) {
      final sent = await _send(
        currentUrl,
        currentMethod,
        currentBody,
        headers,
        charset,
        timeout,
      );
      final status = sent.result.status;
      final location = sent.location;
      if (location == null || location.isEmpty || hop == 6) return sent.result;
      if (status < 300 || status >= 400) return sent.result;

      // 303 一律转 GET；301/302 对 POST 也按浏览器的习惯转 GET
      if (status == 303 ||
          ((status == 301 || status == 302) &&
              currentMethod != 'GET' &&
              currentMethod != 'HEAD')) {
        currentMethod = 'GET';
        currentBody = null;
      }
      try {
        currentUrl = Uri.parse(currentUrl).resolve(location).toString();
      } catch (_) {
        return sent.result;
      }
    }
    throw FetchFailure('重定向次数过多：$url');
  }

  static Future<({FetchResult result, String? location})> _send(
    String url,
    String method,
    String? body,
    Map<String, String> headers,
    String charset,
    Duration timeout,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = headers['User-Agent'] ?? defaultUserAgent;
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.followRedirects = false;
      _defaultHeaders.forEach((k, v) {
        if (!headers.keys.any((h) => h.toLowerCase() == k.toLowerCase())) {
          request.headers.set(k, v);
        }
      });
      headers.forEach((k, v) {
        if (k.toLowerCase() == 'user-agent') return;
        // HttpClient 只收 Latin-1 头值；书源里常写中文占位（如「其他你抓到的Cookie」），
        // 直接 set 会抛 FormatException，这里先洗一遍。
        final safe = _sanitizeHeader(v);
        if (safe == null) return;
        try {
          request.headers.set(k, safe);
        } catch (_) {
          // 头名本身不合法就跳过
        }
      });
      if (method == 'POST' && body != null) {
        final bytes = _encode(body, charset);
        request.headers.contentLength = bytes.length;
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: _isGbk(charset) ? 'gbk' : 'utf-8',
        );
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        buffer.add(chunk);
        if (buffer.length > maxBytes) {
          throw FetchFailure('响应超过 ${maxBytes >> 20}MB，已中止');
        }
      }
      final bytes = buffer.takeBytes();
      final contentType = response.headers.contentType?.charset ?? '';
      final effective = charset.isNotEmpty ? charset : contentType;
      return (
        result: FetchResult(
          body: _decode(bytes, effective),
          url: url,
          status: response.statusCode,
        ),
        location: response.headers.value(HttpHeaders.locationHeader),
      );
    } on FetchFailure {
      rethrow;
    } on TimeoutException {
      throw FetchFailure('请求超时：$url');
    } on SocketException catch (e) {
      throw FetchFailure('网络错误：${e.message}');
    } on FormatException {
      throw FetchFailure('地址不合法：$url');
    } finally {
      client.close(force: true);
    }
  }

  /// 头值只保留 Latin-1 可见字符；洗空了就返回 null 表示跳过。
  static String? _sanitizeHeader(String value) {
    if (value.isEmpty) return null;
    final cleaned = value.replaceAll(RegExp(r'[^\t\x20-\x7E\x80-\xFF]'), '');
    return cleaned.trim().isEmpty ? null : cleaned;
  }

  static bool _isGbk(String charset) {    final c = charset.toLowerCase();
    return c.contains('gbk') || c.contains('gb2312') || c.contains('gb18030');
  }

  static String _decode(Uint8List bytes, String charset) {
    if (_isGbk(charset)) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // 落到 UTF-8 再试一次
      }
    }
    if (bytes.length >= 2 && bytes[0] == 0xEF && bytes[1] == 0xBB) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    // UTF-8 解出大量替换符时，按 GBK 再解一次（很多老站声明不准）
    if (_replacementRatio(text) > 0.02) {
      try {
        return gbk.decode(bytes);
      } catch (_) {}
    }
    return text;
  }

  static double _replacementRatio(String text) {
    if (text.isEmpty) return 0;
    var bad = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD) bad++;
    }
    return bad / text.length;
  }

  static Uint8List _encode(String text, String charset) => _isGbk(charset)
      ? Uint8List.fromList(gbk.encode(text))
      : Uint8List.fromList(utf8.encode(text));
}
