package core

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const nativeCatalogTTL = 15 * time.Minute

type nativeCatalogState struct {
	UpdatedAt time.Time `json:"updatedAt"`
	Page      int       `json:"page"`
	HasMore   bool      `json:"hasMore"`
	Warning   string    `json:"warning,omitempty"`
}

type nativeCatalogDisk struct {
	Version         int                                  `json:"version"`
	Catalogs        map[string][]nativeDrama             `json:"catalogs"`
	States          map[string]nativeCatalogState        `json:"states"`
	Categories      map[string][]nativeCategory          `json:"categories,omitempty"`
	HongguoApp      *hongguoCatalogState                 `json:"hongguoApp,omitempty"`
	Recommendations map[string]nativeRecommendationState `json:"recommendations,omitempty"`
}

func (engine *nativeEngine) loadCatalogCache() {
	file, err := os.Open(filepath.Join(engine.directory, "catalogs.json"))
	if err != nil {
		return
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, nativeCatalogMaxBytes+1))
	if err != nil || len(body) > nativeCatalogMaxBytes {
		return
	}
	var disk nativeCatalogDisk
	if json.Unmarshal(body, &disk) == nil && (disk.Version == 2 || disk.Version == 3) {
		if disk.Catalogs != nil {
			engine.catalogs = disk.Catalogs
			for _, items := range engine.catalogs {
				for index := range items {
					items[index] = migrateNativeDrama(items[index])
				}
			}
		}
		if disk.States != nil {
			engine.catalogStates = disk.States
		}
		engine.categoryOptions = disk.Categories
		engine.recommendations = make(map[string]nativeRecommendationState)
		for genre, state := range disk.Recommendations {
			if genre == state.Query.Genre && state.Query.validate() == nil && state.Page > 0 {
				engine.recommendations[genre] = state
			}
		}
		engine.hongguoCatalog = cloneHongguoCatalogState(disk.HongguoApp)
		if engine.downloader != nil {
			engine.downloader.restoreHongguoCatalog(disk.HongguoApp)
			if disk.HongguoApp != nil {
				engine.hongguoCatalog = engine.downloader.hongguoCatalogSnapshot()
			}
		}
		return
	}
	var legacy map[string][]nativeDrama
	if json.Unmarshal(body, &legacy) == nil && legacy != nil {
		engine.catalogs = legacy
		for _, items := range engine.catalogs {
			for index := range items {
				items[index] = migrateNativeDrama(items[index])
			}
		}
	}
}

func migrateNativeDrama(drama nativeDrama) nativeDrama {
	drama.MetadataSchema = 1
	return drama
}

func catalogKeySource(key string) string {
	if index := strings.IndexByte(key, '|'); index >= 0 {
		key = key[:index]
	}
	return canonicalProviderSource(key)
}

func (engine *nativeEngine) purgeRemovedSourceCaches() {
	dropped := false
	func() {
		engine.mu.Lock()
		defer engine.mu.Unlock()
		for key := range engine.catalogs {
			if !isSupportedProviderSource(catalogKeySource(key)) {
				delete(engine.catalogs, key)
				dropped = true
			}
		}
		for key := range engine.catalogStates {
			if !isSupportedProviderSource(catalogKeySource(key)) {
				delete(engine.catalogStates, key)
				dropped = true
			}
		}
		for key := range engine.categoryOptions {
			if !isSupportedProviderSource(key) {
				delete(engine.categoryOptions, key)
				dropped = true
			}
		}
		if dropped {
			engine.writeCatalogDiskLocked()
		}
	}()
	engine.purgeRemovedSourceFiles()
}

