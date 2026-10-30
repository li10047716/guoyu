package core

// 「阅读 / Legado」规则求值器（Go 侧）。
//
// 书源脚本里大量使用 `java.getString('class.list@tag.li.0@a@text')` 这类
// 扩展函数：它把「阅读」的规则语法作用在当前正文/当前元素上。
// Dart 侧有一份 RuleEngine，但脚本是在 Go 的原生核心里跑的，拿不到那份实现，
// 所以这里按同一套语义（CSS / JSONPath / @ 取值 / && 接续 / || 兜底 /
// ##正则##替换 / {{模板}}）复刻一份精简版，只服务脚本里的取值需求。

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/andybalholm/cascadia"
	"golang.org/x/net/html"
)

// legadoRuleContext 一次规则求值的上下文。
type legadoRuleContext struct {
	body string
	url  string
	vars map[string]string

	root *html.Node
	doc  *html.Node

	jsonParsed bool
	jsonData   any
}

func newLegadoRuleContext(body, address string, vars map[string]string) *legadoRuleContext {
	return &legadoRuleContext{body: body, url: address, vars: vars}
}

// legadoRuleContextForElement 以某个元素为根构造上下文（脚本里的 result 是元素时）。
func legadoRuleContextForElement(node *html.Node, body, address string, vars map[string]string) *legadoRuleContext {
	ctx := newLegadoRuleContext(body, address, vars)
	ctx.root = node
	return ctx
}

func (c *legadoRuleContext) document() *html.Node {
	if c.doc == nil {
		if c.root != nil && c.root.Type == html.DocumentNode {
			c.doc = c.root
		} else {
			c.doc = legadoParseDocument(c.body)
		}
	}
	return c.doc
}

func (c *legadoRuleContext) rootNode() *html.Node {
	if c.root != nil {
		return c.root
	}
	if document := c.document(); document != nil {
		if element := legadoFirstElement(document); element != nil {
			return element
		}
		return document
	}
	return &html.Node{Type: html.ElementNode, Data: "div"}
}

// child 以某个元素为根派生出新上下文，共享正文与 JSON 缓存。
func (c *legadoRuleContext) child(node *html.Node) *legadoRuleContext {
	return &legadoRuleContext{
		body: c.body, url: c.url, vars: c.vars,
		root: node, doc: c.doc,
		jsonParsed: c.jsonParsed, jsonData: c.jsonData,
	}
}

func (c *legadoRuleContext) jsonValue() any {
	if c.jsonParsed {
		return c.jsonData
	}
	c.jsonParsed = true
	trimmed := strings.TrimLeft(c.body, " \t\r\n")
	if !strings.HasPrefix(trimmed, "{") && !strings.HasPrefix(trimmed, "[") {
		return nil
	}
	var decoded any
	if err := json.Unmarshal([]byte(c.body), &decoded); err != nil {
		return nil
	}
	c.jsonData = decoded
	return decoded
}

// legadoEvalRule 求一条规则，结果是元素或字符串的混合列表。
func legadoEvalRule(rule string, ctx *legadoRuleContext) []any {
	trimmed := strings.TrimSpace(rule)
	if trimmed == "" {
		return nil
	}
	parts := strings.Split(trimmed, "##")
	values := legadoEvalAlternatives(parts[0], ctx)
	if len(parts) < 2 {
		return values
	}
	out := make([]any, 0, len(values))
	for _, value := range values {
		text := legadoRuleValueText(value)
		for index := 1; index < len(parts); index += 2 {
			pattern := parts[index]
			if pattern == "" {
				continue
			}
			replacement := ""
			if index+1 < len(parts) {
				replacement = parts[index+1]
			}
			compiled, err := regexp.Compile("(?m)" + pattern)
			if err != nil {
				continue
			}
			text = compiled.ReplaceAllString(text, replacement)
		}
		if strings.TrimSpace(text) != "" {
			out = append(out, strings.TrimSpace(text))
		}
	}
	return out
}

// legadoRuleValueText 把求值结果转成文本：元素取 text()。
func legadoRuleValueText(value any) string {
	switch typed := value.(type) {
	case *html.Node:
		return legadoNodeText(typed)
	case string:
		return typed
	}
	return ""
}

func legadoEvalAlternatives(rule string, ctx *legadoRuleContext) []any {
	for _, branch := range legadoSplitTop(rule, "||") {
		if values := legadoEvalChain(branch, ctx); len(values) > 0 {
			return values
		}
	}
	return nil
}

