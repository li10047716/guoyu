package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// 以下 fixture 均按站点真实返回裁剪而来：
// 卡片封面在 data-src、src 是 loading 占位图；选集是 /play/<剧id>-<线路>-<集索引>；
// 播放页用内联脚本给出 var now（当前集）与 var next（下一集）。
const hanxiaoquanCatalogFixture = `<html><body>
<div class="library-stat">最新韩剧库共有<span class="important">2128</span>部影片</div>
<div class="module"><div class="module-list"><div class="module-items">
<div class="module-item">
<div class="module-item-cover">
<a href="/hanxiaoquan/4645.html" title="暑假2026" class="module-item-pic"><img class="lazy" data-src="https://pic3.yzzyimg.online/upload/vod/2026-10-26/a.jpg" src="/mxstatic/image/loading.gif" alt="暑假2026"><div class="loading"></div></a>
</div><div class="module-item-titlebox">
<a href="/hanxiaoquan/4645.html" class="module-item-title" title="暑假2026">暑假2026</a>
</div>
<div class="module-item-text">2026-10-27</div>
</div>
<div class="module-item">
<div class="module-item-cover">
<a href="/hanxiaoquan/4620.html" title="恋爱博士" class="module-item-pic"><img class="lazy" data-src="/upload/vod/2026-10-05/b.jpg" src="/statics/loading.png" alt="恋爱博士"><div class="loading"></div></a>
</div><div class="module-item-titlebox">
<a href="/hanxiaoquan/4620.html" class="module-item-title" title="恋爱博士">恋爱博士</a>
</div>
<div class="module-item-text">更新至12集</div>
</div>
</div></div>
<div class="module-footer"><div id="page">
<a href="/hxq/1.html" class="page-number page-previous" title="首页">首页</a>
<span class="page-number page-current display">1</span>
<a href="/hxq/1-2.html" class="page-number display" title="第1页">2</a>
<a href="/hxq/1-2.html" class="page-number page-next" title="下一页">下一页</a>
<a href="/hxq/1-60.html" class="page-number page-next" title="尾页">尾页</a>
</div></div>
</div></body></html>`

const hanxiaoquanDetailFixture = `<html><head>
<title>《爱情来了2026》在线观看-韩小圈</title>
<meta name="description" content="爱情来了2026剧情介绍：由洪硕九执导,安喜延等人主演的,于2026年上映。" />
<meta property="og:image" content="https://pic3.yzzyimg.online/upload/vod/2026-07-26/c.jpg" />
<meta property="og:video:area" content="韩国" />
<meta property="og:video:class" content="最新韩剧" />
</head><body>
<ul class="nav-menu-items">
<li class="nav-menu-item selected"><a href="/hxq/1.html" title="最新韩剧"><i class="icon-cate-ds"></i><span class="nav-menu-item-name"> 最新韩剧</span></a></li>
<li class="nav-menu-item "><a href="/hxq/2.html" title="韩国电影"><span> 韩国电影</span></a></li>
<li class="nav-menu-item "><a href="/hxq/3.html" title="韩国综艺"><span> 韩国综艺</span></a></li>
<li class="nav-menu-item "><a href="/hxq/4.html" title="韩国动漫"><span> 韩国动漫</span></a></li>
</ul>
<main id="main"><div class="content">
<div class="video-info">
<h1 class="page-title">爱情来了2026</h1>
<div class="video-info-aux scroll-content">
<a href="/hxq/1.html" title="最新韩剧" class="tag-link"><div class="video-tag-icon"><i class=""></i></div>最新韩剧</a>
<div class="tag-link">豆瓣 7.6分</div>
</div>
<div class="video-info-main">
<div class="video-info-items"><span class="video-info-itemtitle">导演：</span>
<div class="video-info-item video-info-actor"><a href='/search.php?searchword=x'>洪硕九</a>&nbsp;&nbsp;</div></div>
<div class="video-info-items"><span class="video-info-itemtitle">主演：</span>
<div class="video-info-item video-info-actor"><a href='/search.php?searchword=y'>安喜延</a>&nbsp;&nbsp;<span class='slash'>/</span></div></div>
<div class="video-info-items"><span class="video-info-itemtitle">上映：</span>
<div class="video-info-item">2026</div></div>
<div class="video-info-items"><span class="video-info-itemtitle">更新：</span>
<div class="video-info-item">2026-10-26 08:12</div></div>
</div></div>
<div class="tab-content myui-panel_bd">
<div id="playlist2" class="tab-pane fade in clearfix">
<ul class="myui-content__list scrollbar sort-list clearfix">
<li id="10"><a title="第01集" href="/play/4570-1-0.html" target="_self">第01集</a></li><li id="11"><a title="第02集" href="/play/4570-1-1.html" target="_self">第02集</a></li>
</ul></div>
<div id="playlist1" class="tab-pane fade in clearfix">
<ul class="myui-content__list scrollbar sort-list clearfix">
<li id="00"><a href="/play/4570-0-0.html" target="_self">第01集</a></li><li id="01"><a title="第02集" href="/play/4570-0-1.html" target="_self">第02集</a></li><li id="02"><a title="第03集" href="/play/4570-0-2.html" target="_self">第03集</a></li>
</ul></div>
</div>
<div class="module module-bg">
<div class="module-heading"><h2 class="module-title">《爱情来了2026》剧情介绍</h2></div>
<div class="module-items"><div class="video-info des">
<p>韩小圈提供影视作品<b>爱情来了2026</b>高清全集在线观看。</p><p>《爱情来了2026》简介：希望明天不是我的家人，但作为家人的人们的故事。</p>
</div></div></div>
</div></main></body></html>`

