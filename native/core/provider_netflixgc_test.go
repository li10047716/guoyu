package core

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func readNetflixgcFixture(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join("testdata", "netflixgc", name)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取样本 %s 失败：%v", name, err)
	}
	return string(body)
}

// 站点有线路把中文目录写成 %u7B2C01%u96C6，Go 的 url.QueryUnescape 不认 %u，
// 不自己实现就会拼出带 %u 的废地址。
func TestNetflixgcUnescape(t *testing.T) {
	cases := []struct{ input, want string }{
		{"%u7B2C01%u96C6", "第01集"},
		{"%E7%AC%AC01%E9%9B%86", "第01集"},
		{"https://v.fengbao8.com/video/gunuoxiya/%u7B2C01%u96C6/index.m3u8",
			"https://v.fengbao8.com/video/gunuoxiya/第01集/index.m3u8"},
		{"https://example.com/a.mp4", "https://example.com/a.mp4"},
		{"", ""},
		{"100%25", "100%"},
		// 高代理 + 低代理要合成一个 rune，不能出两个替换字符。
		{"%uD83D%uDE00", "😀"},
		// 残缺的 %u 原样保留，不能吞字符。
		{"%u12", "%u12"},
		{"%zz", "%zz"},
	}
	for _, item := range cases {
		if got := netflixgcUnescape(item.input); got != item.want {
			t.Fatalf("netflixgcUnescape(%q) = %q，期望 %q", item.input, got, item.want)
		}
	}
}

// 封面有两类：外链图床，以及套了一层百度取图代理的（image.baidu.com/search/down?url=）。
func TestNetflixgcCoverAddress(t *testing.T) {
	cases := []struct{ input, want string }{
		{"https://tupian.ffeiimg.com/upload/vod/a.jpg", "https://tupian.ffeiimg.com/upload/vod/a.jpg"},
		{"https://image.baidu.com/search/down?url=https://img.picbf.com/upload/vod/b.webp",
			"https://img.picbf.com/upload/vod/b.webp"},
		{"//img1.wsyzy.org/x.jpg", "https://img1.wsyzy.org/x.jpg"},
		{"", ""},
		{"not-a-url", ""},
		// 代理里没有 url 参数时不要退回去当封面。
		{"https://image.baidu.com/search/down", ""},
	}
	for _, item := range cases {
		if got := netflixgcCoverAddress(item.input); got != item.want {
			t.Fatalf("netflixgcCoverAddress(%q) = %q，期望 %q", item.input, got, item.want)
		}
	}
}

func TestNetflixgcParseList(t *testing.T) {
	body := readNetflixgcFixture(t, "list_anime.json")
	items, pageCount, err := parseNetflixgcList(body, "漫剧")
	if err != nil {
		t.Fatalf("列表解析失败：%v", err)
	}
	if len(items) != 40 {
		t.Fatalf("期望 40 条，实际 %d", len(items))
	}
	if pageCount <= 1 {
		t.Fatalf("总页数没解析出来：%d", pageCount)
	}
	first := items[0]
	if first.Source != sourceNetflixgc || first.SourceID != "59434" {
		t.Fatalf("首条标识不对：%+v", first)
	}
	if first.Title != "无论如何我爱你" {
		t.Fatalf("首条标题不对：%q", first.Title)
	}
	if cover := nativeNormalize(first).Cover; !strings.HasPrefix(cover, "https://tupian.ffeiimg.com/") {
		t.Fatalf("首条封面不对：%q", cover)
	}
	if first.Remark != "HD高清" {
		t.Fatalf("首条备注不对：%q", first.Remark)
	}
	// vod_tag 是 HTML 片段，要抽出「欧美动漫」这种类型名。
	if first.Category != "欧美动漫" {
		t.Fatalf("首条类型不对：%q", first.Category)
	}
	if first.ChannelName != netflixgcChannelName {
		t.Fatalf("频道名不对：%q", first.ChannelName)
	}
	// 「更新至第21集」这类备注要保留，发现页靠它显示进度。
	var found bool
	for _, item := range items {
		if item.SourceID == "80230" {
			found = true
			if item.Title != "古诺希亚" || item.Remark != "更新至第21集" {
				t.Fatalf("古诺希亚条目不对：%+v", item)
			}
			if item.Desc == "" {
				t.Fatal("简介（vod_blurb）没带出来")
			}
		}
	}
	if !found {
		t.Fatal("列表里没找到 80230")
	}
}

