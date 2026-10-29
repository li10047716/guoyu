package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 韩小圈（www.jennyhow.com）——MacCMS + myui 模板，全部数据以 HTML 页面返回。
//
// 与青空次元那类 JSON 接口站点不同，这里没有签名、没有 App 接口、播放地址
// 直接写在播放页的内联脚本里，所以整条链路就是「HTML 抓取 + 正则」。
//
// 三个必须留意的坑：
//  1. 封面在 `data-src` 上，`src` 只是 loading 占位图（列表页是
//     /mxstatic/image/loading.gif，搜索页是 /statics/loading.png）；
//  2. 选集地址是 `/play/<剧id>-<线路>-<集索引>.html`，**集索引从 0 开始**；
//     同一个播放页脚本里的 `var next` 是「下一集」的地址，不能当成本集；
//  3. 搜索要过一次 cookie 校验：先拿到 idc_search_browser，再带 `_idc_pass`
//     重放，否则只会得到 600 多字节的「正在验证浏览器」页，看起来像"没结果"。
const (
	hanxiaoquanBaseURL       = "https://www.jennyhow.com"
	hanxiaoquanChannelName   = "韩小圈"
	hanxiaoquanChapterPfx    = "hanxiaoquan-play://"
	hanxiaoquanMaxEpisodes   = 20000
	hanxiaoquanMaxPages      = 100000
	hanxiaoquanMaxQuery      = 128
	hanxiaoquanMaxCategories = 32
	// 站点首页默认分类；「全部」按分类并行合并，不需要单独再请求一次。
	hanxiaoquanDefaultCategory = "1"
)

// 分类固定为「最新韩剧 / 韩国电影 / 韩国综艺 / 韩国动漫」四类。
// 正常情况从页面导航解析，这里只作为解析失败时的兜底，保证源不会因为
// 一次分类请求失败就整体不可用。
var hanxiaoquanFallbackCategories = []nativeCategory{
	{ID: "1", Name: "最新韩剧"},
	{ID: "2", Name: "韩国电影"},
	{ID: "3", Name: "韩国综艺"},
	{ID: "4", Name: "韩国动漫"},
}

var (
	reHanxiaoquanNav         = regexp.MustCompile(`(?is)<li\b[^>]*class=["'][^"']*\bnav-menu-item\b[^"']*["'][^>]*>\s*<a\b[^>]*href=["'][^"']*/hxq/(\d+)\.html["'][^>]*title=["']([^"']+)["']`)
	reHanxiaoquanCard        = regexp.MustCompile(`(?is)<a\b[^>]*class=["'][^"']*\bmodule-item-pic\b[^"']*["'][^>]*>`)
	reHanxiaoquanImgTag      = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	reHanxiaoquanItemText    = regexp.MustCompile(`(?is)<div class=["']module-item-text["']\s*>([^<]*)</div>`)
	reHanxiaoquanMetaTag     = regexp.MustCompile(`(?is)<meta\b[^>]*>`)
	reHanxiaoquanInfoLabel   = regexp.MustCompile(`(?is)<span class=["']video-info-itemtitle["'][^>]*>(.*?)</span>`)
	reHanxiaoquanCategoryTag = regexp.MustCompile(`(?is)<a\b[^>]*href=["'][^"']*/hxq/\d+\.html["'][^>]*>`)
	reHanxiaoquanPlaylistDiv = regexp.MustCompile(`(?is)<div\s+id=["']playlist(\d+)["']`)
	reHanxiaoquanAnchor      = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
	reHanxiaoquanParagraph   = regexp.MustCompile(`(?is)<p\b[^>]*>(.*?)</p>`)
	reHanxiaoquanDetailPath  = regexp.MustCompile(`(?i)/hanxiaoquan/(\d+)\.html`)
	reHanxiaoquanPlayPath    = regexp.MustCompile(`(?i)/play/(\d+)-(\d+)-(\d+)\.html`)
	reHanxiaoquanPlayNow     = regexp.MustCompile(`(?is)\bvar\s+now\s*=\s*["']([^"']*)["']`)
	reHanxiaoquanSearchToken = regexp.MustCompile(`(?i)idc_search_browser=([0-9a-zA-Z]{8,64})`)
	reHanxiaoquanTailLink    = regexp.MustCompile(`(?is)<a\b[^>]*title=["']尾页["'][^>]*>`)
	reHanxiaoquanPageParam   = regexp.MustCompile(`(?i)[?&]page=(\d+)`)
	reHanxiaoquanPagePath    = regexp.MustCompile(`(?i)/hxq/\d+-(\d+)\.html`)
	reHanxiaoquanScore       = regexp.MustCompile(`豆瓣\s*([0-9]+(?:\.[0-9]+)?)\s*分`)
	reHanxiaoquanDateText    = regexp.MustCompile(`^\d{4}-\d{1,2}-\d{1,2}$`)
	reHanxiaoquanBrowseCount = regexp.MustCompile(`(?i)([0-9]+(?:\.[0-9]+)?\s*[w万]?)\s*次播放`)
)