const hanxiaoquanPlayFixture = `<html><body><main id="main"><div class="player-block"><div class="content"><div class="player-box"><div class="player-wrapper embed-responsive">
<script>var vid="4570";var vfrom="1";var vpart="0";var now="%s";var pn="1080zyk"; var next="https://cdn.example-next.com/NEXT/index.m3u8";var prePage="/play/4570-1-0.html";var nextPage="/play/4570-1-1.html";</script><iframe id='cciframe'></iframe>
</div></div></div></div></main></body></html>`

const hanxiaoquanSearchHandshakeFixture = `<!doctype html><html><meta charset="utf-8"><title>请稍候</title><p>正在验证浏览器，请稍候……</p><script>document.cookie="idc_search_browser=e58db764d6c1adbec36733f7ba8f39db; Max-Age=1800; Path=/; SameSite=Lax";</script></html>`

const hanxiaoquanPlaylistFixture = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts\n#EXTINF:6.0,\nseg1.ts\n#EXT-X-ENDLIST\n"

type hanxiaoquanFixture struct {
	server      *httptest.Server
	playlist    string
	searchTries atomic.Int32
	cookieSeen  atomic.Bool
}

func (fixture *hanxiaoquanFixture) start(t *testing.T) *Downloader {
	t.Helper()
	mux := http.NewServeMux()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case path == "/hanxiaoquan/4570.html":
			io.WriteString(w, hanxiaoquanDetailFixture)
		case strings.HasPrefix(path, "/play/4570-"):
			fmt.Fprintf(w, hanxiaoquanPlayFixture, fixture.playlist)
		case path == "/master.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, hanxiaoquanPlaylistFixture)
		case path == "/search.php":
			if cookie, err := r.Cookie("idc_search_browser"); err != nil || cookie.Value == "" {
				fixture.searchTries.Add(1)
				io.WriteString(w, hanxiaoquanSearchHandshakeFixture)
				return
			}
			if r.URL.Query().Get("_idc_pass") == "" {
				t.Error("search replay lost _idc_pass")
			}
			if r.URL.Query().Get("searchword") != "爱情" {
				t.Errorf("search replay lost keyword: %q", r.URL.Query().Get("searchword"))
			}
			fixture.cookieSeen.Store(true)
			fixture.searchTries.Add(1)
			io.WriteString(w, hanxiaoquanCatalogFixture)
		case strings.HasPrefix(path, "/hxq/"):
			io.WriteString(w, hanxiaoquanCatalogFixture)
		default:
			t.Error("unexpected request", path)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	mux.Handle("/", handler)
	fixture.server = httptest.NewServer(mux)
	t.Cleanup(fixture.server.Close)
	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        &http.Client{},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	d.cfg.HanxiaoquanURL = fixture.server.URL
	fixture.playlist = fixture.server.URL + "/master.m3u8"
	return d
}

