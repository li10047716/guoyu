package core

import (
	"context"
	"encoding/base64"
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
	"unicode/utf16"
	"unicode/utf8"
)

// 奈飞工厂（www.netflixgc.com）——苹果 CMS v10 + dsn2（短视）主题。
//
// 这个站的三处结构和普通苹果 CMS 不一样：
//  1. 分类页的 HTML **是空壳**，卡片全部由 JS 拿 JSON 填进来。
//     所以列表只能走 `POST /index.php/ds_api/vod`；同一个地址用 GET 会返回
//     31 字节的 `"短视主题 作者TG @tutucj"`，看着像正常响应其实没有数据。
//  2. 搜索走**搜索结果页** `/vodsearch/-------------.html?wd=&page=`：服务端渲染，
//     每页固定 10 条，页脚 `共N条数据,当前x/y页` 能给总页数，可以一直翻到全量
//     （火影 48 条 / 5 页）。联想接口 `/index.php/ajax/suggest` 有硬上限 20 条且
//     忽略 page 参数，只留作兜底不用；`/ajax/data` 在这个站上直接 500（站点 PHP 8
//     自身 bug），`/api.php/provide/vod` 是 closed，`/index.php/vod/search.html`
//     返回空 body。
//  3. 详情页的分集是 **N 条线路各一个 `ul.anthology-list-play`**（7 条左右），
//     每集地址 `/vodplay/<id>-<线路>-<集>.html`；有的线路是私有加密的
//     （`player_aaaa.url` 形如 `NBY-XMYAES<hash>`），解不出来就得换线路。
//
// 直链都是 m3u8，无 Referer 防盗链、无 UA 校验。
const (
	netflixgcBaseURL     = "https://www.netflixgc.com"
	netflixgcChannelName = "奈飞工厂"
	netflixgcChapterPfx  = "netflixgc-play://"

	netflixgcMaxEpisodes = 20000
	netflixgcMaxPages    = 10000
	netflixgcMaxQuery    = 64
	// 列表接口每页条数由我们自己决定；搜索页是站点固定 10 条，改不了。
	netflixgcPageSize       = 40
	netflixgcSearchPageSize = 10
	netflixgcMaxLineNumber  = 100
	// 播放页解析失败时最多再换几条线路，避免一次播放把 7 条线全打一遍。
	netflixgcMaxLineAttempts = 4
	netflixgcUserAgent       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

// 站点的分类是固定五档（导航里就这五个），不需要额外请求。
var netflixgcCategories = []nativeCategory{
	{ID: "1", Name: "电影"},
	{ID: "2", Name: "连续剧"},
	{ID: "3", Name: "漫剧"},
	{ID: "23", Name: "综艺"},
	{ID: "24", Name: "纪录片"},
}

var (
	reNetflixgcTitle    = regexp.MustCompile(`(?is)<h3\b[^>]*class=["'][^"']*\bslide-info-title\b[^"']*["'][^>]*>(.*?)</h3>`)
	reNetflixgcCover    = regexp.MustCompile(`(?is)<img\b[^>]*class=["'][^"']*\blazy1\b[^"']*["'][^>]*>`)
	reNetflixgcImgTag   = regexp.MustCompile(`(?is)<img\b[^>]*>`)
	reNetflixgcRemarks  = regexp.MustCompile(`(?is)<span\b[^>]*class=["'][^"']*\bslide-info-remarks\b[^"']*["'][^>]*>(.*?)</span>`)
	reNetflixgcIntro    = regexp.MustCompile(`(?is)<div\b[^>]*\bid=["']height_limit["'][^>]*>(.*?)</div>`)
	reNetflixgcPlayList = regexp.MustCompile(
		`(?is)<ul\b[^>]*class=["'][^"']*\banthology-list-play\b[^"']*["'][^>]*>(.*?)</ul>`)
	reNetflixgcAnchor   = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
	reNetflixgcPlayPath = regexp.MustCompile(`(?i)/vodplay/(\d+)-(\d+)-(\d+)\.html`)
	reNetflixgcDetailID = regexp.MustCompile(`(?i)/voddetail/(\d+)\.html`)
	reNetflixgcTagText  = regexp.MustCompile(`(?is)<span\b[^>]*>([^<]{1,24})</span>`)
	reNetflixgcPlayer   = regexp.MustCompile(`(?is)\bplayer_aaaa\s*=\s*(\{.*?\})\s*</script>`)
	reNetflixgcYear     = regexp.MustCompile(`^\d{4}$`)
	reNetflixgcMetaTag  = regexp.MustCompile(`(?is)<meta\b[^>]*>`)

	// 搜索结果是服务端渲染的卡片，块标记就是 class 里的 search-list。
	reNetflixgcSearchBlock = regexp.MustCompile(`(?is)<div\b[^>]*class=["'][^"']*\bsearch-list\b[^"']*["'][^>]*>`)
	// 页脚「共48条数据,当前1/5页」。
	reNetflixgcPageTip   = regexp.MustCompile(`(?is)共\s*(\d+)\s*条数据[^0-9]{0,8}?(\d+)\s*/\s*(\d+)\s*页`)
	reNetflixgcKindField = regexp.MustCompile(`(?is)类型\s*[:：]\s*</strong>(.*?)</div>`)
	reNetflixgcKindItem  = regexp.MustCompile(`(?is)<a\b[^>]*>([^<]{1,32})</a>`)
)

func validNetflixgcID(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 12 {
		return false
	}
	id, err := strconv.ParseInt(value, 10, 64)
	return err == nil && id > 0
}

func validNetflixgcCategory(value string) bool {
	value = strings.TrimSpace(value)
	for _, entry := range netflixgcCategories {
		if entry.ID == value {
			return true
		}
	}
	return false
}

func netflixgcCategoryName(code string) string {
	code = strings.TrimSpace(code)
	for _, entry := range netflixgcCategories {
		if entry.ID == code {
			return entry.Name
		}
	}
	return ""
}

func validNetflixgcLine(value string) bool {
	line, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && line > 0 && line < netflixgcMaxLineNumber
}

func validNetflixgcIndex(value string) bool {
	index, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && index > 0 && index < netflixgcMaxEpisodes
}

// netflixgcCoverAddress 规整封面地址。
//
// 站里有一部分封面走的是百度图片的取图代理
// `https://image.baidu.com/search/down?url=<真实地址>`，直接当封面加载会被拦，
// 这里把 url 参数解出来。
func netflixgcCoverAddress(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "//") {
		raw = "https:" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	if strings.HasSuffix(host, "baidu.com") || strings.HasSuffix(host, "baiduimg.com") {
		if inner := strings.TrimSpace(parsed.Query().Get("url")); inner != "" {
			if nested, nestedErr := url.Parse(inner); nestedErr == nil && validNativeCoverURL(nested) {
				return inner
			}
		}
		return ""
	}
	if !validNativeCoverURL(parsed) {
		return ""
	}
	return parsed.String()
}

// netflixgcUnescape 复刻 JS 的 unescape：`%uXXXX` 变成对应字符，`%XX` 变成一个字节。
//
// 站点有线路把中文目录写成 `%u7B2C01%u96C6`（「第01集」），Go 自带的
// url.QueryUnescape 只认 `%XX`，碰到 `%u` 会原样留下，直链就拼不出来。
func netflixgcUnescape(raw string) string {
	if !strings.Contains(raw, "%") {
		return raw
	}
	out := make([]byte, 0, len(raw))
	for index := 0; index < len(raw); {
		if raw[index] != '%' {
			out = append(out, raw[index])
			index++
			continue
		}
		if index+5 < len(raw) && (raw[index+1] == 'u' || raw[index+1] == 'U') {
			if value, err := strconv.ParseUint(raw[index+2:index+6], 16, 32); err == nil {
				r := rune(value)
				// 代理对：高代理后面紧跟一个 %u 低代理，要合成一个 rune。
				if utf16.IsSurrogate(r) && index+11 < len(raw) && raw[index+6] == '%' &&
					(raw[index+7] == 'u' || raw[index+7] == 'U') {
					if low, lowErr := strconv.ParseUint(raw[index+8:index+12], 16, 32); lowErr == nil {
						if combined := utf16.DecodeRune(r, rune(low)); combined != utf8.RuneError {
							out = utf8.AppendRune(out, combined)
							index += 12
							continue
						}
					}
				}
				out = utf8.AppendRune(out, r)
				index += 6
				continue
			}
		}
		if index+2 < len(raw) {
			if value, err := strconv.ParseUint(raw[index+1:index+3], 16, 8); err == nil {
				out = append(out, byte(value))
				index += 3
				continue
			}
		}
		out = append(out, raw[index])
		index++
	}
	return string(out)
}

// netflixgcRequest 发一次请求。列表接口必须 POST，播放页/详情页用 GET。
func (d *Downloader) netflixgcRequest(ctx context.Context, method, address, referer string, form url.Values) (string, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	request, err := http.NewRequestWithContext(ctx, method, address, body)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", netflixgcUserAgent)
	request.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Sec-Fetch-Dest", "document")
	request.Header.Set("Sec-Fetch-Mode", "navigate")
	request.Header.Set("Sec-Fetch-Site", "none")
	request.Header.Set("Upgrade-Insecure-Requests", "1")
	if form != nil {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
		request.Header.Set("X-Requested-With", "XMLHttpRequest")
	}
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	response, err := d.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return "", err
	}
	payload, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return "", readErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if len(payload) > providerMaxBodyBytes {
		return "", fmt.Errorf("response exceeds %d bytes", providerMaxBodyBytes)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("奈飞工厂请求失败（HTTP %d），请稍后重试", response.StatusCode)
	}
	return string(payload), nil
}