func validHanxiaoquanID(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 12 {
		return false
	}
	id, err := strconv.ParseInt(value, 10, 64)
	return err == nil && id > 0
}

func validHanxiaoquanCategory(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 8 {
		return false
	}
	id, err := strconv.Atoi(value)
	return err == nil && id > 0 && id < 100000
}

func validHanxiaoquanLine(value string) bool {
	line, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && line >= 0 && line < 100
}

func validHanxiaoquanIndex(value string) bool {
	index, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && index >= 0 && index < hanxiaoquanMaxEpisodes
}

// hanxiaoquanCoverAddress 规整封面地址：列表页的 src 是占位图，必须用 data-src。
func hanxiaoquanCoverAddress(raw string, base *url.URL) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "loading.") || strings.Contains(lower, "placeholder") || strings.HasSuffix(lower, "blank.gif") {
		return ""
	}
	if base != nil {
		if resolved, err := base.Parse(raw); err == nil {
			raw = resolved.String()
		}
	}
	if !isProviderHTTPMediaURL(raw) {
		return ""
	}
	return raw
}

func hanxiaoquanPageBase(raw string) *url.URL {
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil
	}
	return parsed
}

func hanxiaoquanMeta(raw, key string) string {
	key = strings.ToLower(strings.TrimSpace(key))
	if key == "" {
		return ""
	}
	for _, tag := range reHanxiaoquanMetaTag.FindAllString(raw, -1) {
		if name := extractAttr(tag, "property", "name"); strings.EqualFold(name, key) {
			return extractAttr(tag, "content")
		}
	}
	return ""
}

// hanxiaoquanBlockAfter 取 marker 之后、第一个 </div> 之前的内容。
func hanxiaoquanBlockAfter(raw, marker string) string {
	index := strings.Index(raw, marker)
	if index < 0 {
		return ""
	}
	rest := raw[index+len(marker):]
	if end := strings.Index(rest, "</div>"); end >= 0 {
		rest = rest[:end]
	}
	return rest
}

// hanxiaoquanInfoField 取详情页「导演 / 主演 / 上映 / 更新」这类字段的值。
func hanxiaoquanInfoField(raw, label string) string {
	for _, match := range reHanxiaoquanInfoLabel.FindAllStringSubmatchIndex(raw, -1) {
		if len(match) < 4 {
			continue
		}
		if !strings.Contains(cleanText(raw[match[2]:match[3]]), label) {
			continue
		}
		rest := raw[match[1]:]
		start := strings.Index(rest, `class="video-info-item`)
		if start < 0 {
			continue
		}
		rest = rest[start:]
		if offset := strings.Index(rest, ">"); offset >= 0 {
			rest = rest[offset+1:]
		}
		if end := strings.Index(rest, "</div>"); end >= 0 {
			rest = rest[:end]
		}
		return cleanText(rest)
	}
	return ""
}

