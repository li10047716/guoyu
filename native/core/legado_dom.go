package core

// 给书源脚本用的 HTML DOM（模拟 Legado 里的 org.jsoup）。
//
// Legado 把 jsoup 直接暴露给脚本：`org.jsoup.Jsoup.parse(html).select(css)`，
// 而且规则前缀选到元素时 `result` 本身就是 jsoup 的 Element，能接着
// `.select('td').get(1).select('a').attr('href')`。这里用
// golang.org/x/net/html + cascadia 把同一套 API 复刻出来。

import (
	"bytes"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/andybalholm/cascadia"
	"github.com/dop251/goja"
	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// legadoParseDocument 把 HTML 文本解析成文档节点。
func legadoParseDocument(text string) *html.Node {
	document, err := html.Parse(strings.NewReader(text))
	if err != nil || document == nil {
		return &html.Node{Type: html.DocumentNode}
	}
	return document
}

// legadoElementHTML 返回节点自身的完整 HTML。
func legadoElementHTML(node *html.Node) string {
	var buffer bytes.Buffer
	if err := html.Render(&buffer, node); err != nil {
		return ""
	}
	return buffer.String()
}

// legadoInnerHTML 返回节点内部的 HTML（不含自身标签）。
func legadoInnerHTML(node *html.Node) string {
	var buffer bytes.Buffer
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if err := html.Render(&buffer, child); err != nil {
			return ""
		}
	}
	return buffer.String()
}

// legadoNodeText 取节点下的可见文本。
//
// 和 jsoup 的 text() 一致：合并连续空白、块级元素之间补空格、最后 trim。
func legadoNodeText(node *html.Node) string {
	var builder strings.Builder
	var walk func(*html.Node)
	walk = func(current *html.Node) {
		switch current.Type {
		case html.TextNode:
			builder.WriteString(current.Data)
			return
		case html.ElementNode:
			if current.Data == "script" || current.Data == "style" {
				return
			}
		}
		for child := current.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
		if current.Type == html.ElementNode && legadoBlockTags[current.Data] {
			builder.WriteString(" ")
		}
	}
	walk(node)
	return normalizeSpace(builder.String())
}

// legadoOwnText 只取直接子文本节点。
func legadoOwnText(node *html.Node) string {
	var builder strings.Builder
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if child.Type == html.TextNode {
			builder.WriteString(child.Data)
		}
	}
	return normalizeSpace(builder.String())
}

func normalizeSpace(text string) string {
	return strings.Join(strings.Fields(text), " ")
}

var legadoBlockTags = map[string]bool{
	"address": true, "article": true, "aside": true, "blockquote": true,
	"div": true, "dl": true, "dd": true, "dt": true, "fieldset": true,
	"figure": true, "footer": true, "form": true, "h1": true, "h2": true,
	"h3": true, "h4": true, "h5": true, "h6": true, "header": true, "hr": true,
	"li": true, "main": true, "nav": true, "ol": true, "p": true, "pre": true,
	"section": true, "table": true, "tr": true, "td": true, "th": true,
	"ul": true, "br": true,
}

// legadoQuery 在当前节点下按 CSS 选择器查找。
func legadoQuery(node *html.Node, selector string) (out []*html.Node) {
	// 书源里的选择器经常不合规范（属性值不加引号），cascadia 会直接解析失败，
	// 按标准补一遍引号再试。
	for _, candidate := range []string{selector, legadoQuoteAttributes(selector)} {
		trimmed := strings.TrimSpace(candidate)
		if trimmed == "" {
			continue
		}
		compiled, err := legadoCompileSelector(trimmed)
		if err != nil {
			continue
		}
		if nodes := cascadia.QueryAll(node, compiled); len(nodes) > 0 {
			return nodes
		}
	}
	return nil
}

// legadoCompileSelector 解析选择器，顺带把 cascadia 的 panic 挡在核心外面。
func legadoCompileSelector(selector string) (matcher cascadia.Sel, err error) {
	defer func() {
		if r := recover(); r != nil {
			matcher = nil
			err = fmt.Errorf("选择器无法解析：%s", selector)
		}
	}()
	return cascadia.Parse(selector)
}

// legadoQuoteAttributes 给 `[href^=/novel]` 这种没加引号的属性值补上引号。
func legadoQuoteAttributes(selector string) string {
	pattern := regexp.MustCompile(`\[([A-Za-z_:][-A-Za-z0-9_:.]*)([~^$*|]?=)([^\]"'\s]+)\]`)
	return pattern.ReplaceAllString(selector, `[$1$2"$3"]`)
}

