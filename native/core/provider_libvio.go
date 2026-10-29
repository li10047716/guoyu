package core

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
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

// LIBVIO（www.libvio.to）——苹果 CMS v10 的 stui 模板，数据全部是 HTML。
//
// 两条必须处理的额外门槛：
//  1. CDN 加了自研 PoW 人机校验。普通请求只会拿到「正在验证您的浏览器」页面
//     （HTTP 403，响应头 `x-cdn-challenge: js-pow`）。页面里内联了 TS / SIG / DIFF，
//     要求算出 n 使 sha256(SIG+n) 以 DIFF 开头，再把 `__cdn_pow` 交回去换
//     `__cdn_verified`（30 分钟）。而且请求头不够"像浏览器"时连挑战页都不给，
//     直接回 44 字节纯文本 403，所以这里的请求头单独写一套。
//  2. 详情页把「视频下载(夸克/迅雷)」网盘面板和真播放线路放在同样的
//     `playlist-panel` 容器里，只能靠 `netdisk-panel` 类名区分；当成选集就会
//     把网盘链接塞进播放列表。
const (
	libvioBaseURL     = "https://www.libvio.to"
	libvioChannelName = "番剧"
	libvioChapterPfx  = "libvio-play://"

	libvioMaxEpisodes    = 20000
	libvioMaxPages       = 1000
	libvioMaxQuery       = 128
	libvioMaxCategories  = 32
	libvioPageSize       = 12
	libvioPowMaxAttempts = 4_000_000
	libvioUserAgent      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

	// 站点给 30 分钟有效，这里提前 5 分钟续期。
	libvioCookieTTL = 25 * time.Minute
)

// 导航里的全部分类（地区维度也一并展示，供用户自己切换）。
var libvioFallbackCategories = []nativeCategory{
	{ID: "1", Name: "电影"},
	{ID: "2", Name: "剧集"},
	{ID: "4", Name: "番剧"},
	{ID: "15", Name: "日韩"},
	{ID: "16", Name: "欧美"},
}

// 「全部」只合并三个内容分类：日韩 / 欧美 是地区维度，和它们大面积重叠，
// 一起合并会让同一部片出现两三次，还会白跑两次请求。
var libvioCatalogCategories = []nativeCategory{
	{ID: "1", Name: "电影"},
	{ID: "2", Name: "剧集"},
	{ID: "4", Name: "番剧"},
}

