package core

// 本地书籍导入（0.7.67）。
//
// 支持两种格式：
//
//	.txt   按编码嗅探解码 → 按「第N章」正则切章
//	.epub  zip 解包 → container.xml → OPF → 按 spine 顺序取 xhtml 正文
//
// 解析结果统一落盘成一个 UTF-8 全文（<id>.txt）+ 一份章节索引
// （<id>.json，记录每章的字节区间），阅读时按偏移 ReadAt 取一章，
// 几 MB 的长篇也不会整本读进内存。
//
// 书籍 ID 取「规范化全文」的 sha1 前 12 位，所以同一本书换个文件名
// 再导入一次，落到的是同一条记录，不会堆重复。

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

// NovelSourceLocal 是本地导入书籍的站源标识。
const NovelSourceLocal = "local"

const (
	localNovelDirName  = "novel-books"
	localNovelMaxBytes = 80 << 20 // 单本上限 80MB，防手滑导入超大文件
	localNovelFallback = 3000     // 切不出章节时每 3000 字切一节
)

// localChapterEntry 是一章在全文文件里的位置。
type localChapterEntry struct {
	Index int    `json:"index"`
	Title string `json:"title"`
	Start int64  `json:"start"`
	End   int64  `json:"end"`
}

// localNovelIndex 是与全文一起落盘的章节索引。
type localNovelIndex struct {
	ID       string              `json:"id"`
	Title    string              `json:"title"`
	Author   string              `json:"author"`
	Format   string              `json:"format"`
	Chars    int                 `json:"chars"`
	Chapters []localChapterEntry `json:"chapters"`
}

var (
	// 章节标题行：必须**顶格**（正文段落通常有全角缩进），行内不出现句读
	// 标点，整行不超过 40 个字符。
	//
	// 0.7.67：早期版本允许行首空白，结果「　　第二章的正文在这里。」这种
	// 带缩进的正文行也被当成标题，一本书被切成双倍章节。
	localChapterLineRe = regexp.MustCompile(`(?m)^第[0-9一二三四五六七八九十百千万零〇两]{1,9}[章节回卷集篇部][^\r\n。，、！？；""''…（）]{0,40}$`)
	localNewlineRe     = regexp.MustCompile(`\r\n?`)
	localBlankLineRe   = regexp.MustCompile(`[ \t　]+`)
	localTagRe         = regexp.MustCompile(`(?s)<[^>]+>`)
	localBlockBreakRe  = regexp.MustCompile(`(?i)</?(p|div|br|h[1-6]|li|tr|section)\s*/?>`)
	localBodyRe        = regexp.MustCompile(`(?s)<body[^>]*>(.*?)</body>`)
	localHeadingRe     = regexp.MustCompile(`(?is)<h[1-3][^>]*>(.*?)</h[1-3]>`)
	localDcTitleRe     = regexp.MustCompile(`(?is)<dc:title[^>]*>(.*?)</dc:title>`)
	localTitleTagRe    = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	localCreatorRe     = regexp.MustCompile(`(?is)<dc:creator[^>]*>(.*?)</dc:creator>`)
	localEpubRootRe    = regexp.MustCompile(`full-path="([^"]+)"`)
	localEpubItemRe    = regexp.MustCompile(`(?s)<item\b[^>]*>`)
	localEpubAttrRe    = regexp.MustCompile(`(\w[\w:-]*)="([^"]*)"`)
	localEpubItemrefRe = regexp.MustCompile(`(?s)<itemref\b[^>]*>`)
)