// legadoAttr 取属性值。
func legadoAttr(node *html.Node, name string) string {
	for _, attribute := range node.Attr {
		if strings.EqualFold(attribute.Key, name) {
			return attribute.Val
		}
	}
	return ""
}

// legadoTagName 返回标签名（document 节点返回 #root）。
func legadoTagName(node *html.Node) string {
	if node.Type == html.DocumentNode {
		return "#root"
	}
	return node.Data
}

// legadoWrapNode 把 DOM 节点包装成脚本可用的 Element 对象。
func legadoWrapNode(vm *goja.Runtime, node *html.Node, baseURL string) *goja.Object {
	object := vm.NewObject()
	wrap := func(target *html.Node) *goja.Object {
		return legadoWrapNode(vm, target, baseURL)
	}

	_ = object.Set("text", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoNodeText(node))
	})
	_ = object.Set("ownText", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoOwnText(node))
	})
	_ = object.Set("html", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoInnerHTML(node))
	})
	_ = object.Set("outerHtml", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoElementHTML(node))
	})
	_ = object.Set("toString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoElementHTML(node))
	})
	_ = object.Set("attr", func(call goja.FunctionCall) goja.Value {
		name := call.Argument(0).String()
		value := legadoAttr(node, name)
		if strings.EqualFold(name, "abs:href") || strings.EqualFold(name, "abs:src") {
			raw := legadoAttr(node, strings.TrimPrefix(strings.ToLower(name), "abs:"))
			return vm.ToValue(legadoResolveURL(baseURL, raw))
		}
		return vm.ToValue(value)
	})
	_ = object.Set("absUrl", func(call goja.FunctionCall) goja.Value {
		raw := legadoAttr(node, call.Argument(0).String())
		return vm.ToValue(legadoResolveURL(baseURL, raw))
	})
	_ = object.Set("hasAttr", func(call goja.FunctionCall) goja.Value {
		name := call.Argument(0).String()
		for _, attribute := range node.Attr {
			if strings.EqualFold(attribute.Key, name) {
				return vm.ToValue(true)
			}
		}
		return vm.ToValue(false)
	})
	_ = object.Set("id", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoAttr(node, "id"))
	})
	_ = object.Set("className", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoAttr(node, "class"))
	})
	_ = object.Set("tagName", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoTagName(node))
	})
	_ = object.Set("select", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWrapNodes(vm, legadoQuery(node, call.Argument(0).String()), baseURL))
	})
	_ = object.Set("selectFirst", func(call goja.FunctionCall) goja.Value {
		found := legadoQuery(node, call.Argument(0).String())
		if len(found) == 0 {
			return goja.Null()
		}
		return vm.ToValue(wrap(found[0]))
	})
	_ = object.Set("getElementsByTag", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWrapNodes(vm, legadoQuery(node, call.Argument(0).String()), baseURL))
	})
	// 阅读的脚本扩展：在当前元素上按规则取值（getString('tag.a@href')）。
	_ = object.Set("getString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoRuleString(call.Argument(0).String(), legadoNodeRuleContext(node, baseURL)))
	})
	_ = object.Set("getStringList", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoRuleStrings(call.Argument(0).String(), legadoNodeRuleContext(node, baseURL)))
	})
	_ = object.Set("getElements", func(call goja.FunctionCall) goja.Value {
		nodes := legadoRuleNodes(call.Argument(0).String(), legadoNodeRuleContext(node, baseURL))
		return vm.ToValue(legadoWrapNodes(vm, nodes, baseURL))
	})
	_ = object.Set("getElementsByClass", func(call goja.FunctionCall) goja.Value {
		selector := "." + strings.ReplaceAll(strings.TrimSpace(call.Argument(0).String()), " ", ".")
		return vm.ToValue(legadoWrapNodes(vm, legadoQuery(node, selector), baseURL))
	})
	_ = object.Set("getElementsByAttribute", func(call goja.FunctionCall) goja.Value {
		name := strings.TrimSpace(call.Argument(0).String())
		value := ""
		if len(call.Arguments) > 1 {
			value = call.Argument(1).String()
		}
		selector := "[" + name + "]"
		matched := legadoQuery(node, selector)
		if value == "" {
			return vm.ToValue(legadoWrapNodes(vm, matched, baseURL))
		}
		filtered := make([]*html.Node, 0, len(matched))
		for _, candidate := range matched {
			if strings.Contains(legadoAttr(candidate, name), value) {
				filtered = append(filtered, candidate)
			}
		}
		return vm.ToValue(legadoWrapNodes(vm, filtered, baseURL))
	})
	_ = object.Set("getAllElements", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWrapNodes(vm, legadoQuery(node, "*"), baseURL))
	})
	_ = object.Set("string", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoNodeText(node))
	})
	// remove()：从文档里摘掉节点（漫画源常先删掉广告块再取 html）。
	_ = object.Set("remove", func(goja.FunctionCall) goja.Value {
		if node.Parent != nil {
			node.Parent.RemoveChild(node)
		}
		return goja.Undefined()
	})
	_ = object.Set("clone", func(goja.FunctionCall) goja.Value {
		copied := *node
		return vm.ToValue(legadoWrapNode(vm, &copied, baseURL))
	})
	_ = object.Set("parent", func(call goja.FunctionCall) goja.Value {
		if node.Parent == nil {
			return goja.Null()
		}
		return vm.ToValue(wrap(node.Parent))
	})
	_ = object.Set("children", func(call goja.FunctionCall) goja.Value {
		var kids []*html.Node
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			if child.Type == html.ElementNode {
				kids = append(kids, child)
			}
		}
		return vm.ToValue(legadoWrapNodes(vm, kids, baseURL))
	})
	_ = object.Set("child", func(call goja.FunctionCall) goja.Value {
		index := int(call.Argument(0).ToInteger())
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			if child.Type != html.ElementNode {
				continue
			}
			if index == 0 {
				return vm.ToValue(wrap(child))
			}
			index--
		}
		return goja.Null()
	})
	_ = object.Set("nextElementSibling", func(call goja.FunctionCall) goja.Value {
		for sibling := node.NextSibling; sibling != nil; sibling = sibling.NextSibling {
			if sibling.Type == html.ElementNode {
				return vm.ToValue(wrap(sibling))
			}
		}
		return goja.Null()
	})
	_ = object.Set("toStringValue", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoNodeText(node))
	})
	// 让 `String(element)` / `element + ''` 得到 outerHTML，和 jsoup 一致
	_ = object.Set("valueOf", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoElementHTML(node))
	})
	// __self 是给 Elements.add / addAll 用的内部访问器
	_ = object.Set("__self", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(node)
	})
	return object
}