// hanxiaoquanDescription 取「《剧名》简介：」之后那段正文。
func hanxiaoquanDescription(raw, fallback string) string {
	block := hanxiaoquanBlockAfter(raw, `<div class="video-info des">`)
	for _, paragraph := range reHanxiaoquanParagraph.FindAllString(block, -1) {
		text := cleanText(paragraph)
		if index := strings.Index(text, "简介："); index >= 0 {
			if body := strings.TrimSpace(text[index+len("简介："):]); body != "" {
				return truncate(body, 12000)
			}
		}
	}
	fallback = strings.TrimSpace(fallback)
	if index := strings.Index(fallback, "剧情介绍："); index >= 0 {
		fallback = strings.TrimSpace(fallback[index+len("剧情介绍："):])
	}
	return truncate(fallback, 12000)
}

func hanxiaoquanTags(values ...string) []string {
	var out []string
	seen := map[string]bool{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || value == "0.0" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
		if len(out) >= 6 {
			break
		}
	}
	return out
}

// parseHanxiaoquanCards 解析列表页 / 搜索页的剧集卡片。
func parseHanxiaoquanCards(raw, pageURL, categoryName string) []Drama {
	base := hanxiaoquanPageBase(pageURL)
	positions := reHanxiaoquanCard.FindAllStringIndex(raw, -1)
	if len(positions) == 0 {
		return nil
	}
	items := make([]Drama, 0, len(positions))
	seen := map[string]bool{}
	for index, position := range positions {
		end := len(raw)
		if index+1 < len(positions) {
			end = positions[index+1][0]
		}
		block := raw[position[0]:end]
		anchor := raw[position[0]:position[1]]
		match := reHanxiaoquanDetailPath.FindStringSubmatch(extractAttr(anchor, "href"))
		if len(match) < 2 {
			continue
		}
		sourceID := strings.TrimSpace(match[1])
		if !validHanxiaoquanID(sourceID) || seen[sourceID] {
			continue
		}
		title := cleanText(extractAttr(anchor, "title"))
		if title == "" {
			title = cleanText(hanxiaoquanBlockAfter(block, `class="module-item-title"`))
		}
		if title == "" {
			title = cleanText(extractAttr(firstMatchText(reHanxiaoquanImgTag, block), "alt"))
		}
		if title == "" {
			continue
		}
		cover := ""
		if img := firstMatchText(reHanxiaoquanImgTag, block); img != "" {
			cover = hanxiaoquanCoverAddress(extractAttr(img, "data-src", "data-original", "src"), base)
		}
		// 卡片右侧那行小字一般是「最近更新日期」，个别条目会写成「更新至 N 集」。
		stamp := ""
		if match := reHanxiaoquanItemText.FindStringSubmatch(block); len(match) > 1 {
			stamp = cleanText(match[1])
		}
		onlineDate, remark := "", ""
		if reHanxiaoquanDateText.MatchString(stamp) {
			onlineDate = stamp
		} else {
			remark = truncate(stamp, 48)
		}
		seen[sourceID] = true
		items = append(items, Drama{
			ID: providerDramaID(sourceHanxiaoquan, sourceID), Source: sourceHanxiaoquan, SourceID: sourceID,
			Title: truncate(title, 256), Name: truncate(title, 256),
			Cover: cover, CoverURL: cover,
			Category: truncate(categoryName, 48), ChannelName: hanxiaoquanChannelName,
			OnlineDate: onlineDate, Remark: remark,
			Tags: nonEmptyStrings(categoryName),
		})
	}
	return items
}

// hanxiaoquanTotalPages 从分页条尾部链接推断总页数。
func hanxiaoquanTotalPages(raw string) int {
	link := firstMatchText(reHanxiaoquanTailLink, raw)
	if link == "" {
		return 0
	}
	href := extractAttr(link, "href")
	if match := reHanxiaoquanPageParam.FindStringSubmatch(href); len(match) > 1 {
		if value, err := strconv.Atoi(match[1]); err == nil && value > 0 && value <= hanxiaoquanMaxPages {
			return value
		}
	}
	if match := reHanxiaoquanPagePath.FindStringSubmatch(href); len(match) > 1 {
		if value, err := strconv.Atoi(match[1]); err == nil && value > 0 && value <= hanxiaoquanMaxPages {
			return value
		}
	}
	return 0
}

