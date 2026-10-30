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

  /// 在给定的 result / 元素上跑脚本（测 java.getString 这类规则扩展）。
  Future<String> runOn(String code, String result, {bool asElement = false}) async {
    final data = await evalLegadoScript({
      'code': code,
      'jsLib': '',
      'key': '关键词',
      'page': 2,
      'baseUrl': 'https://example.com/list',
      'result': result,
      'resultElement': asElement,
      'extras': <String, String>{},
      'source': {
        'key': 'test',
        'name': '测试',
        'url': 'https://example.com',
        'header': '{"X-Test":"1"}',
        'variables': <String, String>{},
      },
    });
    return '${data['value'] ?? ''}';
  }

  group('规则扩展函数', () {
    const listHtml = '<div class="list"><ul>'
        '<li><a href="/b/1">第一本</a></li>'
        '<li><a href="/b/2">第二本</a></li>'
        '</ul></div>';

    test('java.getString 按阅读规则取值', () async {
      final value = await runOn(
        "return java.getString('class.list@tag.li.1@a@text');",
        listHtml,
      );
      expect(value, '第二本');
    });

    test('java.getString 的 href 自动补全相对地址', () async {
      final value = await runOn(
        "return java.getString('class.list@tag.li.0@a@href');",
        listHtml,
      );
      expect(value, 'https://example.com/b/1');
    });

    test('java.getElements / getStringList', () async {
      final value = await runOn(
        "var e = java.getElements('class.list@ul@li');"
        "return e.size() + '|' + java.getStringList('class.list@ul@li@a@text').length;",
        listHtml,
      );
      expect(value, '2|2');
    });

    test('json 结果支持 \$ 路径', () async {
      const json = '{"data":{"list":[{"name":"书名甲"},{"name":"书名乙"}]}}';
      final value = await runOn(
        "return java.getString('\$.data.list[1].name');",
        json,
      );
      expect(value, '书名乙');
    });

    test('元素级 getString / getElements', () async {
      final value = await runOn(
        "return result.getString('tag.a.0@text') + '|' + result.getElements('tag.li').size();",
        '<ul><li><a href="/x">条目</a></li></ul>',
        asElement: true,
      );
      expect(value, '条目|1');
    });

    test('source.getVariable() 无参返回整份 JSON', () async {
      final value = await runOn(
        "source.put('token', 'abc'); return source.getVariable();",
        '',
      );
      expect(value, contains('"token":"abc"'));
    });
  });

  group('CryptoJS / 加密扩展', () {
    test('CryptoJS AES 加解密往返', () async {
      final value = await run(
        "var key = CryptoJS.enc.Utf8.parse('2acf7e91e9864673');"
        "var iv = CryptoJS.enc.Utf8.parse('1c29882d3ddfcfd6');"
        "var enc = CryptoJS.AES.encrypt('你好世界', key, {iv: iv, padding: CryptoJS.pad.Pkcs7}).toString();"
        "var dec = CryptoJS.AES.decrypt({ciphertext: CryptoJS.enc.Base64.parse(enc)}, key,"
        "  {iv: iv, padding: CryptoJS.pad.Pkcs7});"
        "return dec.toString(CryptoJS.enc.Utf8) + '|' + enc.length;",
      );
      expect(value.startsWith('你好世界|'), isTrue);
    });

    test('CryptoJS MD5 / HmacSHA256', () async {
      final value = await run(
        "return CryptoJS.MD5('abc').toString() + '|' +"
        "  CryptoJS.HmacSHA256('abc', 'key').toString();",
      );
      expect(
        value,
        '900150983cd24fb0d6963f7d28e17f72|'
        '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
      );
    });

    test('java.createSymmetricCrypto 往返', () async {
      final value = await run(
        "var key = java.strToBytes('2acf7e91e9864673', 'UTF-8');"
        "var iv = java.strToBytes('1c29882d3ddfcfd6', 'UTF-8');"
        "var sc = java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv);"
        "var enc = sc.encryptBase64('中文内容');"
        "return sc.decryptStr(enc);",
      );
      expect(value, '中文内容');
    });

    test('javax.crypto.Mac HmacSHA256', () async {
      final value = await run(
        "var m = Packages.javax.crypto.Mac.getInstance('HmacSHA256');"
        "m.init(new Packages.javax.crypto.spec.SecretKeySpec("
        "  new Packages.java.lang.String('key').getBytes('UTF-8'), 'HmacSHA256'));"
        "var b = m.doFinal(new Packages.java.lang.String('abc').getBytes('UTF-8'));"
        "var out = ''; for (var i = 0; i < b.length; i++) {"
        "  var x = b[i] & 0xff; out += (x < 16 ? '0' : '') + x.toString(16); }"
        "return out;",
      );
      expect(value, '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab');
    });

    test('java.t2s 繁转简', () async {
      final value = await run("return java.t2s('繁體小說網');");
      expect(value, '繁体小说网');
    });
  });

  group('jsoup 补充', () {
    test('Jsoup.parseBodyFragment + Packages.org.jsoup 路径', () async {
      final value = await run(
        "var doc = Packages.org.jsoup.Jsoup.parseBodyFragment('<div class=\"c\"><b>1</b></div>');"
        "return doc.select('div.c').size() + '|' + doc.select('b').text();",
      );
      expect(value, '1|1');
    });

    test('元素 remove() 后 html() 不含被删节点', () async {
      final value = await run(
        "var doc = org.jsoup.Jsoup.parse('<div id=\"box\"><span class=\"ad\">广告</span><p>正文</p></div>');"
        "var box = doc.select('#box');"
        "var bad = box.select('.ad');"
        "for (var i = 0; i < bad.size(); i++) bad.get(i).remove();"
        "return box.html();",
      );
      expect(value.contains('广告'), isFalse);
      expect(value.contains('正文'), isTrue);
    });

    test('new Elements() + addAll 可以拼接两组节点', () async {
      final value = await run(
        "var doc = org.jsoup.Jsoup.parse('<i class=\"a\">1</i><b class=\"a\">2</b><u class=\"c\">3</u>');"
        "var els = new org.jsoup.select.Elements();"
        "els.addAll(doc.select('.a'));"
        "els.addAll(doc.select('u.c'));"
        "return els.size() + '|' + els.text();",
      );
      expect(value, '3|1 2 3');
    });
  });

  group('java.get / java.post 的 Response', () {
    test('java.get 返回 Response（body / code / header）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        request.response.headers.set('X-Trace', 'trace-1');
        request.response.write('hello');
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final value = await run(
        "var r = java.get('http://127.0.0.1:${server.port}/x');"
        "return r.body() + '|' + r.code() + '|' + r.header('X-Trace') + '|' + String(r);",
      );
      expect(value, 'hello|200|trace-1|hello');
    });

    test('java.post 返回 Response，旧写法可直接当字符串', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.write('got:$body');
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final value = await run(
        "var r = java.post('http://127.0.0.1:${server.port}/p', 'a=1');"
        "return r.body() + '|' + r.trim().length;",
      );
      expect(value, 'got:a=1|7');
    });
  });

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
