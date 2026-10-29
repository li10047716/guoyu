package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	sourceHongguo     = "hongguo"
	sourceSorani      = "sorani"
	sourceHanxiaoquan = "hanxiaoquan"
	sourceLibvio      = "libvio"
	sourceNetflixgc   = "netflixgc"

	providerMaxBodyBytes = 20 * 1024 * 1024
	providerTimeout      = 12 * time.Second
)

var (
	reH1Tag         = regexp.MustCompile(`(?is)<h1[^>]*>(.*?)</h1>`)
	reEpisodeNumber = regexp.MustCompile(`(?i)(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))`)
	reDateText      = regexp.MustCompile(`\d{4}-\d{1,2}-\d{1,2}`)
)

func providerDramaID(source, sourceID string) string {
	return source + ":" + strings.TrimSpace(sourceID)
}

func providerChapterID(source, sourceID, chapterKey string) string {
	return source + ":" + strings.TrimSpace(sourceID) + ":" + strings.TrimSpace(chapterKey)
}

func splitProviderDramaID(id string) (source, sourceID string, ok bool) {
	source, sourceID, ok = strings.Cut(strings.TrimSpace(id), ":")
	source = canonicalProviderSource(source)
	if !ok || strings.TrimSpace(sourceID) == "" || !isSupportedProviderSource(source) {
		return "", "", false
	}
	return source, strings.TrimSpace(sourceID), true
}

func isSupportedProviderSource(source string) bool {
	switch canonicalProviderSource(source) {
	case sourceHongguo, sourceSorani, sourceHanxiaoquan, sourceLibvio, sourceNetflixgc:
		return true
	default:
		return false
	}
}

func canonicalProviderSource(source string) string {
	switch strings.ToLower(strings.TrimSpace(source)) {
	case "hongguo", "hongguoduanju.com":
		return sourceHongguo
	case "sorani", "sorani.net", "www.sorani.net", "api.sorani.cc":
		return sourceSorani
	case "hanxiaoquan", "jennyhow", "jennyhow.com", "www.jennyhow.com":
		return sourceHanxiaoquan
	case "libvio", "libvio.to", "www.libvio.to", "libvio.me", "www.libvio.me":
		return sourceLibvio
	case "netflixgc", "netflixgc.com", "www.netflixgc.com", "netflixgc.net", "www.netflixgc.net",
		"netflixgc.org", "www.netflixgc.org":
		return sourceNetflixgc
	default:
		return strings.TrimSpace(source)
	}
}

func mergeDramaMetadata(base, extra Drama) Drama {
	if base.VIP == nil && extra.VIP != nil {
		value := *extra.VIP
		base.VIP = &value
	}
	if extra.SortMetadata != nil && (base.SortMetadata == nil || extra.SortMetadata.CheckedAt.After(base.SortMetadata.CheckedAt)) {
		base.SortMetadata = extra.SortMetadata
	}
	if strings.TrimSpace(base.ID) == "" {
		base.ID = extra.ID
	}
	if strings.TrimSpace(base.Source) == "" {
		base.Source = extra.Source
	}
	if strings.TrimSpace(base.SourceID) == "" {
		base.SourceID = extra.SourceID
	}
	if strings.TrimSpace(base.Title) == "" {
		base.Title = extra.Title
	}
	if strings.TrimSpace(base.Name) == "" {
		base.Name = extra.Name
	}
	if strings.TrimSpace(base.Desc) == "" {
		base.Desc = extra.Desc
	}
	if strings.TrimSpace(base.Intro) == "" {
		base.Intro = extra.Intro
	}
	if coverPathFromAny(base.Cover) == "" {
		base.Cover = extra.Cover
	}
	if coverPathFromAny(base.CoverURL) == "" {
		base.CoverURL = extra.CoverURL
	}
	if valueEmpty(base.TotalEpisode) {
		base.TotalEpisode = extra.TotalEpisode
	}
	if valueEmpty(base.EpisodeCount) {
		base.EpisodeCount = extra.EpisodeCount
	}
	if strings.TrimSpace(base.ChannelName) == "" {
		base.ChannelName = extra.ChannelName
	}
	if strings.TrimSpace(base.CategoryName) == "" || (base.CategoryName == "首页" && extra.CategoryName != "") {
		base.CategoryName = extra.CategoryName
	}
	if strings.TrimSpace(base.Remark) == "" || base.Remark == "在线观看" {
		base.Remark = extra.Remark
	}
	if strings.TrimSpace(base.Score) == "" {
		base.Score = extra.Score
	}
	if strings.TrimSpace(base.Views) == "" {
		base.Views = extra.Views
	}
	if strings.TrimSpace(base.Heat) == "" {
		base.Heat = extra.Heat
	}
	if strings.TrimSpace(base.OnlineDate) == "" {
		base.OnlineDate = extra.OnlineDate
	}
	if len(base.Tags) == 0 {
		base.Tags = extra.Tags
	}
	if base.ReleaseStatus == "" || base.ReleaseStatus == "unknown" {
		base.ReleaseStatus = extra.ReleaseStatus
	}
	return base
}

func valueEmpty(v any) bool {
	if v == nil {
		return true
	}
	s := strings.TrimSpace(fmt.Sprint(v))
	return s == "" || s == "0" || s == "<nil>"
}