func legadoEvalChain(rule string, ctx *legadoRuleContext) []any {
	steps := legadoSplitTop(rule, "&&")
	if len(steps) == 0 {
		return nil
	}
	current := legadoEvalSingle(steps[0], ctx)
	for index := 1; index < len(steps) && len(current) > 0; index++ {
		next := make([]any, 0, len(current))
		for _, value := range current {
			if node, ok := value.(*html.Node); ok {
				next = append(next, legadoEvalSingle(steps[index], ctx.child(node))...)
			}
		}
		current = next
	}
	return current
}

func legadoEvalSingle(rule string, ctx *legadoRuleContext) []any {
	text := strings.TrimSpace(rule)
	if text == "" {
		return nil
	}
	if strings.HasPrefix(text, "@json:") {
		return legadoRuleJSONValues(strings.TrimSpace(text[6:]), ctx)
	}
	if strings.HasPrefix(text, "$") {
		return legadoRuleJSONValues(text, ctx)
	}
	text = strings.TrimPrefix(text, "@css:")

	segments := make([]string, 0, 4)
	for _, segment := range strings.Split(text, "@") {
		if trimmed := strings.TrimSpace(segment); trimmed != "" {
			segments = append(segments, trimmed)
		}
	}
	if len(segments) == 0 {
		return nil
	}

	nodes := []*html.Node{ctx.rootNode()}
	for index, segment := range segments {
		if legadoRuleIsGetter(segment) {
			return legadoRuleApplyGetter(nodes, segment, ctx)
		}
		selector, pick, contains := legadoRuleParseSelector(segment)
		matched := make([]*html.Node, 0, len(nodes))
		for _, node := range nodes {
			matched = append(matched, legadoRuleQuery(node, selector, contains)...)
		}
		if pick != nil {
			matched = legadoRulePick(matched, *pick)
		}
		nodes = matched
		if len(nodes) == 0 {
			return nil
		}
		if index == len(segments)-1 {
			out := make([]any, 0, len(nodes))
			for _, node := range nodes {
				out = append(out, node)
			}
			return out
		}
	}
	return nil
}

// legadoRuleQuery 在节点下查选择器；text.xxx 按文本包含过滤。
func legadoRuleQuery(node *html.Node, selector, contains string) []*html.Node {
	if selector == "" {
		return []*html.Node{node}
	}
	var matched []*html.Node
	if selector == "*" && contains != "" {
		for _, candidate := range legadoQueryAll(node, "*") {
			if strings.Contains(legadoNodeText(candidate), contains) {
				matched = append(matched, candidate)
			}
		}
		return matched
	}
	if nodes := legadoQuery(node, selector); len(nodes) > 0 {
		return nodes
	}
	return nil
}

func legadoQueryAll(node *html.Node, selector string) (out []*html.Node) {
	compiled, err := legadoCompileSelector(selector)
	if err != nil {
		return nil
	}
	defer func() {
		if recover() != nil {
			out = nil
		}
	}()
	return cascadia.QueryAll(node, compiled)
}

func legadoRulePick(nodes []*html.Node, index int) []*html.Node {
	real := index
	if real < 0 {
		real = len(nodes) + real
	}
	if real < 0 || real >= len(nodes) {
		return nil
	}
	return []*html.Node{nodes[real]}
}

var legadoRuleGetPrefix = regexp.MustCompile(`^(-?\d+)$`)
var legadoRuleGetSuffix = regexp.MustCompile(`!(-?\d+)$`)

// legadoRuleParseSelector 把一段选择器拆成「CSS + 序号」，顺带把阅读的简写转成 CSS。
func legadoRuleParseSelector(segment string) (string, *int, string) {
	selector := strings.TrimSpace(segment)
	var pick *int
	if match := legadoRuleGetSuffix.FindStringSubmatch(selector); match != nil {
		if index, err := strconv.Atoi(match[1]); err == nil {
			pick = &index
		}
		selector = strings.TrimSpace(selector[:len(selector)-len(match[0])])
	}
	if pick == nil {
		if dot := strings.LastIndex(selector, "."); dot > 0 {
			if index, err := strconv.Atoi(selector[dot+1:]); err == nil && legadoRuleGetPrefix.MatchString(selector[dot+1:]) {
				pick = &index
				selector = selector[:dot]
			}
		}
	}
	selector, contains := legadoRuleSelectorToCSS(selector)
	return selector, pick, contains
}

