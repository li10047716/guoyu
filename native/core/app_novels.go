package core

// 小说阅读支持（0.7.61）。
//
// 内置书源：笔趣阁（biquge365.net）——纯 HTML 站，无加密、无需登录：
//
//	搜索  POST /s.php            form: type=articlename&s=<关键词>
//	详情  GET  /book/<id>/       h1 书名、作者/类型/状态、简介、封面、最新章节
//	目录  GET  /newbook/<id>/    全部章节（<li><a> 升序）
//	正文  GET  /chapter/<id>/<cid>.html   div#txt 内即全文
//
// 该站正文把多页拼在同一页里，页与页之间插「（本章未完，请点击下一页继续阅读）」
// 和「第N/M页」标记，正文前还有一行站点广告，统一在 [cleanNovelText] 里剔除。

import (
	"context"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// NovelSourceBiquge365 是内置小说站源标识（与短剧站源 key 不冲突）。
const NovelSourceBiquge365 = "biquge365"

const novelBaseURL = "https://www.biquge365.net"

// Novel 是列表/详情共用的书籍信息。
type Novel struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Title       string `json:"title"`
	Author      string `json:"author"`
	Category    string `json:"category"`
	Status      string `json:"status"`
	Description string `json:"description"`
	Cover       string `json:"cover"`
	Latest      string `json:"latest"`
	Chapters    int    `json:"chapters"`
}

// NovelChapterItem 是目录里的一章。
type NovelChapterItem struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	Title string `json:"title"`
}

// NovelBook 是详情结果（书籍信息 + 目录）。
type NovelBook struct {
	Novel
	ChapterList []NovelChapterItem `json:"chapterList"`
}

// NovelText 是一章正文（已清洗，按段落返回）。
type NovelText struct {
	BookID     string   `json:"bookId"`
	ChapterID  string   `json:"chapterId"`
	Title      string   `json:"title"`
	Paragraphs []string `json:"paragraphs"`
}

var (
	novelTitleRe          = regexp.MustCompile(`<h1[^>]*>([^<]+)</h1>`)
	novelAuthorRe         = regexp.MustCompile(`作者：\s*<a[^>]*>([^<]+)</a>`)
	novelTypeRe           = regexp.MustCompile(`类型：\s*([^<]+)<`)
	novelStatusRe         = regexp.MustCompile(`状态：\s*([^<]+)<`)
	novelCoverRe          = regexp.MustCompile(`class="zhutu"[^>]*>\s*<img[^>]+src="([^"]+)"`)
	novelDescRe           = regexp.MustCompile(`(?s)<div class="x3">(.*?)</div>`)
	novelChapterRe        = regexp.MustCompile(`<li><a href="/chapter/(\d+)/([^"]+)\.html"[^>]*>([^<]+)</a></li>`)
	novelNameRe           = regexp.MustCompile(`<span class="name"><a href="/book/(\d+)/"[^>]*>([^<]+)</a>`)
	novelZuozheRe         = regexp.MustCompile(`<span class="zuo"><a href="[^"]*">([^<]+)</a>`)
	novelTxtDivRe         = regexp.MustCompile(`(?s)<div[^>]*class="txt"[^>]*>(.*?)</div>`)
	novelBreakRe          = regexp.MustCompile(`(?i)<br\s*/?>`)
	novelTagRe            = regexp.MustCompile(`(?s)<[^>]+>`)
	novelSpaceRe          = regexp.MustCompile(`\s+`)
	novelPageMarkRe       = regexp.MustCompile(`^第\d+/\d+页$`)
	novelPageTitleRe      = regexp.MustCompile(`^第[\d一二三四五六七八九十百千]+章.*(（第\d+/\d+页）|\(第\d+/\d+页\))$`)
	novelChapterNumRe     = regexp.MustCompile(`(第\d+章)`)
	novelChapterNumOnlyRe = regexp.MustCompile(`第(\d+)章`)
	novelPageSuffixRe     = regexp.MustCompile(`[（(]第\d+/\d+页[）)]`)
)

// novelSearch 走站内搜索（书名）。
func (d *Downloader) novelSearch(ctx context.Context, query string) ([]Novel, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("请输入书名或作者")
	}
	form := url.Values{}
	form.Set("type", "articlename")
	form.Set("s", query)
	page, err := d.novelPostForm(ctx, "/s.php", form)
	if err != nil {
		return nil, err
	}
	return parseNovelSearch(page), nil
}