func (d *Downloader) netflixgcGet(ctx context.Context, address, referer string) (string, error) {
	return d.netflixgcRequest(ctx, http.MethodGet, address, referer, nil)
}

func (d *Downloader) netflixgcPost(ctx context.Context, address, referer string, form url.Values) (string, error) {
	return d.netflixgcRequest(ctx, http.MethodPost, address, referer, form)
}

// netflixgcFlexID 兼容 vod_id 有时是字符串、有时是数字。
type netflixgcFlexID string

func (f *netflixgcFlexID) UnmarshalJSON(data []byte) error {
	text := strings.TrimSpace(string(data))
	text = strings.Trim(text, `"`)
	if text == "null" {
		text = ""
	}
	*f = netflixgcFlexID(text)
	return nil
}

type netflixgcListItem struct {
	URL     string          `json:"url"`
	ID      netflixgcFlexID `json:"vod_id"`
	Name    string          `json:"vod_name"`
	Pic     string          `json:"vod_pic"`
	Actor   string          `json:"vod_actor"`
	Tag     string          `json:"vod_tag"`
	Score   *float64        `json:"vod_score"`
	Douban  string          `json:"vod_douban_score"`
	Remarks string          `json:"vod_remarks"`
	Serial  string          `json:"vod_serial"`
	Blurb   string          `json:"vod_blurb"`
}

