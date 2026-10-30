package core

import (
	"archive/zip"
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/text/encoding/simplifiedchinese"
)

const sampleNovelTxt = `测试书

作者：某甲

第一章 开始
　　这是第一章的第一段。
　　这是第一章的第二段。

第二章 继续
　　第二章的正文在这里。

第三章 结束
　　最后一章。
`

func TestSplitLocalNovelChapters(t *testing.T) {
	text, chapters := splitLocalNovelText(sampleNovelTxt)
	if len(chapters) != 4 {
		t.Fatalf("期望 4 段（序章 + 3 章），实际 %d", len(chapters))
	}
	if chapters[0].Title != "序章" {
		t.Fatalf("第一段应是序章，实际 %q", chapters[0].Title)
	}
	if got := chapters[1].Title; got != "第一章 开始" {
		t.Fatalf("章节标题不对：%q", got)
	}
	if got := chapters[3].Title; got != "第三章 结束" {
		t.Fatalf("末章标题不对：%q", got)
	}
	// 按偏移切回正文，验证区间没有错位。
	for i, chapter := range chapters {
		body := text[chapter.Start:chapter.End]
		if strings.TrimSpace(body) == "" {
			t.Fatalf("第 %d 段正文为空", i)
		}
	}
	if !strings.Contains(text[chapters[2].Start:chapters[2].End], "第二章的正文在这里") {
		t.Fatal("第二章的偏移没有落在正文上")
	}
}

func TestSplitLocalNovelWithoutChapterMarks(t *testing.T) {
	text := strings.Repeat("这是一段没有章节标记的正文。", 900)
	_, chapters := splitLocalNovelText(text)
	if len(chapters) < 2 {
		t.Fatalf("没有章节标记时应按字数兜底切分，实际 %d 段", len(chapters))
	}
	for _, chapter := range chapters {
		if chapter.End <= chapter.Start {
			t.Fatal("兜底切分出现了空区间")
		}
	}
}

func TestDecodeNovelGBK(t *testing.T) {
	raw, err := simplifiedchinese.GBK.NewEncoder().Bytes([]byte("第一章 测试\n中文正文内容"))
	if err != nil {
		t.Fatalf("编码失败：%v", err)
	}
	decoded, err := decodeNovelBytes(raw)
	if err != nil {
		t.Fatalf("GBK 解码失败：%v", err)
	}
	if !strings.Contains(decoded, "中文正文内容") {
		t.Fatalf("GBK 解码结果不对：%q", decoded)
	}
}

func TestDecodeNovelUTF8BOM(t *testing.T) {
	raw := append([]byte{0xEF, 0xBB, 0xBF}, []byte("带 BOM 的正文")...)
	decoded, err := decodeNovelBytes(raw)
	if err != nil {
		t.Fatalf("解码失败：%v", err)
	}
	if decoded != "带 BOM 的正文" {
		t.Fatalf("BOM 没有被去掉：%q", decoded)
	}
}

func TestImportLocalTxt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "测试书.txt")
	if err := os.WriteFile(path, []byte(sampleNovelTxt), 0o644); err != nil {
		t.Fatalf("写测试文件失败：%v", err)
	}
	d := &Downloader{}
	book, err := d.importLocalNovel(context.Background(), dir, path)
	if err != nil {
		t.Fatalf("导入失败：%v", err)
	}
	if book.Source != NovelSourceLocal {
		t.Fatalf("站源不对：%q", book.Source)
	}
	if book.Title != "测试书" {
		t.Fatalf("书名应回退到文件名，实际 %q", book.Title)
	}
	if book.Chapters != 4 || len(book.ChapterList) != 4 {
		t.Fatalf("章节数不对：%d", book.Chapters)
	}
	if book.Latest != "第三章 结束" {
		t.Fatalf("最新章节不对：%q", book.Latest)
	}
	// 按章读取：第 1 章（索引 1）应该拿到第一章正文。
	text, err := d.localNovelText(dir, book.ID, "1")
	if err != nil {
		t.Fatalf("读正文失败：%v", err)
	}
	if text.Title != "第一章 开始" {
		t.Fatalf("章节标题不对：%q", text.Title)
	}
	if len(text.Paragraphs) == 0 || !strings.Contains(text.Paragraphs[0], "第一章的第一段") {
		t.Fatalf("正文内容不对：%#v", text.Paragraphs)
	}
	// 重复导入应落到同一个 ID（内容相同）。
	again, err := d.importLocalNovel(context.Background(), dir, path)
	if err != nil {
		t.Fatalf("二次导入失败：%v", err)
	}
	if again.ID != book.ID {
		t.Fatalf("同一本书的 ID 不稳定：%s vs %s", again.ID, book.ID)
	}
	// 删除后目录应读不到。
	if err := d.removeLocalNovel(dir, book.ID); err != nil {
		t.Fatalf("删除失败：%v", err)
	}
	if _, err := d.localNovelChapters(dir, book.ID); err == nil {
		t.Fatal("删除后还能读到目录")
	}
}

// buildTestEpub 造一个最小的 epub（两个章节）。
func buildTestEpub(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	writer := zip.NewWriter(&buf)
	files := map[string]string{
		"META-INF/container.xml": `<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>`,
		"OEBPS/content.opf": `<?xml version="1.0"?><package><metadata><dc:title>测试 EPUB</dc:title><dc:creator>某乙</dc:creator></metadata>` +
			`<manifest><item id="c1" href="text/ch1.xhtml"/><item id="c2" href="text/ch2.xhtml"/></manifest>` +
			`<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>`,
		"OEBPS/text/ch1.xhtml": `<html><body><h1>第一章 起点</h1><p>第一段内容。</p><p>第二段内容。</p></body></html>`,
		"OEBPS/text/ch2.xhtml": `<html><body><h1>第二章 终点</h1><p>尾声内容。</p></body></html>`,
	}
	for name, content := range files {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatalf("写 zip 失败：%v", err)
		}
		if _, err := entry.Write([]byte(content)); err != nil {
			t.Fatalf("写 zip 内容失败：%v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("关闭 zip 失败：%v", err)
	}
	return buf.Bytes()
}

func TestImportLocalEpub(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "测试.epub")
	if err := os.WriteFile(path, buildTestEpub(t), 0o644); err != nil {
		t.Fatalf("写 epub 失败：%v", err)
	}
	d := &Downloader{}
	book, err := d.importLocalNovel(context.Background(), dir, path)
	if err != nil {
		t.Fatalf("导入 epub 失败：%v", err)
	}
	if book.Title != "测试 EPUB" {
		t.Fatalf("书名应取 dc:title，实际 %q", book.Title)
	}
	if book.Author != "某乙" {
		t.Fatalf("作者应取 dc:creator，实际 %q", book.Author)
	}
	if book.Chapters != 2 {
		t.Fatalf("章节数不对：%d（目录 %d）", book.Chapters, len(book.ChapterList))
	}
	text, err := d.localNovelText(dir, book.ID, "0")
	if err != nil {
		t.Fatalf("读 epub 正文失败：%v", err)
	}
	if text.Title != "第一章 起点" {
		t.Fatalf("章节标题不对：%q", text.Title)
	}
	joined := strings.Join(text.Paragraphs, "|")
	if !strings.Contains(joined, "第一段内容") || !strings.Contains(joined, "第二段内容") {
		t.Fatalf("正文段落不对：%q", joined)
	}
}
