// 书源 JS 规则批量探测。
//
//	go run ./probe -dir /tmp/yc [关键词]
//
// 对目录下每个书源跑一遍「jsLib + searchUrl 脚本」，统计能跑出请求的多寡。
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"duanjuapp/native/core"
)

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "用法：go run ./probe <书源.json> [关键词] [页码]")
		fmt.Fprintln(os.Stderr, "      go run ./probe -dir <目录> [关键词]")
		os.Exit(64)
	}

	if args[0] == "-dir" {
		dir := args[1]
		keyword := "诡秘之主"
		if len(args) > 2 {
			keyword = args[2]
		}
		runDir(dir, keyword)
		return
	}

	keyword := "诡秘之主"
	if len(args) > 1 {
		keyword = args[1]
	}
	page := 1
	if len(args) > 2 {
		page, _ = strconv.Atoi(args[2])
	}
	for _, source := range loadSources(args[0]) {
		probeOne(source, keyword, page, true)
	}
}

type sourceRow struct {
	Name      string
	URL       string
	SearchURL string
	JsLib     string
	Header    string
}

func loadSources(path string) []sourceRow {
	raw, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取失败：", err)
		return nil
	}
	var rows []map[string]any
	if err := json.Unmarshal(raw, &rows); err != nil {
		var single map[string]any
		if err2 := json.Unmarshal(raw, &single); err2 != nil {
			fmt.Fprintln(os.Stderr, "解析失败：", err)
			return nil
		}
		rows = []map[string]any{single}
	}
	out := make([]sourceRow, 0, len(rows))
	for _, row := range rows {
		name, _ := row["bookSourceName"].(string)
		address, _ := row["bookSourceUrl"].(string)
		searchURL, _ := row["searchUrl"].(string)
		jsLib, _ := row["jsLib"].(string)
		header, _ := row["header"].(string)
		out = append(out, sourceRow{Name: name, URL: address, SearchURL: searchURL, JsLib: jsLib, Header: header})
	}
	return out
}

func runDir(dir, keyword string) {
	entries, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "目录读取失败：", err)
		return
	}
	sort.Strings(entries)
	okCount, jsCount, plainCount, failCount := 0, 0, 0, 0
	for _, entry := range entries {
		for _, source := range loadSources(entry) {
			trimmed := strings.TrimSpace(source.SearchURL)
			if !strings.HasPrefix(trimmed, "@js:") {
				plainCount++
				continue
			}
			jsCount++
			if probeOne(source, keyword, 1, false) {
				okCount++
			} else {
				failCount++
			}
		}
	}
	fmt.Printf("\n合计：searchUrl 为 JS 的 %d 个，跑通 %d 个，失败 %d 个；非 JS 的 %d 个\n",
		jsCount, okCount, failCount, plainCount)
}

func probeOne(source sourceRow, keyword string, page int, verbose bool) bool {
	trimmed := strings.TrimSpace(source.SearchURL)
	if !strings.HasPrefix(trimmed, "@js:") {
		if verbose {
			fmt.Printf("· %s：searchUrl 不是 @js:（%s）\n", source.Name, clip(trimmed, 60))
		}
		return false
	}
	code := strings.TrimSpace(strings.TrimPrefix(trimmed, "@js:"))
	response := core.EvalLegadoScript(core.LegadoJsRequest{
		Code:    code,
		JsLib:   source.JsLib,
		Key:     keyword,
		Page:    page,
		BaseURL: source.URL,
		Source: core.LegadoJsSource{
			Key:    source.URL,
			Name:   source.Name,
			URL:    source.URL,
			Header: source.Header,
		},
	})
	if !response.OK {
		fmt.Printf("✗ %-22s %s\n", clip(source.Name, 22), clip(response.Error, 90))
		return false
	}
	fmt.Printf("✓ %-22s %s\n", clip(source.Name, 22), clip(response.Value, 100))
	return true
}

func clip(text string, limit int) string {
	flat := strings.Join(strings.Fields(text), " ")
	runes := []rune(flat)
	if len(runes) > limit {
		return string(runes[:limit]) + "…"
	}
	return flat
}