// 电影列表里有百度代理封面，确认解析时换成了真实地址。
func TestNetflixgcParseMovieList(t *testing.T) {
	body := readNetflixgcFixture(t, "list_movie.json")
	items, _, err := parseNetflixgcList(body, "电影")
	if err != nil {
		t.Fatalf("电影列表解析失败：%v", err)
	}
	if len(items) == 0 {
		t.Fatal("电影列表为空")
	}
	if items[0].SourceID != "120006" || items[0].Title != "幸福2024" {
		t.Fatalf("电影首条不对：%+v", items[0])
	}
	for _, item := range items {
		cover := nativeNormalize(item).Cover
		if strings.Contains(cover, "image.baidu.com") {
			t.Fatalf("百度代理地址没被解开：%q", cover)
		}
		if cover == "" {
			t.Fatalf("封面缺失：%+v", item)
		}
	}
}

// 详情页的分集是 N 条线路各一个 ul，集号只在各自线路内部有意义。
func TestNetflixgcParseEpisodes(t *testing.T) {
	body := readNetflixgcFixture(t, "detail.html")
	lines := parseNetflixgcEpisodes(body)
	if len(lines) != 7 {
		t.Fatalf("期望 7 条线路，实际 %d", len(lines))
	}
	order := netflixgcLineOrder(lines)
	if len(order) != 7 {
		t.Fatalf("线路号去重后应为 7 条，实际 %d：%v", len(order), order)
	}
	if order[0] != 1 || order[6] != 7 {
		t.Fatalf("线路顺序应为升序：%v", order)
	}
	episodes, candidates := netflixgcChapters(lines)
	if len(episodes) != 21 {
		t.Fatalf("合并后应为 21 集，实际 %d", len(episodes))
	}
	if len(candidates) != len(episodes) {
		t.Fatalf("候选线路条数与集数不一致：%d vs %d", len(candidates), len(episodes))
	}
	// 第 1 集在所有线路都有，候选里应该有 7 条，且首选线路 1。
	if len(candidates[0]) != 7 || candidates[0][0] != 1 {
		t.Fatalf("第 1 集候选线路不对：%v", candidates[0])
	}
	// 最后一集（21）在 1 号线路缺，首选应该落到 2 号线路。
	last := candidates[len(candidates)-1]
	if episodes[len(episodes)-1].index != 21 {
		t.Fatalf("最后一集不是 21：%d", episodes[len(episodes)-1].index)
	}
	if last[0] == 1 {
		t.Fatalf("21 集不该首选 1 号线路（它只有 20 集）：%v", last)
	}
	for _, item := range episodes {
		if item.line <= 0 || item.index <= 0 {
			t.Fatalf("分集定位无效：%+v", item)
		}
		if item.title == "" {
			t.Fatalf("分集标题为空：%+v", item)
		}
	}
}

func TestNetflixgcChapterKey(t *testing.T) {
	key := netflixgcChapterKey("80230", 1, 1, []int{1, 2, 3, 4, 5, 7})
	if key != "80230-1-1-1,2,3,4,5,7" {
		t.Fatalf("分集键格式不对：%q", key)
	}
	request, ok := parseNetflixgcChapterKey(key)
	if !ok {
		t.Fatal("分集键解析失败")
	}
	if request.sourceID != "80230" || request.line != 1 || request.index != 1 {
		t.Fatalf("分集键字段不对：%+v", request)
	}
	if len(request.candidates) != 6 || request.candidates[5] != 7 {
		t.Fatalf("候选线路不对：%v", request.candidates)
	}
	for _, bad := range []string{
		"", "80230", "80230-1", "80230-1-1", "abc-1-1-1", "80230-0-1-1",
		"80230-1-0-1", "80230-1-1-abc",
	} {
		if _, ok := parseNetflixgcChapterKey(bad); ok {
			t.Fatalf("非法分集键应被拒绝：%q", bad)
		}
	}
}

