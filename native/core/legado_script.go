package core

// Legado（阅读 3.x）书源的 JavaScript 运行环境。
//
// 用 goja（纯 Go 的 ES 实现）执行书源里的 `@js:` 规则与 jsLib，
// 并模拟 Legado 暴露给脚本的 java.* / source / cookie 宿主接口。
//
// 关键点：Legado 的脚本语义是「同步」的 —— java.ajax 直接返回响应正文。
// goja 本身就是同步执行，Go 的 http 也是同步语义，所以这里天然对齐，
// 不需要像 Dart 侧那样绕异步。

import (
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

// LegadoJsSource 是执行脚本时可访问的书源信息。
type LegadoJsSource struct {
	Key       string            `json:"key"`
	Name      string            `json:"name"`
	URL       string            `json:"url"`
	Header    string            `json:"header"`
	Variables map[string]string `json:"variables"`
}

// LegadoJsBook 是执行脚本时可访问的书籍信息。
type LegadoJsBook struct {
	Name   string            `json:"name"`
	Author string            `json:"author"`
	URL    string            `json:"url"`
	Vars   map[string]string `json:"vars"`
}

// LegadoJsRequest 一次脚本执行。
type LegadoJsRequest struct {
	// Code 要去掉 `@js:` 前缀之后的脚本体。
	Code string `json:"code"`
	// JsLib 书源的 jsLib，执行前先跑一遍。
	JsLib string `json:"jsLib"`
	// Key / Page 搜索关键词与页码。
	Key  string `json:"key"`
	Page int    `json:"page"`
	// BaseURL 当前页面地址（取值规则里的 baseUrl）。
	BaseURL string `json:"baseUrl"`
	// Result 前置规则的结果，脚本里以 result 访问。
	Result string `json:"result"`
	// ResultIsElement 为真时 Result 是元素的 outerHTML，
	// 脚本里的 result 应该拿到一个能 .select()/.attr() 的元素对象（jsoup 语义）。
	ResultIsElement bool `json:"resultElement"`
	// Extras 额外注入的全局变量（如正文页的 title 等）。
	Extras map[string]string `json:"extras"`
	Source LegadoJsSource    `json:"source"`
	Book   *LegadoJsBook     `json:"book"`
}

// LegadoJsResponse 脚本执行结果。
type LegadoJsResponse struct {
	OK    bool   `json:"ok"`
	Value string `json:"value"`
	Error string `json:"error"`
	// Variables 脚本用 java.put 写下的变量，调用方负责持久化。
	Variables map[string]string `json:"variables"`
	// Requests 记录脚本发起的请求数，方便排查。
	Requests int `json:"requests"`
}

var (
	legadoJarMu sync.Mutex
	legadoJars  = map[string]*cookiejar.Jar{}
)

func legadoJar(sourceKey string) *cookiejar.Jar {
	legadoJarMu.Lock()
	defer legadoJarMu.Unlock()
	key := sourceKey
	if key == "" {
		key = "_default"
	}
	if jar, ok := legadoJars[key]; ok {
		return jar
	}
	jar, _ := cookiejar.New(nil)
	legadoJars[key] = jar
	return jar
}

// ResetLegadoCookies 清掉某个源的 cookie（书源删除时调用）。
func ResetLegadoCookies(sourceKey string) {
	legadoJarMu.Lock()
	defer legadoJarMu.Unlock()
	delete(legadoJars, sourceKey)
}

// legadoHttpOptions 对应 Legado 里 `url,{"method":"POST","body":...,"headers":{...}}` 的第二段。
type legadoHttpOptions struct {
	Method  string            `json:"method"`
	Body    string            `json:"body"`
	Charset string            `json:"charset"`
	Headers map[string]string `json:"headers"`
}

// EvalLegadoScript 执行一段书源脚本，返回字符串结果。
func EvalLegadoScript(req LegadoJsRequest) (resp LegadoJsResponse) {
	resp.Variables = map[string]string{}
	defer func() {
		if r := recover(); r != nil {
			resp.OK = false
			resp.Error = fmt.Sprintf("脚本执行异常：%v", r)
		}
	}()

	vm := goja.New()
	vm.SetFieldNameMapper(goja.TagFieldNameMapper("json", true))

	state := &legadoRuntimeState{
		vm:        vm,
		source:    req.Source,
		variables: map[string]string{},
	}
	for k, v := range req.Source.Variables {
		state.variables[k] = v
	}
	client := &http.Client{
		Timeout: 25 * time.Second,
		Jar:     legadoJar(req.Source.Key),
	}
	state.client = client

	// ---- 全局变量 ----
	_ = vm.Set("key", req.Key)
	_ = vm.Set("page", req.Page)
	_ = vm.Set("baseUrl", req.BaseURL)
	if req.ResultIsElement && strings.TrimSpace(req.Result) != "" {
		element := legadoFirstElement(legadoParseFragment(req.Result))
		if element != nil {
			_ = vm.Set("result", legadoWrapNode(vm, element, req.BaseURL))
		} else {
			_ = vm.Set("result", req.Result)
		}
	} else {
		_ = vm.Set("result", req.Result)
	}
	for k, v := range req.Extras {
		_ = vm.Set(k, v)
	}

	// ---- java 对象 ----
	javaObj := vm.NewObject()
	_ = javaObj.Set("ajax", func(call goja.FunctionCall) goja.Value {
		raw := call.Argument(0).String()
		if len(call.Arguments) > 1 {
			raw = raw + "," + call.Argument(1).String()
		}
		body, err := state.doRequest(raw)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(body)
	})
	_ = javaObj.Set("get", func(call goja.FunctionCall) goja.Value {
		address := call.Argument(0).String()
		headers := ""
		if len(call.Arguments) > 1 {
			headers = call.Argument(1).String()
		}
		body, err := state.doRequest(address + `,{"method":"GET","headers":` + headerJSON(headers) + `}`)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(body)
	})
	_ = javaObj.Set("post", func(call goja.FunctionCall) goja.Value {
		address := call.Argument(0).String()
		payload := ""
		if len(call.Arguments) > 1 {
			payload = call.Argument(1).String()
		}
		headers := ""
		if len(call.Arguments) > 2 {
			headers = call.Argument(2).String()
		}
		options := fmt.Sprintf(`{"method":"POST","body":%s,"headers":%s}`,
			jsonString(payload), headerJSON(headers))
		body, err := state.doRequest(address + "," + options)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(body)
	})
	_ = javaObj.Set("base64Encode", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(base64.StdEncoding.EncodeToString([]byte(call.Argument(0).String())))
	})
	_ = javaObj.Set("base64Decode", func(call goja.FunctionCall) goja.Value {
		bytes, err := base64.StdEncoding.DecodeString(call.Argument(0).String())
		if err != nil {
			return vm.ToValue("")
		}
		return vm.ToValue(string(bytes))
	})
	_ = javaObj.Set("md5Encode", func(call goja.FunctionCall) goja.Value {
		sum := md5.Sum([]byte(call.Argument(0).String()))
		return vm.ToValue(hex.EncodeToString(sum[:]))
	})
	_ = javaObj.Set("md5Encode16", func(call goja.FunctionCall) goja.Value {
		sum := md5.Sum([]byte(call.Argument(0).String()))
		return vm.ToValue(hex.EncodeToString(sum[:])[8:24])
	})
	_ = javaObj.Set("put", func(call goja.FunctionCall) goja.Value {
		state.variables[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = javaObj.Set("log", func(call goja.FunctionCall) goja.Value { return goja.Undefined() })
	_ = javaObj.Set("toast", func(call goja.FunctionCall) goja.Value { return goja.Undefined() })
	_ = javaObj.Set("longToast", func(call goja.FunctionCall) goja.Value { return goja.Undefined() })
	_ = javaObj.Set("getCookie", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(state.cookieOf(call.Argument(0).String()))
	})
	_ = javaObj.Set("setCookie", func(call goja.FunctionCall) goja.Value {
		state.setCookie(call.Argument(0).String(), call.Argument(1).String())
		return goja.Undefined()
	})
	_ = javaObj.Set("removeCookie", func(call goja.FunctionCall) goja.Value {
		ResetLegadoCookies(req.Source.Key)
		return goja.Undefined()
	})
	_ = javaObj.Set("timeFormat", func(call goja.FunctionCall) goja.Value {
		millis := call.Argument(0).ToInteger()
		layout := "2006-01-02 15:04:05"
		if len(call.Arguments) > 1 && call.Argument(1).String() != "" {
			layout = javaTimeLayout(call.Argument(1).String())
		}
		return vm.ToValue(time.UnixMilli(millis).Format(layout))
	})
	_ = javaObj.Set("encodeURI", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(encodeURIComponent(call.Argument(0).String()))
	})

	// ---- 设备信息：书源基本只是拿来做设备指纹，给稳定假值就够 ----
	_ = javaObj.Set("androidId", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoDeviceID(req.Source.Key))
	})
	_ = javaObj.Set("deviceID", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoDeviceID(req.Source.Key))
	})
	_ = javaObj.Set("getWebViewUA", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWebViewUA)
	})

	// ---- 编解码补齐 ----
	_ = javaObj.Set("hexDecodeToString", func(call goja.FunctionCall) goja.Value {
		bytes, err := hex.DecodeString(strings.TrimSpace(call.Argument(0).String()))
		if err != nil {
			return vm.ToValue("")
		}
		return vm.ToValue(string(bytes))
	})
	_ = javaObj.Set("hexDecodeToByteArray", func(call goja.FunctionCall) goja.Value {
		bytes, err := hex.DecodeString(strings.TrimSpace(call.Argument(0).String()))
		if err != nil {
			return vm.ToValue(vm.NewArray())
		}
		return vm.ToValue(legadoByteArray(vm, bytes))
	})
	_ = javaObj.Set("base64DecodeToByteArray", func(call goja.FunctionCall) goja.Value {
		bytes, err := base64.StdEncoding.DecodeString(call.Argument(0).String())
		if err != nil {
			return vm.ToValue(vm.NewArray())
		}
		return vm.ToValue(legadoByteArray(vm, bytes))
	})
	_ = javaObj.Set("digestHex", func(call goja.FunctionCall) goja.Value {
		algo := strings.ToLower(call.Argument(0).String())
		text := call.Argument(1).String()
		return vm.ToValue(legadoDigestHex(algo, text))
	})

	// ---- 批量请求 / 动态加载脚本 ----
	_ = javaObj.Set("ajaxAll", func(call goja.FunctionCall) goja.Value {
		array := vm.NewArray()
		if list, ok := call.Argument(0).Export().([]interface{}); ok {
			for index, item := range list {
				body, err := state.doRequest(fmt.Sprint(item))
				if err != nil {
					body = ""
				}
				_ = array.Set(fmt.Sprint(index), body)
			}
		}
		return vm.ToValue(array)
	})
	_ = javaObj.Set("importScript", func(call goja.FunctionCall) goja.Value {
		address := call.Argument(0).String()
		if !strings.Contains(address, "://") {
			// 相对地址（含 `/prefix/...` 这种根相对）按书源主域补全
			base, err := url.Parse(req.Source.URL)
			if err == nil {
				if ref, refErr := url.Parse(address); refErr == nil {
					address = base.ResolveReference(ref).String()
				}
			}
		}
		body, err := state.doRequest(address)
		if err != nil {
			return goja.Undefined()
		}
		if _, err := vm.RunString(body); err != nil {
			return goja.Undefined()
		}
		return goja.Undefined()
	})

	// ---- 交互式接口：本地没有浏览器 UI，统一给空值，别让脚本直接 TypeError ----
	for _, name := range []string{
		"startBrowser", "startBrowserAwait", "startBrowserDp", "showBrowser",
		"showReadingBrowser", "webView", "open", "openUrl", "getVerificationCode",
		"refreshExplore", "refreshTocUrl", "getReadBookConfigMap",
		"getThemeConfigMap", "upLoginData", "copyText", "setContent",
	} {
		_ = javaObj.Set(name, func(call goja.FunctionCall) goja.Value {
			return vm.ToValue("")
		})
	}
	// qread() 是「轻阅读」的设备标记，这里按普通安卓处理，明确抛错走别的分支
	_ = javaObj.Set("qread", func(call goja.FunctionCall) goja.Value {
		panic(vm.NewTypeError("qread is not supported"))
	})
	_ = vm.Set("java", javaObj)

	// ---- jsoup / Java 类库 ----
	orgObj := vm.NewObject()
	_ = orgObj.Set("jsoup", legadoJsoupObject(vm, req.BaseURL))
	_ = vm.Set("org", orgObj)
	packagesObj, javaResolver := legadoPackagesObject(vm, req.BaseURL)
	_ = vm.Set("Packages", packagesObj)
	javaNamespace := vm.NewObject()
	_ = javaNamespace.Set("type", legadoJavaType(vm, javaResolver))
	_ = vm.Set("Java", javaNamespace)
	// Rhino 的 JavaImporter，书源里配合 with(...){...} 用
	_ = vm.Set("JavaImporter", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(packagesObj)
	})

	// Legado 里 java.get 与读变量同名冲突，这里用一个显式的变量访问对象补上
	varsObj := vm.NewObject()
	_ = varsObj.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(state.variables[call.Argument(0).String()])
	})
	_ = varsObj.Set("put", func(call goja.FunctionCall) goja.Value {
		state.variables[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = vm.Set("cache", varsObj)

	// ---- cookie 对象 ----
	cookieObj := vm.NewObject()
	_ = cookieObj.Set("getCookie", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(state.cookieOf(call.Argument(0).String()))
	})
	_ = cookieObj.Set("setCookie", func(call goja.FunctionCall) goja.Value {
		state.setCookie(call.Argument(0).String(), call.Argument(1).String())
		return goja.Undefined()
	})
	_ = cookieObj.Set("removeCookie", func(call goja.FunctionCall) goja.Value {
		ResetLegadoCookies(req.Source.Key)
		return goja.Undefined()
	})
	_ = vm.Set("cookie", cookieObj)

	// ---- source 对象 ----
	sourceObj := vm.NewObject()
	_ = sourceObj.Set("key", req.Source.Key)
	_ = sourceObj.Set("name", req.Source.Name)
	_ = sourceObj.Set("bookSourceUrl", req.Source.URL)
	_ = sourceObj.Set("getKey", func(call goja.FunctionCall) goja.Value { return vm.ToValue(req.Source.Key) })
	_ = sourceObj.Set("getVariable", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(state.variables[call.Argument(0).String()])
	})
	_ = sourceObj.Set("setVariable", func(call goja.FunctionCall) goja.Value {
		state.variables[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = sourceObj.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(state.variables[call.Argument(0).String()])
	})
	_ = sourceObj.Set("set", func(call goja.FunctionCall) goja.Value {
		state.variables[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = vm.Set("source", sourceObj)

	// ---- book 对象 ----
	bookObj := vm.NewObject()
	if req.Book != nil {
		_ = bookObj.Set("name", req.Book.Name)
		_ = bookObj.Set("author", req.Book.Author)
		_ = bookObj.Set("bookUrl", req.Book.URL)
		_ = bookObj.Set("getVariable", func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(req.Book.Vars[call.Argument(0).String()])
		})
	}
	_ = vm.Set("book", bookObj)

	// ---- 执行 jsLib ----
	if strings.TrimSpace(req.JsLib) != "" {
		if _, err := vm.RunString(req.JsLib); err != nil {
			resp.Error = "jsLib 执行失败：" + shortErr(err)
			return resp
		}
	}

	value, err := vm.RunString(req.Code)
	if err != nil && strings.Contains(err.Error(), "Illegal return statement") {
		// 书源脚本经常直接写 `return x;`（Legado 的 eval 容忍这种写法），
		// 先按原样跑，报这个错时再包成函数重试。
		value, err = vm.RunString("(function(){\n" + req.Code + "\n})()")
	}
	if err != nil {
		resp.Error = shortErr(err)
		return resp
	}
	resp.OK = true
	resp.Value = legadoResultString(value)
	resp.Variables = state.variables
	resp.Requests = state.requests
	return resp
}

// legadoResultString 把脚本返回值转成字符串。
//
// 字符串原样返回；对象/数组转 JSON —— 书源的 bookList 规则常写成
// `@js:list.map(o => JSON.stringify(o))` 或直接返回对象数组，
// 后面再用 `$.name` 这类 JSONPath 取值。
func legadoResultString(value goja.Value) string {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return ""
	}
	switch typed := value.Export().(type) {
	case string:
		return typed
	case []byte:
		return string(typed)
	case map[string]interface{}, []interface{}:
		if encoded, err := json.Marshal(typed); err == nil {
			return string(encoded)
		}
	}
	return value.String()
}

type legadoRuntimeState struct {
	vm        *goja.Runtime
	client    *http.Client
	source    LegadoJsSource
	variables map[string]string
	requests  int
}

// doRequest 解析 Legado 的 `url,{options}` 写法并同步请求。
func (s *legadoRuntimeState) doRequest(raw string) (string, error) {
	address, options := splitLegadoRequest(raw)
	if address == "" {
		return "", fmt.Errorf("空地址")
	}
	if !strings.Contains(address, "://") {
		address = resolveAgainst(s.source.URL, address)
	}

	method := "GET"
	body := ""
	var headers map[string]string
	if options != "" {
		var opt legadoHttpOptions
		if err := json.Unmarshal([]byte(options), &opt); err == nil {
			if opt.Method != "" {
				method = strings.ToUpper(opt.Method)
			}
			body = opt.Body
			headers = opt.Headers
		}
	}

	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request, err := http.NewRequest(method, address, reader)
	if err != nil {
		return "", err
	}
	if s.source.Header != "" {
		applyHeaderJSON(request, s.source.Header)
	}
	for k, v := range headers {
		request.Header.Set(k, v)
	}
	if request.Header.Get("User-Agent") == "" {
		request.Header.Set("User-Agent", legadoDefaultUA)
	}

	s.requests++
	response, err := s.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return "", err
	}
	if response.StatusCode >= 400 {
		return "", fmt.Errorf("HTTP %d", response.StatusCode)
	}
	return decodeLegadoBody(payload, response.Header.Get("Content-Type")), nil
}

func (s *legadoRuntimeState) cookieOf(address string) string {
	parsed, err := url.Parse(address)
	if err != nil || s.client.Jar == nil {
		return ""
	}
	parts := make([]string, 0, 4)
	for _, cookie := range s.client.Jar.Cookies(parsed) {
		parts = append(parts, cookie.Name+"="+cookie.Value)
	}
	return strings.Join(parts, "; ")
}

func (s *legadoRuntimeState) setCookie(address, raw string) {
	parsed, err := url.Parse(address)
	if err != nil || s.client.Jar == nil {
		return
	}
	cookies := parseCookieHeader(raw)
	if len(cookies) > 0 {
		s.client.Jar.SetCookies(parsed, cookies)
	}
}

const legadoDefaultUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
	"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

// splitLegadoRequest 把 `url,{...}` 拆成地址和 options。
func splitLegadoRequest(raw string) (string, string) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", ""
	}
	index := strings.LastIndex(text, `,{`)
	if index <= 0 {
		return text, ""
	}
	candidate := strings.TrimSpace(text[index+1:])
	if !strings.HasSuffix(candidate, "}") {
		return text, ""
	}
	var probe map[string]any
	if err := json.Unmarshal([]byte(candidate), &probe); err != nil {
		return text, ""
	}
	return strings.TrimSpace(text[:index]), candidate
}