// legadoWrapNodes 把一组节点包装成 Elements（数组 + jsoup 的集合方法）。
func legadoWrapNodes(vm *goja.Runtime, nodes []*html.Node, baseURL string) *goja.Object {
	array := vm.NewArray()
	for index, node := range nodes {
		_ = array.Set(strconv.Itoa(index), legadoWrapNode(vm, node, baseURL))
	}
	_ = array.Set("size", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(len(nodes))
	})
	_ = array.Set("get", func(call goja.FunctionCall) goja.Value {
		index := int(call.Argument(0).ToInteger())
		if index < 0 || index >= len(nodes) {
			// jsoup 抛 IndexOutOfBoundsException，脚本常靠 try/catch 兜住
			panic(vm.NewTypeError("IndexOutOfBounds: " + strconv.Itoa(index)))
		}
		return vm.ToValue(legadoWrapNode(vm, nodes[index], baseURL))
	})
	_ = array.Set("first", func(call goja.FunctionCall) goja.Value {
		if len(nodes) == 0 {
			return goja.Null()
		}
		return vm.ToValue(legadoWrapNode(vm, nodes[0], baseURL))
	})
	_ = array.Set("last", func(call goja.FunctionCall) goja.Value {
		if len(nodes) == 0 {
			return goja.Null()
		}
		return vm.ToValue(legadoWrapNode(vm, nodes[len(nodes)-1], baseURL))
	})
	_ = array.Set("text", func(call goja.FunctionCall) goja.Value {
		parts := make([]string, 0, len(nodes))
		for _, node := range nodes {
			if text := legadoNodeText(node); text != "" {
				parts = append(parts, text)
			}
		}
		return vm.ToValue(strings.Join(parts, " "))
	})
	_ = array.Set("html", func(call goja.FunctionCall) goja.Value {
		parts := make([]string, 0, len(nodes))
		for _, node := range nodes {
			parts = append(parts, legadoInnerHTML(node))
		}
		return vm.ToValue(strings.Join(parts, "\n"))
	})
	_ = array.Set("attr", func(call goja.FunctionCall) goja.Value {
		name := call.Argument(0).String()
		absolute := false
		plain := name
		if strings.HasPrefix(strings.ToLower(name), "abs:") {
			absolute = true
			plain = name[4:]
		}
		for _, node := range nodes {
			value := legadoAttr(node, plain)
			if value == "" {
				continue
			}
			if absolute {
				return vm.ToValue(legadoResolveURL(baseURL, value))
			}
			return vm.ToValue(value)
		}
		return vm.ToValue("")
	})
	// Elements 上继续 select（jsoup 的 Elements.select 是「在所有节点下找」）
	_ = array.Set("select", func(call goja.FunctionCall) goja.Value {
		selector := call.Argument(0).String()
		collected := make([]*html.Node, 0, len(nodes))
		for _, node := range nodes {
			collected = append(collected, legadoQuery(node, selector)...)
		}
		return vm.ToValue(legadoWrapNodes(vm, collected, baseURL))
	})
	_ = array.Set("selectFirst", func(call goja.FunctionCall) goja.Value {
		selector := call.Argument(0).String()
		for _, node := range nodes {
			if found := legadoQuery(node, selector); len(found) > 0 {
				return vm.ToValue(legadoWrapNode(vm, found[0], baseURL))
			}
		}
		return goja.Null()
	})
	_ = array.Set("outerHtml", func(goja.FunctionCall) goja.Value {
		parts := make([]string, 0, len(nodes))
		for _, node := range nodes {
			parts = append(parts, legadoElementHTML(node))
		}
		return vm.ToValue(strings.Join(parts, "\n"))
	})
	_ = array.Set("isEmpty", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(len(nodes) == 0)
	})
	_ = array.Set("remove", func(goja.FunctionCall) goja.Value {
		for _, node := range nodes {
			if node.Parent != nil {
				node.Parent.RemoveChild(node)
			}
		}
		return goja.Undefined()
	})
	_ = array.Set("each", func(call goja.FunctionCall) goja.Value {
		callback, ok := goja.AssertFunction(call.Argument(0))
		if !ok {
			return vm.ToValue(array)
		}
		for index, node := range nodes {
			_, _ = callback(goja.Undefined(), vm.ToValue(index), vm.ToValue(legadoWrapNode(vm, node, baseURL)))
		}
		return vm.ToValue(array)
	})
	_ = array.Set("forEach", array.Get("each"))
	// __nodeAt 是给 addAll 用的内部访问器：把第 i 个节点的原生指针交给调用方。
	_ = array.Set("__nodeAt", func(call goja.FunctionCall) goja.Value {
		index := int(call.Argument(0).ToInteger())
		if index < 0 || index >= len(nodes) {
			return goja.Null()
		}
		return vm.ToValue(nodes[index])
	})
	// add / addAll：jsoup 的 Elements 是可变的（漫画源常 new 一个再拼几组）
	_ = array.Set("add", func(call goja.FunctionCall) goja.Value {
		if node := legadoNodeOf(call.Argument(0)); node != nil {
			nodes = append(nodes, node)
		}
		return vm.ToValue(array)
	})
	_ = array.Set("addAll", func(call goja.FunctionCall) goja.Value {
		source, ok := call.Argument(0).(*goja.Object)
		if !ok {
			return vm.ToValue(array)
		}
		sizeFn, okSize := goja.AssertFunction(source.Get("size"))
		nodeFn, okNode := goja.AssertFunction(source.Get("__nodeAt"))
		if !okSize || !okNode {
			return vm.ToValue(array)
		}
		sizeValue, err := sizeFn(source)
		if err != nil {
			return vm.ToValue(array)
		}
		total := int(sizeValue.ToInteger())
		for index := 0; index < total; index++ {
			value, err := nodeFn(source, vm.ToValue(index))
			if err != nil || value == nil || goja.IsNull(value) || goja.IsUndefined(value) {
				continue
			}
			if node, okCast := value.Export().(*html.Node); okCast {
				nodes = append(nodes, node)
			}
		}
		return vm.ToValue(array)
	})
	return array
}

