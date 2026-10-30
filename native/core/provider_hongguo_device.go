package core

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 红果 App 客户端版本画像（0.7.76，对齐 guo v1.2.11 的 7.3.9.32）。
//
// 2026-10-30 实测：网关对旧版 7.3.5.32 画像的 `multi_video_model`
// 取流端点**稳定**返回空体（目录/详情不受影响）；换成 7.3.9.32 画像 +
// 「已注册设备」的 device_id/iid/cookie 后，取流立即返回完整 video_model。
// 也就是说取流风控看的是「设备是否注册过」，不是单纯签名。
const (
	hongguoVersionCode = "73932"
	hongguoVersionName = "7.3.9.32"
)

// hongguoDeviceProfile 红果设备身份与请求画像。
//
// 字段与红果系「device.json」一致（guo PC 播放器导出的注册结果就是这个
// 结构），导入时直接映射；合成画像也用同一结构落盘。
type hongguoDeviceProfile struct {
	DeviceID    string `json:"device_id"`
	InstallID   string `json:"install_id"`
	IID         string `json:"iid,omitempty"`
	CDID        string `json:"cdid,omitempty"`
	OpenUDID    string `json:"openudid,omitempty"`
	DeviceToken string `json:"device_token,omitempty"`
	TTReq       string `json:"ttreq,omitempty"`
	StoreRegion string `json:"store_region,omitempty"`
	DeviceBrand string `json:"device_brand"`
	DeviceType  string `json:"device_type"`
	OSVersion   string `json:"os_version"`
	OSAPI       string `json:"os_api"`
	Resolution  string `json:"resolution"`
	DPI         string `json:"dpi"`
	Channel     string `json:"channel"`
	UserAgent   string `json:"user_agent"`
}

func (p *hongguoDeviceProfile) valid() bool {
	return p != nil &&
		hongguoNumericID.MatchString(p.DeviceID) && p.DeviceID != "0" &&
		hongguoNumericID.MatchString(p.installID()) &&
		strings.TrimSpace(p.UserAgent) != "" &&
		strings.TrimSpace(p.DeviceType) != "" && strings.TrimSpace(p.DeviceBrand) != ""
}

func (p *hongguoDeviceProfile) installID() string {
	if p.IID != "" {
		return p.IID
	}
	return p.InstallID
}

// cookieHeader 组装网关侧期望的 Cookie（guo 的 device.json 里
// odin_tt 为空、ttreq/store_region 有值，与重放验证一致）。
func (p *hongguoDeviceProfile) cookieHeader() string {
	var parts []string
	if value := strings.TrimSpace(p.TTReq); value != "" {
		parts = append(parts, "ttreq="+value)
	}
	if value := strings.TrimSpace(p.StoreRegion); value != "" {
		parts = append(parts, "store-region="+value, "store-region-src=uid")
	}
	return strings.Join(parts, "; ")
}

// importHongguoDeviceProfile 尝试导入 guo PC 播放器注册好的设备。
//
// guo（红果短剧.exe）安装后会在 %APPDATA%\hgplayer\device.json 落一份
// 已注册设备身份。同一台机器上两份身份没有冲突——红果只认「这个设备
// 注册过」，不校验调用方。读不到（未安装 / 路径变化）就返回 nil。
func importHongguoDeviceProfile() (*hongguoDeviceProfile, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(filepath.Join(base, "hgplayer", "device.json"))
	if err != nil {
		return nil, err
	}
	var profile hongguoDeviceProfile
	if err := json.Unmarshal(raw, &profile); err != nil {
		return nil, err
	}
	if !profile.valid() {
		return nil, errors.New("hgplayer device.json 缺少有效的设备 ID")
	}
	return &profile, nil
}

// hongguoDeviceKind 设备画像表里的一款机型。
type hongguoDeviceKind struct {
	brand   string // query 里的 device_brand / UA 里的品牌段
	name    string // UA 里的市场名（Xiaomi 14 这类）
	typ     string // query 里的 device_type（机型代号）
	build   string // Build/ 后面的系统构建号
	osVer   string
	osAPI   string
	res     string
	dpi     string
	channel string
}

