package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

const hongguoBaseURL = "https://hongguoduanju.com"

func (d *Downloader) fetchHongguoDramas(ctx context.Context) ([]Drama, error) {
	initialized := hongguoCatalogInitialized(d.hongguoCatalogSnapshot())
	dramas, appErr := d.fetchHongguoAppCatalog(ctx)
	if len(dramas) > 0 || appErr == nil && initialized {
		return dramas, appErr
	}
	if ctx.Err() != nil {
		return dramas, ctx.Err()
	}
	webDramas, webErr := d.fetchHongguoWebDramas(ctx)
	if len(webDramas) > 0 && webErr == nil {
		return webDramas, nil
	}
	return webDramas, errors.Join(appErr, webErr)
}

func (d *Downloader) fetchHongguoWebDramas(ctx context.Context) ([]Drama, error) {
	routes := []struct {
		path string
		name string
	}{
		{path: "real-drama", name: "真人剧"},
		{path: "comic-drama", name: "漫剧"},
		{path: "ai-drama", name: "AI剧"},
		{path: "comic", name: "动漫"},
	}
	type routeResult struct {
		dramas []Drama
		err    error
	}
	results := make(chan routeResult, len(routes))
	for _, route := range routes {
		route := route
		go func() {
			dramas, err := d.fetchHongguoRoute(ctx, route.path, route.name)
			results <- routeResult{dramas: dramas, err: err}
		}()
	}
	seen := map[string]bool{}
	var out []Drama
	var failures []error
	for range routes {
		result := <-results
		if result.err != nil {
			failures = append(failures, result.err)
		}
		for _, drama := range result.dramas {
			if drama.ID != "" && !seen[drama.ID] {
				seen[drama.ID] = true
				out = append(out, drama)
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].DisplayTitle() < out[j].DisplayTitle() })
	return out, errors.Join(failures...)
}

func (d *Downloader) fetchHongguoRoute(ctx context.Context, route, category string) ([]Drama, error) {
	pages := d.cfg.MaxPagesPerSort
	if pages < 1 {
		pages = 1
	}
	var dramas []Drama
	seen := map[string]bool{}
	for page := 1; page <= pages; page++ {
		items, totalPages, err := d.fetchHongguoCategoryPage(ctx, route+"?page="+strconv.Itoa(page), category)
		if err != nil {
			return dramas, fmt.Errorf("%s: %w", category, err)
		}
		if totalPages > pages {
			pages = totalPages
			if pages > 500 {
				pages = 500
			}
		}
		reportLibraryProgress(ctx, sourceHongguo, items, nil, false)
		added := 0
		for _, drama := range items {
			if !seen[drama.ID] {
				seen[drama.ID] = true
				dramas = append(dramas, drama)
				added++
			}
		}
		if added == 0 || len(items) < 24 {
			break
		}
	}
	return dramas, nil
}

func (d *Downloader) fetchHongguoCategoryPage(ctx context.Context, route, category string) ([]Drama, int, error) {
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/category/"+route, hongguoBaseURL+"/")
	if err != nil {
		return nil, 0, err
	}
	data := parseRouterData(body)
	page := routerLoaderMap(data, "category_page", "category_$")
	if len(page) == 0 || page["isSuccess"] == false {
		return nil, 0, errors.New("红果分类数据不可用，可能是页面结构或访问权限变化")
	}
	items := anyList(page["recommendList"])
	out := make([]Drama, 0, len(items))
	for _, item := range items {
		if dr := hongguoDramaFromAny(item, category); dr.ID != "" {
			out = append(out, dr)
		}
	}
	pages, _ := strconv.Atoi(mapString(nestedMap(page, "pagination"), "totalPages"))
	return out, pages, nil
}

