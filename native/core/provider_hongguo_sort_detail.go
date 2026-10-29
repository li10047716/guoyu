package core

import "errors"

func parseHongguoSortDetail(body, id string) (Drama, error) {
	row := nestedMap(routerLoaderMap(parseRouterData(body), "detail_page", "detail_"), "seriesDetail")
	if mapString(row, "series_id", "series_id_str") != id || mapString(row, "series_name", "series_title") == "" {
		return Drama{}, errors.New("红果网页详情与请求剧集不符")
	}
	patch := hongguoDramaFromAny(row, "")
	patch.Title = mapString(row, "series_name", "series_title")
	patch.Name = patch.Title
	patch.OnlineDate = providerTimestampDate(mapString(row, "first_visible_time"))
	if cover := hongguoCoverAddress(mapString(row, "series_cover", "cover")); cover != "" {
		patch.Cover, patch.CoverURL = cover, cover
	}
	return patch, nil
}