// importLocalNovel 导入一个本地文件（.txt / .epub），返回书籍信息与目录。
//
// dir 由调用方传入（Flutter 的 application support 目录），
// 落盘位置是 <dir>/novel-books/<id>.{txt,json}。
func (d *Downloader) importLocalNovel(ctx context.Context, dir, path string) (NovelBook, error) {
	dir = strings.TrimSpace(dir)
	path = strings.TrimSpace(path)
	if dir == "" {
		return NovelBook{}, errors.New("缺少应用数据目录")
	}
	if path == "" {
		return NovelBook{}, errors.New("没有选择文件")
	}
	info, err := os.Stat(path)
	if err != nil {
		return NovelBook{}, fmt.Errorf("读不到这个文件：%w", err)
	}
	if info.IsDir() {
		return NovelBook{}, errors.New("请选择一个书籍文件")
	}
	if info.Size() > localNovelMaxBytes {
		return NovelBook{}, errors.New("文件太大了，暂时只支持 80MB 以内的书")
	}
	if err := ctx.Err(); err != nil {
		return NovelBook{}, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return NovelBook{}, fmt.Errorf("读取文件失败：%w", err)
	}
	if len(raw) == 0 {
		return NovelBook{}, errors.New("这个文件是空的")
	}

	fallbackTitle := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	format := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))

	var (
		text     string
		title    string
		author   string
		chapters []localChapterEntry
	)
	// epub 本质是 zip（PK\x03\x04），扩展名不可靠时也能认出来。
	isZip := len(raw) > 4 && raw[0] == 'P' && raw[1] == 'K' && raw[2] == 3 && raw[3] == 4
	if format == "epub" || (isZip && format != "txt") {
		text, title, author, chapters, err = parseLocalEpub(raw)
		if err != nil {
			return NovelBook{}, err
		}
		format = "epub"
	} else {
		text, err = decodeNovelBytes(raw)
		if err != nil {
			return NovelBook{}, err
		}
		text, chapters = splitLocalNovelText(text)
		format = "txt"
	}
	text = localNewlineRe.ReplaceAllString(text, "\n")
	if strings.TrimSpace(text) == "" {
		return NovelBook{}, errors.New("没有解析出正文，可能不是纯文本小说")
	}
	if title == "" {
		title = fallbackTitle
	}
	if len(chapters) == 0 {
		return NovelBook{}, errors.New("这本书切不出章节，暂时读不了")
	}

	// 书籍 ID 用正文内容算，重复导入会落到同一条记录。
	sum := sha1.Sum([]byte(text))
	id := hex.EncodeToString(sum[:])[:12]

	target := filepath.Join(dir, localNovelDirName)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return NovelBook{}, fmt.Errorf("创建书籍目录失败：%w", err)
	}
	if err := os.WriteFile(filepath.Join(target, id+".txt"), []byte(text), 0o644); err != nil {
		return NovelBook{}, fmt.Errorf("写入书籍文件失败：%w", err)
	}
	index := localNovelIndex{
		ID:       id,
		Title:    title,
		Author:   author,
		Format:   format,
		Chars:    utf8.RuneCountInString(text),
		Chapters: chapters,
	}
	payload, err := json.Marshal(index)
	if err != nil {
		return NovelBook{}, err
	}
	if err := os.WriteFile(filepath.Join(target, id+".json"), payload, 0o644); err != nil {
		return NovelBook{}, fmt.Errorf("写入目录索引失败：%w", err)
	}

	book := NovelBook{
		Novel: Novel{
			ID:       id,
			Source:   NovelSourceLocal,
			Title:    title,
			Author:   author,
			Category: "本地",
			Status:   "已导入",
			Chapters: len(chapters),
		},
	}
	if len(chapters) > 0 {
		book.Latest = chapters[len(chapters)-1].Title
	}
	book.ChapterList = make([]NovelChapterItem, len(chapters))
	for i, chapter := range chapters {
		book.ChapterList[i] = NovelChapterItem{
			Index: i,
			ID:    strconv.Itoa(i),
			Title: chapter.Title,
		}
	}
	return book, nil
}

// localNovelChapters 只读索引，返回目录（不进正文）。
func (d *Downloader) localNovelChapters(dir, bookID string) ([]NovelChapterItem, error) {
	index, err := readLocalNovelIndex(dir, bookID)
	if err != nil {
		return nil, err
	}
	items := make([]NovelChapterItem, len(index.Chapters))
	for i, chapter := range index.Chapters {
		items[i] = NovelChapterItem{
			Index: i,
			ID:    strconv.Itoa(i),
			Title: chapter.Title,
		}
	}
	return items, nil
}