type netflixgcListResponse struct {
	Code      int                 `json:"code"`
	Msg       string              `json:"msg"`
	Page      int                 `json:"page"`
	PageCount int                 `json:"pagecount"`
	Limit     int                 `json:"limit"`
	Total     int                 `json:"total"`
	List      []netflixgcListItem `json:"list"`
}

func netflixgcTagText(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if match := reNetflixgcTagText.FindStringSubmatch(raw); len(match) > 1 {
		if text := cleanText(match[1]); text != "" {
			return text
		}
	}
	return cleanText(raw)
}

func netflixgcScore(item netflixgcListItem) string {
	if item.Score != nil && *item.Score > 0 {
		return strconv.FormatFloat(*item.Score, 'f', -1, 64)
	}
	if value, err := strconv.ParseFloat(strings.TrimSpace(item.Douban), 64); err == nil && value > 0 {
		return strconv.FormatFloat(value, 'f', -1, 64)
	}
	return ""
}

func parseNetflixgcList(body, categoryName string) ([]Drama, int, error) {
	trimmed := strings.TrimSpace(strings.TrimPrefix(body, "\ufeff"))
	if trimmed == "" {
		return nil, 0, errors.New("奈飞工厂返回了空内容，请稍后重试")
	}
	// GET 打这个接口时服务端会回一句纯文本提示，这里明确报错，免得看着像解析失败。
	if !strings.HasPrefix(trimmed, "{") {
		return nil, 0, errors.New("奈飞工厂列表接口未返回数据，请稍后重试")
	}
	var payload netflixgcListResponse
	if err := json.Unmarshal([]byte(trimmed), &payload); err != nil {
		return nil, 0, fmt.Errorf("奈飞工厂列表解析失败：%w", err)
	}
	if payload.Code != 1 {
		message := strings.TrimSpace(payload.Msg)
		if message == "" {
			message = "列表接口返回异常"
		}
		return nil, 0, fmt.Errorf("奈飞工厂%s，请稍后重试", message)
	}
	items := make([]Drama, 0, len(payload.List))
	seen := map[string]bool{}
	for _, item := range payload.List {
		sourceID := strings.TrimSpace(string(item.ID))
		if !validNetflixgcID(sourceID) {
			if match := reNetflixgcDetailID.FindStringSubmatch(item.URL); len(match) > 1 {
				sourceID = match[1]
			}
		}
		if !validNetflixgcID(sourceID) || seen[sourceID] {
			continue
		}
		title := cleanText(item.Name)
		if title == "" {
			continue
		}
		seen[sourceID] = true
		cover := netflixgcCoverAddress(item.Pic)
		tag := netflixgcTagText(item.Tag)
		category := firstNonEmpty(tag, categoryName)
		blurb := truncate(cleanText(item.Blurb), 2000)
		items = append(items, Drama{
			ID: providerDramaID(sourceNetflixgc, sourceID), Source: sourceNetflixgc, SourceID: sourceID,
			Title: truncate(title, 256), Name: truncate(title, 256),
			Desc: blurb, Intro: blurb,
			Cover: cover, CoverURL: cover,
			Category:    truncate(category, 48),
			ChannelName: netflixgcChannelName,
			Remark:      truncate(cleanText(item.Remarks), 48),
			Score:       netflixgcScore(item),
			Tags:        nonEmptyStrings(tag, truncate(categoryName, 24)),
		})
	}
	return items, payload.PageCount, nil
}