func (d *Downloader) fetchHongguoChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	sourceID = strings.TrimPrefix(strings.TrimSpace(sourceID), "hg-series-v1:")
	if sourceID == "" {
		return "", nil, fmt.Errorf("empty hongguo sourceID")
	}
	entry, appErr := d.hongguoAppDetail(ctx, sourceID)
	if appErr == nil {
		return entry.Drama.DisplayTitle(), append([]Chapter(nil), entry.Chapters...), nil
	}
	if ctx.Err() != nil {
		return "", nil, ctx.Err()
	}
	title, chapters, webErr := d.fetchHongguoWebChapters(ctx, sourceID)
	if webErr == nil {
		return title, chapters, nil
	}
	return "", nil, fmt.Errorf("App 详情失败: %v；网页详情失败: %w", publicError(appErr), webErr)
}

func (d *Downloader) fetchHongguoWebChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/detail?series_id="+url.QueryEscape(sourceID), hongguoBaseURL+"/")
	if err != nil {
		return "", nil, err
	}
	data := parseRouterData(body)
	page := routerLoaderMap(data, "detail_page", "detail_")
	detail, _ := page["seriesDetail"].(map[string]any)
	if len(detail) == 0 {
		return "", nil, fmt.Errorf("hongguo detail is empty")
	}
	title := firstNonEmpty(mapString(detail, "series_name", "series_title", "name"), sourceID)
	vids := anyList(detail["vid_list"])
	chapters := make([]Chapter, 0, len(vids))
	for i, v := range vids {
		vid := strings.TrimSpace(fmt.Sprint(v))
		if vid == "" || vid == "<nil>" {
			continue
		}
		idx := i + 1
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceHongguo, sourceID, vid), Source: sourceHongguo, Title: fmt.Sprintf("第%d集", idx), VideoURL: "hongguo-cenc://" + vid, CurrentEpisode: rawEpisode(idx)})
	}
	if len(chapters) == 0 {
		return title, nil, errors.New("红果详情没有返回剧集 ID")
	}
	return title, chapters, nil
}

func parseRouterData(raw string) map[string]any {
	idx := regexp.MustCompile(`(?s)(?:window\.)?_ROUTER_DATA\s*=\s*`).FindStringIndex(raw)
	if idx == nil {
		return nil
	}
	var data map[string]any
	dec := json.NewDecoder(strings.NewReader(raw[idx[1]:]))
	dec.UseNumber()
	if err := dec.Decode(&data); err != nil {
		return nil
	}
	return data
}

func (d *Downloader) resolveHongguoMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceHongguo {
		return providerMedia{}, fmt.Errorf("红果章节缺少剧 ID，请刷新剧库后重新加入队列")
	}
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, "hongguo-cenc://")
	if !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("红果章节 ID 无效，请重新获取章节")
	}
	media, nativeErr := d.resolveHongguoAppMedia(ctx, videoID)
	if nativeErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, pageErr := d.resolveHongguoWebMedia(ctx, seriesID, videoID)
	if pageErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, apiErr := d.resolveHongguoPlaybackAPI(ctx, seriesID, videoID)
	if apiErr == nil {
		return media, nil
	}
	// 0.7.77：App 取流已恢复（裸请求），这里的兜底只在网关整体不可达时才走到，
	// 错误文案保留三条链路各自的原因，方便排查而不是给用户下结论。
	return providerMedia{}, fmt.Errorf(
		"红果暂不可播：App 取流 %v；网页取流 %v；备用线路 %v。可稍后重试，或换其他站源查找这部剧",
		publicError(nativeErr), publicError(pageErr), publicError(apiErr))
}

