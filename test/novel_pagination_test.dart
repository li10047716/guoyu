import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/novel/novel_pagination.dart';

/// 分页引擎单测：重点验证「切割发生在行边界」「长段落能跨页」「不丢内容」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NovelPagination build({
    required List<String> paragraphs,
    double width = 340,
    double height = 600,
    double fontSize = 17,
    double lineHeight = 1.75,
    double titleInset = 0,
  }) {
    return NovelPagination.build(
      paragraphs: paragraphs,
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeight: lineHeight,
      color: const Color(0xFF000000),
      titleInset: titleInset,
    );
  }

  test('短章节只有一页', () {
    final paging = build(paragraphs: ['第一段。', '第二段。']);
    expect(paging.pageCount, 1);
    paging.dispose();
  });

  test('长章节按行切成多页，每页都不超过页容量', () {
    final paragraphs = List.generate(
      40,
      (i) => '这是第 $i 段正文内容，用来把章节撑长一些。' * 6,
    );
    final paging = build(paragraphs: paragraphs, height: 500);
    expect(paging.pageCount, greaterThan(1));
    for (final slice in paging.slices) {
      expect(slice.height, lessThanOrEqualTo(500 + .5));
    }
    paging.dispose();
  });

  test('超长段落能跨页，不会被整段塞进一页', () {
    // 单段 2400 字，远超一页容量。旧实现（不拆段）会整段塞进首页然后溢出。
    final long = '测试文本内容' * 400;
    final paging = build(paragraphs: [long], height: 400);
    expect(paging.pageCount, greaterThan(1));
    paging.dispose();
  });

  test('分页覆盖全文：从顶部开始，最后一页正好收尾', () {
    final paragraphs = List.generate(12, (i) => '段落 $i 的内容。');
    final paging = build(paragraphs: paragraphs, height: 300);
    expect(paging.slices.first.top, 0);
    final last = paging.slices.last;
    expect(last.top + last.height, closeTo(paging.painter.height, 1));
    paging.dispose();
  });

  test('首页给标题留白后，第一页正文更矮', () {
    final paragraphs = List.generate(30, (i) => '内容 $i ' * 8);
    final plain = build(paragraphs: paragraphs, height: 400);
    final withTitle = build(paragraphs: paragraphs, height: 400, titleInset: 60);
    expect(withTitle.slices.first.height, lessThan(plain.slices.first.height));
    withTitle.dispose();
    plain.dispose();
  });

  test('空正文兜底成一页，不崩', () {
    final paging = build(paragraphs: const ['', '   ', '\u3000']);
    expect(paging.pageCount, 1);
    paging.dispose();
  });
}