// fetchNetflixgcCategories 直接返回站点固定的五档分类，不需要额外请求。
func (d *Downloader) fetchNetflixgcCategories(_ context.Context) ([]nativeCategory, error) {
	return append([]nativeCategory{}, netflixgcCategories...), nil
}

func (d *Downloader) fetchNetflixgcCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > netflixgcMaxPages || len(query) > netflixgcMaxQuery {
		return nil, false, errors.New("奈飞工厂目录查询参数无效")
	}
	if category != "" && !validNetflixgcCategory(category) {
		return nil, false, errors.New("奈飞工厂内容分类无效")
	}
	if query != "" {
		return d.fetchNetflixgcSearchPage(ctx, query)
	}
	if category != "" {
		return d.fetchNetflixgcCategoryPage(ctx, page, category)
	}
	// 「全部」= 并行合并五档内容分类。
	type outcome struct {
		items []Drama
		more  bool
		err   error
	}
	results := make([]outcome, len(netflixgcCategories))
	slots := make(chan struct{}, 3)
	var group sync.WaitGroup
	for index, entry := range netflixgcCategories {
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
				d.fetchNetflixgcCategoryPage(ctx, page, entry.ID)
		}(index, entry)
	}
	group.Wait()
	var items []Drama
	var failures []error
	more := false
	// 同一部片可能同时挂在多个分类下，合并时按剧集 ID 去重。
	seen := map[string]bool{}
	for _, entry := range results {
		for _, item := range entry.items {
			if item.ID != "" && seen[item.ID] {
				continue
			}
			seen[item.ID] = true
			items = append(items, item)
		}
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

func (d *Downloader) fetchNetflixgcCategoryPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	base := d.providerBaseURL(sourceNetflixgc)
	form := url.Values{}
	form.Set("type", category)
	form.Set("page", strconv.Itoa(page))
	form.Set("limit", strconv.Itoa(netflixgcPageSize))
	form.Set("mid", "1")
	form.Set("level", "0")
	form.Set("by", "time")
	referer := fmt.Sprintf("%s/vodshow/%s-----------.html", base, category)
	body, err := d.netflixgcPost(ctx, base+"/index.php/ds_api/vod", referer, form)
	if err != nil {
		return nil, false, err
	}
	items, pageCount, err := parseNetflixgcList(body, netflixgcCategoryName(category))
	if err != nil {
		return nil, false, err
	}
	more := len(items) >= netflixgcPageSize && (pageCount == 0 || page < pageCount)
	return items, more, nil
}

// netflixgcSearchAddress 拼搜索结果页地址。
//
// 搜索词走 query 参数（`?wd=`）而不是路径段：路径式的槽位是用 `-` 分隔的，
// 搜索词里带 `-` 会把分页字段搅乱。空格必须编成 %20 而不是 `+`，
// 这个站按 %20 解码时最稳。
func netflixgcSearchAddress(base, query string, page int) string {
	if page < 1 {
		page = 1
	}
	escaped := strings.ReplaceAll(url.QueryEscape(strings.TrimSpace(query)), "+", "%20")
	return fmt.Sprintf("%s/vodsearch/-------------.html?wd=%s&page=%d", base, escaped, page)
}

// fetchNetflixgcSearchPage 只用来满足旧调用点（第 1 页）。
func (d *Downloader) fetchNetflixgcSearchPage(ctx context.Context, query string) ([]Drama, bool, error) {
	return d.fetchNetflixgcSearchPageAt(ctx, 1, query)
}

// fetchNetflixgcSearchPageAt 走站点搜索结果页，按页脚的总页数翻页。
//
// 每页固定 10 条（站点写死的），所以「能不能翻」只看 page 和 总页数的关系；
// 站点偶尔不给页脚（只有一条命中的时候），这时按「本页满 10 条就当作还有」兜底。
func (d *Downloader) fetchNetflixgcSearchPageAt(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, false, errors.New("奈飞工厂搜索关键词无效")
	}
	if runes := []rune(query); len(runes) > netflixgcMaxQuery {
		query = strings.TrimSpace(string(runes[:netflixgcMaxQuery]))
	}
	if page < 1 {
		page = 1
	}
	if page > netflixgcMaxPages {
		return nil, false, nil
	}
	base := d.providerBaseURL(sourceNetflixgc)
	address := netflixgcSearchAddress(base, query, page)
	body, err := d.netflixgcGet(ctx, address, base+"/vodsearch/")
	if err != nil {
		return nil, false, err
	}
	items, totalPages, err := parseNetflixgcSearchPage(body)
	if err != nil {
		return nil, false, err
	}
	more := page < totalPages
	if totalPages == 0 {
		more = len(items) >= netflixgcSearchPageSize
	}
	if len(items) == 0 {
		more = false
	}
	return items, more, nil
}