func (d *Downloader) resolveHongguoWebMedia(ctx context.Context, seriesID, videoID string) (providerMedia, error) {
	pageURL := hongguoBaseURL + "/player/" + url.PathEscape(seriesID) + "/" + url.PathEscape(videoID)
	body, err := d.fetchProviderText(ctx, pageURL, hongguoBaseURL+"/")
	if err != nil {
		// 站点对「非公开集」直接 404 播放页；先试公开流，再给可读说明。
		if strings.Contains(err.Error(), "HTTP 404") {
			if media, ok := d.hongguoPublicTrialMedia(ctx, "", videoID); ok {
				return media, nil
			}
			return providerMedia{}, fmt.Errorf("红果该集只有约 10 秒的试看片段（站点未公开整集）；完整剧集需在红果 App 内观看，也可在其他站源查找这部剧")
		}
		return providerMedia{}, err
	}
	page := routerLoaderMap(parseRouterData(body), "player_", "player_page")
	if mapString(page, "vid") != videoID || mapString(page, "series_id") != seriesID {
		// 0.7.39：站点改版后播放页可能不再有 player_page 数据块，
		// 但公开试看流仍可拼出，先按公开流兜底，再判失败。
		if media, ok := d.hongguoPublicTrialMedia(ctx, body, videoID); ok {
			return media, nil
		}
		return providerMedia{}, fmt.Errorf("红果该集只有约 10 秒的试看片段（站点未公开整集）；完整剧集需在红果 App 内观看，也可在其他站源查找这部剧")
	}
	info, _ := page["video_player_info"].(map[string]any)
	addresses := hongguoMediaAddresses(info)
	if len(addresses) == 0 {
		// 2026-10-27 起网页不再下发 video_player_info，改为前台拼 /video/public/<vid>/360p.mp4；
		// 取不到直链时按公开流兜底。
		if media, ok := d.hongguoPublicTrialMedia(ctx, body, videoID); ok {
			return media, nil
		}
		return providerMedia{}, fmt.Errorf("红果该集只有约 10 秒的试看片段（站点未公开整集）；完整剧集需在红果 App 内观看，也可在其他站源查找这部剧")
	}
	duration, _ := strconv.ParseFloat(mapString(info, "duration"), 64)
	media := providerMedia{URL: addresses[0], Referer: d.providerBaseURL(sourceHongguo) + "/", Duration: time.Duration(duration * float64(time.Second))}
	for _, address := range addresses {
		variant := media
		variant.URL, variant.Variants = address, nil
		media.Variants = append(media.Variants, variant)
	}
	return media, nil
}

// hongguoPublicStreamPath 匹配页面里内嵌的公开流路径（带 vid，便于校验）。
var hongguoPublicStreamPath = regexp.MustCompile(`/video/public/([1-9][0-9]{0,18})/[A-Za-z0-9_.\-]+\.(?:mp4|m3u8)`)

// hongguoPublicTrialMedia 取站点公开的试看流（0.7.39）。
//
// 站点前台（player.*.js）的取址规则是纯拼路径：
//
//	/video/public/<vid>/360p.mp4
//
// 站点对这个路径给的是**约 10 秒的试看片段**（实测 6 集全部 589~591 KB、
// ffprobe 10.08 秒），不是整集；所以探测除了看 206，还要看总字节数，
// 片段会被 hongguoPublicStreamReady 判为不可用，避免把 10 秒预告播成正片。
// 路径里带完整 vid，也保证了不会张冠李戴。
func (d *Downloader) hongguoPublicTrialMedia(ctx context.Context, body, videoID string) (providerMedia, bool) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, false
	}
	var candidates []string
	if match := hongguoPublicStreamPath.FindStringSubmatch(body); len(match) > 1 && match[1] == videoID {
		// 部分集把地址直接写进 <video src>（第 1 集常见）。
		candidates = append(candidates, hongguoBaseURL+match[0])
	}
	candidates = append(candidates, hongguoBaseURL+"/video/public/"+videoID+"/360p.mp4")
	for _, address := range candidates {
		if !d.hongguoPublicStreamReady(ctx, address) {
			continue
		}
		quality := 0
		if digits := hongguoQualityNumber.FindString(address[strings.LastIndex(address, "/")+1:]); digits != "" {
			quality, _ = strconv.Atoi(digits)
		}
		return providerMedia{URL: address, Referer: hongguoBaseURL + "/", Quality: quality}, true
	}
	return providerMedia{}, false
}

