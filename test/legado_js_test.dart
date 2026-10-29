/// 书源脚本运行时的能力测试（jsoup / Java 类库）。
///
/// 需要原生核心：
///   DUANJU_CORE_DLL=windows/runner/duanju_core.dll flutter test test/legado_js_test.dart
///
/// 找不到 DLL 时整组跳过，CI 上不会失败。
library;

import 'dart:io';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dll = Platform.environment['DUANJU_CORE_DLL'] ?? '';
  final ready = dll.isNotEmpty && File(dll).existsSync();
  if (!ready) {
    test('书源脚本能力测试', () {}, skip: '需要 DUANJU_CORE_DLL 指向已构建的原生核心');
    return;
  }

  /// 跑一段脚本，返回字符串结果。
  Future<String> run(String code) async {
    final data = await evalLegadoScript({
      'code': code,
      'jsLib': '',
      'key': '关键词',
      'page': 1,
      'baseUrl': 'https://example.com',
      'result': '',
      'extras': <String, String>{},
      'source': {
        'key': 'test',
        'name': '测试',
        'url': 'https://example.com',
        'header': '',
        'variables': <String, String>{},
      },
    });
    return '${data['value'] ?? ''}';
  }

  group('jsoup', () {
    test('parse + select + text + attr', () async {
      final value = await run('''
        var doc = org.jsoup.Jsoup.parse('<div class="list"><a href="/b/1">一</a><a href="/b/2">二</a></div>');
        var links = doc.select('a');
        return links.size() + '|' + links.get(1).text() + '|' + links.get(0).attr('href');
      ''');
      expect(value, '2|二|/b/1');
    });

    test('元素级 result 可以继续 select', () async {
      final data = await evalLegadoScript({
        'code': '''
          var href = result.select('td').get(1).select('a').attr('href');
          return href.replace('/Book/', '/m/');
        ''',
        'jsLib': '',
        'key': '',
        'page': 1,
        'baseUrl': 'https://example.com',
        'result':
            '<tr><td>书名</td><td><a href="http://x.com/Book/9">链接</a></td></tr>',
        'resultElement': true,
        'extras': <String, String>{},
        'source': {
          'key': 'test',
          'name': '测试',
          'url': 'https://example.com',
          'header': '',
          'variables': <String, String>{},
        },
      });
      expect('${data['value']}', 'http://x.com/m/9');
    });

    test('abs 属性按 baseUrl 补全', () async {
      final value = await run(
        'return org.jsoup.Jsoup.parse(\'<a href="/x/1">a</a>\').select("a").attr("abs:href");',
      );
      expect(value, 'https://example.com/x/1');
    });
  });

  group('Java 类库', () {
    test('MessageDigest MD5', () async {
      // MD5("abc") 的 base64 是 kAFQmDzST7DWlj99KOF/cg==
      final value = await run('''
        var digest = Packages.java.security.MessageDigest.getInstance('MD5');
        var raw = digest.digest(java.base64DecodeToByteArray('YWJj'));
        return Packages.java.util.Base64.getEncoder().encodeToString(raw);
      ''');
      expect(value, 'kAFQmDzST7DWlj99KOF/cg==');
    });

    test('Base64 编解码', () async {
      final value = await run('''
        var enc = Packages.java.util.Base64.getEncoder().encodeToString(
          [104, 105]);
        var dec = new Packages.java.lang.String(
          Packages.java.util.Base64.getDecoder().decode(enc), 'UTF-8');
        return enc + '|' + dec;
      ''');
      expect(value, 'aGk=|hi');
    });

    test('Arrays.copyOfRange 与 BigInteger', () async {
      final value = await run('''
        var slice = Packages.java.util.Arrays.copyOfRange([1,2,3,4,5], 1, 3);
        var big = Packages.java.math.BigInteger.valueOf(255).multiply(
          Packages.java.math.BigInteger.valueOf(2));
        return slice.join(',') + '|' + big.toString(16);
      ''');
      expect(value, '2,3|1fe');
    });

    test('AES-CBC 加解密往返', () async {
      final value = await run('''
        var key = [];
        for (var i = 0; i < 16; i++) key.push(i);
        var iv = [];
        for (var i = 16; i < 32; i++) iv.push(0);
        var cipher = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
        cipher.init(1, new Packages.javax.crypto.spec.SecretKeySpec(key, 'AES'),
          new Packages.javax.crypto.spec.IvParameterSpec(iv));
        var encrypted = cipher.doFinal([104, 101, 108, 108, 111]);
        var dec = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
        dec.init(2, new Packages.javax.crypto.spec.SecretKeySpec(key, 'AES'),
          new Packages.javax.crypto.spec.IvParameterSpec(iv));
        var plain = dec.doFinal(encrypted);
        return encrypted.length + '|' + new Packages.java.lang.String(plain, 'UTF-8');
      ''');
      expect(value, '16|hello');
    });

    test('Java.type 也能取到类', () async {
      final value = await run('''
        var md = Java.type('java.security.MessageDigest');
        return typeof md.getInstance;
      ''');
      expect(value, 'function');
    });
  });
}