// parseNetflixgcSearchPage 解析搜索结果页，返回本页剧集和总页数。
func parseNetflixgcSearchPage(body string) ([]Drama, int, error) {
	trimmed := strings.TrimSpace(strings.TrimPrefix(body, "\ufeff"))
	if trimmed == "" {
		return nil, 0, errors.New("奈飞工厂搜索页返回了空内容，请稍后重试")
	}
	marks := reNetflixgcSearchBlock.FindAllStringIndex(trimmed, -1)
	// 真正的搜索页一定带着这些链接；两者都没有说明拿到的是错误页，别静默返回空列表。
	if len(marks) == 0 && !strings.Contains(trimmed, "/vodsearch/") {
		return nil, 0, errors.New("奈飞工厂搜索页结构异常，请稍后重试")
	}
	totalPages := 0
	if match := reNetflixgcPageTip.FindStringSubmatch(trimmed); len(match) > 3 {
		if value, err := strconv.Atoi(match[3]); err == nil && value > 0 {
			totalPages = value
		}
	}
	items := make([]Drama, 0, len(marks))
	seen := map[string]bool{}
	for index, mark := range marks {
		end := len(trimmed)
		if index+1 < len(marks) {
			end = marks[index+1][0]
		}
		block := trimmed[mark[0]:end]
		// firstMatchText 返回的是整段匹配（带 /voddetail/ 前缀），这里要的是捕获组。
		sourceID := ""
		if match := reNetflixgcDetailID.FindStringSubmatch(block); len(match) > 1 {
			sourceID = strings.TrimSpace(match[1])
		}
		if !validNetflixgcID(sourceID) || seen[sourceID] {
			continue
		}
		title := cleanText(firstMatchText(reNetflixgcTitle, block))
		if title == "" {
			if img := firstMatchText(reNetflixgcImgTag, block); img != "" {
				title = cleanText(extractAttr(img, "alt"))
			}
		}
		title = cleanText(title)
		if title == "" {
			continue
		}
		seen[sourceID] = true
		cover := ""
		if img := firstMatchText(reNetflixgcCover, block); img != "" {
			cover = netflixgcCoverAddress(extractAttr(img, "data-src", "data-original", "src"))
		}
		// 第一段 remarks 是「已完结」，后面依次是年份和地区。
		remark := ""
		var extra []string
		for spanIndex, match := range reNetflixgcRemarks.FindAllStringSubmatch(block, -1) {
			if len(match) < 2 {
				continue
			}
			text := cleanText(match[1])
			if spanIndex == 0 {
				remark = text
				continue
			}
			if text != "" {
				extra = append(extra, text)
			}
		}
		var kinds []string
		if match := reNetflixgcKindField.FindStringSubmatch(block); len(match) > 1 {
			for _, anchor := range reNetflixgcKindItem.FindAllStringSubmatch(match[1], -1) {
				if text := cleanText(anchor[1]); text != "" {
					kinds = append(kinds, text)
				}
			}
		}
		tags := make([]string, 0, 4)
		picked := map[string]bool{}
		for _, kind := range kinds {
			if len(tags) >= 2 {
				break
			}
			if picked[kind] {
				continue
			}
			picked[kind] = true
			tags = append(tags, truncate(kind, 24))
		}
		if len(extra) > 0 {
			region := extra[len(extra)-1]
			if region != "" && region != "未知" && !picked[region] {
				tags = append(tags, truncate(region, 24))
			}
		}
		if len(tags) == 0 {
			tags = []string{"搜索"}
		}
		category := "搜索"
		if len(kinds) > 0 {
			category = kinds[0]
		}
		items = append(items, Drama{
			ID: providerDramaID(sourceNetflixgc, sourceID), Source: sourceNetflixgc, SourceID: sourceID,
			Title: truncate(title, 256), Name: truncate(title, 256),
			Cover: cover, CoverURL: cover,
			Category:    truncate(category, 48),
			ChannelName: netflixgcChannelName,
			Remark:      truncate(remark, 48),
			Tags:        tags,
		})
	}
	return items, totalPages, nil
}

type netflixgcEpisode struct {
	line  int
	index int
	title string
}

// parseNetflixgcEpisodes 按线路分组解析详情页的分集。
//
// 每条线路是独立的 `ul.anthology-list-play`，集号只在该线路内部有意义，
// 所以必须先按线路分开、再按集号合并。
func parseNetflixgcEpisodes(raw string) [][]netflixgcEpisode {
	blocks := reNetflixgcPlayList.FindAllStringSubmatch(raw, -1)
	if len(blocks) == 0 {
		return nil
	}
	var lines [][]netflixgcEpisode
	for _, block := range blocks {
		if len(block) < 2 {
			continue
		}
		var episodes []netflixgcEpisode
		seen := map[int]bool{}
		for _, anchor := range reNetflixgcAnchor.FindAllStringSubmatch(block[1], -1) {
			if len(anchor) < 3 {
				continue
			}
			tag := "<a " + anchor[1] + ">"
			match := reNetflixgcPlayPath.FindStringSubmatch(extractAttr(tag, "href"))
			if len(match) < 4 {
				continue
			}
			line, lineErr := strconv.Atoi(match[2])
			number, indexErr := strconv.Atoi(match[3])
			if lineErr != nil || indexErr != nil {
				continue
			}
			if line <= 0 || line >= netflixgcMaxLineNumber || number <= 0 || number >= netflixgcMaxEpisodes {
				continue
			}
			if seen[number] {
				continue
			}
			seen[number] = true
			title := cleanText(extractAttr(tag, "title"))
			if title == "" {
				title = cleanText(anchor[2])
			}
			episodes = append(episodes, netflixgcEpisode{line: line, index: number, title: title})
		}
		if len(episodes) > 0 {
			lines = append(lines, episodes)
		}
	}
	return lines
}

