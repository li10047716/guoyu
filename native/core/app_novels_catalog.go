package core

// 小说书城（0.7.67）：分类浏览与收藏排行。
//
// 站点结构（biquge365.net）：
//
//	分类页  GET /sort/<分类号>_<页码>/   （第1/1779页，每页 10 本）
//	列表    <ul class="wanben"> 里每个 <li> 一个封面 + 书名，书架式排版
//	排行    <ul class="bangdan"> 收藏排行，只有序号 + 书名
//
// 分类号固定 1~8，与站点导航栏一致。

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// NovelCategory 是一个书目分类。
type NovelCategory struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// NovelPage 是分类列表的一页。
type NovelPage struct {
	Items []Novel `json:"items"`
	Page  int     `json:"page"`
	Pages int     `json:"pages"`
}

// builtinNovelCategories 与站点导航栏保持一致（顺序即展示顺序）。
var builtinNovelCategories = []NovelCategory{
	{ID: 1, Name: "玄幻魔法"},
	{ID: 2, Name: "仙侠修真"},
	{ID: 3, Name: "都市言情"},
	{ID: 4, Name: "网游动漫"},
	{ID: 5, Name: "科幻小说"},
	{ID: 6, Name: "恐怖灵异"},
	{ID: 7, Name: "历史军事"},
	{ID: 8, Name: "其他小说"},
}

var (
	novelWanbenBlockRe  = regexp.MustCompile(`(?s)<ul class="wanben">(.*?)</ul>`)
	novelListItemRe     = regexp.MustCompile(`(?s)<li>(.*?)</li>`)
	novelBookHrefRe     = regexp.MustCompile(`href="/book/(\d+)/"`)
	novelImgSrcRe       = regexp.MustCompile(`<img[^>]+src="([^"]+)"`)
	novelImgAltRe       = regexp.MustCompile(`<img[^>]+alt="([^"]*)"`)
	novelBangdanBlockRe = regexp.MustCompile(`(?s)<ul class="bangdan">(.*?)</ul>`)
	novelBangdanItemRe  = regexp.MustCompile(`<a href="/book/(\d+)/"[^>]*>([^<]+)</a>`)
	novelPageTotalRe    = regexp.MustCompile(`第(\d+)/(\d+)页`)
)

// novelCategories 返回内置分类清单（无网络请求）。
func novelCategories() []NovelCategory {
	out := make([]NovelCategory, len(builtinNovelCategories))
	copy(out, builtinNovelCategories)
	return out
}

// novelCategoryBooks 抓分类列表的某一页。
func (d *Downloader) novelCategoryBooks(ctx context.Context, categoryID, page int) (NovelPage, error) {
	if categoryID <= 0 {
		return NovelPage{}, errors.New("分类不存在")
	}
	if page <= 0 {
		page = 1
	}
	path := fmt.Sprintf("%s/sort/%d_%d/", novelBaseURL, categoryID, page)
	body, err := d.fetchProviderText(ctx, path, novelBaseURL+"/")
	if err != nil {
		return NovelPage{}, err
	}
	result := parseNovelCategoryPage(body)
	result.Page = page
	return result, nil
}

// novelRanking 抓某分类的「收藏排行」（站内 sidebar，约 15 条）。
func (d *Downloader) novelRanking(ctx context.Context, categoryID int) ([]Novel, error) {
	if categoryID <= 0 {
		return nil, errors.New("分类不存在")
	}
	path := fmt.Sprintf("%s/sort/%d_1/", novelBaseURL, categoryID)
	body, err := d.fetchProviderText(ctx, path, novelBaseURL+"/")
	if err != nil {
		return nil, err
	}
	items := parseNovelBangdan(body)
	if len(items) == 0 {
		return nil, errors.New("这个分类暂时没有排行数据")
	}
	return items, nil
}

// parseNovelCategoryPage 解析分类页：书籍列表 + 总页数。
func parseNovelCategoryPage(body string) NovelPage {
	result := NovelPage{}
	if m := novelPageTotalRe.FindStringSubmatch(body); m != nil {
		if total, err := strconv.Atoi(m[2]); err == nil {
			result.Pages = total
		}
	}
	block := novelWanbenBlockRe.FindStringSubmatch(body)
	if block == nil {
		return result
	}
	items := make([]Novel, 0, 12)
	seen := make(map[string]bool, 12)
	for _, li := range novelListItemRe.FindAllStringSubmatch(block[1], -1) {
		row := li[1]
		href := novelBookHrefRe.FindStringSubmatch(row)
		if href == nil {
			continue
		}
		id := href[1]
		if seen[id] {
			continue
		}
		seen[id] = true
		title := ""
		if alt := novelImgAltRe.FindStringSubmatch(row); alt != nil {
			title = cleanNovelInline(alt[1])
		}
		if title == "" {
			// 兜底：用 <h3> 里的书名链接。
			if m := novelBangdanItemRe.FindStringSubmatch(row); m != nil {
				title = strings.Trim(cleanNovelInline(m[2]), "《》")
			}
		}
		cover := ""
		if src := novelImgSrcRe.FindStringSubmatch(row); src != nil {
			cover = novelAbsoluteURL(src[1])
		}
		items = append(items, Novel{
			ID:     id,
			Source: NovelSourceBiquge365,
			Title:  title,
			Cover:  cover,
		})
	}
	result.Items = items
	return result
}

// parseNovelBangdan 解析「收藏排行」块（只有书名，没有封面）。
func parseNovelBangdan(body string) []Novel {
	block := novelBangdanBlockRe.FindStringSubmatch(body)
	if block == nil {
		return nil
	}
	matches := novelBangdanItemRe.FindAllStringSubmatch(block[1], -1)
	items := make([]Novel, 0, len(matches))
	seen := make(map[string]bool, len(matches))
	for _, m := range matches {
		id := m[1]
		if seen[id] {
			continue
		}
		seen[id] = true
		items = append(items, Novel{
			ID:     id,
			Source: NovelSourceBiquge365,
			Title:  strings.Trim(cleanNovelInline(m[2]), "《》"),
		})
	}
	return items
}