func resolveAgainst(base, link string) string {
	if link == "" {
		return link
	}
	if strings.HasPrefix(link, "//") {
		return "https:" + link
	}
	parsedBase, err := url.Parse(base)
	if err != nil {
		return link
	}
	parsedLink, err := url.Parse(link)
	if err != nil {
		return link
	}
	return parsedBase.ResolveReference(parsedLink).String()
}

func applyHeaderJSON(request *http.Request, raw string) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return
	}
	var headers map[string]string
	if err := json.Unmarshal([]byte(trimmed), &headers); err != nil {
		return
	}
	for k, v := range headers {
		request.Header.Set(k, v)
	}
}

func headerJSON(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "{}"
	}
	if strings.HasPrefix(trimmed, "{") {
		return trimmed
	}
	return "{}"
}

func jsonString(text string) string {
	encoded, err := json.Marshal(text)
	if err != nil {
		return `""`
	}
	return string(encoded)
}

func parseCookieHeader(raw string) []*http.Cookie {
	parts := strings.Split(raw, ";")
	out := make([]*http.Cookie, 0, len(parts))
	for _, part := range parts {
		item := strings.TrimSpace(part)
		if item == "" {
			continue
		}
		name, value, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		out = append(out, &http.Cookie{Name: strings.TrimSpace(name), Value: strings.TrimSpace(value)})
	}
	return out
}