// netflixgcLineOrder 给出线路优先级：线路号小的排前面。
//
// 站点线路号越小越接近主线路（1 号通常是 FFZY 那套，最稳）；集数多的不一定最稳，
// 所以这里按号排序而不是按集数排序，缺集再由后面的线路补。
func netflixgcLineOrder(lines [][]netflixgcEpisode) []int {
	seen := map[int]bool{}
	var order []int
	for _, episodes := range lines {
		for _, episode := range episodes {
			if !seen[episode.line] {
				seen[episode.line] = true
				order = append(order, episode.line)
			}
		}
	}
	sort.Ints(order)
	return order
}

// netflixgcChapters 把多线路合并成一串分集，每集带上「可以尝试的线路列表」。
func netflixgcChapters(lines [][]netflixgcEpisode) ([]netflixgcEpisode, [][]int) {
	order := netflixgcLineOrder(lines)
	if len(order) == 0 {
		return nil, nil
	}
	// 集号 -> 线路 -> 分集
	index := map[int]map[int]netflixgcEpisode{}
	var numbers []int
	for _, episodes := range lines {
		for _, episode := range episodes {
			if index[episode.index] == nil {
				index[episode.index] = map[int]netflixgcEpisode{}
				numbers = append(numbers, episode.index)
			}
			index[episode.index][episode.line] = episode
		}
	}
	sort.Ints(numbers)
	out := make([]netflixgcEpisode, 0, len(numbers))
	candidates := make([][]int, 0, len(numbers))
	for _, number := range numbers {
		available := index[number]
		var linesForEpisode []int
		for _, line := range order {
			if _, ok := available[line]; ok {
				linesForEpisode = append(linesForEpisode, line)
			}
		}
		if len(linesForEpisode) == 0 {
			continue
		}
		out = append(out, available[linesForEpisode[0]])
		candidates = append(candidates, linesForEpisode)
	}
	return out, candidates
}

func netflixgcMetaContent(raw, key string) string {
	key = strings.ToLower(strings.TrimSpace(key))
	if key == "" {
		return ""
	}
	for _, tag := range reNetflixgcMetaTag.FindAllString(raw, -1) {
		if name := extractAttr(tag, "property", "name"); strings.EqualFold(name, key) {
			return extractAttr(tag, "content")
		}
	}
	return ""
}