// novelDetail 抓详情页 + 目录页，合成一本书。
func (d *Downloader) novelDetail(ctx context.Context, id string) (NovelBook, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return NovelBook{}, errors.New("书籍编号无效")
	}
	page, err := d.fetchProviderText(ctx, novelBaseURL+"/book/"+id+"/", novelBaseURL+"/")
	if err != nil {
		return NovelBook{}, err
	}
	book := NovelBook{Novel: Novel{ID: id, Source: NovelSourceBiquge365}}
	if m := novelTitleRe.FindStringSubmatch(page); m != nil {
		book.Title = cleanNovelInline(m[1])
	}
	if m := novelAuthorRe.FindStringSubmatch(page); m != nil {
		book.Author = cleanNovelInline(m[1])
	}
	if m := novelTypeRe.FindStringSubmatch(page); m != nil {
		book.Category = cleanNovelInline(m[1])
	}
	if m := novelStatusRe.FindStringSubmatch(page); m != nil {
		book.Status = cleanNovelInline(m[1])
	}
	if m := novelCoverRe.FindStringSubmatch(page); m != nil {
		book.Cover = novelAbsoluteURL(m[1])
	}
	if m := novelDescRe.FindStringSubmatch(page); m != nil {
		desc := cleanNovelInline(novelTagRe.ReplaceAllString(m[1], ""))
		desc = strings.TrimPrefix(desc, "简介：")
		// 站点在简介末尾拼接 SEO 尾巴（--书名 / 书名全文免费阅读 …），截掉。
		if idx := strings.Index(desc, "--"); idx > 0 {
			desc = desc[:idx]
		}
		book.Description = strings.TrimSpace(desc)
	}
	chapters, err := d.novelChapters(ctx, id)
	if err != nil {
		return NovelBook{}, err
	}
	book.ChapterList = chapters
	book.Chapters = len(chapters)
	if len(chapters) > 0 {
		book.Latest = chapters[len(chapters)-1].Title
	}
	if book.Title == "" {
		return NovelBook{}, errors.New("没有找到这本书，可能已下架")
	}
	return book, nil
}

// novelChapters 抓完整目录（/newbook/<id>/ 一次性给出全部章节）。
func (d *Downloader) novelChapters(ctx context.Context, id string) ([]NovelChapterItem, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("书籍编号无效")
	}
	page, err := d.fetchProviderText(ctx, novelBaseURL+"/newbook/"+id+"/", novelBaseURL+"/book/"+id+"/")
	if err != nil {
		return nil, err
	}
	matches := novelChapterRe.FindAllStringSubmatch(page, -1)
	if len(matches) == 0 {
		return nil, errors.New("这本书还没有章节")
	}
	// 目录页顶部有「最新九章」块（倒序），正文位置才是全量升序列表，
	// 因此按章节号稳定排序；番外等没有「第N章」的条目排在最后、保持原序。
	type chapterRow struct {
		num    int
		hasNum bool
		item   NovelChapterItem
	}
	seen := make(map[string]bool, len(matches))
	rows := make([]chapterRow, 0, len(matches))
	for _, m := range matches {
		chapterID := m[2]
		if seen[chapterID] {
			continue
		}
		seen[chapterID] = true
		title := cleanNovelInline(m[3])
		num, hasNum := novelChapterNumber(title)
		rows = append(rows, chapterRow{num: num, hasNum: hasNum, item: NovelChapterItem{
			ID:    chapterID,
			Title: title,
		}})
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].hasNum != rows[j].hasNum {
			return rows[i].hasNum
		}
		if rows[i].hasNum && rows[i].num != rows[j].num {
			return rows[i].num < rows[j].num
		}
		return false
	})
	list := make([]NovelChapterItem, len(rows))
	for i, row := range rows {
		row.item.Index = i
		list[i] = row.item
	}
	return list, nil
}

// novelChapterNumber 从章节标题里取「第N章」的 N（支持阿拉伯数字；取不到返回 false）。
func novelChapterNumber(title string) (int, bool) {
	m := novelChapterNumOnlyRe.FindStringSubmatch(title)
	if m == nil {
		return 0, false
	}
	n, err := strconv.Atoi(m[1])
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// novelContent 抓一章正文并清洗。
func (d *Downloader) novelContent(ctx context.Context, bookID, chapterID string) (NovelText, error) {
	bookID = strings.TrimSpace(bookID)
	chapterID = strings.TrimSpace(chapterID)
	if bookID == "" || chapterID == "" {
		return NovelText{}, errors.New("章节不存在")
	}
	page, err := d.fetchProviderText(ctx, novelBaseURL+"/chapter/"+bookID+"/"+chapterID+".html", novelBaseURL+"/book/"+bookID+"/")
	if err != nil {
		return NovelText{}, err
	}
	m := novelTxtDivRe.FindStringSubmatch(page)
	if m == nil {
		return NovelText{}, errors.New("这一章暂时读不到内容，请稍后重试")
	}
	paragraphs, title := cleanNovelText(m[1])
	if len(paragraphs) == 0 {
		return NovelText{}, errors.New("这一章暂时读不到内容，请稍后重试")
	}
	return NovelText{
		BookID:     bookID,
		ChapterID:  chapterID,
		Title:      title,
		Paragraphs: paragraphs,
	}, nil
}

// novelPostForm 发一个表单 POST（搜索用），复用站源的 UA / 超时 / 限流。
func (d *Downloader) novelPostForm(ctx context.Context, path string, form url.Values) (string, error) {
	body := strings.NewReader(form.Encode())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, novelBaseURL+path, body)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Referer", novelBaseURL+"/")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := d.doCatalogRequestWithTimeout(req, providerTimeout)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("小说站返回异常（%d）", resp.StatusCode)
	}
	return string(raw), nil
}