// 详情页整条链路（标题 / 封面 / 简介 / 分集）。
func TestNetflixgcFetchDetail(t *testing.T) {
	detail := readNetflixgcFixture(t, "detail.html")
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if strings.HasSuffix(request.URL.Path, "/voddetail/80230.html") {
			return sourceFixtureResponse(request, http.StatusOK, detail), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
	})
	downloader := sourceFixtureDownloader(t, transport)
	drama, chapters, err := downloader.fetchNetflixgcDetail(context.Background(), "80230")
	if err != nil {
		t.Fatalf("详情解析失败：%v", err)
	}
	if drama.Title != "古诺希亚" || drama.ID != "netflixgc:80230" {
		t.Fatalf("详情字段不对：%+v", drama)
	}
	if cover := nativeNormalize(drama).Cover; !strings.HasPrefix(cover, "https://tupian.ffeiimg.com/") {
		t.Fatalf("详情封面不对：%q", cover)
	}
	if drama.Desc == "" {
		t.Fatal("简介没解析出来")
	}
	if len(chapters) != 21 {
		t.Fatalf("期望 21 个分集，实际 %d", len(chapters))
	}
	if chapters[0].Title != "第01集" {
		t.Fatalf("首集标题不对：%q", chapters[0].Title)
	}
	if !strings.HasPrefix(chapters[0].VideoURL, netflixgcChapterPfx) {
		t.Fatalf("分集地址前缀不对：%q", chapters[0].VideoURL)
	}
	if chapters[0].Source != sourceNetflixgc {
		t.Fatalf("分集来源不对：%q", chapters[0].Source)
	}
}

// 播放页 encrypt=2：先 unescape、再 base64、再 unescape 一次才拿到 URL。
func TestNetflixgcPlayerDecode(t *testing.T) {
	cases := []struct{ fixture, want string }{
		{"play_line1.html", "https://vip.ffzy-plays.com/20251012/46420_97bb6beb/index.m3u8"},
		{"play_line2.html", "https://v.fengbao8.com/video/gunuoxiya/第01集/index.m3u8"},
	}
	for _, item := range cases {
		body := readNetflixgcFixture(t, item.fixture)
		player, found := parseNetflixgcPlayer(body)
		if !found {
			t.Fatalf("%s 里没找到 player_aaaa", item.fixture)
		}
		if player.Encrypt != 2 {
			t.Fatalf("%s 的 encrypt 应为 2，实际 %d", item.fixture, player.Encrypt)
		}
		candidates := netflixgcMediaCandidates(player)
		var hit bool
		for _, candidate := range candidates {
			if candidate == item.want {
				hit = true
				break
			}
		}
		if !hit {
			t.Fatalf("%s 解码失败，候选里没有 %q：%v", item.fixture, item.want, candidates)
		}
	}
}