// localNovelText 按章节序号取一章正文。
func (d *Downloader) localNovelText(dir, bookID, chapterID string) (NovelText, error) {
	index, err := readLocalNovelIndex(dir, bookID)
	if err != nil {
		return NovelText{}, err
	}
	position, convErr := strconv.Atoi(strings.TrimSpace(chapterID))
	if convErr != nil || position < 0 || position >= len(index.Chapters) {
		return NovelText{}, errors.New("章节不存在")
	}
	entry := index.Chapters[position]
	file, err := os.Open(filepath.Join(dir, localNovelDirName, index.ID+".txt"))
	if err != nil {
		return NovelText{}, errors.New("书籍文件丢失了，请重新导入")
	}
	defer file.Close()
	length := entry.End - entry.Start
	if length <= 0 {
		return NovelText{}, errors.New("这一章没有正文")
	}
	buf := make([]byte, length)
	if _, err := file.ReadAt(buf, entry.Start); err != nil && !errors.Is(err, io.EOF) {
		return NovelText{}, fmt.Errorf("读取正文失败：%w", err)
	}
	paragraphs := localParagraphs(string(buf))
	// 正文首行常常就是章节标题，去掉避免和阅读器标题重复。
	if len(paragraphs) > 0 && strings.TrimSpace(paragraphs[0]) == strings.TrimSpace(entry.Title) {
		paragraphs = paragraphs[1:]
	}
	if len(paragraphs) == 0 {
		return NovelText{}, errors.New("这一章没有正文")
	}
	return NovelText{
		BookID:     bookID,
		ChapterID:  strconv.Itoa(position),
		Title:      entry.Title,
		Paragraphs: paragraphs,
	}, nil
}