// parseNovelSearch 解析搜索结果列表。
func parseNovelSearch(page string) []Novel {
	parts := strings.Split(page, `<span class="name">`)
	if len(parts) <= 1 {
		return nil
	}
	items := make([]Novel, 0, len(parts)-1)
	seen := make(map[string]bool, len(parts))
	base := ""
	for i, part := range parts {
		if i == 0 {
			continue
		}
		m := novelNameRe.FindStringSubmatch(`<span class="name">` + part)
		if m == nil {
			continue
		}
		if seen[m[1]] {
			continue
		}
		seen[m[1]] = true
		base = ""
		if a := novelZuozheRe.FindStringSubmatch(part); a != nil {
			base = cleanNovelInline(a[1])
		}
		items = append(items, Novel{
			ID:     m[1],
			Source: NovelSourceBiquge365,
			Title:  cleanNovelInline(m[2]),
			Author: base,
		})
	}
	return items
}

// cleanNovelText 把正文 HTML 片段清洗成段落数组，并返回章节标题。
//
// 规则：<br> 转换行 → 去标签 → 反转义实体 → 逐行丢弃空行、站点广告、
// 「第N/M页」标记和带页码的章节标题行。
func cleanNovelText(fragment string) ([]string, string) {
	text := novelBreakRe.ReplaceAllString(fragment, "\n")
	text = novelTagRe.ReplaceAllString(text, "")
	text = html.UnescapeString(text)
	text = strings.ReplaceAll(text, "\u00a0", " ")

	lines := strings.Split(text, "\n")
	paragraphs := make([]string, 0, len(lines))
	title := ""
	for _, line := range lines {
		line = strings.TrimSpace(novelSpaceRe.ReplaceAllString(line, " "))
		if line == "" {
			continue
		}
		// 站点广告：「一秒记住【笔趣阁】biquge365.net，更新快，无弹窗！」
		if strings.Contains(line, "一秒记住") || strings.Contains(line, "biquge365") {
			continue
		}
		// 分页提示：「（本章未完，请点击下一页继续阅读）」
		if strings.Contains(line, "本章未完") || strings.Contains(line, "点击下一页") {
			continue
		}
		if novelPageMarkRe.MatchString(line) {
			continue
		}
		if novelPageTitleRe.MatchString(line) {
			if title == "" {
				title = stripNovelPageSuffix(line)
			}
			continue
		}
		paragraphs = append(paragraphs, line)
	}
	if title == "" && len(paragraphs) > 0 {
		// 有些章节正文第一行就是标题（无页码后缀），识别出来当标题并去掉。
		if m := novelChapterNumRe.FindStringSubmatch(paragraphs[0]); m != nil && len([]rune(paragraphs[0])) <= 40 {
			title = paragraphs[0]
			paragraphs = paragraphs[1:]
		}
	}
	return paragraphs, title
}

// stripNovelPageSuffix 去掉标题末尾的「(第1/2页)」分页后缀。
func stripNovelPageSuffix(title string) string {
	title = novelPageSuffixRe.ReplaceAllString(title, "")
	return strings.TrimSpace(title)
}

// cleanNovelInline 处理单行文本（书名/作者/简介等）。
func cleanNovelInline(value string) string {
	value = html.UnescapeString(value)
	value = strings.ReplaceAll(value, "\u00a0", " ")
	return strings.TrimSpace(novelSpaceRe.ReplaceAllString(value, " "))
}

// novelAbsoluteURL 把站内相对地址补成绝对地址。
func novelAbsoluteURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return raw
	}
	if strings.HasPrefix(raw, "//") {
		return "https:" + raw
	}
	if !strings.HasPrefix(raw, "/") {
		raw = "/" + raw
	}
	return novelBaseURL + raw
}