func TestHanxiaoquanCatalogParsesCardsAndPaging(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	items, more, err := d.fetchHanxiaoquanCatalogPage(context.Background(), 1, "1", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || !more {
		t.Fatalf("catalog = %d items, more=%v", len(items), more)
	}
	first := items[0]
	if first.ID != "hanxiaoquan:4645" || first.SourceID != "4645" || first.Title != "暑假2026" {
		t.Fatalf("unexpected first card: %+v", first)
	}
	// 封面必须取 data-src，不能是 loading.gif 占位。
	if first.Cover != "https://pic3.yzzyimg.online/upload/vod/2026-10-26/a.jpg" {
		t.Fatalf("cover = %q", first.Cover)
	}
	if first.OnlineDate != "2026-10-27" || first.Category != "最新韩剧" {
		t.Fatalf("card metadata = %+v", first)
	}
	// 相对路径封面要按页面地址补全。
	if items[1].Cover != fixture.server.URL+"/upload/vod/2026-10-05/b.jpg" {
		t.Fatalf("relative cover = %q", items[1].Cover)
	}
	// 「更新至12集」不是日期，不能塞进上线时间。
	if items[1].OnlineDate != "" || items[1].Remark != "更新至12集" {
		t.Fatalf("non-date stamp handling = %+v", items[1])
	}
}

func TestHanxiaoquanCatalogMergesAllCategories(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	items, more, err := d.fetchHanxiaoquanCatalogPage(context.Background(), 1, "", "")
	if err != nil {
		t.Fatal(err)
	}
	// 四个分类各返回同一份 fixture（2 部），合并后应为 8 条。
	if len(items) != 8 || !more {
		t.Fatalf("merged catalog = %d items, more=%v", len(items), more)
	}
	names := map[string]bool{}
	for _, item := range items {
		names[item.Category] = true
	}
	for _, want := range []string{"最新韩剧", "韩国电影", "韩国综艺", "韩国动漫"} {
		if !names[want] {
			t.Fatalf("merged catalog lost category %q: %v", want, names)
		}
	}
}

func TestHanxiaoquanCategoriesFromNav(t *testing.T) {
	categories := parseHanxiaoquanCategories(hanxiaoquanDetailFixture)
	want := []nativeCategory{
		{ID: "1", Name: "最新韩剧"},
		{ID: "2", Name: "韩国电影"},
		{ID: "3", Name: "韩国综艺"},
		{ID: "4", Name: "韩国动漫"},
	}
	if len(categories) != len(want) {
		t.Fatalf("categories = %+v", categories)
	}
	for index, entry := range want {
		if categories[index] != entry {
			t.Fatalf("category %d = %+v, want %+v", index, categories[index], entry)
		}
	}
}

func TestHanxiaoquanDetailParsesDramaAndChapters(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	drama, chapters, err := d.fetchHanxiaoquanDetail(context.Background(), "4570")
	if err != nil {
		t.Fatal(err)
	}
	if drama.ID != "hanxiaoquan:4570" || drama.Title != "爱情来了2026" {
		t.Fatalf("drama = %+v", drama)
	}
	if drama.Cover != "https://pic3.yzzyimg.online/upload/vod/2026-07-26/c.jpg" {
		t.Fatalf("cover = %q", drama.Cover)
	}
	if drama.OnlineDate != "2026-10-26" || drama.Score != "7.6" {
		t.Fatalf("metadata = %+v", drama)
	}
	if !strings.Contains(drama.Desc, "希望明天不是我的家人") || strings.Contains(drama.Desc, "高清全集在线观看") {
		t.Fatalf("description = %q", drama.Desc)
	}
	if len(drama.Tags) != 3 || drama.Tags[0] != "最新韩剧" || drama.Tags[1] != "韩国" || drama.Tags[2] != "2026" {
		t.Fatalf("tags = %v", drama.Tags)
	}
	// 线路 1 只有 2 集，线路 0 有 3 集 —— 应取集数最多的那条。
	if len(chapters) != 3 || drama.EpisodeCount != 3 {
		t.Fatalf("chapters = %d, episodeCount=%v", len(chapters), drama.EpisodeCount)
	}
	first := chapters[0]
	if first.ID != providerChapterID("hanxiaoquan", "4570", "4570-0-0") {
		t.Fatalf("chapter id = %q", first.ID)
	}
	if first.VideoURL != "hanxiaoquan-play://4570-0-0" {
		t.Fatalf("chapter url = %q", first.VideoURL)
	}
	if first.Title != "第01集" || first.EpisodeString(1) != "1" {
		t.Fatalf("chapter title = %q / episode = %q", first.Title, first.EpisodeString(1))
	}
}

func TestHanxiaoquanPlayAddressPrefersNow(t *testing.T) {
	body := `<script>var vid="4570";var now="https://cdn.example.com/A/index.m3u8";var next="https://cdn.example.com/B/index.m3u8";</script>`
	if address := hanxiaoquanPlayAddress(body); address != "https://cdn.example.com/A/index.m3u8" {
		t.Fatalf("address = %q", address)
	}
	if address := hanxiaoquanPlayAddress(`<script>var next="https://cdn.example.com/B/index.m3u8";</script>`); address != "" {
		// 只有 next（下一集）时宁可不播，也不能串集。
		t.Fatalf("address without now = %q", address)
	}
	if address := hanxiaoquanPlayAddress(`<script>var now="javascript:alert(1)";</script>`); address != "" {
		t.Fatalf("address with invalid scheme = %q", address)
	}
}

func TestHanxiaoquanResolveMedia(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	_, chapters, err := d.fetchHanxiaoquanDetail(context.Background(), "4570")
	if err != nil {
		t.Fatal(err)
	}
	media, err := d.resolveProviderMedia(context.Background(), Task{
		DramaID: "hanxiaoquan:4570",
		Chapter: chapters[1],
		Index:   2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != fixture.playlist {
		t.Fatalf("media url = %q", media.URL)
	}
	if media.Referer != fixture.server.URL+"/play/4570-0-1.html" {
		t.Fatalf("media referer = %q", media.Referer)
	}
	if !strings.HasPrefix(media.Playlist, "#EXTM3U") || media.Duration <= 0 {
		t.Fatalf("playlist = %q duration=%v", media.Playlist, media.Duration)
	}
}

func TestHanxiaoquanResolveRejectsForeignChapter(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	if _, err := d.resolveProviderMedia(context.Background(), Task{
		DramaID: "hanxiaoquan:4570",
		Chapter: Chapter{ID: "hanxiaoquan:4571:4571-0-0", Source: sourceHanxiaoquan},
	}); err == nil {
		t.Fatal("foreign chapter should be rejected")
	}
	if _, err := d.resolveProviderMedia(context.Background(), Task{
		DramaID: "hanxiaoquan:4570",
		Chapter: Chapter{ID: providerChapterID(sourceHanxiaoquan, "4570", "4570-1"), Source: sourceHanxiaoquan},
	}); err == nil {
		t.Fatal("malformed chapter key should be rejected")
	}
}

func TestHanxiaoquanSearchHandshake(t *testing.T) {
	fixture := &hanxiaoquanFixture{}
	d := fixture.start(t)
	items, _, err := d.fetchHanxiaoquanCatalogPage(context.Background(), 1, "", "爱情")
	if err != nil {
		t.Fatal(err)
	}
	if fixture.searchTries.Load() != 2 || !fixture.cookieSeen.Load() {
		t.Fatalf("search handshake = %d tries, cookieSeen=%v", fixture.searchTries.Load(), fixture.cookieSeen.Load())
	}
	if len(items) != 2 {
		t.Fatalf("search items = %d", len(items))
	}
}

func TestHanxiaoquanSearchRejectsBlockedReplay(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 一直回握手页：说明站点没有放行，必须报错而不是返回"空结果"。
		io.WriteString(w, hanxiaoquanSearchHandshakeFixture)
	}))
	defer server.Close()
	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        &http.Client{},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	d.cfg.HanxiaoquanURL = server.URL
	if _, _, err := d.fetchHanxiaoquanCatalogPage(context.Background(), 1, "", "爱情"); err == nil {
		t.Fatal("blocked search should fail loudly")
	}
}

