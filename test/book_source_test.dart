import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_engine.dart';
import 'package:duanju_app/novel/booksource/book_source_parser.dart';
import 'package:duanju_app/novel/booksource/book_source_rules.dart';
import 'package:duanju_app/novel/booksource/rule_engine.dart';

const _html = '''
<html><body>
  <div class="item"><a href="/book/1">斗破苍穹</a><span class="author">天蚕土豆</span></div>
  <div class="item"><a href="/book/2">诡秘之主</a><span class="author">爱潜水的乌贼</span></div>
</body></html>
''';

const _baseUrl = 'https://example.com/search?q=x';

Map<String, dynamic> _readySource() => {
  'bookSourceName': '测试源',
  'bookSourceUrl': 'https://example.com',
  'searchUrl': 'https://example.com/search?q={{key}}&p={{page}}',
  'ruleSearch': {
    'bookList': 'class.item',
    'name': 'tag.a@text',
    'author': 'class.author@text',
    'bookUrl': 'tag.a@href',
  },
  'ruleToc': {
    'chapterList': 'class.chapter',
    'chapterName': 'tag.a@text',
    'chapterUrl': 'tag.a@href',
  },
  'ruleContent': {'content': 'id.content@html'},
};

void main() {
  group('书源导入', () {
    test('数组里的多个源都能解析，并按地址去重', () {
      final payload = jsonEncode([_readySource(), _readySource()]);
      final first = parseBookSources(payload);
      expect(first.parsed, hasLength(1), reason: '同地址的第二个源应算重复');
      expect(first.duplicated, 1);
      expect(first.parsed.single.status, BookSourceStatus.ready);
      expect(first.usableCount, 1);

      final second = parseBookSources(
        payload,
        existing: first.parsed,
      );
      expect(second.isEmpty, isTrue);
      // 两条都是重复的（同批里就已经去重过，地址相同）
      expect(second.duplicated, 2);
    });

    test('单个对象也能导入', () {
      final result = parseBookSources(jsonEncode(_readySource()));
      expect(result.parsed, hasLength(1));
      expect(result.parsed.single.name, '测试源');
    });

    test('带 yuedu:// 一键导入链接时能取出真实地址', () {
      const link =
          'yuedu://booksource/importonline?src=https%3A%2F%2Fwww.yckceo.com%2Fyuedu%2Fshuyuan%2Fjson%2Fid%2F7953.json';
      expect(
        extractSourceUrl(link),
        'https://www.yckceo.com/yuedu/shuyuan/json/id/7953.json',
      );
      expect(extractSourceUrl('https://a.com/b.json'), 'https://a.com/b.json');
      expect(extractSourceUrl('[{"a":1}]'), isNull);
    });

    test('用到 @js 的源交给原生 JS 运行时，仍然可用', () {
      final jsSource = _readySource()
        ..['bookSourceName'] = '番茄'
        ..['ruleSearch'] = {
          'bookList': '@js:(function(){ return result; })()',
        };
      final source = BookSource.fromLegado(jsSource);
      expect(source.status.usable, isTrue);
    });

    test('直接实例化 Java 类的源也交给本地运行时', () {
      // Java 类库已实现常用子集（MessageDigest / Cipher / Base64 ...），
      // 这类源不再预先判死，能不能跑由实测决定。
      final javaSource = _readySource()
        ..['bookSourceName'] = '番茄'
        ..['jsLib'] =
            'var d = Packages.java.security.MessageDigest.getInstance("MD5");';
      final source = BookSource.fromLegado(javaSource);
      expect(source.status.usable, isTrue);
    });

    test('缺目录/正文规则时标记为规则不全', () {
      final broken = _readySource()..remove('ruleContent');
      final source = BookSource.fromLegado(broken);
      expect(source.status, BookSourceStatus.incomplete);
    });

    test('导入结果会汇总不可用原因', () {
      final xpath = _readySource()
        ..['bookSourceUrl'] = 'https://xpath.example.com'
        ..['ruleToc'] = {'chapterList': '@xpath://div[@class="item"]'};
      final result = parseBookSources(jsonEncode([xpath]));
      expect(result.parsed, hasLength(1));
      expect(result.blockedCount, 1);
      expect(result.warnings.join(), contains('需要 XPath'));
    });
  });

  group('exploreUrl 解析', () {
    test('按换行拆条目', () {
      final entries = BookSourceExploreEntry.parseList(
        '玄幻::https://a.com/x/1.html\n修真::https://a.com/z/1.html',
      );
      expect(entries, hasLength(2));
      expect(entries[0].name, '玄幻');
      expect(entries[0].url, 'https://a.com/x/1.html');
      expect(entries[1].url, 'https://a.com/z/1.html');
    });

    test('0.7.82：多条压在一行用 && 连接也能拆开', () {
      // 番茄源那种写法：整段 exploreUrl 没有换行，全用 && 连接。
      // 以前会把 `&&修真小说` 一起当成地址，请求出去直接 404。
      final entries = BookSourceExploreEntry.parseList(
        '玄幻小说::https://a.com/x/1.html&&修真小说::https://a.com/z/1.html'
        '&&排行::https://a.com/rank/1.html',
      );
      expect(entries, hasLength(3));
      expect([for (final e in entries) e.name], ['玄幻小说', '修真小说', '排行']);
      expect([for (final e in entries) e.url], [
        'https://a.com/x/1.html',
        'https://a.com/z/1.html',
        'https://a.com/rank/1.html',
      ]);
    });

    test('分组标题与 && 混用', () {
      final entries = BookSourceExploreEntry.parseList(
        '🔥 分类::&&玄幻::https://a.com/x/1.html&&修真::https://a.com/z/1.html',
      );
      expect(entries, hasLength(3));
      expect(entries.first.isHeader, isTrue);
      expect(entries[1].group, '🔥 分类');
      expect(entries[1].url, 'https://a.com/x/1.html');
    });

    test('0.7.83：JSON 数组写法', () {
      final entries = BookSourceExploreEntry.parseList(
        '[{"title":"我的书架","url":"https://a.com/shelf"},'
        '{"title":"今日限免","url":"https://a.com/free"}]',
      );
      expect(entries, hasLength(2));
      expect(entries[0].name, '我的书架');
      expect(entries[1].url, 'https://a.com/free');
    });

    test('0.7.83：脚本写法交异步求值，同步解析返回空', () {
      const raw = '<js>let a=[];a.push({title:"玄幻",url:"https://a.com/1"});'
          'JSON.stringify(a)</js>';
      expect(BookSourceExploreEntry.isScript(raw), isTrue);
      expect(BookSourceExploreEntry.parseList(raw), isEmpty);
      expect(
        BookSourceExploreEntry.scriptCode(raw).startsWith('let a=[]'),
        isTrue,
      );
      expect(BookSourceExploreEntry.scriptCode(raw).endsWith('</js>'), isFalse);
      // 脚本求值结果（JSON）再解析
      final resolved = BookSourceExploreEntry.parseResolved(
        '[{"title":"玄幻","url":"https://a.com/1"}]',
      );
      expect(resolved.single.name, '玄幻');
      expect(resolved.single.url, 'https://a.com/1');
    });

    test('0.7.83：脚本返回文本列表也能解析', () {
      final resolved = BookSourceExploreEntry.parseResolved(
        '玄幻::https://a.com/1\n修真::https://a.com/2',
      );
      expect([for (final e in resolved) e.name], ['玄幻', '修真']);
    });
  });

  group('规则引擎', () {
    test('CSS：取链接并补成绝对地址', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(RuleEngine.selectStrings('class.item@tag.a@href', ctx), [
        'https://example.com/book/1',
        'https://example.com/book/2',
      ]);
    });

    test('CSS：取文本', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(RuleEngine.selectOne('class.item@tag.a@text', ctx), '斗破苍穹');
      expect(RuleEngine.selectStrings('class.item@tag.span@text', ctx), [
        '天蚕土豆',
        '爱潜水的乌贼',
      ]);
    });

    test('CSS：!n 索引', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(RuleEngine.selectOne('class.item!1@tag.a@text', ctx), '诡秘之主');
    });

    test('|| 取第一个有结果的规则', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(
        RuleEngine.selectOne('class.none@tag.a@text||class.item!0@tag.a@text', ctx),
        '斗破苍穹',
      );
    });

    test('## 正则后处理支持捕获组替换', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(
        RuleEngine.selectOne('class.item!0@tag.span@text##(土豆)##马铃薯', ctx),
        '天蚕马铃薯',
      );
    });

    test('JSON 路径：数组通配与递归取值', () {
      final body = jsonEncode({
        'data': {
          'list': [
            {'name': 'A', 'author': '甲'},
            {'name': 'B', 'author': '乙'},
          ],
        },
      });
      final ctx = RuleContext(body: body, url: 'https://api.example.com');
      expect(RuleEngine.selectStrings(r'$.data.list[*].name', ctx), ['A', 'B']);
      expect(RuleEngine.selectStrings(r'$..author', ctx), ['甲', '乙']);
      expect(RuleEngine.selectStrings(r'@json:$.data.list[0].name', ctx), ['A']);
    });

    test('模板变量与算术', () {
      final ctx = RuleContext(body: '', vars: {'key': '斗破', 'page': '2'});
      expect(RuleEngine.expandTemplate('q={{key}}&p={{page}}', ctx), 'q=斗破&p=2');
      expect(RuleEngine.expandTemplate('{{(page - 1) * 10}}', ctx), '10');
    });

    test('遇到 @js / @xpath 抛 UnsupportedRule', () {
      final ctx = RuleContext(body: _html, url: _baseUrl);
      expect(
        () => RuleEngine.selectStrings('@js:1+1', ctx),
        throwsA(isA<UnsupportedRule>()),
      );
      expect(
        () => RuleEngine.selectStrings('@xpath://div', ctx),
        throwsA(isA<UnsupportedRule>()),
      );
    });

    test('JS 规则支持 @js: 与 <js> 两种写法', () {
      // 行内：前缀是取值规则，后面是脚本
      final inline = BookSourceRules.splitJs('class.title@js:result.trim()')!;
      expect(inline.prefix, 'class.title');
      expect(inline.code, 'result.trim()');

      // 块状：整条都是脚本，块后面的内容忽略
      final block = BookSourceRules.splitJs('<js>return 1</js>class.title')!;
      expect(block.prefix, '');
      expect(block.code, 'return 1');

      // 块状带前缀
      final mixed = BookSourceRules.splitJs('class.item<js>result</js>')!;
      expect(mixed.prefix, 'class.item');
      expect(mixed.code, 'result');

      expect(BookSourceRules.hasJs('class.item'), isFalse);
      expect(BookSourceRules.hasJs('class.item<js>1</js>'), isTrue);
    });
  });

  group('书籍 ID', () {
    test('编解码可以还原源与地址', () {
      final id = BookSourceIds.encode('abc123', 'https://example.com/book/9');
      expect(BookSourceIds.looksLikeBookSource(id), isTrue);
      final decoded = BookSourceIds.decode(id)!;
      expect(decoded.key, 'abc123');
      expect(decoded.url, 'https://example.com/book/9');
      expect(BookSourceIds.decode('native-id'), isNull);
    });
  });
}
