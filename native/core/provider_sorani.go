package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

const (
	soraniBaseURL     = "https://www.sorani.net"
	soraniAPIBaseURL  = "https://api.sorani.cc/sorani-cms"
	soraniSiteReferer = soraniBaseURL + "/"
	soraniChapterPfx  = "sorani-play://"
	soraniDefaultLine = "anime_jp_m3u8"
	soraniPageSize    = 24
	soraniMaxRows     = 500
	soraniMaxEpisodes = 10000
)

func validSoraniID(value string) bool {
	if value == "" || len(value) > 12 {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	id, err := strconv.ParseInt(value, 10, 64)
	return err == nil && id > 0
}

func soraniInteger(value any) (int64, bool) {
	switch value := value.(type) {
	case json.Number:
		number, err := value.Int64()
		return number, err == nil && number >= 0
	case float64:
		if value >= 0 && value == float64(int64(value)) {
			return int64(value), true
		}
	case string:
		number, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
		return number, err == nil && number >= 0
	}
	return 0, false
}

func soraniStrings(value any) []string {
	rows, valid := value.([]any)
	if !valid {
		return nil
	}
	var out []string
	for _, entry := range rows {
		if text, ok := entry.(string); ok {
			if text = strings.TrimSpace(text); text != "" && len([]rune(text)) <= 48 {
				out = append(out, text)
			}
		}
	}
	return out
}

func soraniDramaFromMap(row map[string]any) (Drama, error) {
	id, valid := soraniInteger(row["id"])
	if !valid || id <= 0 || id > 1e12 {
		return Drama{}, errors.New("青空次元返回的剧集信息不完整")
	}
	title, _ := row["title"].(string)
	if strings.TrimSpace(title) == "" {
		return Drama{}, errors.New("青空次元返回的剧集标题为空")
	}
	sourceID := strconv.FormatInt(id, 10)
	cover, _ := row["coverLarge"].(string)
	if strings.TrimSpace(cover) == "" {
		cover, _ = row["cover"].(string)
	}
	cover = strings.TrimSpace(cover)
	if cover != "" && !isProviderHTTPMediaURL(cover) {
		cover = ""
	}
	episodes := int64(0)
	if row["episodeCount"] != nil {
		episodes, valid = soraniInteger(row["episodeCount"])
		if !valid || episodes < 0 || episodes > 100000 {
			episodes = 0
		}
	}
	description, _ := row["summary"].(string)
	category, _ := row["categoryName"].(string)
	if strings.TrimSpace(category) == "" {
		category = "番剧"
	}
	tags := soraniStrings(row["tagList"])
	if tags == nil {
		tags = soraniStrings(row["categoryTags"])
	}
	if len(tags) > 12 {
		tags = tags[:12]
	}
	score := ""
	if value, valid := soraniInteger(row["bangumiRating"]); valid && value > 0 && value <= 100 {
		score = strconv.FormatInt(value, 10)
	} else if value, valid := soraniInteger(row["score"]); valid && value > 0 && value <= 10 {
		score = strconv.FormatInt(value, 10)
	}
	remark, _ := row["statusText"].(string)
	if strings.TrimSpace(remark) == "" {
		remark, _ = row["latestEpisodeLabel"].(string)
	}
	return Drama{
		ID: providerDramaID(sourceSorani, sourceID), Source: sourceSorani, SourceID: sourceID,
		Title: truncate(title, 256), Name: truncate(title, 256), Desc: truncate(description, 12000), Intro: truncate(description, 12000),
		Cover: cover, CoverURL: cover, TotalEpisode: int(episodes), EpisodeCount: int(episodes),
		Category: truncate(category, 48), ChannelName: "青空次元", Tags: tags, Remark: truncate(remark, 48), Score: score,
	}, nil
}

func (d *Downloader) soraniGet(ctx context.Context, route string, query url.Values, limit int64) (any, error) {
	address := soraniAPIBaseURL + route
	if len(query) > 0 {
		address += "?" + query.Encode()
	}
	body, err := d.fetchProviderText(ctx, address, soraniSiteReferer)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errors.New("青空次元返回的数据过大")
	}
	var envelope struct {
		Code int             `json:"code"`
		Msg  string          `json:"msg"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &envelope); err != nil {
		return nil, errors.New("青空次元返回的数据格式无效")
	}
	if envelope.Code != 200 {
		message := strings.TrimSpace(envelope.Msg)
		if message == "" {
			message = "接口返回异常"
		}
		return nil, fmt.Errorf("青空次元接口错误：%s", message)
	}
	if len(envelope.Data) == 0 || string(envelope.Data) == "null" {
		return nil, errors.New("青空次元接口未返回数据")
	}
	var decoded any
	decoder := json.NewDecoder(strings.NewReader(string(envelope.Data)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, errors.New("青空次元返回的数据格式无效")
	}
	return decoded, nil
}

func (d *Downloader) fetchSoraniCategories(ctx context.Context) ([]nativeCategory, error) {
	data, err := d.soraniGet(ctx, "/api/category/tree", nil, 1<<20)
	if err != nil {
		return nil, err
	}
	rows, valid := data.([]any)
	if !valid || len(rows) > 100 {
		return nil, errors.New("青空次元分类数据格式无效")
	}
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, entry := range rows {
		row, _ := entry.(map[string]any)
		kind, _ := row["type"].(string)
		if kind != "video" {
			continue
		}
		id, valid := soraniInteger(row["id"])
		if !valid || id <= 0 {
			return nil, errors.New("青空次元分类数据包含无效条目")
		}
		name, _ := row["name"].(string)
		name = strings.TrimSpace(name)
		key := strconv.FormatInt(id, 10)
		if name == "" || len([]rune(name)) > 24 || seen[key] {
			return nil, errors.New("青空次元分类数据包含无效或重复条目")
		}
		seen[key] = true
		categories = append(categories, nativeCategory{ID: key, Name: name})
	}
	if len(categories) == 0 {
		return nil, errors.New("青空次元暂未返回内容分类，请稍后重试")
	}
	return categories, nil
}

func (d *Downloader) fetchSoraniCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 1000000 || len(query) > 512 {
		return nil, false, errors.New("青空次元目录查询参数无效")
	}
	values := url.Values{"page": {strconv.Itoa(page)}, "pageSize": {strconv.Itoa(soraniPageSize)}}
	switch {
	case query != "":
		values.Set("keyword", query)
	case category != "":
		if !validSoraniID(category) {
			return nil, false, errors.New("青空次元内容分类无效")
		}
		values.Set("categoryId", category)
	}
	data, err := d.soraniGet(ctx, "/api/video", values, 12<<20)
	if err != nil {
		return nil, false, err
	}
	row, valid := data.(map[string]any)
	if !valid {
		return nil, false, errors.New("青空次元目录数据格式无效")
	}
	rows, valid := row["records"].([]any)
	if !valid || len(rows) > soraniMaxRows {
		return nil, false, errors.New("青空次元目录数据格式无效")
	}
	totalPages := page
	if row["pages"] != nil {
		if value, valid := soraniInteger(row["pages"]); valid && value >= 1 && value <= 1000000 {
			totalPages = int(value)
		}
	}
	if row["current"] != nil {
		if value, valid := soraniInteger(row["current"]); valid && value >= 1 && value != int64(page) {
			return nil, false, errors.New("青空次元返回的页码与请求不符")
		}
	}
	items := make([]Drama, 0, len(rows))
	seen := map[string]bool{}
	for _, entry := range rows {
		value, _ := entry.(map[string]any)
		drama, err := soraniDramaFromMap(value)
		if err != nil {
			return nil, false, err
		}
		if seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		items = append(items, drama)
	}
	return items, page < totalPages && len(items) > 0, nil
}

type soraniEpisode struct {
	id    string
	order int
	title string
}

func (d *Downloader) fetchSoraniDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if !validSoraniID(sourceID) {
		return Drama{}, nil, errors.New("青空次元剧集地址无效")
	}
	data, err := d.soraniGet(ctx, "/api/video/"+sourceID, nil, 8<<20)
	if err != nil {
		return Drama{}, nil, err
	}
	row, valid := data.(map[string]any)
	if !valid {
		return Drama{}, nil, errors.New("青空次元详情数据格式无效")
	}
	drama, err := soraniDramaFromMap(row)
	if err != nil {
		return Drama{}, nil, err
	}
	if drama.SourceID != sourceID {
		return Drama{}, nil, errors.New("青空次元详情与请求剧集不符")
	}
	rows, valid := row["episodes"].([]any)
	if !valid || len(rows) > soraniMaxEpisodes {
		return Drama{}, nil, errors.New("青空次元分集目录格式无效")
	}
	var parsed []soraniEpisode
	seen := map[string]bool{}
	for _, entry := range rows {
		episode, _ := entry.(map[string]any)
		if enable, ok := episode["enable"].(bool); ok && !enable {
			continue
		}
		id, valid := soraniInteger(episode["episodeId"])
		if !valid || id <= 0 {
			return Drama{}, nil, errors.New("青空次元分集目录包含无效分集")
		}
		key := strconv.FormatInt(id, 10)
		if seen[key] {
			return Drama{}, nil, errors.New("青空次元分集目录包含重复分集，请刷新详情")
		}
		seen[key] = true
		order := len(parsed) + 1
		if value, valid := soraniInteger(episode["episodeOrder"]); valid && value > 0 && value <= 100000 {
			order = int(value)
		}
		title, _ := episode["title"].(string)
		parsed = append(parsed, soraniEpisode{id: key, order: order, title: strings.TrimSpace(title)})
	}
	if len(parsed) == 0 {
		return Drama{}, nil, errors.New("该剧暂时没有可播放的分集")
	}
	sort.SliceStable(parsed, func(i, j int) bool {
		if parsed[i].order != parsed[j].order {
			return parsed[i].order < parsed[j].order
		}
		return parsed[i].id < parsed[j].id
	})
	chapters := make([]Chapter, 0, len(parsed))
	seenNumbers := map[int]bool{}
	for index, episode := range parsed {
		number := episode.order
		if number == 0 {
			number = index + 1
		}
		if seenNumbers[number] {
			return Drama{}, nil, errors.New("青空次元分集编号重复，请刷新详情")
		}
		seenNumbers[number] = true
		chapters = append(chapters, Chapter{
			ID: providerChapterID(sourceSorani, sourceID, episode.id), Source: sourceSorani,
			Title: fmt.Sprintf("第 %d 集", number), CurrentEpisode: json.RawMessage(strconv.Itoa(number)),
			VideoURL: soraniChapterPfx + episode.id, Referer: soraniSiteReferer,
		})
	}
	return drama, chapters, nil
}

func (d *Downloader) resolveSoraniMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	prefix := providerChapterID(sourceSorani, sourceID, "")
	if !valid || source != sourceSorani || !validSoraniID(sourceID) || !strings.HasPrefix(task.Chapter.ID, prefix) {
		return providerMedia{}, errors.New("青空次元播放分集信息无效，请刷新详情")
	}
	episodeID := strings.TrimPrefix(task.Chapter.ID, prefix)
	if !validSoraniID(episodeID) {
		return providerMedia{}, errors.New("青空次元分集地址无效")
	}
	values := url.Values{"lineCode": {soraniDefaultLine}}
	data, err := d.soraniGet(ctx, "/api/video/episode/"+episodeID+"/play", values, 256<<10)
	if err != nil {
		return providerMedia{}, err
	}
	row, valid := data.(map[string]any)
	if !valid {
		return providerMedia{}, errors.New("青空次元播放信息格式无效")
	}
	if canPlay, ok := row["canPlay"].(bool); ok && !canPlay {
		message, _ := row["message"].(string)
		message = strings.TrimSpace(message)
		if message == "" {
			message = "该分集暂不可播放"
		}
		return providerMedia{}, fmt.Errorf("青空次元：%s", message)
	}
	address, _ := row["playUrl"].(string)
	address = strings.TrimSpace(address)
	if address == "" || !isProviderHTTPMediaURL(address) {
		return providerMedia{}, errors.New("青空次元未返回有效播放地址，请重试")
	}
	media := providerMedia{URL: address, Referer: soraniSiteReferer}
	parsed, _ := url.Parse(address)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(providerMediaContext(ctx, media.credentials), media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取青空次元播放列表失败：%w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, errors.New("青空次元未返回有效播放列表，请重试")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}
