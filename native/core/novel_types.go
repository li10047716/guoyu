package core

// 小说数据结构（本地书籍与自定义书源共用）。
//
// 0.7.85：内置笔趣阁站源整体移除，这些类型原本定义在 app_novels.go 里，
// 现在只剩本地导入的书在用（app_novels_local.go），单独放到这里。

import (
	"html"
	"regexp"
	"strings"
)

// Novel 是列表/详情共用的书籍信息。
type Novel struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Title       string `json:"title"`
	Author      string `json:"author"`
	Category    string `json:"category"`
	Status      string `json:"status"`
	Description string `json:"description"`
	Cover       string `json:"cover"`
	Latest      string `json:"latest"`
	Chapters    int    `json:"chapters"`
}

// NovelChapterItem 是目录里的一章。
type NovelChapterItem struct {
	Index int    `json:"index"`
	ID    string `json:"id"`
	Title string `json:"title"`
}

// NovelBook 是详情结果（书籍信息 + 目录）。
type NovelBook struct {
	Novel
	ChapterList []NovelChapterItem `json:"chapterList"`
}

// NovelText 是一章正文（已清洗，按段落返回）。
type NovelText struct {
	BookID     string   `json:"bookId"`
	ChapterID  string   `json:"chapterId"`
	Title      string   `json:"title"`
	Paragraphs []string `json:"paragraphs"`
}

var novelSpaceRe = regexp.MustCompile(`\s+`)

// cleanNovelInline 处理单行文本（书名 / 作者 / 简介等）：解 HTML 实体、压空白。
func cleanNovelInline(value string) string {
	value = html.UnescapeString(value)
	value = strings.ReplaceAll(value, "\u00a0", " ")
	return strings.TrimSpace(novelSpaceRe.ReplaceAllString(value, " "))
}