var (
	reLibvioCard        = regexp.MustCompile(`(?is)<a\b[^>]*class=["'][^"']*\bstui-vodlist__thumb\b[^"']*["'][^>]*>`)
	reLibvioImgTag      = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	reLibvioPosterImg   = regexp.MustCompile(`(?is)<img\b[^>]*\bid=["']js-poster-img["'][^>]*>`)
	reLibvioMetaTag     = regexp.MustCompile(`(?is)<meta\b[^>]*>`)
	reLibvioTitleTag    = regexp.MustCompile(`(?is)<h1\b[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>(.*?)</h1>`)
	reLibvioMetaItem    = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bmeta-item\b[^"']*["'][^>]*>(.*?)</span>`)
	reLibvioDescTag     = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bdetail-content\b[^"']*["'][^>]*>(.*?)</span>`)
	reLibvioScoreTag    = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bscore\b[^"']*["'][^>]*>\s*([0-9]+(?:\.[0-9]+)?)\s*分`)
	reLibvioCardScore   = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bpic-tag\b[^"']*["'][^>]*>\s*([0-9]+(?:\.[0-9]+)?)\s*<`)
	reLibvioPicText     = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bpic-text\b[^"']*["'][^>]*>(.*?)</span>`)
	reLibvioPanel       = regexp.MustCompile(`(?is)<div\s+class=["']playlist-panel([^"']*)["']`)
	reLibvioAnchor      = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
	reLibvioNavLink     = regexp.MustCompile(`(?is)<a\b[^>]*href=["']/type/(\d+)\.html["'][^>]*>([^<]{1,16})</a>`)
	reLibvioDetailPath  = regexp.MustCompile(`(?i)/detail/(\d+)\.html`)
	reLibvioPlayPath    = regexp.MustCompile(`(?i)/w/(\d+)-(\d+)-(\d+)\.html`)
	reLibvioTotalPages  = regexp.MustCompile(`(?is)<li\s+class=["']active num["'][^>]*>\s*<a>\s*\d+\s*/\s*(\d+)\s*</a>`)
	reLibvioPlayerJSON  = regexp.MustCompile(`(?is)\bplayer_aaaa\s*=\s*(\{.*?\})\s*</script>`)
	reLibvioYear        = regexp.MustCompile(`^\d{4}$`)
	reLibvioReleaseLine = regexp.MustCompile(`上映\s*(\d{4}-\d{1,2}-\d{1,2})`)
	reLibvioUpdateLine  = regexp.MustCompile(`更新\s*(\d{4}-\d{1,2}-\d{1,2})`)
	reLibvioEpisodeLine = regexp.MustCompile(`共\s*(\d+)\s*集`)

	reLibvioChallengeTS   = regexp.MustCompile(`\bTS\s*=\s*"([^"]*)"`)
	reLibvioChallengeSIG  = regexp.MustCompile(`\bSIG\s*=\s*"([^"]*)"`)
	reLibvioChallengeDiff = regexp.MustCompile(`\bDIFF\s*=\s*"([^"]*)"`)
	reLibvioChallengeMode = regexp.MustCompile(`\bMODE\s*=\s*"([^"]*)"`)
)

func validLibvioID(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 12 {
		return false
	}
	id, err := strconv.ParseInt(value, 10, 64)
	return err == nil && id > 0
}

func validLibvioCategory(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 8 {
		return false
	}
	id, err := strconv.Atoi(value)
	return err == nil && id > 0 && id < 100000
}

func validLibvioLine(value string) bool {
	line, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && line > 0 && line < 100
}

func validLibvioIndex(value string) bool {
	index, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && index > 0 && index < libvioMaxEpisodes
}

func libvioPageBase(raw string) *url.URL {
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil
	}
	return parsed
}

// libvioCoverAddress 规整封面地址。列表页 src 是 /statics/img/load.gif 占位图，
// 真正的地址在 data-original 上。
func libvioCoverAddress(raw string, base *url.URL) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "load.gif") || strings.Contains(lower, "loading.") || strings.Contains(lower, "placeholder") {
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

func libvioMeta(raw, key string) string {
	key = strings.ToLower(strings.TrimSpace(key))
	if key == "" {
		return ""
	}
	for _, tag := range reLibvioMetaTag.FindAllString(raw, -1) {
		if name := extractAttr(tag, "property", "name"); strings.EqualFold(name, key) {
			return extractAttr(tag, "content")
		}
	}
	return ""
}

func libvioMatchScore(pattern *regexp.Regexp, raw string) string {
	match := pattern.FindStringSubmatch(raw)
	if len(match) < 2 {
		return ""
	}
	value, err := strconv.ParseFloat(match[1], 64)
	if err != nil || value <= 0 {
		return ""
	}
	return match[1]
}

func libvioScore(raw string) string {
	for _, pattern := range []*regexp.Regexp{reLibvioScoreTag, reLibvioCardScore} {
		if score := libvioMatchScore(pattern, raw); score != "" {
			return score
		}
	}
	return ""
}

// libvioCards 解析列表页 / 搜索页的影片卡片。
//
// 卡片与普通苹果 CMS 模板不同：封面不在 <img> 上，而是缩略图 <a> 自己的
// data-original（<img> 根本没渲染，是 lazyload 占位）。所以封面、进度小字、
// 评分都从这个 <a> 内部取。
func parseLibvioCards(raw, pageURL, categoryName string) []Drama {
	base := libvioPageBase(pageURL)
	positions := reLibvioCard.FindAllStringIndex(raw, -1)
	if len(positions) == 0 {
		return nil
	}
	items := make([]Drama, 0, len(positions))
	seen := map[string]bool{}
	for _, position := range positions {
		anchor := raw[position[0]:position[1]]
		match := reLibvioDetailPath.FindStringSubmatch(extractAttr(anchor, "href"))
		if len(match) < 2 {
			continue
		}
		sourceID := strings.TrimSpace(match[1])
		if !validLibvioID(sourceID) || seen[sourceID] {
			continue
		}
		title := cleanText(extractAttr(anchor, "title"))
		// 卡片内容只到自己的 </a> 为止，避免把相邻卡片的小字算进来。
		inner := ""
		if close := strings.Index(raw[position[1]:], "</a>"); close >= 0 {
			inner = raw[position[1] : position[1]+close]
		}
		if title == "" {
			title = cleanText(extractAttr(firstMatchText(reLibvioImgTag, inner), "alt"))
		}
		if title == "" {
			continue
		}
		cover := libvioCoverAddress(extractAttr(anchor, "data-original", "data-src", "src"), base)
		if cover == "" {
			cover = libvioCoverAddress(extractAttr(firstMatchText(reLibvioImgTag, inner), "data-original", "data-src", "src"), base)
		}
		// 卡片右下角的小字：「第09集/周六更新」「全12集」这类进度说明。
		remark := ""
		if match := reLibvioPicText.FindStringSubmatch(inner); len(match) > 1 {
			remark = truncate(cleanText(match[1]), 48)
		}
		seen[sourceID] = true
		items = append(items, Drama{
			ID: providerDramaID(sourceLibvio, sourceID), Source: sourceLibvio, SourceID: sourceID,
			Title: truncate(title, 256), Name: truncate(title, 256),
			Cover: cover, CoverURL: cover,
			Category: truncate(categoryName, 48), ChannelName: libvioChannelName,
			Remark: remark, Score: libvioScore(inner),
			Tags: nonEmptyStrings(categoryName),
		})
	}
	return items
}

func parseLibvioCategories(raw string) []nativeCategory {
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, match := range reLibvioNavLink.FindAllStringSubmatch(raw, -1) {
		id := strings.TrimSpace(match[1])
		name := cleanText(match[2])
		if !validLibvioCategory(id) || name == "" || len([]rune(name)) > 12 || seen[id] {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
		if len(categories) >= libvioMaxCategories {
			break
		}
	}
	return categories
}

// libvioTotalPages 从分页条的「1/96」读总页数。
func libvioTotalPages(raw string) int {
	match := reLibvioTotalPages.FindStringSubmatch(raw)
	if len(match) < 2 {
		return 0
	}
	value, err := strconv.Atoi(match[1])
	if err != nil || value <= 0 || value > libvioMaxPages {
		return 0
	}
	return value
}

func libvioHasMore(page, totalPages, count int) bool {
	if totalPages > 0 {
		return page < totalPages
	}
	return count >= libvioPageSize
}

func libvioCategoryName(code string) string {
	for _, entry := range libvioFallbackCategories {
		if entry.ID == code {
			return entry.Name
		}
	}
	return ""
}

// fetchLibvioCategories 返回导航里的分类，失败时退回内置列表。
func (d *Downloader) fetchLibvioCategories(ctx context.Context) ([]nativeCategory, error) {
	base := d.providerBaseURL(sourceLibvio)
	body, err := d.libvioGet(ctx, base+"/type/"+libvioCatalogCategories[2].ID+".html", base+"/")
	if err == nil {
		if categories := parseLibvioCategories(body); len(categories) > 0 {
			return categories, nil
		}
	}
	return append([]nativeCategory{}, libvioFallbackCategories...), nil
}

func (d *Downloader) fetchLibvioCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > libvioMaxPages || len(query) > libvioMaxQuery {
		return nil, false, errors.New("LIBVIO 目录查询参数无效")
	}
	if category != "" && !validLibvioCategory(category) {
		return nil, false, errors.New("LIBVIO 内容分类无效")
	}
	if query != "" {
		return d.fetchLibvioSearchPage(ctx, page, query)
	}
	if category != "" {
		return d.fetchLibvioCategoryPage(ctx, page, category, libvioCategoryName(category))
	}
	type outcome struct {
		items []Drama
		more  bool
		err   error
	}
	results := make([]outcome, len(libvioCatalogCategories))
	slots := make(chan struct{}, 3)
	var group sync.WaitGroup
	for index, entry := range libvioCatalogCategories {
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
				d.fetchLibvioCategoryPage(ctx, page, entry.ID, entry.Name)
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

func (d *Downloader) fetchLibvioCategoryPage(ctx context.Context, page int, category, categoryName string) ([]Drama, bool, error) {
	base := d.providerBaseURL(sourceLibvio)
	address := base + "/type/" + category + ".html"
	if page > 1 {
		address = fmt.Sprintf("%s/type/%s-%d.html", base, category, page)
	}
	body, err := d.libvioGet(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	items := parseLibvioCards(body, address, categoryName)
	return items, libvioHasMore(page, libvioTotalPages(body), len(items)), nil
}

// fetchLibvioSearchPage 走站点的静态化搜索地址 /search/<kw>----------<page>---.html。
func (d *Downloader) fetchLibvioSearchPage(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, false, errors.New("LIBVIO 搜索关键词无效")
	}
	base := d.providerBaseURL(sourceLibvio)
	address := base + "/search/" + url.PathEscape(query) + "----------" + strconv.Itoa(page) + "---.html"
	body, err := d.libvioGet(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	items := parseLibvioCards(body, address, "搜索")
	return items, libvioHasMore(page, libvioTotalPages(body), len(items)), nil
}

type libvioEpisode struct {
	line  int
	index int
	title string
}

// parseLibvioEpisodes 只收非网盘面板里的分集。
//
// 网盘面板（夸克 / 迅雷）用的是同一个 playlist-panel 容器，
// 靠附加类名 netdisk-panel 区分；把它们当分集会让播放全部失败。
func parseLibvioEpisodes(raw string) [][]libvioEpisode {
	positions := reLibvioPanel.FindAllStringSubmatchIndex(raw, -1)
	if len(positions) == 0 {
		return nil
	}
	var lines [][]libvioEpisode
	for index, position := range positions {
		if len(position) < 4 {
			continue
		}
		if strings.Contains(raw[position[2]:position[3]], "netdisk") {
			continue
		}
		end := len(raw)
		if index+1 < len(positions) {
			end = positions[index+1][0]
		}
		block := raw[position[1]:end]
		if close := strings.Index(block, "</ul>"); close >= 0 {
			block = block[:close]
		}
		var episodes []libvioEpisode
		for _, anchor := range reLibvioAnchor.FindAllStringSubmatch(block, -1) {
			if len(anchor) < 3 {
				continue
			}
			tag := "<a " + anchor[1] + ">"
			match := reLibvioPlayPath.FindStringSubmatch(extractAttr(tag, "href"))
			if len(match) < 4 {
				continue
			}
			line, err := strconv.Atoi(match[2])
			if err != nil || line <= 0 || line >= 100 {
				continue
			}
			episodeIndex, err := strconv.Atoi(match[3])
			if err != nil || episodeIndex <= 0 || episodeIndex >= libvioMaxEpisodes {
				continue
			}
			title := cleanText(extractAttr(tag, "title"))
			if title == "" {
				title = cleanText(anchor[2])
			}
			episodes = append(episodes, libvioEpisode{line: line, index: episodeIndex, title: title})
		}
		if len(episodes) > 0 {
			lines = append(lines, episodes)
		}
	}
	return lines
}

// libvioBestEpisodes 取集数最多的线路，缺的集数用其它线路补齐。
func libvioBestEpisodes(lines [][]libvioEpisode) []libvioEpisode {
	if len(lines) == 0 {
		return nil
	}
	best := 0
	for index := range lines {
		if len(lines[index]) > len(lines[best]) {
			best = index
		}
	}
	chosen := map[int]libvioEpisode{}
	var order []int
	collect := func(list []libvioEpisode) {
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
	out := make([]libvioEpisode, 0, len(order))
	for _, episodeIndex := range order {
		out = append(out, chosen[episodeIndex])
	}
	return out
}

func libvioDetailMeta(raw string) (tags []string, area, year, release, updated, total string) {
	for index, match := range reLibvioMetaItem.FindAllStringSubmatch(raw, -1) {
		if len(match) < 2 {
			continue
		}
		text := cleanText(match[1])
		if text == "" {
			continue
		}
		switch {
		case index == 0 && strings.Contains(text, ","):
			// 第一个 meta-item 是「喜剧,爱情,动画,运动」这种类型串。
			for _, tag := range strings.Split(text, ",") {
				if tag = strings.TrimSpace(tag); tag != "" {
					tags = append(tags, tag)
				}
			}
		case reLibvioYear.MatchString(text):
			if year == "" {
				year = text
			}
		case strings.HasPrefix(text, "上映"):
			if match := reLibvioReleaseLine.FindStringSubmatch(text); len(match) > 1 {
				release = match[1]
			}
		case strings.HasPrefix(text, "更新"):
			if match := reLibvioUpdateLine.FindStringSubmatch(text); len(match) > 1 {
				updated = match[1]
			}
		case strings.HasPrefix(text, "共"):
			if match := reLibvioEpisodeLine.FindStringSubmatch(text); len(match) > 1 {
				total = match[1]
			}
		case !strings.HasPrefix(text, "主演") && !strings.HasPrefix(text, "导演") && len([]rune(text)) <= 8:
			// 剩下没有前缀的短字段就是地区（日本 / 美国 / 大陆…）。
			if area == "" {
				area = text
			}
		}
	}
	return tags, area, year, release, updated, total
}

func (d *Downloader) fetchLibvioDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	sourceID = strings.TrimSpace(sourceID)
	if !validLibvioID(sourceID) {
		return Drama{}, nil, errors.New("LIBVIO 剧集地址无效")
	}
	base := d.providerBaseURL(sourceLibvio)
	detailURL := base + "/detail/" + sourceID + ".html"
	body, err := d.libvioGet(ctx, detailURL, base+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	pageBase := libvioPageBase(detailURL)
	title := cleanText(firstMatchText(reLibvioTitleTag, body))
	if title == "" {
		title = cleanText(libvioMeta(body, "og:title"))
	}
	if title == "" {
		return Drama{}, nil, errors.New("LIBVIO 详情页未返回片名，请稍后重试")
	}
	cover := ""
	if img := firstMatchText(reLibvioPosterImg, body); img != "" {
		cover = libvioCoverAddress(extractAttr(img, "data-original", "data-src", "src"), pageBase)
	}
	if cover == "" {
		cover = libvioCoverAddress(libvioMeta(body, "og:image"), pageBase)
	}
	tags, area, year, release, updated, _ := libvioDetailMeta(body)
	description := cleanText(firstMatchText(reLibvioDescTag, body))
	if description == "" {
		description = cleanText(libvioMeta(body, "og:description"))
	}
	if description == "" {
		description = cleanText(libvioMeta(body, "description"))
	}
	// 详情页的分数在 <span class="score">8.5分</span>；0.0 表示站方没打分。
	score := libvioMatchScore(reLibvioScoreTag, body)
	episodes := libvioBestEpisodes(parseLibvioEpisodes(body))
	if len(episodes) == 0 {
		return Drama{}, nil, errors.New("该片暂时没有可播放的分集")
	}
	category := ""
	if len(tags) > 0 {
		category = tags[0]
	}
	drama := Drama{
		ID: providerDramaID(sourceLibvio, sourceID), Source: sourceLibvio, SourceID: sourceID,
		Title: truncate(title, 256), Name: truncate(title, 256),
		Desc: truncate(description, 12000), Intro: truncate(description, 12000),
		Cover: cover, CoverURL: cover,
		TotalEpisode: len(episodes), EpisodeCount: len(episodes),
		Category: truncate(category, 48), ChannelName: libvioChannelName,
		Tags:       libvioTags(tags, area, year),
		Score:      score,
		OnlineDate: normalizeDate(firstNonEmpty(updated, release)),
	}
	chapters := make([]Chapter, 0, len(episodes))
	seenNumbers := map[int]bool{}
	for _, episode := range episodes {
		number := episodeIndex(episode.title, episode.index)
		if seenNumbers[number] {
			return Drama{}, nil, errors.New("LIBVIO 分集编号重复，请刷新详情")
		}
		seenNumbers[number] = true
		key := fmt.Sprintf("%s-%d-%d", sourceID, episode.line, episode.index)
		chapterTitle := episode.title
		if chapterTitle == "" {
			chapterTitle = fmt.Sprintf("第 %d 集", number)
		}
		chapters = append(chapters, Chapter{
			ID: providerChapterID(sourceLibvio, sourceID, key), Source: sourceLibvio,
			Title: chapterTitle, CurrentEpisode: []byte(strconv.Itoa(number)),
			// 真正的文件地址要再请求一次播放页。
			VideoURL: libvioChapterPfx + key, Referer: detailURL,
		})
	}
	return drama, chapters, nil
}

func (d *Downloader) fetchLibvioChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	drama, chapters, err := d.fetchLibvioDetail(ctx, sourceID)
	return drama.DisplayTitle(), chapters, err
}

func libvioTags(values ...any) []string {
	var out []string
	seen := map[string]bool{}
	appendValue := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" || value == "0.0" || seen[value] || len(out) >= 6 {
			return
		}
		seen[value] = true
		out = append(out, value)
	}
	for _, value := range values {
		switch item := value.(type) {
		case []string:
			for _, tag := range item {
				appendValue(tag)
			}
		case string:
			appendValue(item)
		}
	}
	return out
}

// libvioPlayer 对应播放页里的 `var player_aaaa={...}`。
type libvioPlayer struct {
	Encrypt int    `json:"encrypt"`
	Trysee  int    `json:"trysee"`
	URL     string `json:"url"`
	From    string `json:"from"`
}

func parseLibvioPlayer(raw string) (libvioPlayer, bool) {
	match := reLibvioPlayerJSON.FindStringSubmatch(raw)
	if len(match) < 2 {
		return libvioPlayer{}, false
	}
	var player libvioPlayer
	if err := json.Unmarshal([]byte(match[1]), &player); err != nil {
		return libvioPlayer{}, false
	}
	return player, true
}

// libvioMediaAddress 把播放页里的地址还原成可播放直链。
//
// 苹果 CMS 的 `encrypt`：1 = 只做了 JS 转义，2 = 转义 + base64；3 表示原样。
// 这里逐个尝试而不是写死分支，站点换模板也不会立刻失效。
func libvioMediaAddress(player libvioPlayer) string {
	candidates := []string{strings.TrimSpace(player.URL)}
	if player.Encrypt == 2 {
		if decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(player.URL)); err == nil {
			candidates = append(candidates, string(decoded))
		}
	}
	for _, candidate := range candidates {
		if isProviderHTTPMediaURL(candidate) {
			return candidate
		}
	}
	for _, candidate := range candidates {
		if unescaped, err := url.PathUnescape(candidate); err == nil {
			if isProviderHTTPMediaURL(unescaped) {
				return unescaped
			}
		}
	}
	return ""
}

func (d *Downloader) resolveLibvioMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceLibvio, sourceID, "")
	if !valid || source != sourceLibvio || !validLibvioID(sourceID) || !strings.HasPrefix(task.Chapter.ID, prefix) {
		return providerMedia{}, errors.New("LIBVIO 播放分集信息无效，请刷新详情")
	}
	parts := strings.Split(strings.TrimPrefix(task.Chapter.ID, prefix), "-")
	if len(parts) != 3 {
		return providerMedia{}, errors.New("LIBVIO 分集地址无效")
	}
	dramaID, line, episodeIndex := parts[0], parts[1], parts[2]
	if dramaID != sourceID || !validLibvioLine(line) || !validLibvioIndex(episodeIndex) {
		return providerMedia{}, errors.New("LIBVIO 分集地址无效")
	}
	base := d.providerBaseURL(sourceLibvio)
	pageURL := base + "/w/" + dramaID + "-" + line + "-" + episodeIndex + ".html"
	body, err := d.libvioGet(ctx, pageURL, base+"/detail/"+dramaID+".html")
	if err != nil {
		return providerMedia{}, err
	}
	player, found := parseLibvioPlayer(body)
	if !found {
		return providerMedia{}, errors.New("LIBVIO 播放页未返回播放参数，请刷新分集或稍后重试")
	}
	address := libvioMediaAddress(player)
	if address == "" {
		return providerMedia{}, errors.New("LIBVIO 未返回有效播放地址，请刷新分集或稍后重试")
	}
	media := providerMedia{URL: address, Referer: pageURL}
	if parsed, parseErr := url.Parse(address); parseErr == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取 LIBVIO 播放列表失败：%w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, errors.New("LIBVIO 未返回有效播放列表，请重试")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}

type libvioChallenge struct {
	TS   string
	SIG  string
	DIFF string
	MODE string
}

func parseLibvioChallenge(body string) (libvioChallenge, bool) {
	var challenge libvioChallenge
	for pattern, target := range map[*regexp.Regexp]*string{
		reLibvioChallengeTS:   &challenge.TS,
		reLibvioChallengeSIG:  &challenge.SIG,
		reLibvioChallengeDiff: &challenge.DIFF,
		reLibvioChallengeMode: &challenge.MODE,
	} {
		match := pattern.FindStringSubmatch(body)
		if len(match) < 2 {
			continue
		}
		*target = strings.TrimSpace(match[1])
	}
	if len(challenge.SIG) < 32 || challenge.DIFF == "" || challenge.TS == "" {
		return libvioChallenge{}, false
	}
	if challenge.MODE == "" {
		challenge.MODE = "auto"
	}
	return challenge, true
}

func solveLibvioPow(sig, diff string) (int, bool) {
	diff = strings.ToLower(strings.TrimSpace(diff))
	if diff == "" || len(diff) > 64 || strings.Trim(diff, "0123456789abcdef") != "" {
		return 0, false
	}
	digest := make([]byte, 64)
	for nonce := 0; nonce < libvioPowMaxAttempts; nonce++ {
		sum := sha256.Sum256([]byte(sig + strconv.Itoa(nonce)))
		hex.Encode(digest, sum[:])
		if string(digest[:len(diff)]) == diff {
			return nonce, true
		}
	}
	return 0, false
}

// libvioRequest 发一次请求，**不跟随重定向**——校验通过后服务端是用 302
// 带 Set-Cookie 下发 __cdn_verified 的，跟丢了就拿不到凭证。
func (d *Downloader) libvioRequest(ctx context.Context, address, referer, cookie string) (*http.Response, string, error) {
	requestCtx, cancel := context.WithTimeout(ctx, providerTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, address, nil)
	if err != nil {
		return nil, "", err
	}
	request.Header.Set("User-Agent", libvioUserAgent)
	request.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Sec-Fetch-Dest", "document")
	request.Header.Set("Sec-Fetch-Mode", "navigate")
	request.Header.Set("Sec-Fetch-Site", "none")
	request.Header.Set("Upgrade-Insecure-Requests", "1")
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	if cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	client := &http.Client{
		Transport: d.client.Transport,
		Timeout:   d.client.Timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, "", err
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return nil, "", readErr
	}
	if closeErr != nil {
		return nil, "", closeErr
	}
	if len(body) > providerMaxBodyBytes {
		return nil, "", fmt.Errorf("response exceeds %d bytes", providerMaxBodyBytes)
	}
	return response, string(body), nil
}

func libvioCookieValue(header, name string) (string, bool) {
	prefix := name + "="
	header = strings.TrimSpace(header)
	if !strings.HasPrefix(header, prefix) {
		return "", false
	}
	value := strings.TrimPrefix(header, prefix)
	if index := strings.Index(value, ";"); index >= 0 {
		value = value[:index]
	}
	value = strings.TrimSpace(value)
	return value, value != ""
}

func (d *Downloader) libvioAuthCookie() string {
	d.libvioMu.Lock()
	defer d.libvioMu.Unlock()
	if d.libvioCookie == "" || time.Now().After(d.libvioExpires) {
		return ""
	}
	return d.libvioCookie
}

// libvioUnlock 解一次 PoW 并把 __cdn_verified 存下来。
//
// 同一时刻只允许一个请求求解：分类页是并行合并的，几个请求会同时撞上挑战页，
// 各自算一遍纯属浪费。
func (d *Downloader) libvioUnlock(ctx context.Context, body string) error {
	d.libvioMu.Lock()
	defer d.libvioMu.Unlock()
	if d.libvioCookie != "" && time.Now().Before(d.libvioExpires) {
		return nil
	}
	base := d.providerBaseURL(sourceLibvio)
	challenge, found := parseLibvioChallenge(body)
	if !found {
		response, fresh, err := d.libvioRequest(ctx, base+"/", base+"/", "")
		if err != nil {
			return err
		}
		if response.StatusCode >= 200 && response.StatusCode < 300 && len(fresh) > 0 {
			return nil
		}
		if challenge, found = parseLibvioChallenge(fresh); !found {
			return errors.New("LIBVIO 站点验证页未返回校验参数，请稍后重试")
		}
	}
	nonce, solved := solveLibvioPow(challenge.SIG, challenge.DIFF)
	if !solved {
		return errors.New("LIBVIO 站点验证未完成，请稍后重试")
	}
	pow := "__cdn_pow=" + challenge.TS + "_" + challenge.MODE + "_" + strconv.Itoa(nonce) + "_" + challenge.SIG
	response, _, err := d.libvioRequest(ctx, base+"/", base+"/", pow)
	if err != nil {
		return err
	}
	for _, header := range response.Header.Values("Set-Cookie") {
		value, valid := libvioCookieValue(header, "__cdn_verified")
		if !valid {
			continue
		}
		d.libvioCookie = "__cdn_verified=" + value
		d.libvioExpires = time.Now().Add(libvioCookieTTL)
		return nil
	}
	return errors.New("LIBVIO 站点验证未通过，请稍后重试")
}

func libvioChallengeRequired(response *http.Response, body string) bool {
	if response.Header.Get("x-cdn-challenge") != "" {
		return true
	}
	return strings.Contains(body, "__cdn_pow") || strings.Contains(body, "正在验证您的浏览器")
}

// libvioGet 是所有 LIBVIO 请求的唯一入口：命中校验页就解一次再重试。
func (d *Downloader) libvioGet(ctx context.Context, address, referer string) (string, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		response, body, err := d.libvioRequest(ctx, address, referer, d.libvioAuthCookie())
		if err != nil {
			return "", err
		}
		if response.StatusCode >= 200 && response.StatusCode < 300 {
			return body, nil
		}
		if response.StatusCode == http.StatusForbidden {
			lastErr = errors.New("LIBVIO 拒绝访问，站点验证未通过，请稍后重试")
		} else {
			lastErr = fmt.Errorf("LIBVIO 请求失败（HTTP %d），请稍后重试", response.StatusCode)
		}
		if !libvioChallengeRequired(response, body) {
			return "", lastErr
		}
		if err := d.libvioUnlock(ctx, body); err != nil {
			return "", err
		}
	}
	return "", lastErr
}