func parseHanxiaoquanCategories(raw string) []nativeCategory {
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, match := range reHanxiaoquanNav.FindAllStringSubmatch(raw, -1) {
		id := strings.TrimSpace(match[1])
		name := cleanText(match[2])
		if !validHanxiaoquanCategory(id) || name == "" || len([]rune(name)) > 24 || seen[id] {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
		if len(categories) >= hanxiaoquanMaxCategories {
			break
		}
	}
	return categories
}

// fetchHanxiaoquanCategories 返回站点导航里的分类。
//
// 分类请求失败时退回内置四类而不是让整个源不可用——否则站点偶尔抽风一次，
// 这个源就会从分类栏里整体消失，用户只能等下次刷新。
func (d *Downloader) fetchHanxiaoquanCategories(ctx context.Context) ([]nativeCategory, error) {
	base := d.providerBaseURL(sourceHanxiaoquan)
	body, err := d.fetchProviderText(ctx, base+"/hxq/"+hanxiaoquanDefaultCategory+".html", base+"/")
	if err == nil {
		if categories := parseHanxiaoquanCategories(body); len(categories) > 0 {
			return categories, nil
		}
	}
	return append([]nativeCategory{}, hanxiaoquanFallbackCategories...), nil
}

// fetchHanxiaoquanCatalogPage 拉取一页目录。
//
// category 为空表示「全部」——站点没有全站列表，只能把各分类的同一页并行合并。
func (d *Downloader) fetchHanxiaoquanCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > hanxiaoquanMaxPages || len(query) > hanxiaoquanMaxQuery {
		return nil, false, errors.New("韩小圈目录查询参数无效")
	}
	if category != "" && !validHanxiaoquanCategory(category) {
		return nil, false, errors.New("韩小圈内容分类无效")
	}
	if query != "" {
		body, err := d.hanxiaoquanSearchPage(ctx, page, query)
		if err != nil {
			return nil, false, err
		}
		items := parseHanxiaoquanCards(body, d.providerBaseURL(sourceHanxiaoquan)+"/", "搜索")
		return items, hanxiaoquanHasMore(page, hanxiaoquanTotalPages(body), len(items)), nil
	}
	if category != "" {
		return d.fetchHanxiaoquanCategoryPage(ctx, page, category, hanxiaoquanCategoryName(category))
	}
	type result struct {
		items []Drama
		more  bool
		err   error
	}
	categories := hanxiaoquanFallbackCategories
	results := make([]result, len(categories))
	slots := make(chan struct{}, 3)
	var group sync.WaitGroup
	for index, entry := range categories {
		group.Add(1)
		go func(index int, entry nativeCategory) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			results[index].items, results[index].more, results[index].err =
				d.fetchHanxiaoquanCategoryPage(ctx, page, entry.ID, entry.Name)
		}(index, entry)
	}
	group.Wait()
	var items []Drama
	var failures []error
	more := false
	for _, entry := range results {
		items = append(items, entry.items...)
		more = more || entry.more
		if entry.err != nil {
			failures = append(failures, entry.err)
		}
	}
	if len(items) == 0 {
		if err := errors.Join(failures...); err != nil {
			return nil, false, err
		}
	}
	return items, more, nil
}

func hanxiaoquanCategoryName(category string) string {
	for _, entry := range hanxiaoquanFallbackCategories {
		if entry.ID == category {
			return entry.Name
		}
	}
	return ""
}

func hanxiaoquanHasMore(page, totalPages, count int) bool {
	if totalPages > 0 {
		return page < totalPages
	}
	// 分页条认不出来时按"本页满页"推断：宁可多请求一页，也不要漏内容。
	return count >= 24
}