// hongguoDeviceKinds 合成画像用的机型池。
//
// 全部是 2025-2026 年在网关画像里常见的真实机型代号 + 匹配的系统构建号；
// 没放更新的旗舰是因为画像越冷门越容易被风控盯上。
var hongguoDeviceKinds = []hongguoDeviceKind{
	{brand: "xiaomi", name: "Xiaomi 14", typ: "23127PN0CC", build: "UKQ1.230804.001", osVer: "14", osAPI: "34", res: "1200*2670", dpi: "460", channel: "xiaomi_8662_64"},
	{brand: "Redmi", name: "M2012K11AC", typ: "M2012K11AC", build: "RKQ1.200826.002", osVer: "11", osAPI: "30", res: "1080*2190", dpi: "440", channel: "update_64"},
	{brand: "Redmi", name: "25053RT47C", typ: "25053RT47C", build: "BP2A.250605.031.A3", osVer: "16", osAPI: "36", res: "1280*2772", dpi: "520", channel: "update_64"},
	{brand: "HONOR", name: "BVL-AN16", typ: "BVL-AN16", build: "4.2.0.156(C460E1R4P1)", osVer: "14", osAPI: "34", res: "1260*2720", dpi: "480", channel: "update_64"},
	{brand: "HUAWEI", name: "ALN-AL00", typ: "ALN-AL00", build: "HUAWEIALN-AL00", osVer: "14", osAPI: "34", res: "1216*2688", dpi: "480", channel: "update_64"},
}

// hongguoUAVersion Cronet/Quic 版本串（2026-08 批次的网关画像）。
const hongguoUAVersion = "Cronet/TTNetVersion:8d40f833 QuicVersion:462f352c 2026-08-31"

func (kind hongguoDeviceKind) userAgent() string {
	return "com.phoenix.read/" + hongguoVersionCode +
		" (Linux; U; Android " + kind.osVer + "; zh_CN; " + kind.name +
		"; Build/" + kind.build + "; " + hongguoUAVersion + ")"
}

// newHongguoDeviceProfile 生成一份匿名合成画像（未导入注册设备时使用）。
//
// 注意：合成画像**没有注册身份**（device_id 是本地随机数），目录/详情
// 可用，取流端点大概率仍被风控；真正的播放放行要靠导入注册设备。
func newHongguoDeviceProfile() *hongguoDeviceProfile {
	kind := hongguoDeviceKinds[hongguoRandomInt(len(hongguoDeviceKinds))]
	return &hongguoDeviceProfile{
		DeviceID:    newHongguoDeviceID(),
		InstallID:   newHongguoDeviceID(),
		CDID:        hongguoRandomUUID(),
		OpenUDID:    hongguoRandomHex(8),
		DeviceBrand: kind.brand,
		DeviceType:  kind.typ,
		OSVersion:   kind.osVer,
		OSAPI:       kind.osAPI,
		Resolution:  kind.res,
		DPI:         kind.dpi,
		Channel:     kind.channel,
		UserAgent:   kind.userAgent(),
	}
}

func hongguoRandomInt(n int) int {
	if n <= 0 {
		return 0
	}
	value, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(value.Int64())
}

func hongguoRandomHex(n int) string {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return strings.Repeat("0", n*2)
	}
	return hexEncodeUpper(raw, false)
}

func hongguoRandomUUID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		fallback := time.Now().UnixNano()
		for index := range raw {
			raw[index] = byte(fallback >> (uint(index%8) * 8))
		}
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	text := hexEncodeUpper(raw[:], false)
	return strings.Join([]string{text[0:8], text[8:12], text[12:16], text[16:20], text[20:32]}, "-")
}

// hongguoProfileFromState 兼容旧版目录状态里散落的 device_id/iid。
func hongguoProfileFromState(deviceID, installID string) *hongguoDeviceProfile {
	if !hongguoNumericID.MatchString(deviceID) || !hongguoNumericID.MatchString(installID) {
		return nil
	}
	profile := newHongguoDeviceProfile()
	profile.DeviceID = deviceID
	profile.InstallID = installID
	return profile
}

func hexEncodeUpper(raw []byte, upper bool) string {
	const lower = "0123456789abcdef"
	out := make([]byte, 0, len(raw)*2)
	for _, b := range raw {
		out = append(out, lower[b>>4], lower[b&0x0f])
	}
	if upper {
		return strings.ToUpper(string(out))
	}
	return string(out)
}