func decodeLegadoBody(payload []byte, contentType string) string {
	lower := strings.ToLower(contentType)
	if strings.Contains(lower, "gbk") || strings.Contains(lower, "gb2312") {
		if converted, err := decodeNovelBytes(payload); err == nil {
			return converted
		}
	}
	if converted, err := decodeNovelBytes(payload); err == nil {
		return converted
	}
	return string(payload)
}

func encodeURIComponent(text string) string {
	return strings.ReplaceAll(url.QueryEscape(text), "+", "%20")
}

// javaTimeLayout 把 Java 的 SimpleDateFormat 粗略映射成 Go layout。
func javaTimeLayout(pattern string) string {
	replacer := strings.NewReplacer(
		"yyyy", "2006",
		"yy", "06",
		"MM", "01",
		"dd", "02",
		"HH", "15",
		"mm", "04",
		"ss", "05",
	)
	return replacer.Replace(pattern)
}

func shortErr(err error) string {
	text := err.Error()
	if len(text) > 200 {
		text = text[:200] + "…"
	}
	return text
}


// legadoWebViewUA 是 java.getWebViewUA() 的返回值。
//
// 书源主要拿它冒充浏览器内核，用安卓 WebView 的常见串最稳。
const legadoWebViewUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) " +
	"AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/119.0.6045.163 Mobile Safari/537.36"

// legadoDeviceID 生成稳定的伪设备号。
//
// 书源（尤其聚合源）用 java.androidId() / java.deviceID() 做设备指纹，
// 值本身不重要，但要保证同一次运行里前后一致、不同源之间不串味。
func legadoDeviceID(seed string) string {
	sum := md5.Sum([]byte("duanju-legado-device:" + seed))
	return hex.EncodeToString(sum[:])
}

// legadoByteArray 把字节切片转成 JS 的整数数组（Legado 返回的是 byte[]）。
func legadoByteArray(vm *goja.Runtime, bytes []byte) goja.Value {
	values := make([]interface{}, len(bytes))
	for index, b := range bytes {
		values[index] = int64(b)
	}
	return vm.ToValue(values)
}

// legadoDigestHex 实现 java.digestHex(algo, text)。
func legadoDigestHex(algo, text string) string {
	switch algo {
	case "md5":
		sum := md5.Sum([]byte(text))
		return hex.EncodeToString(sum[:])
	case "sha1":
		sum := sha1.Sum([]byte(text))
		return hex.EncodeToString(sum[:])
	case "sha256":
		sum := sha256.Sum256([]byte(text))
		return hex.EncodeToString(sum[:])
	}
	return ""
}