// removeLocalNovel 删除一本本地书的磁盘文件（从书架移除时调用）。
func (d *Downloader) removeLocalNovel(dir, bookID string) error {
	dir = strings.TrimSpace(dir)
	bookID = strings.TrimSpace(bookID)
	if dir == "" || bookID == "" {
		return errors.New("参数无效")
	}
	base := filepath.Join(dir, localNovelDirName, bookID)
	for _, ext := range []string{".txt", ".json"} {
		if err := os.Remove(base + ext); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func readLocalNovelIndex(dir, bookID string) (localNovelIndex, error) {
	dir = strings.TrimSpace(dir)
	bookID = strings.TrimSpace(bookID)
	if dir == "" || bookID == "" {
		return localNovelIndex{}, errors.New("参数无效")
	}
	raw, err := os.ReadFile(filepath.Join(dir, localNovelDirName, bookID+".json"))
	if err != nil {
		return localNovelIndex{}, errors.New("这本书的目录丢了，请重新导入")
	}
	var index localNovelIndex
	if err := json.Unmarshal(raw, &index); err != nil {
		return localNovelIndex{}, errors.New("目录文件损坏了，请重新导入")
	}
	if len(index.Chapters) == 0 {
		return localNovelIndex{}, errors.New("这本书没有章节")
	}
	return index, nil
}

// ── 编码 ──────────────────────────────────────────────────────────────────

// decodeNovelBytes 把原始字节解成 UTF-8 文本。
//
// 中文 txt 最常见的三种情况：带 BOM 的 UTF-8 / UTF-16，以及无 BOM 的
// GBK（老站点下载的排版多是这个）。GB18030 是 GBK 的超集，统一用它兜底。
func decodeNovelBytes(raw []byte) (string, error) {
	switch {
	case bytes.HasPrefix(raw, []byte{0xEF, 0xBB, 0xBF}):
		return string(raw[3:]), nil
	case bytes.HasPrefix(raw, []byte{0xFF, 0xFE}):
		return decodeUTF16(raw[2:], binary.LittleEndian), nil
	case bytes.HasPrefix(raw, []byte{0xFE, 0xFF}):
		return decodeUTF16(raw[2:], binary.BigEndian), nil
	}
	if utf8.Valid(raw) {
		return string(raw), nil
	}
	decoded, err := simplifiedchinese.GB18030.NewDecoder().Bytes(raw)
	if err == nil && utf8.Valid(decoded) {
		return string(decoded), nil
	}
	// GB18030 也会失败时，按「能解多少解多少」处理，总比直接报错好。
	decoded, _ = simplifiedchinese.GB18030.NewDecoder().Bytes(raw)
	return string(decoded), nil
}

func decodeUTF16(raw []byte, order binary.ByteOrder) string {
	if len(raw)%2 != 0 {
		raw = raw[:len(raw)-1]
	}
	units := make([]uint16, len(raw)/2)
	for i := range units {
		units[i] = order.Uint16(raw[i*2:])
	}
	return string(utf16.Decode(units))
}

// ── txt 切章 ──────────────────────────────────────────────────────────────

// splitLocalNovelText 按「第N章」把全文切成章节，返回规范化正文与章节区间。
func splitLocalNovelText(text string) (string, []localChapterEntry) {
	text = localNewlineRe.ReplaceAllString(text, "\n")
	// 顺便压掉行尾空白，避免偏移量里混进不可见字符。
	text = strings.TrimLeft(text, "\n")

	var builder strings.Builder
	builder.Grow(len(text) + 16)
	builder.WriteString(text)
	normalized := builder.String()

	lines := localChapterLineRe.FindAllStringIndex(normalized, -1)
	if len(lines) < 2 {
		return normalized, splitByLength(normalized)
	}
	chapters := make([]localChapterEntry, 0, len(lines))
	// 第一章之前若有实际内容（书名、作者、简介），当成「序章」保留。
	if head := strings.TrimSpace(normalized[:lines[0][0]]); head != "" {
		chapters = append(chapters, localChapterEntry{
			Index: 0,
			Title: "序章",
			Start: 0,
			End:   int64(lines[0][0]),
		})
	}
	for i, span := range lines {
		end := int64(len(normalized))
		if i+1 < len(lines) {
			end = int64(lines[i+1][0])
		}
		title := strings.TrimSpace(normalized[span[0]:span[1]])
		title = localBlankLineRe.ReplaceAllString(title, " ")
		if title == "" {
			title = fmt.Sprintf("第%d章", i+1)
		}
		chapters = append(chapters, localChapterEntry{
			Index: len(chapters),
			Title: title,
			Start: int64(span[0]),
			End:   end,
		})
	}
	return normalized, chapters
}

// splitByLength 在小说没有章节标记时按字数兜底切分。
func splitByLength(text string) []localChapterEntry {
	runes := []rune(text)
	if len(runes) == 0 {
		return nil
	}
	// rune 下标换算回字节偏移。
	offsets := make([]int64, len(runes)+1)
	pos := int64(0)
	for i, r := range runes {
		offsets[i] = pos
		pos += int64(utf8.RuneLen(r))
	}
	offsets[len(runes)] = pos

	chapters := make([]localChapterEntry, 0, len(runes)/localNovelFallback+1)
	for start := 0; start < len(runes); start += localNovelFallback {
		end := start + localNovelFallback
		if end > len(runes) {
			end = len(runes)
		}
		chapters = append(chapters, localChapterEntry{
			Index: len(chapters),
			Title: fmt.Sprintf("第%d节", len(chapters)+1),
			Start: offsets[start],
			End:   offsets[end],
		})
	}
	return chapters
}

// localParagraphs 把一章正文切成段落（丢空行、压行内空白）。
func localParagraphs(body string) []string {
	lines := strings.Split(localNewlineRe.ReplaceAllString(body, "\n"), "\n")
	paragraphs := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(localBlankLineRe.ReplaceAllString(line, " "))
		if line == "" {
			continue
		}
		paragraphs = append(paragraphs, line)
	}
	return paragraphs
}

// ── epub ──────────────────────────────────────────────────────────────────

// parseLocalEpub 解 epub：container.xml → OPF → spine 顺序取正文。
func parseLocalEpub(raw []byte) (string, string, string, []localChapterEntry, error) {
	reader, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return "", "", "", nil, errors.New("这个 epub 文件打不开")
	}
	files := make(map[string]*zip.File, len(reader.File))
	for _, file := range reader.File {
		// key 用不转义的原始名；href 里可能有 %20 之类的转义。
		files[normalizeEpubPath(file.Name)] = file
	}
	container, err := readZipText(files, "META-INF/container.xml")
	if err != nil {
		return "", "", "", nil, errors.New("这不是一个标准 epub（缺少 container.xml）")
	}
	rootMatch := localEpubRootRe.FindStringSubmatch(container)
	if rootMatch == nil {
		return "", "", "", nil, errors.New("epub 的 container.xml 不完整")
	}
	opfPath := normalizeEpubPath(rootMatch[1])
	opf, err := readZipText(files, opfPath)
	if err != nil {
		return "", "", "", nil, errors.New("epub 的主文件读不出来")
	}
	baseDir := ""
	if idx := strings.LastIndex(opfPath, "/"); idx >= 0 {
		baseDir = opfPath[:idx+1]
	}

	title := cleanNovelInline(firstTagText(opf, localDcTitleRe))
	if title == "" {
		// 部分生成的 epub 只写了 <title>，退回这个。
		title = cleanNovelInline(firstTagText(opf, localTitleTagRe))
	}
	author := ""
	if m := localCreatorRe.FindStringSubmatch(opf); m != nil {
		author = cleanNovelInline(localTagRe.ReplaceAllString(m[1], ""))
	}
	// manifest：id → href
	manifest := make(map[string]string)
	for _, tag := range localEpubItemRe.FindAllString(opf, -1) {
		id, href := "", ""
		for _, attr := range localEpubAttrRe.FindAllStringSubmatch(tag, -1) {
			switch attr[1] {
			case "id":
				id = attr[2]
			case "href":
				href = attr[2]
			}
		}
		if id != "" && href != "" {
			manifest[id] = baseDir + normalizeEpubPath(href)
		}
	}
	// spine：阅读顺序
	spineIDs := make([]string, 0, len(manifest))
	for _, tag := range localEpubItemrefRe.FindAllString(opf, -1) {
		for _, attr := range localEpubAttrRe.FindAllStringSubmatch(tag, -1) {
			if attr[1] == "idref" {
				spineIDs = append(spineIDs, attr[2])
			}
		}
	}
	if len(spineIDs) == 0 {
		// 没有 spine 时退回 manifest 顺序，至少能读。
		for id := range manifest {
			spineIDs = append(spineIDs, id)
		}
	}

	var (
		builder  strings.Builder
		chapters []localChapterEntry
	)
	for _, id := range spineIDs {
		path, ok := manifest[id]
		if !ok {
			continue
		}
		content, err := readZipText(files, path)
		if err != nil {
			continue
		}
		paragraphs, heading := epubPlainText(content)
		if len(paragraphs) == 0 {
			continue
		}
		if heading == "" {
			heading = fmt.Sprintf("第%d章", len(chapters)+1)
		}
		chunk := strings.Join(paragraphs, "\n")
		start := int64(builder.Len())
		// 章节标题单独占一行写进全文，阅读器按段落取时会自动去掉首行。
		builder.WriteString(heading)
		builder.WriteByte('\n')
		builder.WriteString(chunk)
		builder.WriteString("\n\n")
		chapters = append(chapters, localChapterEntry{
			Index: len(chapters),
			Title: heading,
			Start: start,
			End:   int64(builder.Len()),
		})
	}
	if builder.Len() == 0 {
		return "", "", "", nil, errors.New("这个 epub 里没有正文")
	}
	return builder.String(), title, author, chapters, nil
}

