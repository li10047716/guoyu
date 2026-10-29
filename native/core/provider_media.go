package core

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"
)

type providerMedia struct {
	credentials *providerMediaCredentials
	URL         string
	Referer     string
	Duration    time.Duration
	Playlist    string
	HLSKey      []byte
	CENCKey     []byte
	Quality     int
	Variants    []providerMedia
}

func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	var configured, fallback string
	switch source {
	case sourceHongguo:
		configured, fallback = d.cfg.HongguoURL, hongguoBaseURL
	case sourceSorani:
		configured, fallback = d.cfg.SoraniURL, soraniBaseURL
	case sourceHanxiaoquan:
		configured, fallback = d.cfg.HanxiaoquanURL, hanxiaoquanBaseURL
	case sourceLibvio:
		configured, fallback = d.cfg.LibvioURL, libvioBaseURL
	case sourceNetflixgc:
		configured, fallback = d.cfg.NetflixgcURL, netflixgcBaseURL
	default:
		return ""
	}
	return strings.TrimRight(firstNonEmpty(configured, fallback), "/")
}

func providerSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	switch {
	case host == "hongguoduanju.com" || host == "www.hongguoduanju.com":
		return sourceHongguo
	case host == "sorani.net" || host == "www.sorani.net" || host == "api.sorani.cc":
		return sourceSorani
	case host == "jennyhow.com" || host == "www.jennyhow.com":
		return sourceHanxiaoquan
	case host == "libvio.to" || host == "www.libvio.to" || host == "libvio.me" || host == "www.libvio.me":
		return sourceLibvio
	case host == "netflixgc.com" || host == "www.netflixgc.com" || host == "netflixgc.net" ||
		host == "www.netflixgc.net" || host == "netflixgc.org" || host == "www.netflixgc.org":
		return sourceNetflixgc
	default:
		return ""
	}
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (providerMedia, error) {
	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = sourceFromDramaID(task.DramaID)
	}
	if chapter.Source == sourceSorani {
		return d.resolveSoraniMedia(ctx, task)
	}
	if chapter.Source == sourceHanxiaoquan {
		return d.resolveHanxiaoquanMedia(ctx, task)
	}
	if chapter.Source == sourceLibvio {
		return d.resolveLibvioMedia(ctx, task)
	}
	if chapter.Source == sourceNetflixgc {
		return d.resolveNetflixgcMedia(ctx, task)
	}
	if strings.HasPrefix(chapter.VideoURL, "hongguo-cenc://") {
		return d.resolveHongguoMedia(ctx, task)
	}
	media := providerMedia{URL: chapter.VideoURL, Referer: firstNonEmpty(chapter.Referer, d.providerBaseURL(chapter.Source)+"/")}
	if !isProviderHTTPMediaURL(media.URL) {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", chapter.Source)
	}
	parsed, _ := url.Parse(media.URL)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}
