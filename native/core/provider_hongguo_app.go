package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"

// hongguoAttemptsKey 让调用方按请求类型压低 App 接口的重试次数。
type hongguoAttemptsKey struct{}

// errHongguoAppEmptyBody 网关「200 + 空体」。
//
// 0.7.39 实测：目录/详情接口偶发空体（可重试），而播放取流端点
// （video_model / multi_video_model）对第三方客户端**稳定**返回空体，
// 说明是端点级风控，不是网络抖动。
var errHongguoAppEmptyBody = errors.New("红果 App 接口未返回有效数据")

const hongguoAppUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

type hongguoCatalogCursor struct {
	Offset        int       `json:"offset"`
	SessionID     string    `json:"sessionId,omitempty"`
	LastID        string    `json:"lastId,omitempty"`
	PageSignature string    `json:"pageSignature,omitempty"`
	Initialized   bool      `json:"initialized"`
	Exhausted     bool      `json:"exhausted"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type hongguoCatalogState struct {
	Version   int                             `json:"version"`
	DeviceID  string                          `json:"deviceId"`
	InstallID string                          `json:"installId"`
	// Device 是 0.7.76 起的完整设备画像（注册身份 + 请求画像）。
	// 为 nil 时兼容 0.7.75 之前的 v1 状态：请求用镜像字段兜底。
	Device    *hongguoDeviceProfile           `json:"device,omitempty"`
	Feeds     map[string]hongguoCatalogCursor `json:"feeds"`
}

type hongguoAppClient struct {
	mu             sync.Mutex
	catalogMu      sync.Mutex
	baseURL        string
	state          hongguoCatalogState
	details        map[string]hongguoDetailEntry
	pending        map[string]*hongguoDetailCall
	searches       map[string]hongguoSearchEntry
	searchPending  map[string]*hongguoSearchCall
	suggestions    map[string]hongguoSuggestionEntry
	suggestPending map[string]*hongguoSuggestionCall
}

func (downloader *Downloader) hongguoClient() *hongguoAppClient {
	downloader.hongguoOnce.Do(func() {
		// 0.7.76：优先导入本机 guo（红果短剧 PC 播放器）注册好的设备身份；
		// 没有就生成匿名合成画像（目录/详情可用，取流仍可能被风控）。
		profile, importErr := importHongguoDeviceProfile()
		if profile == nil {
			profile = newHongguoDeviceProfile()
		}
		downloader.hongguoImported = importErr == nil
		downloader.hongguo = &hongguoAppClient{
			baseURL: hongguoAppBaseURL,
			state: hongguoCatalogState{
				Version: 2, Device: profile,
				DeviceID: profile.DeviceID, InstallID: profile.installID(),
				Feeds: map[string]hongguoCatalogCursor{},
			},
			details: map[string]hongguoDetailEntry{}, pending: map[string]*hongguoDetailCall{},
			searches: map[string]hongguoSearchEntry{}, searchPending: map[string]*hongguoSearchCall{},
			suggestions: map[string]hongguoSuggestionEntry{}, suggestPending: map[string]*hongguoSuggestionCall{},
		}
	})
	return downloader.hongguo
}

func cloneHongguoCatalogState(state *hongguoCatalogState) *hongguoCatalogState {
	if state == nil {
		return nil
	}
	cloned := *state
	cloned.Feeds = make(map[string]hongguoCatalogCursor, len(state.Feeds))
	for name, cursor := range state.Feeds {
		cloned.Feeds[name] = cursor
	}
	return &cloned
}

func (downloader *Downloader) restoreHongguoCatalog(state *hongguoCatalogState) {
	if state == nil || (state.Version != 1 && state.Version != 2) || !hongguoNumericID.MatchString(state.DeviceID) || !hongguoNumericID.MatchString(state.InstallID) {
		return
	}
	cloned := cloneHongguoCatalogState(state)
	// v1 状态没有画像字段；v2 的画像要有效才采用，
	// 否则保留 client 初始化时的（导入或合成）画像。
	if cloned.Device != nil && !cloned.Device.valid() {
		cloned.Device = nil
	}
	for name, cursor := range cloned.Feeds {
		known := false
		for _, genre := range hongguoAppGenres {
			known = known || name == genre.key || name == "category:"+genre.key
		}
		if !known || !cursor.Initialized || cursor.Offset < 0 || cursor.Offset > 1_000_000 || len(cursor.SessionID) > 4096 || len(cursor.LastID) > 256 || len(cursor.PageSignature) > 64 {
			delete(cloned.Feeds, name)
		}
	}
	client := downloader.hongguoClient()
	client.catalogMu.Lock()
	defer client.catalogMu.Unlock()
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.state.Feeds) != 0 {
		return
	}
	adopted := *cloned
	if adopted.Device == nil && client.state.Device != nil {
		// 保留启动时导入/合成的画像（v1 磁盘状态里没有）。
		adopted.Device = client.state.Device
	}
	if adopted.Device != nil {
		// 镜像字段始终与画像保持一致，方便旧校验逻辑继续工作。
		adopted.DeviceID = adopted.Device.DeviceID
		adopted.InstallID = adopted.Device.installID()
	}
	client.state = adopted
}

func (downloader *Downloader) hongguoCatalogSnapshot() *hongguoCatalogState {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return cloneHongguoCatalogState(&client.state)
}

func hongguoCatalogInitialized(state *hongguoCatalogState) bool {
	if state != nil && state.Version == 1 {
		for _, cursor := range state.Feeds {
			if cursor.Initialized {
				return true
			}
		}
	}
	return false
}

func hongguoCatalogHasMore(state *hongguoCatalogState) bool {
	for _, genre := range hongguoAppGenres {
		if state == nil || !state.Feeds[genre.key].Exhausted {
			return true
		}
	}
	return false
}

// 红果 App 接口全局节流（0.7.16）。
//
// 实测：连续突发请求（首页三组推荐并发）会被网关间歇性丢成「200 + 空体」。
// 串行化并保持最小间隔后，同样三组请求全部正常返回。
const hongguoAppMinInterval = 600 * time.Millisecond

var (
	hongguoAppThrottleMu  sync.Mutex
	hongguoAppLastRequest time.Time
)

func hongguoAppThrottle(ctx context.Context) error {
	hongguoAppThrottleMu.Lock()
	wait := hongguoAppMinInterval - time.Since(hongguoAppLastRequest)
	hongguoAppThrottleMu.Unlock()
	if wait > 0 {
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	hongguoAppThrottleMu.Lock()
	hongguoAppLastRequest = time.Now()
	hongguoAppThrottleMu.Unlock()
	return nil
}

// hongguoBaseKey 允许调用方按请求覆盖网关主机（取流端点在四个
// sinfonine 边缘池之间轮换，与 guo 的 hostPicker 行为一致）。
type hongguoBaseKey struct{}

// hongguoGatewayHosts 红果 App 网关的边缘主机池（0.7.76，取自
// guo v1.2.11 内置的 hostPicker 列表）。
var hongguoGatewayHosts = []string{
	"https://api5-normal-sinfonlineb.fqnovel.com",
	"https://api5-normal-sinfonlinea.fqnovel.com",
	"https://api5-normal-sinfonlinec.fqnovel.com",
	"https://api3-normal-sinfonlinea.fqnovel.com",
}

func (downloader *Downloader) hongguoAppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	base := client.baseURL
	profile := client.state.Device
	deviceID, installID := client.state.DeviceID, client.state.InstallID
	client.mu.Unlock()
	// 取流等调用方可以要求跨主机轮换。
	if override, ok := ctx.Value(hongguoBaseKey{}).(string); ok && override != "" {
		base = override
	}
	if profile == nil {
		// 兼容 v1 磁盘状态：没有画像时按镜像字段构造一份最小画像。
		profile = hongguoProfileFromState(deviceID, installID)
	}
	brand, typ := "Redmi", "25053RT47C"
	osAPI, osVer, resolution, dpi, channel := "36", "16", "1280*2772", "520", "update_64"
	ua := hongguoAppUserAgent
	var cookies string
	if profile != nil {
		brand, typ = profile.DeviceBrand, profile.DeviceType
		osAPI, osVer, resolution, dpi, channel = profile.OSAPI, profile.OSVersion, profile.Resolution, profile.DPI, profile.Channel
		ua = profile.UserAgent
		cookies = profile.cookieHeader()
		deviceID, installID = profile.DeviceID, profile.installID()
	}
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {hongguoVersionCode}, "version_name": {hongguoVersionName},
		"manifest_version_code": {hongguoVersionCode}, "update_version_code": {hongguoVersionCode}, "channel": {channel},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {typ},
		"device_brand": {brand}, "language": {"zh"}, "os_api": {osAPI}, "os_version": {osVer},
		"resolution": {resolution}, "dpi": {dpi}, "ac": {"wifi"}, "device_id": {deviceID}, "iid": {installID},
		// 0.7.16：网关签名校验会看设备画像字段，缺这两个时接口仍返回空体。
		"host_abi": {"arm64-v8a"}, "dragon_device_type": {"phone"},
	}
	if profile != nil {
		// 0.7.76：设备一致性字段（guo 的请求里带），缺了也会被画像校验盯上。
		if profile.CDID != "" {
			query.Set("cdid", profile.CDID)
		}
		if profile.OpenUDID != "" {
			query.Set("openudid", profile.OpenUDID)
		}
	}
	for key, values := range extra {
		query[key] = append([]string(nil), values...)
	}
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}
	// 0.7.16：网关会间歇性返回空体，单次失败不代表源不可用，
	// 因此这里至少重试 4 次（上限 5），间隔 700ms 递增。
	attempts := downloader.cfg.Retries
	if attempts < 4 {
		attempts = 4
	}
	if attempts > 5 {
		attempts = 5
	}
	// 取流（播放/下载）端点被网关稳定拒收时，4 次退避要白等 5 秒以上；
	// 允许调用方按上下文压低重试次数（见 resolveHongguoAppMedia）。
	if limit, ok := ctx.Value(hongguoAttemptsKey{}).(int); ok && limit > 0 && attempts > limit {
		attempts = limit
	}
	var lastErr error
	for attempt := 0; attempt < attempts; attempt++ {
		if err := hongguoAppThrottle(ctx); err != nil {
			return nil, err
		}
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * 700 * time.Millisecond):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", ua)
		if cookies != "" {
			request.Header.Set("Cookie", cookies)
		}
		request.Header.Set("Accept", "application/json; charset=utf-8,application/x-protobuf")
		request.Header.Set("X-XS-From-Web", "0")
		request.Header.Set("Sdk-Version", "2")
		// 0.7.16：红果 App 网关现在校验完整客户端特征，缺这几项时
		// 部分接口（尤其播放取流）会返回 HTTP 200 + 空体。
		request.Header.Set("X-Tt-Request-Tag", "t=0;n=0")
		request.Header.Set("Passport-Sdk-Version", "50561")
		request.Header.Set("X-Vc-Bdturing-Sdk-Version", "3.7.2.cn")
		request.Header.Set("X-Tt-Dt", "")
		if payload != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
			now := time.Now()
			query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
			prepared.URL.RawQuery = query.Encode()
			signHongguoRequest(prepared, body, now)
		})
		if err != nil {
			lastErr = err
			var backoff *requestBackoff
			if errors.As(err, &backoff) || ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		if len(content) == 0 || len(content) > providerMaxBodyBytes {
			// 0.7.16：空体是红果网关的间歇性风控表现（突发请求时出现），
			// 属于可重试失败；原先直接返回错误，导致首页三组推荐并发时整片失败。
			lastErr = errHongguoAppEmptyBody
			continue
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			lastErr = errors.New("红果 App 接口返回格式异常")
			continue
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s %s）", truncate(code, 20), truncate(firstNonEmpty(mapString(result, "message", "msg", "data"), ""), 60))
		}
		return result, nil
	}
	return nil, lastErr
}