func (d *Downloader) fetchHanxiaoquanCategoryPage(ctx context.Context, page int, category, categoryName string) ([]Drama, bool, error) {
	base := d.providerBaseURL(sourceHanxiaoquan)
	address := fmt.Sprintf("%s/hxq/%s-%d.html", base, category, page)
	body, err := d.fetchProviderText(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	items := parseHanxiaoquanCards(body, address, categoryName)
	return items, hanxiaoquanHasMore(page, hanxiaoquanTotalPages(body), len(items)), nil
}

type hanxiaoquanEpisode struct {
	line  int
	index int
	title string
}

// parseHanxiaoquanEpisodes 解析详情页里的所有线路，返回按线路分组的分集。
//
// 注意 tab 的编号（playlist1 / playlist2）与播放地址里的线路号**不是一回事**：
// playlist1 里的地址是 /play/<剧id>-0-<集>，playlist2 里的是 -1-。
// 线路号只能从地址里取，按 tab 编号取会串线路。
func parseHanxiaoquanEpisodes(raw string) [][]hanxiaoquanEpisode {
	positions := reHanxiaoquanPlaylistDiv.FindAllStringIndex(raw, -1)
	if len(positions) == 0 {
		return nil
	}
	var lines [][]hanxiaoquanEpisode
	for index, position := range positions {
		end := len(raw)
		if index+1 < len(positions) {
			end = positions[index+1][0]
		}
		block := raw[position[1]:end]
		if close := strings.Index(block, "</ul>"); close >= 0 {
			block = block[:close]
		}
		var episodes []hanxiaoquanEpisode
		for _, anchor := range reHanxiaoquanAnchor.FindAllStringSubmatch(block, -1) {
			if len(anchor) < 3 {
				continue
			}
			tag := "<a " + anchor[1] + ">"
			match := reHanxiaoquanPlayPath.FindStringSubmatch(extractAttr(tag, "href"))
			if len(match) < 4 {
				continue
			}
			route, err := strconv.Atoi(match[2])
			if err != nil || route < 0 || route >= 100 {
				continue
			}
			episodeIndex, err := strconv.Atoi(match[3])
			if err != nil {
				continue
			}
			// 有的线路只写 title，有的只写文字，两种都要认。
			title := cleanText(extractAttr(tag, "title"))
			if title == "" {
				title = cleanText(anchor[2])
			}
			episodes = append(episodes, hanxiaoquanEpisode{
				line:  route,
				index: episodeIndex,
				title: title,
			})
		}
		if len(episodes) > 0 {
			lines = append(lines, episodes)
		}
	}
	return lines
}

// hanxiaoquanBestEpisodes 取集数最多的那条线路，缺的集数用其它线路补齐。
func hanxiaoquanBestEpisodes(lines [][]hanxiaoquanEpisode) []hanxiaoquanEpisode {
	if len(lines) == 0 {
		return nil
	}
	best := 0
	for index := range lines {
		if len(lines[index]) > len(lines[best]) {
			best = index
		}
	}
	chosen := map[int]hanxiaoquanEpisode{}
	var order []int
	collect := func(list []hanxiaoquanEpisode) {
		for _, episode := range list {
			if _, found := chosen[episode.index]; found {
				continue
			}
			chosen[episode.index] = episode
			order = append(order, episode.index)
		}
	}
	collect(lines[best])
	for index, list := range lines {
		if index == best {
			continue
		}
		collect(list)
	}
	sort.Ints(order)
	out := make([]hanxiaoquanEpisode, 0, len(order))
	for _, episodeIndex := range order {
		out = append(out, chosen[episodeIndex])
	}
	return out
}

func (d *Downloader) fetchHanxiaoquanDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	sourceID = strings.TrimSpace(sourceID)
	if !validHanxiaoquanID(sourceID) {
		return Drama{}, nil, errors.New("韩小圈剧集地址无效")
	}
	base := d.providerBaseURL(sourceHanxiaoquan)
	detailURL := base + "/hanxiaoquan/" + sourceID + ".html"
	body, err := d.fetchProviderText(ctx, detailURL, base+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	pageBase := hanxiaoquanPageBase(detailURL)
	title := cleanText(firstMatchText(reH1Tag, body))
	if title == "" {
		title = cleanText(hanxiaoquanMeta(body, "og:title"))
	}
	if title == "" {
		return Drama{}, nil, errors.New("韩小圈详情页未返回剧名，请稍后重试")
	}
	cover := hanxiaoquanCoverAddress(hanxiaoquanMeta(body, "og:image"), pageBase)
	category := cleanText(hanxiaoquanMeta(body, "og:video:class"))
	if category == "" {
		category = cleanText(extractAttr(firstMatchText(reHanxiaoquanCategoryTag, body), "title"))
	}
	area := cleanText(hanxiaoquanMeta(body, "og:video:area"))
	year := hanxiaoquanInfoField(body, "上映：")
	updated := hanxiaoquanInfoField(body, "更新：")
	description := hanxiaoquanDescription(body, hanxiaoquanMeta(body, "description"))
	if description == "" {
		description = cleanText(hanxiaoquanMeta(body, "og:description"))
	}
	score := ""
	if match := reHanxiaoquanScore.FindStringSubmatch(body); len(match) > 1 {
		if value, convErr := strconv.ParseFloat(match[1], 64); convErr == nil && value > 0 {
			score = match[1]
		}
	}
	views := ""
	if match := reHanxiaoquanBrowseCount.FindStringSubmatch(body); len(match) > 1 {
		views = strings.TrimSpace(match[1])
	}
	episodes := hanxiaoquanBestEpisodes(parseHanxiaoquanEpisodes(body))
	if len(episodes) == 0 {
		return Drama{}, nil, errors.New("该剧暂时没有可播放的分集")
	}
	// 站点的「更新」是最近一次更新集数的时间，粒度为天，与列表卡片的日期一致。
	onlineDate := ""
	if len(updated) >= 10 && reHanxiaoquanDateText.MatchString(updated[:10]) {
		onlineDate = updated[:10]
	}
	drama := Drama{
		ID: providerDramaID(sourceHanxiaoquan, sourceID), Source: sourceHanxiaoquan, SourceID: sourceID,
		Title: truncate(title, 256), Name: truncate(title, 256),
		Desc: description, Intro: description,
		Cover: cover, CoverURL: cover,
		TotalEpisode: len(episodes), EpisodeCount: len(episodes),
		Category: truncate(category, 48), ChannelName: hanxiaoquanChannelName,
		Tags:       hanxiaoquanTags(category, area, year),
		Score:      score,
		Views:      views,
		OnlineDate: onlineDate,
	}
	if len(drama.Tags) == 0 {
		drama.Tags = nonEmptyStrings(category)
	}
	chapters := make([]Chapter, 0, len(episodes))
	seenNumbers := map[int]bool{}
	for _, episode := range episodes {
		number := episode.index + 1
		if seenNumbers[number] {
			return Drama{}, nil, errors.New("韩小圈分集编号重复，请刷新详情")
		}
		seenNumbers[number] = true
		key := fmt.Sprintf("%s-%d-%d", sourceID, episode.line, episode.index)
		chapterTitle := episode.title
		if chapterTitle == "" {
			chapterTitle = fmt.Sprintf("第 %d 集", number)
		}
		chapters = append(chapters, Chapter{
			ID: providerChapterID(sourceHanxiaoquan, sourceID, key), Source: sourceHanxiaoquan,
			Title: chapterTitle, CurrentEpisode: []byte(strconv.Itoa(number)),
			// 真正的地址要再请求一次播放页，这里只记录定位信息。
			VideoURL: hanxiaoquanChapterPfx + key, Referer: detailURL,
		})
	}
	return drama, chapters, nil
}

func (d *Downloader) fetchHanxiaoquanChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	drama, chapters, err := d.fetchHanxiaoquanDetail(ctx, sourceID)
	return drama.DisplayTitle(), chapters, err
}

