package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// 0.7.48 移除黄豆 / 黄剧 / 黄果系列站源后，数据目录里属于它们的文件与条目
// 必须一起清掉，否则升级后应用"看起来已经删了、目录里却还留着"。
func TestNativePurgesRemovedSourceFiles(t *testing.T) {
	directory := t.TempDir()
	write := func(name string, value any) {
		t.Helper()
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("sources.json", map[string]any{
		sourceHongguo: map[string]any{"operation": "update", "stage": "已完成"},
		"huangdou":    map[string]any{"operation": "update", "stage": "已完成"},
		"huangju":     map[string]any{"operation": "update", "stage": "已完成"},
		"cloudfront":  map[string]any{"operation": "update", "stage": "已完成"},
	})
	write("catalogs.json", nativeCatalogDisk{
		Version:  3,
		Catalogs: map[string][]nativeDrama{sourceHongguo: {{ID: "hongguo:1", Source: sourceHongguo}}, "huangguoai": {{ID: "huangguoai:1", Source: "huangguoai"}}},
		States:   map[string]nativeCatalogState{sourceHongguo: {Page: 1}, "huangguoai": {Page: 2}},
		Categories: map[string][]nativeCategory{
			sourceHongguo:    {{ID: "all", Name: "全部"}},
			"huangguo-video": {{ID: "all", Name: "全部"}},
		},
	})
	write("detail_cache/details.json", map[string]any{
		"entries": map[string]any{
			sourceHongguo + "|hongguo:1": map[string]any{"storedAt": 1, "raw": map[string]any{}},
			"huangdou|huangdou:2":        map[string]any{"storedAt": 1, "raw": map[string]any{}},
			"cloudfront|cloudfront:3":    map[string]any{"storedAt": 1, "raw": map[string]any{}},
		},
	})
	sessionPath := filepath.Join(directory, "huangguo-session.json")
	if err := os.WriteFile(sessionPath, []byte(`{"version":1,"scope":"synthetic"}`), 0600); err != nil {
		t.Fatal(err)
	}

	engine, err := newNativeEngine(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.downloads.close()

	var records map[string]json.RawMessage
	body, err := os.ReadFile(filepath.Join(directory, "sources.json"))
	if err != nil || json.Unmarshal(body, &records) != nil {
		t.Fatalf("read sources.json: %v", err)
	}
	for _, removed := range []string{"huangdou", "huangju", "cloudfront"} {
		if _, found := records[removed]; found {
			t.Fatalf("removed source record survived: %s", removed)
		}
	}
	if _, found := records[sourceHongguo]; !found {
		t.Fatal("kept source record was dropped")
	}

	if _, err := os.Stat(sessionPath); !os.IsNotExist(err) {
		t.Fatal("removed source session file survived")
	}

	var document struct {
		Entries map[string]json.RawMessage `json:"entries"`
	}
	body, err = os.ReadFile(filepath.Join(directory, "detail_cache", "details.json"))
	if err != nil || json.Unmarshal(body, &document) != nil {
		t.Fatalf("read details.json: %v", err)
	}
	if len(document.Entries) != 1 {
		t.Fatalf("wrong detail cache entries: %d", len(document.Entries))
	}
	if _, found := document.Entries[sourceHongguo+"|hongguo:1"]; !found {
		t.Fatal("kept detail cache entry was dropped")
	}

	if _, err := os.Stat(filepath.Join(directory, "catalogs.json")); err != nil {
		t.Fatal(err)
	}
	for _, source := range []string{"huangguoai", "huangguo-video"} {
		if _, found := engine.catalogs[source]; found {
			t.Fatalf("removed source catalog survived: %s", source)
		}
		if _, found := engine.catalogStates[source]; found {
			t.Fatalf("removed source catalog state survived: %s", source)
		}
		if _, found := engine.categoryOptions[source]; found {
			t.Fatalf("removed source category options survived: %s", source)
		}
	}
	if len(engine.catalogs[sourceHongguo]) != 1 {
		t.Fatal("kept catalog was dropped")
	}
}
