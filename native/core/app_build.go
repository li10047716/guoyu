package core

import "errors"

var buildAllSources = "false"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
	return source == sourceHongguo || buildAllSources == "true" && isSupportedProviderSource(source)
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

// nativeKnownDrama 判断剧集所属站源是否仍在本应用的站源清单里。
//
// 与 nativeDramaAvailable 的区别：它只看站源**是否还存在**，不看当前版本**是否启用**。
// 单站源版本里其它站源的剧集不可用，但仍属于已知站源，本地记录应当保留；
// 只有清单里已被移除的站源（如历史上的黄豆 / 黄剧 / 黄果系列）才彻底丢弃。
func nativeKnownDrama(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && isSupportedProviderSource(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

// nativeKnownDownload 判断下载记录是否属于仍存在的站源。
func nativeKnownDownload(job nativeDownloadJob) bool {
	return nativeKnownDrama(job.Drama)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions":
		if !nativeSourceAvailable(sourceHongguo) {
			return errNativeBuildSource
		}
	case "rankings":
		board, found := findRankingBoard(input.Board)
		if !found || !nativeSourceAvailable(board.Source) {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus", "sourceJob", "cancelSourceJob":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
		if input.Action == "sourceJob" && input.Drama.ID != "" &&
			(!nativeDramaAvailable(input.Drama) || sourceFromDramaID(input.Drama.ID) != canonicalProviderSource(input.Source)) {
			return errNativeBuildSource
		}
	case "cover", "prepareCover", "detail", "metadata", "resolve", "preload", "prepareHandoff", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if (input.Action == "resolve" || input.Action == "preload" || input.Action == "prepareHandoff") && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	}
	return nil
}