// hanxiaoquanSearchPage 处理搜索前的那道 cookie 校验。
func (d *Downloader) hanxiaoquanSearchPage(ctx context.Context, page int, query string) (string, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return "", errors.New("韩小圈搜索关键词无效")
	}
	base := d.providerBaseURL(sourceHanxiaoquan)
	values := url.Values{"searchword": {query}}
	if page > 1 {
		values.Set("page", strconv.Itoa(page))
	}
	address := base + "/search.php?" + values.Encode()
	body, err := d.fetchProviderText(ctx, address, base+"/")
	if err != nil {
		return "", err
	}
	match := reHanxiaoquanSearchToken.FindStringSubmatch(body)
	if len(match) < 2 {
		return body, nil
	}
	// 站点要求带上校验 cookie 再请求一次，才会返回真正的结果页。
	values.Set("_idc_pass", strconv.FormatInt(time.Now().UnixNano(), 36))
	signed := base + "/search.php?" + values.Encode()
	result, err := d.hanxiaoquanGetWithCookie(ctx, signed, address, "idc_search_browser="+match[1])
	if err != nil {
		return "", err
	}
	if reHanxiaoquanSearchToken.MatchString(result) {
		return "", errors.New("韩小圈搜索被站点验证拦下，请稍后重试")
	}
	return result, nil
}