// epubPlainText 从一章 xhtml 里抽段落与标题。
func epubPlainText(content string) ([]string, string) {
	heading := ""
	if m := localHeadingRe.FindStringSubmatch(content); m != nil {
		heading = cleanNovelInline(localTagRe.ReplaceAllString(m[1], ""))
	}
	body := content
	if m := localBodyRe.FindStringSubmatch(content); m != nil {
		body = m[1]
	}
	text := localBlockBreakRe.ReplaceAllString(body, "\n")
	text = localTagRe.ReplaceAllString(text, "")
	text = html.UnescapeString(text)
	paragraphs := localParagraphs(text)
	if heading != "" && len(paragraphs) > 0 && paragraphs[0] == heading {
		paragraphs = paragraphs[1:]
	}
	return paragraphs, heading
}

func readZipText(files map[string]*zip.File, name string) (string, error) {
	file, ok := files[normalizeEpubPath(name)]
	if !ok {
		// 有些 epub 的 href 带 URL 转义，再按未转义名试一次。
		file, ok = files[normalizeEpubPath(unescapeEpubPath(name))]
		if !ok {
			return "", errors.New("文件不存在：" + name)
		}
	}
	reader, err := file.Open()
	if err != nil {
		return "", err
	}
	defer reader.Close()
	raw, err := io.ReadAll(io.LimitReader(reader, localNovelMaxBytes))
	if err != nil {
		return "", err
	}
	text, err := decodeNovelBytes(raw)
	if err != nil {
		return string(raw), nil
	}
	return text, nil
}

func normalizeEpubPath(path string) string {
	path = strings.TrimSpace(path)
	path = strings.ReplaceAll(path, "\\", "/")
	path = strings.TrimPrefix(path, "./")
	return path
}

func unescapeEpubPath(path string) string {
	replacer := strings.NewReplacer("%20", " ", "%28", "(", "%29", ")", "%2C", ",")
	return replacer.Replace(path)
}

func firstTagText(source string, pattern *regexp.Regexp) string {
	if m := pattern.FindStringSubmatch(source); m != nil {
		return localTagRe.ReplaceAllString(m[1], "")
	}
	return ""
}
