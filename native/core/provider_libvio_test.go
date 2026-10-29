package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func readLibvioFixture(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join("testdata", "libvio", name)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取样本 %s 失败：%v", name, err)
	}
	return string(body)
}

// 列表页：封面挂在缩略图 <a> 的 data-original 上（<img> 只是 lazyload 占位），
// 进度小字在 pic-text，评分在 pic-tag。这三样以前都取不到。
func TestParseLibvioListCards(t *testing.T) {
	body := readLibvioFixture(t, "list.html")
	items := parseLibvioCards(body, "https://www.libvio.to/type/4.html", "番剧")
	if len(items) != 12 {
		t.Fatalf("期望解析出 12 条卡片，实际 %d", len(items))
	}
	first := items[0]
	if first.Source != sourceLibvio || first.SourceID != "714893605" {
		t.Fatalf("首条卡片标识不对：%+v", first)
	}
	if first.Title != "死神 千年血战篇 -祸进谭" {
		t.Fatalf("首条卡片标题不对：%q", first.Title)
	}
	if cover := nativeNormalize(first).Cover; !strings.HasPrefix(cover, "https://img.meituan.net/content/") {
		t.Fatalf("首条卡片封面未解析：%q", cover)
	}
	if first.Remark != "第09集/周六更新" {
		t.Fatalf("首条卡片进度小字不对：%q", first.Remark)
	}
	if first.Score != "8.5" {
		t.Fatalf("首条卡片评分不对：%q", first.Score)
	}
	if first.Category != "番剧" || first.ChannelName != libvioChannelName {
		t.Fatalf("首条卡片分类不对：%+v", first)
	}
	for _, item := range items {
		if cover := nativeNormalize(item).Cover; strings.Contains(cover, "load.gif") {
			t.Fatalf("占位图被当成封面：%q", cover)
		}
	}
}

func TestParseLibvioSearchCards(t *testing.T) {
	body := readLibvioFixture(t, "search.html")
	items := parseLibvioCards(body, "https://www.libvio.to/search/%E9%9D%92%E4%B9%8B%E7%AE%B1----------1---.html", "搜索")
	if len(items) != 2 {
		t.Fatalf("期望解析出 2 条搜索结果，实际 %d", len(items))
	}
	if items[0].Title != "青之箱 第二季" || items[0].SourceID != "714893734" {
		t.Fatalf("搜索结果第一条不对：%+v", items[0])
	}
	if items[1].Title != "青之箱" || items[1].SourceID != "714891959" {
		t.Fatalf("搜索结果第二条不对：%+v", items[1])
	}
}

func TestParseLibvioCategories(t *testing.T) {
	body := readLibvioFixture(t, "list.html")
	categories := parseLibvioCategories(body)
	want := []string{"电影", "剧集", "番剧", "日韩", "欧美"}
	if len(categories) != len(want) {
		t.Fatalf("期望 %d 个分类，实际 %d：%+v", len(want), len(categories), categories)
	}
	for index, name := range want {
		if categories[index].Name != name {
			t.Fatalf("第 %d 个分类应为 %q，实际 %q", index, name, categories[index].Name)
		}
	}
}

func TestLibvioTotalPages(t *testing.T) {
	body := readLibvioFixture(t, "list.html")
	if pages := libvioTotalPages(body); pages != 96 {
		t.Fatalf("期望总页数 96，实际 %d", pages)
	}
	if libvioHasMore(96, 96, 12) {
		t.Fatal("最后一页不应再要求翻页")
	}
	if !libvioHasMore(1, 96, 12) {
		t.Fatal("第一页应继续翻页")
	}
}

// 详情页混合了「BD5播放」和两个「视频下载(夸克/迅雷)」网盘面板，
// 后者用同一个 playlist-panel 容器，必须靠 netdisk-panel 类名剔除。
func TestParseLibvioEpisodesSkipsNetdisk(t *testing.T) {
	body := readLibvioFixture(t, "detail.html")
	lines := parseLibvioEpisodes(body)
	if len(lines) != 1 {
		t.Fatalf("期望只有 1 条可播线路（网盘面板应剔除），实际 %d", len(lines))
	}
	episodes := libvioBestEpisodes(lines)
	// 样本抓取时该剧只在播 4 集（页面元数据写「共 12 集」，选集列表才是准的）。
	if len(episodes) != 4 {
		t.Fatalf("期望 4 集，实际 %d", len(episodes))
	}
	if episodes[0].line != 1 || episodes[0].index != 1 || episodes[0].title != "第01集" {
		t.Fatalf("首集解析不对：%+v", episodes[0])
	}
	if episodes[3].index != 4 {
		t.Fatalf("末集序号不对：%+v", episodes[3])
	}
	if number := episodeIndex(episodes[3].title, episodes[3].index); number != 4 {
		t.Fatalf("末集编号应为 4，实际 %d", number)
	}
}