// legadoNodeOf 从脚本传进来的元素对象里取回原生节点。
func legadoNodeOf(value goja.Value) *html.Node {
	object, ok := value.(*goja.Object)
	if !ok {
		return nil
	}
	self, okSelf := goja.AssertFunction(object.Get("__self"))
	if !okSelf {
		return nil
	}
	result, err := self(object)
	if err != nil || result == nil || goja.IsNull(result) || goja.IsUndefined(result) {
		return nil
	}
	if node, okCast := result.Export().(*html.Node); okCast {
		return node
	}
	return nil
}

// legadoJsoupObject 构造 `org.jsoup` 命名空间（脚本里写 org.jsoup.Jsoup）。
func legadoJsoupObject(vm *goja.Runtime, baseURL string) *goja.Object {
	namespace := vm.NewObject()
	jsoup := vm.NewObject()

	parse := func(call goja.FunctionCall) goja.Value {
		text := call.Argument(0).String()
		base := baseURL
		if len(call.Arguments) > 1 && call.Argument(1).String() != "" {
			base = legadoResolveURL(baseURL, call.Argument(1).String())
		}
		return vm.ToValue(legadoWrapNode(vm, legadoParseDocument(text), base))
	}
	_ = jsoup.Set("parse", parse)
	// Jsoup.parseBodyFragment(html)：解析片段并返回 <body>，漫画源用来处理卡片列表。
	_ = jsoup.Set("parseBodyFragment", func(call goja.FunctionCall) goja.Value {
		text := call.Argument(0).String()
		base := baseURL
		if len(call.Arguments) > 1 && call.Argument(1).String() != "" {
			base = legadoResolveURL(baseURL, call.Argument(1).String())
		}
		body := &html.Node{Type: html.ElementNode, Data: "body", DataAtom: atom.Body}
		container := legadoParseFragment(text)
		children := make([]*html.Node, 0, 8)
		for child := container.FirstChild; child != nil; child = child.NextSibling {
			children = append(children, child)
		}
		for _, child := range children {
			// 片段里的节点已经挂在临时容器上，先摘下来再挂到 body
			container.RemoveChild(child)
			body.AppendChild(child)
		}
		return vm.ToValue(legadoWrapNode(vm, body, base))
	})
	// 少数书源写 Jsoup.connect(url).get()，本地没有连接池，返回空对象
	_ = jsoup.Set("connect", func(call goja.FunctionCall) goja.Value {
		return goja.Undefined()
	})
	_ = namespace.Set("Jsoup", jsoup)
	_ = namespace.Set("parse", parse)

	// org.jsoup.select.Elements / org.jsoup.nodes.Element：脚本里偶尔直接 new 出来判类型
	selectNs := vm.NewObject()
	_ = selectNs.Set("Elements", legadoClassObject(vm, "org.jsoup.select.Elements", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			return legadoWrapNodes(vm, nil, baseURL)
		},
	}))
	_ = namespace.Set("select", selectNs)
	nodesNs := vm.NewObject()
	_ = nodesNs.Set("Element", legadoClassObject(vm, "org.jsoup.nodes.Element", nil))
	_ = nodesNs.Set("Document", legadoClassObject(vm, "org.jsoup.nodes.Document", nil))
	_ = namespace.Set("nodes", nodesNs)
	return namespace
}

