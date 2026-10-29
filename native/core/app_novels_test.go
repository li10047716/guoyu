package core

import (
	"context"
	"os"
	"strings"
	"testing"
)

// 离线解析测试：用真实页面片段校验正则与清洗规则（不联网）。
func TestCleanNovelText(t *testing.T) {
	fragment := `<p style="font-weight:bold";>一秒记住【笔趣阁】biquge365.net，更新快，无弹窗！</p><br>
&nbsp;&nbsp;&nbsp;&nbsp;第1111章仇敌见面(第1/2页)<br/>
&nbsp;&nbsp;&nbsp;&nbsp;正文第一段。<br/>
&nbsp;&nbsp;&nbsp;&nbsp;（本章未完，请点击下一页继续阅读）第1111章仇敌见面(第2/2页)<br/>
&nbsp;&nbsp;&nbsp;&nbsp;正文第二段。<br/>`
	paragraphs, title := cleanNovelText(fragment)
	if len(paragraphs) != 2 {
		t.Fatalf("期望 2 段正文，实际 %d 段：%v", len(paragraphs), paragraphs)
	}
	if paragraphs[0] != "正文第一段。" || paragraphs[1] != "正文第二段。" {
		t.Fatalf("正文清洗结果不符：%v", paragraphs)
	}
	if title == "" {
		t.Fatalf("应识别出章节标题")
	}
}

func TestNovelAbsoluteURL(t *testing.T) {
	cases := map[string]string{
		"/files/a.jpg":   "https://www.biquge365.net/files/a.jpg",
		"files/a.jpg":    "https://www.biquge365.net/files/a.jpg",
		"//cdn.test/a":   "https://cdn.test/a",
		"https://x.test": "https://x.test",
	}
	for in, want := range cases {
		if got := novelAbsoluteURL(in); got != want {
			t.Fatalf("%q -> %q，期望 %q", in, got, want)
		}
	}
}

// 联网冒烟：NOVEL_LIVE=1 go test ./core/ -run TestNovelLive -v
func TestNovelLive(t *testing.T) {
	if os.Getenv("NOVEL_LIVE") != "1" {
		t.Skip("设置 NOVEL_LIVE=1 才执行联网测试")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("初始化核心失败: %v", err)
	}
	d := engine.downloader
	ctx := context.Background()
	items, err := d.novelSearch(ctx, "桃花")
	if err != nil {
		t.Fatalf("搜索失败: %v", err)
	}
	if len(items) == 0 {
		t.Fatalf("搜索没有结果")
	}
	first := items[0]
	t.Logf("搜索首条: %s / %s (id=%s)", first.Title, first.Author, first.ID)

	book, err := d.novelDetail(ctx, first.ID)
	if err != nil {
		t.Fatalf("详情失败: %v", err)
	}
	t.Logf("详情: %s 作者=%s 分类=%s 状态=%s 章节=%d 最新=%s 封面=%s",
		book.Title, book.Author, book.Category, book.Status, len(book.ChapterList), book.Latest, book.Cover)
	if len(book.ChapterList) == 0 {
		t.Fatalf("目录为空")
	}
	ch := book.ChapterList[0]
	text, err := d.novelContent(ctx, first.ID, ch.ID)
	if err != nil {
		t.Fatalf("正文失败: %v", err)
	}
	if len(text.Paragraphs) == 0 {
		t.Fatalf("正文为空")
	}
	t.Logf("正文: %s 段落=%d 首段=%s", text.Title, len(text.Paragraphs), strings.Join([]string{text.Paragraphs[0]}, ""))
}