func TestHanxiaoquanValidators(t *testing.T) {
	for _, value := range []string{"4570", "1", "999999999999"} {
		if !validHanxiaoquanID(value) {
			t.Fatalf("id %q should be valid", value)
		}
	}
	for _, value := range []string{"", "0", "abc", "-1", "1234567890123"} {
		if validHanxiaoquanID(value) {
			t.Fatalf("id %q should be invalid", value)
		}
	}
	for _, value := range []string{"1", "4", "12"} {
		if !validHanxiaoquanCategory(value) {
			t.Fatalf("category %q should be valid", value)
		}
	}
	for _, value := range []string{"", "0", "abc", "1|2", "x/1"} {
		if validHanxiaoquanCategory(value) {
			t.Fatalf("category %q should be invalid", value)
		}
	}
	if validHanxiaoquanLine("100") || !validHanxiaoquanLine("0") {
		t.Fatal("line bounds are wrong")
	}
	if validHanxiaoquanIndex("-1") || !validHanxiaoquanIndex("0") {
		t.Fatal("index bounds are wrong")
	}
}

func TestHanxiaoquanSourceRegistered(t *testing.T) {
	if !isSupportedProviderSource("hanxiaoquan") || canonicalProviderSource("www.jennyhow.com") != sourceHanxiaoquan {
		t.Fatal("hanxiaoquan source is not registered")
	}
	if !validNativeCategory(sourceHanxiaoquan, "1") || validNativeCategory(sourceHanxiaoquan, "x") {
		t.Fatal("hanxiaoquan category validation is wrong")
	}
	if providerSourceForURL("https://www.jennyhow.com/hanxiaoquan/4570.html") != sourceHanxiaoquan {
		t.Fatal("hanxiaoquan url detection is wrong")
	}
}