func (d *Downloader) hanxiaoquanGetWithCookie(ctx context.Context, address, referer, cookie string) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", referer)
	request.Header.Set("Cookie", cookie)
	response, err := d.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return "", err
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return "", readErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if len(body) > providerMaxBodyBytes {
		return "", errors.New("韩小圈返回的数据过大")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("韩小圈搜索请求失败（HTTP %d）", response.StatusCode)
	}
	return string(body), nil
}

// hanxiaoquanPlayAddress 从播放页内联脚本里取**当前集**的地址。
//
// 只认 `var now=`：同一段脚本里的 `var next` 是下一集的地址，
// 拿它当本集播放就会串集。
func hanxiaoquanPlayAddress(raw string) string {
	match := reHanxiaoquanPlayNow.FindStringSubmatch(raw)
	if len(match) < 2 {
		return ""
	}
	address := strings.TrimSpace(match[1])
	if !isProviderHTTPMediaURL(address) {
		return ""
	}
	return address
}

func (d *Downloader) resolveHanxiaoquanMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceHanxiaoquan, sourceID, "")
	if !valid || source != sourceHanxiaoquan || !validHanxiaoquanID(sourceID) || !strings.HasPrefix(task.Chapter.ID, prefix) {
		return providerMedia{}, errors.New("韩小圈播放分集信息无效，请刷新详情")
	}
	parts := strings.Split(strings.TrimPrefix(task.Chapter.ID, prefix), "-")
	if len(parts) != 3 {
		return providerMedia{}, errors.New("韩小圈分集地址无效")
	}
	dramaID, line, episodeIndex := parts[0], parts[1], parts[2]
	if dramaID != sourceID || !validHanxiaoquanLine(line) || !validHanxiaoquanIndex(episodeIndex) {
		return providerMedia{}, errors.New("韩小圈分集地址无效")
	}
	base := d.providerBaseURL(sourceHanxiaoquan)
	pageURL := base + "/play/" + dramaID + "-" + line + "-" + episodeIndex + ".html"
	body, err := d.fetchProviderText(ctx, pageURL, base+"/")
	if err != nil {
		return providerMedia{}, err
	}
	address := hanxiaoquanPlayAddress(body)
	if address == "" {
		return providerMedia{}, errors.New("韩小圈未返回有效播放地址，请刷新分集或稍后重试")
	}
	media := providerMedia{URL: address, Referer: pageURL}
	if parsed, parseErr := url.Parse(address); parseErr == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取韩小圈播放列表失败：%w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, errors.New("韩小圈未返回有效播放列表，请重试")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}