func (d *Downloader) fetchNetflixgcDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	sourceID = strings.TrimSpace(sourceID)
	if !validNetflixgcID(sourceID) {
		return Drama{}, nil, errors.New("奈飞工厂剧集地址无效")
	}
	base := d.providerBaseURL(sourceNetflixgc)
	detailURL := base + "/voddetail/" + sourceID + ".html"
	body, err := d.netflixgcGet(ctx, detailURL, base+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	title := cleanText(firstMatchText(reNetflixgcTitle, body))
	if title == "" {
		title = cleanText(netflixgcMetaContent(body, "og:title"))
	}
	if title == "" {
		return Drama{}, nil, errors.New("奈飞工厂详情页未返回片名，请稍后重试")
	}
	cover := ""
	if img := firstMatchText(reNetflixgcCover, body); img != "" {
		cover = netflixgcCoverAddress(extractAttr(img, "data-src", "data-original", "src"))
	}
	if cover == "" {
		cover = netflixgcCoverAddress(netflixgcMetaContent(body, "og:image"))
	}
	// 第一段 slide-info-remarks 是「更新至第21集」，后面几段是年份和地区。
	remark := ""
	var tags []string
	for index, match := range reNetflixgcRemarks.FindAllStringSubmatch(body, -1) {
		if len(match) < 2 {
			continue
		}
		if index == 0 {
			remark = cleanText(match[1])
			continue
		}
		text := cleanText(match[1])
		if text != "" && (reNetflixgcYear.MatchString(text) || len([]rune(text)) <= 10) {
			tags = append(tags, text)
		}
	}
	description := cleanText(firstMatchText(reNetflixgcIntro, body))
	if description == "" {
		description = cleanText(netflixgcMetaContent(body, "og:description"))
	}
	if description == "" {
		description = cleanText(netflixgcMetaContent(body, "description"))
	}
	episodes, candidates := netflixgcChapters(parseNetflixgcEpisodes(body))
	if len(episodes) == 0 {
		return Drama{}, nil, errors.New("该片暂时没有可播放的分集")
	}
	category := ""
	if len(tags) > 0 {
		category = tags[len(tags)-1]
	}
	drama := Drama{
		ID: providerDramaID(sourceNetflixgc, sourceID), Source: sourceNetflixgc, SourceID: sourceID,
		Title: truncate(title, 256), Name: truncate(title, 256),
		Desc: truncate(description, 12000), Intro: truncate(description, 12000),
		Cover: cover, CoverURL: cover,
		TotalEpisode: len(episodes), EpisodeCount: len(episodes),
		Category: truncate(category, 48), ChannelName: netflixgcChannelName,
		Tags:   nonEmptyStrings(category),
		Remark: truncate(remark, 48),
	}
	chapters := make([]Chapter, 0, len(episodes))
	seenNumbers := map[int]bool{}
	for position, episode := range episodes {
		number := episodeIndex(episode.title, episode.index)
		if seenNumbers[number] {
			number = episode.index
		}
		if seenNumbers[number] {
			return Drama{}, nil, errors.New("奈飞工厂分集编号重复，请刷新详情")
		}
		seenNumbers[number] = true
		chapterTitle := episode.title
		if chapterTitle == "" {
			chapterTitle = fmt.Sprintf("第 %d 集", number)
		}
		key := netflixgcChapterKey(sourceID, episode.line, episode.index, candidates[position])
		chapters = append(chapters, Chapter{
			ID:     providerChapterID(sourceNetflixgc, sourceID, fmt.Sprintf("%d-%d", episode.line, episode.index)),
			Source: sourceNetflixgc,
			Title:  chapterTitle, CurrentEpisode: []byte(strconv.Itoa(number)),
			// 真正的地址要再请求一次播放页，所以这里只存定位信息和候选线路。
			VideoURL: netflixgcChapterPfx + key, Referer: detailURL,
		})
	}
	return drama, chapters, nil
}

func (d *Downloader) fetchNetflixgcChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	drama, chapters, err := d.fetchNetflixgcDetail(ctx, sourceID)
	return drama.DisplayTitle(), chapters, err
}

// netflixgcChapterKey 形如 `80230-1-1-1,2,3,4,5,7`：剧集 / 首线路 / 集号 / 候选线路。
func netflixgcChapterKey(sourceID string, line, index int, candidates []int) string {
	lines := make([]string, 0, len(candidates))
	for _, value := range candidates {
		lines = append(lines, strconv.Itoa(value))
	}
	if len(lines) == 0 {
		lines = append(lines, strconv.Itoa(line))
	}
	return sourceID + "-" + strconv.Itoa(line) + "-" + strconv.Itoa(index) + "-" + strings.Join(lines, ",")
}

type netflixgcPlayRequest struct {
	sourceID   string
	line       int
	index      int
	candidates []int
}

func parseNetflixgcChapterKey(key string) (netflixgcPlayRequest, bool) {
	parts := strings.Split(strings.TrimSpace(key), "-")
	if len(parts) != 4 {
		return netflixgcPlayRequest{}, false
	}
	if !validNetflixgcID(parts[0]) || !validNetflixgcLine(parts[1]) || !validNetflixgcIndex(parts[2]) {
		return netflixgcPlayRequest{}, false
	}
	line, _ := strconv.Atoi(parts[1])
	index, _ := strconv.Atoi(parts[2])
	request := netflixgcPlayRequest{sourceID: parts[0], line: line, index: index}
	for _, piece := range strings.Split(parts[3], ",") {
		if !validNetflixgcLine(piece) {
			continue
		}
		value, _ := strconv.Atoi(piece)
		request.candidates = append(request.candidates, value)
	}
	// 候选线路一段全部非法，说明这个键是伪造或已损坏的，直接拒绝。
	if len(request.candidates) == 0 {
		return netflixgcPlayRequest{}, false
	}
	return request, true
}

// netflixgcPlayer 对应播放页里的 `var player_aaaa={...}`。
type netflixgcPlayer struct {
	Encrypt int    `json:"encrypt"`
	Trysee  int    `json:"trysee"`
	URL     string `json:"url"`
	Flag    string `json:"flag"`
}

func parseNetflixgcPlayer(raw string) (netflixgcPlayer, bool) {
	match := reNetflixgcPlayer.FindStringSubmatch(raw)
	if len(match) < 2 {
		return netflixgcPlayer{}, false
	}
	var player netflixgcPlayer
	if err := json.Unmarshal([]byte(match[1]), &player); err != nil {
		return netflixgcPlayer{}, false
	}
	return player, true
}