// 私有加密线路（NBY-XMYAES…）解不出来时，要自动换下一条线路。
func TestNetflixgcResolveFallsBackToNextLine(t *testing.T) {
	play1 := readNetflixgcFixture(t, "play_line1.html")
	play2 := readNetflixgcFixture(t, "play_line2.html")
	playlist := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXTINF:8.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
	var requested []string
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		requested = append(requested, request.URL.Path)
		switch {
		case strings.HasSuffix(request.URL.Path, "/vodplay/80230-1-1.html"):
			// 1 号线路这次解不出来（模拟私有加密）。
			return sourceFixtureResponse(request, http.StatusOK,
				`<script>var player_aaaa={"encrypt":2,"trysee":100000,"url":"NBY-XMYAESb9582168b65ab25edc"};</script>`), nil
		case strings.HasSuffix(request.URL.Path, "/vodplay/80230-2-1.html"):
			return sourceFixtureResponse(request, http.StatusOK, play2), nil
		case strings.HasSuffix(request.URL.Path, ".m3u8"):
			return sourceFixtureResponse(request, http.StatusOK, playlist), nil
		case strings.HasSuffix(request.URL.Path, "/vodplay/80230-3-1.html"):
			return sourceFixtureResponse(request, http.StatusOK, play1), nil
		}
		return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
	})
	downloader := sourceFixtureDownloader(t, transport)
	media, err := downloader.resolveNetflixgcMedia(context.Background(), Task{
		DramaID: "netflixgc:80230",
		Chapter: Chapter{
			ID:       "netflixgc:80230:1-1",
			Source:   sourceNetflixgc,
			VideoURL: netflixgcChapterPfx + "80230-1-1-2,3",
		},
	})
	if err != nil {
		t.Fatalf("兜底失败：%v", err)
	}
	if !strings.Contains(media.URL, "fengbao8.com") {
		t.Fatalf("没有换到 2 号线路：%q", media.URL)
	}
	if media.Playlist == "" {
		t.Fatal("播放列表没带回来")
	}
	// 1 号失败后应该只打 2 号，不该把候选全试一遍。
	if len(requested) < 2 {
		t.Fatalf("请求次数不对：%v", requested)
	}
	if !strings.Contains(strings.Join(requested, " "), "/vodplay/80230-2-1.html") {
		t.Fatalf("没有请求 2 号线路：%v", requested)
	}
}

// 伪造 / 越界的分集必须被拦下，不能拿着任意 id 去打站点。
func TestNetflixgcRejectInvalidChapter(t *testing.T) {
	downloader := sourceFixtureDownloader(t, sourceFixtureTransport(
		func(request *http.Request) (*http.Response, error) {
			return sourceFixtureResponse(request, http.StatusOK, ""), nil
		}))
	cases := []struct {
		name string
		task Task
	}{
		{"来源不符", Task{DramaID: "hanxiaoquan:80230", Chapter: Chapter{
			ID: "netflixgc:80230:1-1", Source: sourceNetflixgc, VideoURL: netflixgcChapterPfx + "80230-1-1-1"}}},
		{"剧集不符", Task{DramaID: "netflixgc:80230", Chapter: Chapter{
			ID: "netflixgc:99999:1-1", Source: sourceNetflixgc, VideoURL: netflixgcChapterPfx + "99999-1-1-1"}}},
		{"key 不对", Task{DramaID: "netflixgc:80230", Chapter: Chapter{
			ID: "netflixgc:80230:1-1", Source: sourceNetflixgc, VideoURL: netflixgcChapterPfx + "80230-1"}}},
		{"缺前缀", Task{DramaID: "netflixgc:80230", Chapter: Chapter{
			ID: "netflixgc:80230:1-1", Source: sourceNetflixgc, VideoURL: "https://evil.example.com/x.m3u8"}}},
		{"集号越界", Task{DramaID: "netflixgc:80230", Chapter: Chapter{
			ID: "netflixgc:80230:1-1", Source: sourceNetflixgc, VideoURL: netflixgcChapterPfx + "80230-1-99999999-1"}}},
	}
	for _, item := range cases {
		if _, err := downloader.resolveNetflixgcMedia(context.Background(), item.task); err == nil {
			t.Fatalf("%s 应该被拒绝", item.name)
		}
	}
}

// 「全部」= 单请求 type=0（全站时间线），不再并行合并五个分类。
func TestNetflixgcCatalogAllSingleRequest(t *testing.T) {
	anime := readNetflixgcFixture(t, "list_anime.json")
	var types []string
	var limits []string
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if !strings.HasSuffix(request.URL.Path, "/index.php/ds_api/vod") {
			return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
		}
		if request.Method != http.MethodPost {
			// GET 打这个接口只会拿到一句提示文本。
			return sourceFixtureResponse(request, http.StatusOK, `"短视主题 作者TG @tutucj"`), nil
		}
		if err := request.ParseForm(); err != nil {
			return sourceFixtureResponse(request, http.StatusBadRequest, ""), nil
		}
		types = append(types, request.PostForm.Get("type"))
		limits = append(limits, request.PostForm.Get("limit"))
		return sourceFixtureResponse(request, http.StatusOK, anime), nil
	})
	downloader := sourceFixtureDownloader(t, transport)
	items, more, err := downloader.fetchNetflixgcCatalogPage(context.Background(), 1, "", "")
	if err != nil {
		t.Fatalf("全部目录失败：%v", err)
	}
	if len(types) != 1 || types[0] != "0" {
		t.Fatalf("应该只发一次 type=0 请求，实际 %v", types)
	}
	if len(limits) != 1 || limits[0] != strconv.Itoa(netflixgcFeedPageSize) {
		t.Fatalf("limit 应该是 %d，实际 %v", netflixgcFeedPageSize, limits)
	}
	if !more {
		t.Fatal("应该还有下一页")
	}
	if len(items) == 0 {
		t.Fatal("全部目录结果为空")
	}
}

