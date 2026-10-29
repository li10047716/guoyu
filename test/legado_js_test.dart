/// 书源脚本运行时的能力测试（jsoup / Java 类库）。
///
/// 需要原生核心：
///   DUANJU_CORE_DLL=windows/runner/duanju_core.dll flutter test test/legado_js_test.dart
///
/// 找不到 DLL 时整组跳过，CI 上不会失败。
library;

import 'dart:convert';
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

    test('ISO-8859-1 编解码往返（番茄源签名依赖）', () async {
      // 0x00..0xFF 每个字节都要原样还原，一旦按 UTF-8 走长度就会膨胀。
      final value = await run('''
        var latin1 = Packages.java.nio.charset.Charset.forName('ISO-8859-1');
        var text = new Packages.java.lang.String([0, 65, 127, 128, 195, 169, 255], latin1);
        var back = text.getBytes(latin1);
        var utf8 = new Packages.java.lang.String([0xe4, 0xbd, 0xa0], 'UTF-8');
        return text.length() + '|' + back.length + '|' + back.join(',') + '|' + utf8.toString();
      ''');
      expect(value, '7|7|0,65,127,128,195,169,255|你');
    });

    test('BigInteger.modPow 与 toByteArray', () async {
      final value = await run('''
        var base = Packages.java.math.BigInteger.valueOf(2);
        var mod = Packages.java.math.BigInteger.valueOf(1000);
        var result = base.modPow(Packages.java.math.BigInteger.valueOf(10), mod);
        return result.toString() + '|' + result.bitLength();
      ''');
      expect(value, '24|5');
    });

    test('source.put 写下的变量会回传', () async {
      final data = await evalLegadoScript({
        'code': "source.put('token', 'abc'); return source.get('token');",
        'jsLib': '',
        'key': '',
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
      expect('${data['value']}', 'abc');
      expect((data['variables'] as Map)['token'], 'abc');
    });

    test('java.net.URL + HttpURLConnection 能 POST 并读回响应', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.write('got:${request.method}:$body');
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final value = await run('''
        var conn = new Packages.java.net.URL('http://127.0.0.1:${server.port}/post').openConnection();
        conn.setRequestMethod('POST');
        conn.setDoOutput(true);
        conn.setRequestProperty('Content-Type', 'text/plain');
        var out = conn.getOutputStream();
        out.write([104, 105]);
        out.flush();
        out.close();
        var code = conn.getResponseCode();
        var reader = new Packages.java.io.BufferedReader(
          new Packages.java.io.InputStreamReader(conn.getInputStream(), 'UTF-8'));
        var text = '';
        var line;
        while ((line = reader.readLine()) != null) text += String(line);
        return code + '|' + text;
      ''');
      expect(value, '200|got:POST:hi');
    });
  });
}