func (d *Downloader) GetProviderChapters(ctx context.Context, source, sourceID string) (string, []Chapter, error) {
	switch canonicalProviderSource(source) {
	case sourceHongguo:
		return d.fetchHongguoChapters(ctx, sourceID)
	default:
		return "", nil, fmt.Errorf("unsupported provider source: %s", source)
	}
}

func (d *Downloader) fetchProviderText(ctx context.Context, rawURL, referer string) (string, error) {
	retries := d.cfg.Retries
	if retries <= 0 {
		retries = 3
	}
	if referer == "" {
		referer = rawURL
	}
	var lastErr error
	for attempt := 1; attempt <= retries; attempt++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if attempt > 1 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("User-Agent", userAgent)
		req.Header.Set("Referer", referer)
		req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
		resp, err := d.doCatalogRequestWithTimeout(req, providerTimeout)
		if err != nil {
			lastErr = err
			var backoff *requestBackoff
			if errors.As(err, &backoff) {
				return "", err
			}
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
		closeErr := resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if closeErr != nil {
			lastErr = closeErr
			continue
		}
		if len(body) > providerMaxBodyBytes {
			lastErr = fmt.Errorf("response exceeds %d bytes", providerMaxBodyBytes)
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 || catalogResponseBlockReason(resp, body) != "" {
			lastErr = d.catalogResponseError(req, resp, body)
			if catalogResponseBlockReason(resp, body) != "" || resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 408 {
				return "", lastErr
			}
			continue
		}
		rememberPlaybackResponseURL(ctx, rawURL, resp)
		return string(body), nil
	}
	return "", lastErr
}

func (d *Downloader) fetchProviderTextTimeout(ctx context.Context, rawURL, candidate, referer string, timeout time.Duration) (string, error) {
	if referer == "" {
		referer = rawURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, candidate, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("Referer", referer)
	resp, err := d.doCatalogRequestWithTimeout(req, timeout)
	if err != nil {
		return "", err
	}
	body, readErr := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
	closeErr := resp.Body.Close()
	if readErr != nil {
		return "", readErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if len(body) > providerMaxBodyBytes {
		return "", fmt.Errorf("response exceeds %d bytes", providerMaxBodyBytes)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || catalogResponseBlockReason(resp, body) != "" {
		return "", d.catalogResponseError(req, resp, body)
	}
	rememberPlaybackResponseURL(ctx, rawURL, resp)
	return string(body), nil
}

func extractAttr(block string, names ...string) string {
	for _, name := range names {
		re := regexp.MustCompile(`(?is)\b` + regexp.QuoteMeta(name) + `\s*=\s*["']([^"']+)["']`)
		if m := re.FindStringSubmatch(block); len(m) > 1 {
			return strings.TrimSpace(html.UnescapeString(m[1]))
		}
	}
	return ""
}

func firstMatchText(re *regexp.Regexp, raw string) string {
	if m := re.FindString(raw); m != "" {
		return strings.TrimSpace(m)
	}
	return ""
}

func normalizeDate(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	matches := reDateText.FindAllString(s, -1)
	for _, m := range matches {
		parts := strings.Split(m, "-")
		if len(parts) != 3 {
			continue
		}
		y, yErr := strconv.Atoi(parts[0])
		mo, moErr := strconv.Atoi(parts[1])
		d, dErr := strconv.Atoi(parts[2])
		if yErr == nil && moErr == nil && dErr == nil && y >= 2000 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31 {
			return fmt.Sprintf("%04d-%02d-%02d", y, mo, d)
		}
	}
	return ""
}

func cleanText(s string) string {
	s = regexp.MustCompile(`(?is)<script\b.*?</script>`).ReplaceAllString(s, " ")
	s = regexp.MustCompile(`(?is)<style\b.*?</style>`).ReplaceAllString(s, " ")
	s = regexp.MustCompile(`(?is)<[^>]+>`).ReplaceAllString(s, " ")
	s = html.UnescapeString(s)
	s = spaceChars.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func nonEmptyStrings(values ...string) []string {
	var out []string
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			out = append(out, strings.TrimSpace(v))
		}
	}
	return out
}

func mapString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if v, ok := m[key]; ok {
			switch x := v.(type) {
			case string:
				if text := strings.TrimSpace(x); text != "" {
					return text
				}
			case bool:
				return strconv.FormatBool(x)
			case float64:
				if x == float64(int64(x)) {
					return strconv.FormatInt(int64(x), 10)
				}
				return strconv.FormatFloat(x, 'f', -1, 64)
			case int:
				return strconv.Itoa(x)
			case json.Number:
				return x.String()
			}
		}
	}
	return ""
}

func mapStringSlice(m map[string]any, keys ...string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, key := range keys {
		v, ok := m[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case string:
			for _, part := range strings.FieldsFunc(x, func(r rune) bool { return r == ',' || r == '/' || r == '，' || r == '、' }) {
				add(part)
			}
		case []any:
			for _, item := range x {
				add(fmt.Sprint(item))
			}
		}
	}
	return out
}

func rawEpisode(n int) json.RawMessage {
	if n <= 0 {
		n = 1
	}
	return json.RawMessage(strconv.Itoa(n))
}

func episodeIndex(s string, fallback int) int {
	if m := reEpisodeNumber.FindStringSubmatch(s); len(m) > 1 {
		for _, group := range m[1:] {
			if group == "" {
				continue
			}
			if n, err := strconv.Atoi(group); err == nil && n > 0 {
				return n
			}
		}
	}
	return fallback
}

func isProviderHTTPMediaURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Hostname() != "" && parsed.User == nil
}