// legadoNodeRuleContext 以某个元素为根构造规则上下文（元素级 getString 用）。
func legadoNodeRuleContext(node *html.Node, baseURL string) *legadoRuleContext {
	ctx := newLegadoRuleContext(legadoElementHTML(node), baseURL, nil)
	ctx.root = node
	return ctx
}

// legadoParseFragment 解析「HTML 片段」，返回一个容纳结果的容器节点。
//
// 直接用 html.Parse 会踩 HTML5 的树构建规则：`<tr>`/`<td>` 出现在
// body 里会被整段丢掉。所以按首标签挑合适的上下文再做 ParseFragment。
func legadoParseFragment(text string) *html.Node {
	context := legadoFragmentContext(text)
	nodes, err := html.ParseFragment(strings.NewReader(text), context)
	container := &html.Node{Type: html.ElementNode, Data: "div", DataAtom: atom.Div}
	if err != nil {
		return container
	}
	for _, node := range nodes {
		container.AppendChild(node)
	}
	return container
}

func legadoFragmentContext(text string) *html.Node {
	lower := strings.ToLower(strings.TrimSpace(text))
	makeNode := func(name string, a atom.Atom) *html.Node {
		return &html.Node{Type: html.ElementNode, Data: name, DataAtom: a}
	}
	switch {
	case strings.HasPrefix(lower, "<tr"):
		return makeNode("tbody", atom.Tbody)
	case strings.HasPrefix(lower, "<td"), strings.HasPrefix(lower, "<th"):
		return makeNode("tr", atom.Tr)
	case strings.HasPrefix(lower, "<tbody"), strings.HasPrefix(lower, "<thead"),
		strings.HasPrefix(lower, "<tfoot"), strings.HasPrefix(lower, "<caption"):
		return makeNode("table", atom.Table)
	case strings.HasPrefix(lower, "<li"):
		return makeNode("ul", atom.Ul)
	case strings.HasPrefix(lower, "<option"):
		return makeNode("select", atom.Select)
	}
	return makeNode("div", atom.Div)
}

// legadoFirstElement 取文档里的第一个元素节点（document 下面就是 <html>）。
func legadoFirstElement(document *html.Node) *html.Node {
	if document == nil {
		return nil
	}
	if document.Type == html.ElementNode {
		return document
	}
	for child := document.FirstChild; child != nil; child = child.NextSibling {
		if found := legadoFirstElement(child); found != nil {
			return found
		}
	}
	return nil
}