func TestLibvioDetailMeta(t *testing.T) {
	body := readLibvioFixture(t, "detail.html")
	tags, area, year, release, updated, total := libvioDetailMeta(body)
	if len(tags) != 4 || tags[0] != "喜剧" || tags[3] != "运动" {
		t.Fatalf("类型标签不对：%+v", tags)
	}
	if area != "日本" || year != "2026" {
		t.Fatalf("地区/年份不对：area=%q year=%q", area, year)
	}
	if release != "2026-10-04" || updated != "2026-10-26" || total != "12" {
		t.Fatalf("上映/更新/集数不对：release=%q updated=%q total=%q", release, updated, total)
	}
	title := cleanText(firstMatchText(reLibvioTitleTag, body))
	if title != "青之箱 第二季" {
		t.Fatalf("详情页片名不对：%q", title)
	}
	cover := libvioCoverAddress(extractAttr(firstMatchText(reLibvioPosterImg, body), "data-original", "data-src", "src"), nil)
	if !strings.HasPrefix(cover, "https://img.meituan.net/content/") {
		t.Fatalf("详情页封面未解析：%q", cover)
	}
	if description := cleanText(firstMatchText(reLibvioDescTag, body)); !strings.Contains(description, "羽毛球部") {
		t.Fatalf("简介未解析：%q", truncate(description, 40))
	}
}

// 播放页 encrypt=3 表示地址原样可用，但仍要走 JSON 反转义（\/ → /）。
func TestParseLibvioPlayer(t *testing.T) {
	body := readLibvioFixture(t, "play.html")
	player, found := parseLibvioPlayer(body)
	if !found {
		t.Fatal("未解析出 player_aaaa")
	}
	if player.Encrypt != 3 || player.Trysee != 10 {
		t.Fatalf("播放参数不对：%+v", player)
	}
	address := libvioMediaAddress(player)
	want := "https://v.vimsec.app/2026/fun/10/Ao.no.Hako.S02/Ao.no.Hako.S02E01.mp4"
	if address != want {
		t.Fatalf("播放地址不对：%q", address)
	}
}

func TestLibvioMediaAddressEncrypt2(t *testing.T) {
	encoded := "aHR0cHM6Ly9jZG4uZXhhbXBsZS5jb20vYS9iLm1wNA==" // https://cdn.example.com/a/b.mp4
	player := libvioPlayer{Encrypt: 2, URL: encoded}
	if address := libvioMediaAddress(player); address != "https://cdn.example.com/a/b.mp4" {
		t.Fatalf("encrypt=2 未解出地址：%q", address)
	}
	if address := libvioMediaAddress(libvioPlayer{URL: "not-a-url"}); address != "" {
		t.Fatalf("非法地址应返回空：%q", address)
	}
}

func TestLibvioCoverAddress(t *testing.T) {
	base := libvioPageBase("https://www.libvio.to/type/4.html")
	if got := libvioCoverAddress("/statics/img/load.gif", base); got != "" {
		t.Fatalf("占位图应被丢弃：%q", got)
	}
	if got := libvioCoverAddress("/upload/a.png", base); got != "https://www.libvio.to/upload/a.png" {
		t.Fatalf("相对地址未补全：%q", got)
	}
	if got := libvioCoverAddress("", base); got != "" {
		t.Fatalf("空地址应返回空：%q", got)
	}
}

func TestParseLibvioChallenge(t *testing.T) {
	body := readLibvioFixture(t, "challenge.html")
	challenge, found := parseLibvioChallenge(body)
	if !found {
		t.Fatal("未解析出 PoW 校验参数")
	}
	if len(challenge.SIG) != 64 || challenge.DIFF == "" || challenge.TS == "" {
		t.Fatalf("校验参数不完整：%+v", challenge)
	}
	if challenge.MODE == "" {
		t.Fatal("MODE 应有默认值 auto")
	}
	nonce, solved := solveLibvioPow(challenge.SIG, challenge.DIFF)
	if !solved {
		t.Fatal("PoW 未解出")
	}
	sum := sha256.Sum256([]byte(challenge.SIG + strconv.Itoa(nonce)))
	if !strings.HasPrefix(hex.EncodeToString(sum[:]), challenge.DIFF) {
		t.Fatalf("解出的 nonce 校验不通过：nonce=%d target=%s", nonce, challenge.DIFF)
	}
	if _, ok := solveLibvioPow(challenge.SIG, "zzzz"); ok {
		t.Fatal("非法 DIFF 应直接失败")
	}
}

