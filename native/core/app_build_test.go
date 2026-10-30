package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestNativeBuildAuthorization(t *testing.T) {
	cases := []struct {
		source  string
		allowed bool
	}{
		{sourceHongguo, true},
		{sourceHanxiaoquan, buildAllSources == "true"},
		{sourceNetflixgc, buildAllSources == "true"},
		// 0.7.78 起青空次元与 LIBVIO 已从站源清单移除，任何构建都不再放行。
		{"sorani", false},
		{"libvio", false},
		{"unknown", false},
	}
	for _, testCase := range cases {
		for _, action := range []string{"catalog", "cached", "sourceStatus", "sourceJob", "cancelSourceJob", "detail", "cover", "resolve", "enqueueDownloads", "localPlayback"} {
			input := nativeInput{Action: action, Source: testCase.source, Drama: nativeDrama{ID: testCase.source + ":123", Source: testCase.source}}
			err := nativeAuthorizeInput(input)
			if (err == nil) != testCase.allowed {
				t.Fatalf("%s %s: allowed=%v, error=%v", action, testCase.source, testCase.allowed, err)
			}
		}
	}
	for _, input := range []nativeInput{
		{Action: "resolve", Drama: nativeDrama{ID: "hanxiaoquan:123", Source: sourceHongguo}},
		{Action: "resolve", Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}, Chapter: Chapter{Source: sourceNetflixgc}},
		{Action: "resolve", Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}, Chapter: Chapter{ID: "netflixgc:123:1"}},
	} {
		if !errors.Is(nativeAuthorizeInput(input), errNativeBuildSource) {
			t.Fatal("mismatched source passed native authorization")
		}
	}
	manager := downloadTestManager(t)
	input := downloadTestInput(1)
	input.Entries[0].Chapter.Source = sourceNetflixgc
	if _, err := manager.enqueue(input); !errors.Is(err, errNativeBuildSource) {
		t.Fatalf("mismatched download source accepted: %v", err)
	}
}

func TestNativeBuildPreservesEditionRecordsAndDropsRemovedSources(t *testing.T) {
	manager := downloadTestManager(t)
	// 三条记录：当前版本可用（红果）、已知但本版本未启用（韩小圈）、
	// 站源已从应用中移除（huangdou）。
	records := []*nativeDownloadRecord{}
	for index, source := range []string{sourceHongguo, sourceHanxiaoquan, "huangdou"} {
		drama := nativeDrama{ID: source + ":123", Source: source, Title: "合成下载"}
		record := &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
			ID: nativeDownloadID(drama.ID, 1), Drama: drama, Index: 1,
			Chapter: Chapter{ID: "1", Source: source, CurrentEpisode: json.RawMessage("1")}, State: "queued", Created: int64(index),
		}}
		records = append(records, record)
	}
	data, err := json.Marshal(records)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(manager.root, "index.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	jobs, err := reopened.snapshot()
	if err != nil || len(jobs) != 1 {
		t.Fatalf("wrong visible downloads: %v, %v", jobs, err)
	}
	// 已移除站源的记录被丢弃，本版本未启用的已知站源记录仍留在内存与磁盘上。
	if len(reopened.jobs) != len(records)-1 {
		t.Fatalf("wrong kept downloads after source removal: %d", len(reopened.jobs))
	}
	if reopened.jobs[records[2].ID] != nil {
		t.Fatal("removed source download survived")
	}
	started := make(chan string, 4)
	reopened.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		started <- job.Drama.Source
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}
	if err := reopened.control("", "resumeAll"); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for index := 0; index < 1; index++ {
		select {
		case source := <-started:
			seen[source] = true
		case <-time.After(5 * time.Second):
			t.Fatal("allowed download did not start")
		}
	}
	if !seen[sourceHongguo] {
		t.Fatalf("wrong sources scheduled: %v", seen)
	}
	{
		reopened.mu.Lock()
		active := len(reopened.active)
		reopened.mu.Unlock()
		if active != 1 {
			t.Fatal("foreign-source task was scheduled")
		}
		foreign := records[1]
		if err := reopened.control(foreign.ID, "remove"); !errors.Is(err, errNativeBuildSource) {
			t.Fatalf("foreign task could be removed: %v", err)
		}
		if _, _, err := reopened.localPlan(foreign.Drama.ID, 1); !errors.Is(err, errNativeBuildSource) {
			t.Fatalf("foreign task could be played: %v", err)
		}
	}
	if err := reopened.control("", "pauseAll"); err != nil {
		t.Fatal(err)
	}
	reopened.close()
	{
		// 载入时会对剧集做一次 migrateNativeDrama，比较前先对齐这份迁移结果。
		expected := *records[1]
		expected.Drama = migrateNativeDrama(expected.Drama)
		if !reflect.DeepEqual(reopened.jobs[records[1].ID], &expected) {
			t.Fatal("hidden download changed during bulk operations")
		}
		stored, err := os.ReadFile(filepath.Join(reopened.root, "index.json"))
		if err != nil {
			t.Fatal(err)
		}
		var saved []nativeDownloadRecord
		if err := json.Unmarshal(stored, &saved); err != nil || len(saved) != len(records)-1 {
			t.Fatalf("saved hidden downloads lost: %v", err)
		}
		for _, record := range saved {
			if record.Drama.Source == "huangdou" {
				t.Fatal("removed source download was written back")
			}
		}
	}
}