// 单分类分页要带上 page，且只在还有下一页时报告 hasMore。
func TestNetflixgcCategoryPaging(t *testing.T) {
	anime := readNetflixgcFixture(t, "list_anime.json")
	var pages []string
	var types []string
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if err := request.ParseForm(); err != nil {
			return sourceFixtureResponse(request, http.StatusBadRequest, ""), nil
		}
		pages = append(pages, request.PostForm.Get("page"))
		types = append(types, request.PostForm.Get("type"))
		return sourceFixtureResponse(request, http.StatusOK, anime), nil
	})
	downloader := sourceFixtureDownloader(t, transport)
	if _, more, err := downloader.fetchNetflixgcCatalogPage(context.Background(), 1, "3", ""); err != nil || !more {
		t.Fatalf("第 1 页应还有更多：more=%v err=%v", more, err)
	}
	if len(pages) != 1 || pages[0] != "1" {
		t.Fatalf("分页参数不对：%v", pages)
	}
	if len(types) != 1 || types[0] != "3" {
		t.Fatalf("分类参数不对：%v", types)
	}
}

// 搜索只走 suggest，且它不分页——第 2 页必须直接返回空，不能再去打站点。
// 搜索走站点结果页：一页 10 条，页脚给出总页数（火影 48 条 / 5 页）。
func TestNetflixgcSearchParsesPage(t *testing.T) {
	items, totalPages, err := parseNetflixgcSearchPage(readNetflixgcFixture(t, "search_page1.html"))
	if err != nil {
		t.Fatalf("搜索页解析失败：%v", err)
	}
	if totalPages != 5 {
		t.Fatalf("总页数应为 5，实际 %d", totalPages)
	}
	if len(items) != 10 {
		t.Fatalf("期望 10 条，实际 %d", len(items))
	}
	first := items[0]
	if first.SourceID != "7159" || first.Title != "火影忍者" {
		t.Fatalf("首条搜索结果不对：%+v", first)
	}
	if first.ID != "netflixgc:7159" || first.Source != sourceNetflixgc {
		t.Fatalf("首条 ID 不对：%q / %q", first.ID, first.Source)
	}
	if first.Remark != "已完结" {
		t.Fatalf("备注不对：%q", first.Remark)
	}
	if first.Category != "喜剧" {
		t.Fatalf("分类应取第一个类型：%q", first.Category)
	}
	if cover := nativeNormalize(first).Cover; !strings.Contains(cover, "fffgood.com") {
		t.Fatalf("封面应取 data-src：%q", cover)
	}
	if len(first.Tags) != 2 || first.Tags[0] != "喜剧" || first.Tags[1] != "动画" {
		t.Fatalf("标签不对：%v", first.Tags)
	}
}

// 末页只有 8 条，总页数仍是 5，所以不该报告还有更多。
func TestNetflixgcSearchLastPage(t *testing.T) {
	items, totalPages, err := parseNetflixgcSearchPage(readNetflixgcFixture(t, "search_page5.html"))
	if err != nil {
		t.Fatalf("末页解析失败：%v", err)
	}
	if totalPages != 5 {
		t.Fatalf("总页数应为 5，实际 %d", totalPages)
	}
	if len(items) != 8 {
		t.Fatalf("末页应为 8 条，实际 %d", len(items))
	}
}