// hongguoPublicStreamReady 探测公开流是否可取。
//
// 2026-10-27 实测（同一 vid 反复请求）：边缘节点在缓存未就绪时对首个请求回 404，
// 间隔两三秒重试就会转成 206；并发稍高还会收到 444（站点主动断连限频）。
// 单次探测会把大量真实可播的集数误判成「该集无片源」，所以这里必须退避重试。
// hongguoPublicPreviewBytes 是「试看片段」的体积上限。
//
// 2026-10-27 实测：/video/public/<vid>/360p.mp4 在 6 集上全部是 589~591 KB，
// ffprobe 时长一律 10.08 秒（640x360 h264 + aac）——站点公开给你的是十分钟
// 影片里的一小段预告，不是整集。正片 360p 至少数 MB，所以用体积就能区分。
const hongguoPublicPreviewBytes = 2 << 20

func (d *Downloader) hongguoPublicStreamReady(ctx context.Context, address string) bool {
	// 整个探测过程给 12 秒预算：单次请求偶尔会挂到超时，不能让点播放等太久。
	probeCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	const attempts = 4
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			select {
			case <-probeCtx.Done():
				return false
			case <-time.After(1500 * time.Millisecond):
			}
		}
		status, total, err := d.hongguoPublicStreamStatus(probeCtx, address)
		if err == nil && (status == http.StatusOK || status == http.StatusPartialContent) {
			// 站点给的公开文件只是十几秒预告，不能当整集播；重试也不会有变化。
			if total > 0 && total < hongguoPublicPreviewBytes {
				return false
			}
			return true
		}
		// 明确的鉴权拒绝不必浪费重试次数；404/444/超时都当作「可能还没就绪」。
		if status == http.StatusForbidden || status == http.StatusUnauthorized {
			return false
		}
		// 边缘节点是按连接命中的：复用 keep-alive 会一直问同一个未就绪的节点，
		// 丢掉空闲连接强制重新拨号，才有机会落到已经缓存好的节点上。
		if d.client != nil {
			d.client.CloseIdleConnections()
		}
	}
	return false
}

// hongguoWebUserAgent 是请求红果网页资源时使用的桌面浏览器 UA。
//
// 2026-10-27 实测：同一 vid 的 /video/public/<vid>/360p.mp4，用移动端（iPhone/Android/
// App webview）UA 请求恒为 404，改用桌面 Chrome UA 才返回 206；播放页的移动版也少了
// pcPlaybackAuthState / libraConfig 一整块数据（约 12KB）。所以网页侧不能沿用全局的
// 移动 UA。
const hongguoWebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

// hongguoPublicStreamStatus 探测公开流，返回状态码与资源总字节数。
//
// 总字节数来自 206 的 Content-Range（`bytes 0-1/589639`），用于识别
// 「站点只给了十几秒试看片段」这种情况——只看状态码会把片段当成整集。
func (d *Downloader) hongguoPublicStreamStatus(ctx context.Context, address string) (int, int64, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return 0, 0, err
	}
	// 只取 2 字节：够拿到 206/200 状态，不下载整集。
	request.Header.Set("Range", "bytes=0-1")
	request.Header.Set("User-Agent", hongguoWebUserAgent)
	request.Header.Set("Referer", hongguoBaseURL+"/")
	response, err := d.doCatalogRequestWithTimeout(request, 10*time.Second)
	if err != nil {
		return 0, 0, err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64))
	_ = response.Body.Close()
	return response.StatusCode, hongguoContentRangeTotal(response.Header), nil
}