// purgeRemovedSourceFiles 清理已移除站源遗留在数据目录里的其它文件。
//
// 0.7.48 移除了黄豆 / 黄剧 / 黄果剧场 / 黄果 AI / 黄果旧版：它们的状态记录
// （sources.json）、会话缓存（huangguo-session.json）和详情缓存
// （detail_cache/details.json）已经没有任何代码会再读取，留在磁盘上既不占地方
// 也没有意义，还会让"这个站源还在"看起来像没删干净。
func (engine *nativeEngine) purgeRemovedSourceFiles() {
	directory := engine.directory
	if directory == "" {
		return
	}
	// 站源任务记录：丢掉已移除站源的条目并回写（与 loadSourceRecords 的过滤保持一致）。
	recordsPath := filepath.Join(directory, "sources.json")
	if body, err := os.ReadFile(recordsPath); err == nil && len(body) <= nativeSourceMaxBytes {
		var records map[string]json.RawMessage
		if json.Unmarshal(body, &records) == nil {
			dropped := false
			for source := range records {
				if !isSupportedProviderSource(source) {
					delete(records, source)
					dropped = true
				}
			}
			if dropped {
				if body, err = json.Marshal(records); err == nil {
					_ = writeNativeCacheFile(recordsPath, body)
				}
			}
		}
	}
	// 黄果会话缓存：整个文件都是已移除站源的产物，直接删除。
	_ = os.Remove(filepath.Join(directory, "huangguo-session.json"))
	// 详情缓存：条目 key 形如 "<source>|<剧集 ID>"，按前缀丢掉已移除站源。
	detailPath := filepath.Join(directory, "detail_cache", "details.json")
	if body, err := os.ReadFile(detailPath); err == nil && len(body) <= 8<<20 {
		var document map[string]json.RawMessage
		if json.Unmarshal(body, &document) == nil {
			var entries map[string]json.RawMessage
			if raw, found := document["entries"]; found && json.Unmarshal(raw, &entries) == nil {
				dropped := false
				for key := range entries {
					if !isSupportedProviderSource(catalogKeySource(key)) {
						delete(entries, key)
						dropped = true
					}
				}
				if dropped {
					if raw, err = json.Marshal(entries); err == nil {
						document["entries"] = raw
						if body, err = json.Marshal(document); err == nil {
							_ = writeNativeCacheFile(detailPath, body)
						}
					}
				}
			}
		}
	}
}

func (engine *nativeEngine) nativeCached(source string) nativeCatalogResult {
	source = canonicalProviderSource(source)
	engine.mu.Lock()
	defer engine.mu.Unlock()
	items := append([]nativeDrama{}, engine.catalogs[source]...)
	state, found := engine.catalogStates[source]
	age := time.Since(state.UpdatedAt)
	result := nativeCatalogResult{
		Items: items, Page: max(1, state.Page), HasMore: !found || state.HasMore,
		Fresh:   len(items) > 0 && state.Warning == "" && !state.UpdatedAt.IsZero() && age >= 0 && age < nativeCatalogTTL,
		Warning: state.Warning,
	}
	if engine.catalogSaveError != nil {
		result.Warning = joinNativeWarnings(result.Warning, engine.catalogSaveError.Error())
		result.saveError = engine.catalogSaveError
		result.Fresh, result.HasMore = false, true
	}
	return result
}

func mergeNativeCatalog(first, second []nativeDrama) []nativeDrama {
	items := append([]nativeDrama{}, first...)
	indices := make(map[string]int, len(items))
	for index, item := range items {
		indices[item.ID] = index
	}
	for _, item := range second {
		if index, found := indices[item.ID]; found {
			items[index] = mergeNativeDrama(items[index], item)
		} else {
			indices[item.ID] = len(items)
			items = append(items, item)
		}
	}
	return items
}

func mergeNativeDrama(previous, fresh nativeDrama) nativeDrama {
	previous, fresh = migrateNativeDrama(previous), migrateNativeDrama(fresh)
	if previous.ID != "" && fresh.ID != previous.ID {
		return fresh
	}
	if fresh.Source == "" {
		fresh.Source = previous.Source
	}
	if fresh.SourceID == "" {
		fresh.SourceID = previous.SourceID
	}
	if fresh.Title == "" || fresh.Title == "短剧" {
		fresh.Title = previous.Title
	}
	if fresh.Description == "" {
		fresh.Description = previous.Description
	}
	if fresh.Cover == "" {
		fresh.Cover = previous.Cover
	}
	if fresh.Category == "" || nativeGenericCategory(fresh.Category) && previous.Category != "" && !nativeGenericCategory(previous.Category) {
		fresh.Category = previous.Category
	}
	if fresh.Episodes == 0 {
		fresh.Episodes = previous.Episodes
	}
	if fresh.VIP == nil {
		fresh.VIP = previous.VIP
	}
	if fresh.Heat == "" {
		fresh.Heat = previous.Heat
	}
	if fresh.Views == "" {
		fresh.Views = previous.Views
	}
	if fresh.OnlineDate == "" {
		fresh.OnlineDate = previous.OnlineDate
	}
	if len(fresh.Tags) == 0 {
		fresh.Tags = previous.Tags
	}
	if fresh.ReleaseStatus == "" || fresh.ReleaseStatus == "unknown" {
		fresh.ReleaseStatus = previous.ReleaseStatus
	}
	return fresh
}