// 只有一条命中时站点不给页脚，这时按「本页满 10 条才算还有更多」兜底。
func TestNetflixgcSearchWithoutPageTip(t *testing.T) {
	items, totalPages, err := parseNetflixgcSearchPage(readNetflixgcFixture(t, "search_single.html"))
	if err != nil {
		t.Fatalf("单条搜索页解析失败：%v", err)
	}
	if totalPages != 0 {
		t.Fatalf("这页没有页脚，总页数应为 0，实际 %d", totalPages)
	}
	if len(items) != 1 {
		t.Fatalf("应为 1 条，实际 %d", len(items))
	}
}

func TestNetflixgcSearchAddress(t *testing.T) {
	address := netflixgcSearchAddress(netflixgcBaseURL, "火影", 3)
	want := netflixgcBaseURL + "/vodsearch/-------------.html?wd=%E7%81%AB%E5%BD%B1&page=3"
	if address != want {
		t.Fatalf("搜索地址不对：%s", address)
	}
	// 空格必须是 %20：%2B 和 + 都会被这个站当成加号或直接丢词。
	if got := netflixgcSearchAddress(netflixgcBaseURL, "a b", 1); !strings.Contains(got, "wd=a%20b") {
		t.Fatalf("空格编码不对：%s", got)
	}
	// 搜索词里的 - 不能出现在路径段里，否则会把分页槽位搅乱。
	if got := netflixgcSearchAddress(netflixgcBaseURL, "X-Men", 1); !strings.Contains(got, "wd=X-Men") {
		t.Fatalf("连字符应留在 query 里：%s", got)
	}
	if got := netflixgcSearchAddress(netflixgcBaseURL, "火影", 0); !strings.HasSuffix(got, "page=1") {
		t.Fatalf("页码下限应钳到 1：%s", got)
	}
}

func TestNetflixgcSearchPaging(t *testing.T) {
	pages := map[string]string{
		"1": readNetflixgcFixture(t, "search_page1.html"),
		"2": readNetflixgcFixture(t, "search_page2.html"),
		"5": readNetflixgcFixture(t, "search_page5.html"),
	}
	var asked []string
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/vodsearch/-------------.html" {
			t.Fatalf("搜索不该再打别的地址：%s", request.URL.Path)
		}
		if got := request.URL.Query().Get("wd"); got != "火影" {
			t.Fatalf("搜索关键词没带上：%q", got)
		}
		page := request.URL.Query().Get("page")
		asked = append(asked, page)
		body, ok := pages[page]
		if !ok {
			t.Fatalf("不该请求第 %s 页", page)
		}
		return sourceFixtureResponse(request, http.StatusOK, body), nil
	})
	downloader := sourceFixtureDownloader(t, transport)
	ctx := context.Background()

	first, more, err := downloader.fetchNetflixgcSearchPageAt(ctx, 1, "火影")
	if err != nil {
		t.Fatalf("第 1 页搜索失败：%v", err)
	}
	if len(first) != 10 || !more {
		t.Fatalf("第 1 页应 10 条且还有更多：n=%d more=%v", len(first), more)
	}
	second, more, err := downloader.fetchNetflixgcSearchPageAt(ctx, 2, "火影")
	if err != nil {
		t.Fatalf("第 2 页搜索失败：%v", err)
	}
	if len(second) != 10 || !more {
		t.Fatalf("第 2 页应 10 条且还有更多：n=%d more=%v", len(second), more)
	}
	if second[0].SourceID != "58419" {
		t.Fatalf("第 2 页首条不对：%+v", second[0])
	}
	last, more, err := downloader.fetchNetflixgcSearchPageAt(ctx, 5, "火影")
	if err != nil {
		t.Fatalf("第 5 页搜索失败：%v", err)
	}
	if len(last) != 8 || more {
		t.Fatalf("末页应 8 条且没有更多：n=%d more=%v", len(last), more)
	}
	if strings.Join(asked, ",") != "1,2,5" {
		t.Fatalf("请求的页码不对：%v", asked)
	}
}