// legadoRuleSelectorToCSS 把 `class.a b` / `tag.div` / `id.x` / `text.xx` 转成 CSS。
func legadoRuleSelectorToCSS(selector string) (string, string) {
	trimmed := strings.TrimSpace(selector)
	switch {
	case strings.HasPrefix(trimmed, "class."):
		return "." + strings.ReplaceAll(strings.TrimSpace(trimmed[6:]), " ", "."), ""
	case strings.HasPrefix(trimmed, "id."):
		return "#" + strings.TrimSpace(trimmed[3:]), ""
	case strings.HasPrefix(trimmed, "tag."):
		return strings.TrimSpace(trimmed[4:]), ""
	case strings.HasPrefix(trimmed, "text."):
		return "*", strings.TrimSpace(trimmed[5:])
	}
	return trimmed, ""
}

// legadoRuleIsGetter 判断这一段是「取值器」还是「选择器」。
func legadoRuleIsGetter(segment string) bool {
	switch segment {
	case "text", "textNodes", "ownText", "html", "all", "string":
		return true
	}
	if strings.HasPrefix(segment, "abs:") {
		return true
	}
	switch segment {
	case "href", "src", "content", "value", "title", "alt", "class", "id":
		return true
	}
	// data-src / data-original 这类带连字符的只可能是属性
	if strings.Contains(segment, "-") && legadoRuleAttrName.MatchString(segment) {
		return true
	}
	return false
}

var legadoRuleAttrName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]*$`)

// legadoRuleURLAttrs 取到这些属性时把相对地址补成绝对地址。
var legadoRuleURLAttrs = map[string]bool{
	"href": true, "src": true, "data-src": true, "data-original": true,
	"data-lazy-src": true, "data-echo": true, "data-url": true, "poster": true,
	"action": true,
}

func legadoRuleApplyGetter(nodes []*html.Node, getter string, ctx *legadoRuleContext) []any {
	out := make([]any, 0, len(nodes))
	name := getter
	absolute := false
	if strings.HasPrefix(name, "abs:") {
		absolute = true
		name = strings.TrimSpace(name[4:])
	}
	for _, node := range nodes {
		switch name {
		case "text", "string":
			if text := strings.TrimSpace(legadoNodeText(node)); text != "" {
				out = append(out, text)
			}
		case "ownText":
			if text := strings.TrimSpace(legadoOwnText(node)); text != "" {
				out = append(out, text)
			}
		case "textNodes":
			for child := node.FirstChild; child != nil; child = child.NextSibling {
				if child.Type != html.TextNode {
					continue
				}
				if text := strings.TrimSpace(child.Data); text != "" {
					out = append(out, text)
				}
			}
		case "html", "all":
			if inner := strings.TrimSpace(legadoInnerHTML(node)); inner != "" {
				out = append(out, inner)
			}
		default:
			raw := strings.TrimSpace(legadoAttr(node, name))
			if raw == "" {
				continue
			}
			if absolute || legadoRuleURLAttrs[name] {
				out = append(out, legadoResolveURL(ctx.url, raw))
				continue
			}
			out = append(out, raw)
		}
	}
	return out
}

// legadoRuleString 求一条规则，返回第一个非空文本结果（java.getString 用）。
func legadoRuleString(rule string, ctx *legadoRuleContext) string {
	for _, value := range legadoEvalRule(rule, ctx) {
		if text := strings.TrimSpace(legadoRuleValueText(value)); text != "" {
			return text
		}
	}
	return ""
}

// legadoRuleStrings 求一条规则，返回全部非空文本结果。
func legadoRuleStrings(rule string, ctx *legadoRuleContext) []string {
	out := make([]string, 0, 8)
	for _, value := range legadoEvalRule(rule, ctx) {
		if text := strings.TrimSpace(legadoRuleValueText(value)); text != "" {
			out = append(out, text)
		}
	}
	return out
}

// legadoRuleNodes 求一条规则，只保留元素结果。
func legadoRuleNodes(rule string, ctx *legadoRuleContext) []*html.Node {
	out := make([]*html.Node, 0, 8)
	for _, value := range legadoEvalRule(rule, ctx) {
		if node, ok := value.(*html.Node); ok {
			out = append(out, node)
		}
	}
	return out
}

// legadoSplitTop 按顶层 `||` / `&&` 切分，跳过 `##正则##` 段里的分隔符。
func legadoSplitTop(rule, token string) []string {
	parts := make([]string, 0, 4)
	var builder strings.Builder
	depth := 0
	inRegex := false
	index := 0
	for index < len(rule) {
		if strings.HasPrefix(rule[index:], "##") {
			inRegex = !inRegex
			builder.WriteString("##")
			index += 2
			continue
		}
		if !inRegex {
			switch rule[index] {
			case '(', '[':
				depth++
			case ')', ']':
				depth--
			}
			if depth <= 0 && strings.HasPrefix(rule[index:], token) {
				parts = append(parts, strings.TrimSpace(builder.String()))
				builder.Reset()
				index += len(token)
				continue
			}
		}
		builder.WriteByte(rule[index])
		index++
	}
	parts = append(parts, strings.TrimSpace(builder.String()))
	out := parts[:0]
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// legadoRuleJSONValues 求 JSON 路径。
func legadoRuleJSONValues(path string, ctx *legadoRuleContext) []any {
	data := ctx.jsonValue()
	if data == nil {
		return nil
	}
	values := legadoJSONPath(data, path)
	out := make([]any, 0, len(values))
	for _, value := range values {
		if value == nil {
			continue
		}
		out = append(out, legadoJSONValueString(value))
	}
	return out
}

// legadoJSONValueString 把 JSON 值转成字符串，数字不带多余的 .0 / 科学计数。
func legadoJSONValueString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case bool:
		if typed {
			return "true"
		}
		return "false"
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(encoded)
}