func nativeGenericCategory(category string) bool {
	switch category {
	case "短剧", "真人剧", "漫剧", "AI剧", "AI 剧", "AI短剧", "AI 短剧", "AI漫剧", "AI 漫剧":
		return true
	}
	return false
}

func (engine *nativeEngine) saveCatalogCache(source string, result *nativeCatalogResult) error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	previous := engine.catalogs[source]
	state := engine.catalogStates[source]
	var items []nativeDrama
	if result.Page == 1 {
		items = result.Items
		if len(previous) > 0 {
			old := make(map[string]nativeDrama, len(previous))
			for _, item := range previous {
				old[item.ID] = item
			}
			for index, item := range items {
				items[index] = mergeNativeDrama(old[item.ID], item)
			}
			fresh := make(map[string]bool, len(items))
			for _, item := range items {
				fresh[item.ID] = true
			}
			for _, item := range previous {
				if !fresh[item.ID] {
					items = append(items, item)
				}
			}
			result.Items = items
			result.Page = max(1, state.Page)
			if source != sourceHongguo && state.Page > 1 {
				result.HasMore = state.HasMore
			}
		}
	} else {
		items = mergeNativeCatalog(previous, result.Items)
		if result.Page < state.Page {
			result.Page, result.HasMore = state.Page, state.HasMore
		}
	}
	engine.catalogs[source] = items
	if result.hongguo != nil {
		engine.hongguoCatalog = cloneHongguoCatalogState(result.hongguo)
	}
	if result.Warning != "" {
		result.Page = max(1, state.Page)
		result.HasMore = true
	}
	state.Page, state.HasMore = result.Page, result.HasMore
	state.Warning = result.Warning
	if result.Warning == "" {
		state.UpdatedAt = time.Now()
		result.Fresh = true
	}
	engine.catalogStates[source] = state
	if base, _, categorized := strings.Cut(source, "|"); categorized {
		engine.catalogs[base] = mergeNativeCatalog(engine.catalogs[base], items)
	}
	err := engine.writeCatalogDiskLocked()
	result.saveError = err
	if err != nil {
		result.Warning = joinNativeWarnings(result.Warning, err.Error())
		result.Fresh, result.HasMore = false, true
	}
	return err
}

func (engine *nativeEngine) writeCatalogDiskLocked() error {
	body, err := json.Marshal(nativeCatalogDisk{Version: 3, Catalogs: engine.catalogs, States: engine.catalogStates, Categories: engine.categoryOptions, HongguoApp: engine.hongguoCatalog, Recommendations: engine.recommendations})
	if err == nil && len(body) > nativeCatalogMaxBytes {
		err = errNativeCatalogLimit
	}
	if err == nil {
		err = writeNativeCacheFile(filepath.Join(engine.directory, "catalogs.json"), body)
	}
	engine.catalogSaveError = nativeSaveError("剧库", err)
	if err == nil {
		engine.finishCatalogSaveLocked()
	} else {
		engine.markCatalogSavePendingLocked()
	}
	return engine.catalogSaveError
}

func writeNativeCacheFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".cache-write-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	_, writeErr := temporary.Write(data)
	if writeErr == nil {
		writeErr = temporary.Sync()
	}
	closeErr := temporary.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporary.Name(), path)
}

func (engine *nativeEngine) saveDetailMetadata(drama nativeDrama) error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	changed := false
	for _, items := range engine.catalogs {
		for index := range items {
			if items[index].ID == drama.ID {
				items[index] = mergeNativeDrama(items[index], drama)
				changed = true
			}
		}
	}
	if changed {
		return engine.writeCatalogDiskLocked()
	}
	return nil
}
