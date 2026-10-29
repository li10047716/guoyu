package core

import (
	"context"
	"errors"
	"strings"
)

type nativeCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			if category == genre.key {
				return true
			}
		}
	case sourceSorani:
		return validSoraniID(category)
	case sourceHanxiaoquan:
		return validHanxiaoquanCategory(category)
	case sourceLibvio:
		return validLibvioCategory(category)
	case sourceNetflixgc:
		return validNetflixgcCategory(category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	all := []nativeCategory{{Name: "全部"}}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			all = append(all, nativeCategory{ID: genre.key, Name: genre.name})
		}
		return all, nil
	}
	engine.mu.Lock()
	cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
	engine.mu.Unlock()
	if len(cached) > 1 && !force {
		return cached, nil
	}
	d := engine.downloader
	var err error
	switch source {
	case sourceSorani:
		var categories []nativeCategory
		categories, err = d.fetchSoraniCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceHanxiaoquan:
		var categories []nativeCategory
		categories, err = d.fetchHanxiaoquanCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceLibvio:
		var categories []nativeCategory
		categories, err = d.fetchLibvioCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceNetflixgc:
		var categories []nativeCategory
		categories, err = d.fetchNetflixgcCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	default:
		return nil, errors.New("请选择有效站源")
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.mu.Lock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
	engine.mu.Unlock()
	return all, nil
}