// 完整走一遍「拿到校验页 → 解 PoW → 换 __cdn_verified → 重试成功」。
// 这条链路以前只能靠手写 curl 验证，现在锁进测试里，改动 request 逻辑不会静默失效。
func TestLibvioUnlockAndRetry(t *testing.T) {
	challenge := readLibvioFixture(t, "challenge.html")
	list := readLibvioFixture(t, "list.html")
	verified := ""
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		cookie := request.Header.Get("Cookie")
		switch {
		case strings.Contains(cookie, "__cdn_pow="):
			verified = "abc123"
			header := http.Header{}
			header.Set("Set-Cookie", "__cdn_verified=abc123; Path=/; HttpOnly; Max-Age=1800")
			header.Set("Location", "/")
			return &http.Response{StatusCode: http.StatusFound, Header: header,
				Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
		case verified != "" && strings.Contains(cookie, "__cdn_verified="+verified):
			return sourceFixtureResponse(request, http.StatusOK, list), nil
		default:
			response := sourceFixtureResponse(request, http.StatusForbidden, challenge)
			response.Header.Set("x-cdn-challenge", "js-pow")
			return response, nil
		}
	})
	downloader := sourceFixtureDownloader(t, transport)
	body, err := downloader.libvioGet(context.Background(), libvioBaseURL+"/type/4.html", libvioBaseURL+"/")
	if err != nil {
		t.Fatalf("解锁后仍请求失败：%v", err)
	}
	if body != list {
		t.Fatal("解锁后没有拿到正文")
	}
	if cookie := downloader.libvioAuthCookie(); cookie != "__cdn_verified=abc123" {
		t.Fatalf("凭证未缓存：%q", cookie)
	}
	// 第二次请求不应再触发校验（凭证还在有效期内）。
	if _, err := downloader.libvioGet(context.Background(), libvioBaseURL+"/type/4.html", libvioBaseURL+"/"); err != nil {
		t.Fatalf("复用凭证失败：%v", err)
	}
}

// 详情 → 选集 → 播放页 → 直链，全链路离线验证。
func TestLibvioDetailToMediaFlow(t *testing.T) {
	detail := readLibvioFixture(t, "detail.html")
	play := readLibvioFixture(t, "play.html")
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		switch {
		case request.URL.Path == "/detail/714893734.html":
			return sourceFixtureResponse(request, http.StatusOK, detail), nil
		case request.URL.Path == "/w/714893734-1-1.html":
			return sourceFixtureResponse(request, http.StatusOK, play), nil
		default:
			return sourceFixtureResponse(request, http.StatusNotFound, ""), nil
		}
	})
	downloader := sourceFixtureDownloader(t, transport)
	drama, chapters, err := downloader.fetchLibvioDetail(context.Background(), "714893734")
	if err != nil {
		t.Fatalf("详情解析失败：%v", err)
	}
	if drama.Title != "青之箱 第二季" || drama.ID != "libvio:714893734" {
		t.Fatalf("详情字段不对：%+v", drama)
	}
	if len(chapters) != 4 {
		t.Fatalf("期望 4 个分集，实际 %d", len(chapters))
	}
	if chapters[0].CurrentEpisode == nil || string(chapters[0].CurrentEpisode) != "1" {
		t.Fatalf("首集编号不对：%+v", chapters[0])
	}
	media, err := downloader.resolveLibvioMedia(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[0]})
	if err != nil {
		t.Fatalf("播放地址解析失败：%v", err)
	}
	want := "https://v.vimsec.app/2026/fun/10/Ao.no.Hako.S02/Ao.no.Hako.S02E01.mp4"
	if media.URL != want {
		t.Fatalf("直链不对：%q", media.URL)
	}
	if !strings.HasSuffix(media.Referer, "/w/714893734-1-1.html") {
		t.Fatalf("Referer 不对：%q", media.Referer)
	}
	// 伪造分集地址必须被拒绝，不能带着任意 id 去打站点。
	if _, err := downloader.resolveLibvioMedia(context.Background(), Task{DramaID: "libvio:714893734",
		Chapter: Chapter{ID: "libvio:714893734:999999999-1-1"}}); err == nil {
		t.Fatal("越界分集地址应被拒绝")
	}
}

// 联网验证：默认跳过，需要时 `LIBVIO_LIVE=1 go test ./core/ -run TestLibvioLive -v`。
// 站点的 PoW 参数会变，这条用例用来确认现网还能通。
func TestLibvioLive(t *testing.T) {
	if os.Getenv("LIBVIO_LIVE") == "" {
		t.Skip("未设置 LIBVIO_LIVE，跳过联网验证")
	}
	downloader := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 12, MaxPagesPerSort: 1},
		client:        &http.Client{Timeout: 25 * time.Second},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	items, more, err := downloader.fetchLibvioCategoryPage(ctx, 1, "4", "番剧")
	if err != nil {
		t.Fatalf("番剧分类页请求失败：%v", err)
	}
	if len(items) == 0 {
		t.Fatal("番剧分类页没有解析出条目")
	}
	t.Logf("番剧第 1 页 %d 条，还有更多：%v，首条：%s", len(items), more, items[0].Title)
	drama, chapters, err := downloader.fetchLibvioDetail(ctx, items[0].SourceID)
	if err != nil {
		t.Fatalf("详情请求失败：%v", err)
	}
	if len(chapters) == 0 {
		t.Fatal("详情页没有解析出分集")
	}
	t.Logf("详情：%s，分集 %d 个", drama.Title, len(chapters))
	media, err := downloader.resolveLibvioMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0]})
	if err != nil {
		t.Fatalf("播放地址解析失败：%v", err)
	}
	t.Logf("直链：%s", media.URL)
}