// legadoJSONPath 迷你 JSONPath：`$.a.b`、`$.a[*].b`、`$.a[0]`、`$..name`。
func legadoJSONPath(root any, path string) []any {
	trimmed := strings.TrimSpace(path)
	if strings.HasPrefix(trimmed, "@json:") {
		trimmed = strings.TrimSpace(trimmed[6:])
	}
	if trimmed == "$" {
		return []any{root}
	}
	trimmed = strings.TrimPrefix(trimmed, "$")

	current := []any{root}
	index := 0
	for index < len(trimmed) {
		if trimmed[index] == '[' {
			end := strings.IndexByte(trimmed[index:], ']')
			if end < 0 {
				break
			}
			inner := strings.TrimSpace(trimmed[index+1 : index+end])
			index += end + 1
			next := make([]any, 0, len(current))
			if inner == "*" {
				for _, value := range current {
					if list, ok := value.([]any); ok {
						next = append(next, list...)
					}
				}
			} else {
				cleaned := strings.Trim(inner, `'"`)
				if offset, err := strconv.Atoi(cleaned); err == nil {
					for _, value := range current {
						list, ok := value.([]any)
						if !ok {
							continue
						}
						real := offset
						if real < 0 {
							real = len(list) + real
						}
						if real >= 0 && real < len(list) {
							next = append(next, list[real])
						}
					}
				} else {
					for _, value := range current {
						if object, ok := value.(map[string]any); ok {
							if found, exists := object[cleaned]; exists {
								next = append(next, found)
							}
						}
					}
				}
			}
			current = next
			continue
		}

		recursive := trimmed[index] == '.' && index+1 < len(trimmed) && trimmed[index+1] == '.'
		if trimmed[index] == '.' {
			if recursive {
				index += 2
			} else {
				index++
			}
		}
		start := index
		for index < len(trimmed) && trimmed[index] != '.' && trimmed[index] != '[' {
			index++
		}
		key := trimmed[start:index]
		if key == "" {
			continue
		}
		if recursive {
			next := make([]any, 0, 4)
			for _, value := range current {
				legadoJSONDescend(value, key, &next)
			}
			current = next
			continue
		}
		next := make([]any, 0, len(current))
		for _, value := range current {
			if object, ok := value.(map[string]any); ok {
				if found, exists := object[key]; exists {
					next = append(next, found)
				}
			}
		}
		current = next
	}
	return current
}

// legadoJSONDescend 递归找所有同名 key（`$..name`）。
func legadoJSONDescend(node any, key string, out *[]any) {
	switch typed := node.(type) {
	case map[string]any:
		if found, exists := typed[key]; exists {
			*out = append(*out, found)
		}
		for _, value := range typed {
			legadoJSONDescend(value, key, out)
		}
	case []any:
		for _, value := range typed {
			legadoJSONDescend(value, key, out)
		}
	}
}

// legadoExpandTemplate 把规则里的 `{{key}}` / `{{page}}` 换成实际值。
func legadoExpandTemplate(text string, vars map[string]string) string {
	if !strings.Contains(text, "{{") {
		return text
	}
	return legadoTemplatePattern.ReplaceAllStringFunc(text, func(token string) string {
		key := strings.TrimSpace(token[2 : len(token)-2])
		if value, ok := vars[key]; ok {
			return value
		}
		return ""
	})
}

var legadoTemplatePattern = regexp.MustCompile(`\{\{([^}]+)\}\}`)