func netflixgcBase64Decode(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}
	candidates := []string{
		strings.TrimSpace(raw),
		strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(raw, "-", "+"), "_", "/")),
	}
	for _, candidate := range candidates {
		if decoded, err := base64.StdEncoding.DecodeString(candidate); err == nil {
			return string(decoded), true
		}
		if decoded, err := base64.RawStdEncoding.DecodeString(strings.TrimRight(candidate, "=")); err == nil {
			return string(decoded), true
		}
	}
	return "", false
}

// netflixgcMediaCandidates 把播放页的 url 还原成若干候选地址。
//
// 苹果 CMS 的 `encrypt`：1 = 只做 JS 转义，2 = 转义 + base64，3 = 原样。
// 站点在 2 的基础上还套了一层 unescape（直接链解出来是 `%68%74%74%70...`），
// 个别线路再用 `%uXXXX` 编码中文目录，所以这里逐层剥、逐层试，不写死分支。
func netflixgcMediaCandidates(player netflixgcPlayer) []string {
	raw := strings.TrimSpace(player.URL)
	if raw == "" {
		return nil
	}
	var out []string
	seen := map[string]bool{}
	add := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			return
		}
		seen[value] = true
		out = append(out, value)
	}
	add(raw)
	add(netflixgcUnescape(raw))
	for _, base := range append([]string{}, out...) {
		if decoded, ok := netflixgcBase64Decode(base); ok {
			add(decoded)
			add(netflixgcUnescape(decoded))
		}
	}
	return out
}

// netflixgcResolveLine 请求一条线路的播放页并解出直链。
func (d *Downloader) netflixgcResolveLine(ctx context.Context, sourceID string, line, index int, referer string) (providerMedia, error) {
	base := d.providerBaseURL(sourceNetflixgc)
	pageURL := fmt.Sprintf("%s/vodplay/%s-%d-%d.html", base, sourceID, line, index)
	body, err := d.netflixgcGet(ctx, pageURL, referer)
	if err != nil {
		return providerMedia{}, err
	}
	player, found := parseNetflixgcPlayer(body)
	if !found {
		return providerMedia{}, errors.New("奈飞工厂播放页未返回播放参数")
	}
	for _, candidate := range netflixgcMediaCandidates(player) {
		if !isProviderHTTPMediaURL(candidate) {
			continue
		}
		media := providerMedia{URL: candidate, Referer: pageURL}
		if parsed, parseErr := url.Parse(candidate); parseErr == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
			playlist, finalURL, playlistErr := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
			if playlistErr != nil {
				return providerMedia{}, fmt.Errorf("获取奈飞工厂播放列表失败：%w", playlistErr)
			}
			if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
				return providerMedia{}, errors.New("奈飞工厂未返回有效播放列表，请重试")
			}
			if duration := m3u8Duration(playlist); duration > 0 {
				media.Duration = duration
			}
			media.Playlist = playlist
			media.URL = finalURL
		}
		return media, nil
	}
	return providerMedia{}, errors.New("奈飞工厂该线路未返回有效播放地址")
}

// resolveNetflixgcMedia 依次尝试候选线路：站里有的线路是私有加密的，
// 单条线路解不出来时换下一条，而不是直接把失败抛给用户。
func (d *Downloader) resolveNetflixgcMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceNetflixgc, sourceID, "")
	if !valid || source != sourceNetflixgc || !validNetflixgcID(sourceID) || !strings.HasPrefix(task.Chapter.VideoURL, netflixgcChapterPfx) {
		return providerMedia{}, errors.New("奈飞工厂播放分集信息无效，请刷新详情")
	}
	if !strings.HasPrefix(task.Chapter.ID, prefix) {
		return providerMedia{}, errors.New("奈飞工厂播放分集信息无效，请刷新详情")
	}
	key := strings.TrimPrefix(task.Chapter.VideoURL, netflixgcChapterPfx)
	request, ok := parseNetflixgcChapterKey(key)
	if !ok || request.sourceID != sourceID {
		return providerMedia{}, errors.New("奈飞工厂分集地址无效")
	}
	base := d.providerBaseURL(sourceNetflixgc)
	referer := firstNonEmpty(task.Chapter.Referer, base+"/voddetail/"+sourceID+".html")
	attempts := request.candidates
	if len(attempts) > netflixgcMaxLineAttempts {
		attempts = attempts[:netflixgcMaxLineAttempts]
	}
	var failures []error
	for _, line := range attempts {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		media, err := d.netflixgcResolveLine(ctx, sourceID, line, request.index, referer)
		if err == nil {
			return media, nil
		}
		failures = append(failures, err)
	}
	if err := errors.Join(failures...); err != nil {
		return providerMedia{}, fmt.Errorf("奈飞工厂所有可用线路都解析失败，请稍后重试")
	}
	return providerMedia{}, errors.New("奈飞工厂未返回有效播放地址，请刷新分集或稍后重试")
}