// 搜索页拿到错误页时必须报错，不能静默当成「没有结果」。
func TestNetflixgcSearchRejectsBrokenPage(t *testing.T) {
	if _, _, err := parseNetflixgcSearchPage(""); err == nil {
		t.Fatal("空响应应该报错")
	}
	if _, _, err := parseNetflixgcSearchPage(`<html><title>404 - Page Not Found</title></html>`); err == nil {
		t.Fatal("没有结果的错误页应该报错")
	}
	// 结构正常但没有卡片 = 真的没有结果，不算错误。
	empty := `<html><a href="/vodsearch/-------------.html">搜索</a></html>`
	items, totalPages, err := parseNetflixgcSearchPage(empty)
	if err != nil || len(items) != 0 || totalPages != 0 {
		t.Fatalf("空结果页应返回空列表：n=%d pages=%d err=%v", len(items), totalPages, err)
	}
}

// 用 GET 打列表接口会拿到一句提示文本，必须给出明确错误而不是空列表。
func TestNetflixgcListRejectsPlainText(t *testing.T) {
	if _, _, err := parseNetflixgcList(`"短视主题 作者TG @tutucj"`, "漫剧"); err == nil {
		t.Fatal("纯文本响应应该报错")
	}
	if _, _, err := parseNetflixgcList("", "漫剧"); err == nil {
		t.Fatal("空响应应该报错")
	}
	if _, _, err := parseNetflixgcList(`{"code":0,"msg":"数据列表"}`, "漫剧"); err == nil {
		t.Fatal("code 非 1 应该报错")
	}
}

func TestNetflixgcCategoryValidation(t *testing.T) {
	for _, entry := range netflixgcCategories {
		if !validNetflixgcCategory(entry.ID) {
			t.Fatalf("分类 %s 应该被接受", entry.ID)
		}
		if netflixgcCategoryName(entry.ID) == "" {
			t.Fatalf("分类 %s 没有名字", entry.ID)
		}
	}
	for _, bad := range []string{"", "0", "4", "99", "abc", "3|1"} {
		if validNetflixgcCategory(bad) {
			t.Fatalf("分类 %q 不该被接受", bad)
		}
	}
}

// 联网验证：默认跳过，需要时 `NETFLIXGC_LIVE=1 go test ./core/ -run TestNetflixgcLive -v`。
func TestNetflixgcLive(t *testing.T) {
	if os.Getenv("NETFLIXGC_LIVE") == "" {
		t.Skip("未设置 NETFLIXGC_LIVE，跳过联网验证")
	}
	downloader := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        &http.Client{Timeout: 25 * time.Second},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	for _, entry := range netflixgcCategories {
		items, more, err := downloader.fetchNetflixgcCategoryPage(ctx, 1, entry.ID)
		if err != nil {
			t.Fatalf("%s 分类请求失败：%v", entry.Name, err)
		}
		if len(items) == 0 {
			t.Fatalf("%s 分类没有解析出条目", entry.Name)
		}
		t.Logf("%s：第 1 页 %d 条，还有更多：%v，首条：%s", entry.Name, len(items), more, items[0].Title)
	}
	found, foundMore, err := downloader.fetchNetflixgcSearchPageAt(ctx, 1, "火影")
	if err != nil {
		t.Fatalf("搜索请求失败：%v", err)
	}
	if len(found) == 0 || !foundMore {
		t.Fatalf("搜索应有整页结果且能继续翻：n=%d more=%v", len(found), foundMore)
	}
	t.Logf("搜索「火影」：第 1 页 %d 条，还有更多：%v，首条：%s",
		len(found), foundMore, found[0].Title)
	drama, chapters, err := downloader.fetchNetflixgcDetail(ctx, "80230")
	if err != nil {
		t.Fatalf("详情请求失败：%v", err)
	}
	if len(chapters) == 0 {
		t.Fatal("详情页没有解析出分集")
	}
	t.Logf("详情：%s，分集 %d 个", drama.Title, len(chapters))
	media, err := downloader.resolveNetflixgcMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0]})
	if err != nil {
		t.Fatalf("播放地址解析失败：%v", err)
	}
	t.Logf("直链：%s", media.URL)
}