// hongguoContentRangeTotal 从 Content-Range 里取资源总长，取不到返回 0。
func hongguoContentRangeTotal(header http.Header) int64 {
	value := header.Get("Content-Range")
	slash := strings.LastIndex(value, "/")
	if slash < 0 {
		return 0
	}
	total, err := strconv.ParseInt(strings.TrimSpace(value[slash+1:]), 10, 64)
	if err != nil || total <= 0 {
		return 0
	}
	return total
}

func hongguoDramaFromAny(v any, category string) Drama {
	m, ok := v.(map[string]any)
	if !ok {
		return Drama{}
	}
	vd, _ := m["video_data"].(map[string]any)
	if len(vd) == 0 {
		vd = m
	}
	sourceID := firstNonEmpty(mapString(vd, "series_id_str", "series_id"), mapString(m, "series_id_str", "series_id"), mapString(vd, "keyword"), mapString(m, "keyword"))
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(vd, "series_title", "series_name", "title"), mapString(m, "series_name", "name"), sourceID)
	cover := firstNonEmpty(mapString(vd, "series_cover", "cover"), mapString(m, "series_cover"))
	intro := firstNonEmpty(mapString(vd, "series_intro", "video_desc"), mapString(m, "series_intro"))
	count := firstNonEmpty(mapString(vd, "episode_cnt"), mapString(m, "episode_cnt"))
	remark := firstNonEmpty(mapString(vd, "episode_right_text"), mapString(m, "episode_right_text"))
	releaseStatus := releaseStatusFromRemark(remark)
	if mapString(vd, "series_status") == "1" {
		releaseStatus = "finished"
	} else if mapString(vd, "series_status") == "0" {
		releaseStatus = "ongoing"
	}
	if remark == "" && count != "" {
		remark = "共" + count + "集"
	}
	tags := mapStringSlice(vd, "tags")
	for _, value := range anyList(vd["category_list"]) {
		item, _ := value.(map[string]any)
		if name := mapString(item, "name"); name != "" && !slices.Contains(tags, name) {
			tags = append(tags, name)
		}
	}
	var categories []struct {
		Name string `json:"name"`
	}
	if json.Unmarshal([]byte(mapString(vd, "category_schema")), &categories) == nil {
		for _, item := range categories {
			if item.Name != "" && !slices.Contains(tags, item.Name) {
				tags = append(tags, item.Name)
			}
		}
	}
	genre := mapString(vd, "category_name", "categoryName", "category")
	if genre == "" && len(tags) > 0 {
		genre = tags[0]
	}
	return Drama{ID: providerDramaID(sourceHongguo, sourceID), Source: sourceHongguo, SourceID: sourceID, Title: title, Name: title, Desc: intro, Intro: intro, Cover: cover, CoverURL: cover, CategoryName: firstNonEmpty(genre, category), ChannelName: "红果", Remark: remark, TotalEpisode: count, EpisodeCount: count, Tags: tags, ReleaseStatus: releaseStatus, Score: mapString(vd, "score"), Views: mapString(vd, "series_play_cnt", "play_cnt"), Heat: hongguoHeat(vd), OnlineDate: hongguoOnlineDate(vd, time.Now())}
}

func nestedMap(v any, keys ...string) map[string]any {
	cur, _ := v.(map[string]any)
	for _, key := range keys {
		if cur == nil {
			return nil
		}
		cur, _ = cur[key].(map[string]any)
	}
	return cur
}

func routerLoaderMap(data map[string]any, names ...string) map[string]any {
	loader, _ := data["loaderData"].(map[string]any)
	for _, name := range names {
		if page, _ := loader[name].(map[string]any); len(page) > 0 {
			return page
		}
	}
	for key, value := range loader {
		for _, name := range names {
			if strings.TrimSuffix(name, "$") != "" && strings.HasPrefix(key, strings.TrimSuffix(name, "$")) {
				if page, _ := value.(map[string]any); len(page) > 0 {
					return page
				}
			}
		}
	}
	return nil
}

func anyList(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if out := anyList(x[key]); len(out) > 0 {
				return out
			}
		}
	}
	return nil
}
