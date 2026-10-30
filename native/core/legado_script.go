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
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"golang.org/x/net/html"
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
	// JsLibKey 是 JsLib 的缓存键（书源 key + 内容摘要）。带上它以后，
	// 后续请求可以只传键、不重复传几百 KB~几 MB 的库源码。
	JsLibKey string `json:"jsLibKey"`
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

// legadoJsLibCache 缓存书源 jsLib：番茄这类源单个库就有 1.4MB，
// 每章正文都重新传一遍不现实，Dart 侧发一次后只发 JsLibKey。
var (
	legadoJsLibMu    sync.Mutex
	legadoJsLibCache = map[string]string{}
	legadoJsLibOrder []string
)

const (
	legadoJsLibCacheLimit = 32
	// legadoJsLibMissing 是「只发了键、本地没缓存」的错误前缀，Dart 侧据此重发整库。
	legadoJsLibMissing = "jsLib-missing:"
)

// resolveLegadoJsLib 取本次要执行的 jsLib：优先用请求里带的，其次查缓存。
func resolveLegadoJsLib(req LegadoJsRequest) (string, error) {
	key := strings.TrimSpace(req.JsLibKey)
	if strings.TrimSpace(req.JsLib) == "" {
		if key == "" {
			return "", nil
		}
		legadoJsLibMu.Lock()
		defer legadoJsLibMu.Unlock()
		lib, ok := legadoJsLibCache[key]
		if !ok {
			return "", fmt.Errorf("%s%s", legadoJsLibMissing, key)
		}
		return lib, nil
	}
	if key != "" {
		legadoJsLibMu.Lock()
		if _, exists := legadoJsLibCache[key]; !exists {
			for len(legadoJsLibOrder) >= legadoJsLibCacheLimit {
				delete(legadoJsLibCache, legadoJsLibOrder[0])
				legadoJsLibOrder = legadoJsLibOrder[1:]
			}
			legadoJsLibOrder = append(legadoJsLibOrder, key)
		}
		legadoJsLibCache[key] = req.JsLib
		legadoJsLibMu.Unlock()
	}
	return req.JsLib, nil
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

	jsLib, libErr := resolveLegadoJsLib(req)
	if libErr != nil {
		resp.Error = libErr.Error()
		return resp
	}

	vm := goja.New()
	vm.SetFieldNameMapper(goja.TagFieldNameMapper("json", true))

	state := &legadoRuntimeState{
		vm:        vm,
		source:    req.Source,
		variables: map[string]string{},
		extras:    req.Extras,
	}
	for k, v := range req.Source.Variables {
		state.variables[k] = v
	}
	client := &http.Client{
		Timeout: 25 * time.Second,
		Jar:     legadoJar(req.Source.Key),
	}
	state.client = client

	// ---- 规则求值上下文：java.getString / getElements 等扩展函数用 ----
	ruleVars := map[string]string{
		"key":     req.Key,
		"page":    strconv.Itoa(req.Page),
		"baseUrl": req.BaseURL,
	}
	for key, value := range req.Extras {
		ruleVars[key] = value
	}
	var contentRoot *html.Node
	if req.ResultIsElement && strings.TrimSpace(req.Result) != "" {
		contentRoot = legadoFirstElement(legadoParseFragment(req.Result))
	}
	if contentRoot != nil {
		state.ruleCtx = legadoRuleContextForElement(contentRoot, req.Result, req.BaseURL, ruleVars)
	} else {
		state.ruleCtx = newLegadoRuleContext(req.Result, req.BaseURL, ruleVars)
	}

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
	// java.get / java.post 在「阅读」里返回的是 Response 对象
	// （`resp.body()` / `resp.header('location')` / `resp.code()`），
	// 但不少书源也直接把它当字符串用，所以返回对象同时实现了字符串转换。
	_ = javaObj.Set("get", func(call goja.FunctionCall) goja.Value {
		address := strings.TrimSpace(call.Argument(0).String())
		if !legadoLooksLikeURL(address) {
			// java.get('time') 这类是取上一次解析的字段，给空值兜底
			return vm.ToValue(state.lookupExtra(address))
		}
		headers := legadoHeaderArgs(call.Argument(1))
		result, err := state.fetch("GET", address, "", headers, false)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(legadoResponseObject(vm, result, address))
	})
	_ = javaObj.Set("post", func(call goja.FunctionCall) goja.Value {
		address := strings.TrimSpace(call.Argument(0).String())
		payload := ""
		if len(call.Arguments) > 1 {
			payload = call.Argument(1).String()
		}
		result, err := state.fetch("POST", address, payload, legadoHeaderArgs(call.Argument(2)), true)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(legadoResponseObject(vm, result, address))
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

	// ---- 规则取值扩展：java.getString / getElements / getElementList ... ----
	//
	// 书源脚本（尤其聚合源和漫画源）大量用这套把「阅读」规则作用在当前正文上，
	// 比如 `java.getString('class.list@tag.li.0@a@href')`。
	_ = javaObj.Set("getString", func(call goja.FunctionCall) goja.Value {
		rule := legadoExpandTemplate(call.Argument(0).String(), ruleVars)
		if rule == "" {
			return vm.ToValue("")
		}
		value := legadoRuleString(rule, state.ruleCtx)
		if len(call.Arguments) > 1 && call.Argument(1).ToBoolean() && value != "" {
			value = legadoResolveURL(state.ruleCtx.url, value)
		}
		return vm.ToValue(value)
	})
	_ = javaObj.Set("getStringList", func(call goja.FunctionCall) goja.Value {
		rule := legadoExpandTemplate(call.Argument(0).String(), ruleVars)
		if rule == "" {
			return vm.ToValue(vm.NewArray())
		}
		return vm.ToValue(legadoRuleStrings(rule, state.ruleCtx))
	})
	_ = javaObj.Set("getElements", func(call goja.FunctionCall) goja.Value {
		rule := legadoExpandTemplate(call.Argument(0).String(), ruleVars)
		return vm.ToValue(legadoWrapNodes(vm, legadoRuleNodes(rule, state.ruleCtx), state.ruleCtx.url))
	})
	_ = javaObj.Set("getElement", func(call goja.FunctionCall) goja.Value {
		rule := legadoExpandTemplate(call.Argument(0).String(), ruleVars)
		nodes := legadoRuleNodes(rule, state.ruleCtx)
		if len(nodes) == 0 {
			return goja.Null()
		}
		return vm.ToValue(legadoWrapNode(vm, nodes[0], state.ruleCtx.url))
	})
	_ = javaObj.Set("getElementList", javaObj.Get("getElements"))

	// ---- 编码 / 字符集 ----
	_ = javaObj.Set("strToBytes", func(call goja.FunctionCall) goja.Value {
		charset := ""
		if len(call.Arguments) > 1 {
			charset = legadoCharsetName(vm, call.Argument(1))
		}
		return vm.ToValue(legadoByteArray(vm, legadoBytesOfString(call.Argument(0).String(), charset)))
	})
	_ = javaObj.Set("bytesToStr", func(call goja.FunctionCall) goja.Value {
		charset := ""
		if len(call.Arguments) > 1 {
			charset = legadoCharsetName(vm, call.Argument(1))
		}
		return vm.ToValue(legadoStringOfBytes(legadoBytesOf(call.Argument(0)), charset))
	})
	_ = javaObj.Set("hexEncodeToString", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(hex.EncodeToString(legadoBytesOf(call.Argument(0))))
	})
	// ---- 繁转简（书源里的「简体显示」开关） ----
	_ = javaObj.Set("t2s", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoT2S(call.Argument(0).String()))
	})
	// ---- 对称加解密快捷接口 ----
	_ = javaObj.Set("createSymmetricCrypto", func(call goja.FunctionCall) goja.Value {
		transformation := strings.TrimSpace(call.Argument(0).String())
		key := legadoBytesOf(call.Argument(1))
		var iv []byte
		if len(call.Arguments) > 2 {
			iv = legadoBytesOf(call.Argument(2))
		}
		return vm.ToValue(legadoSymmetricCrypto(vm, transformation, key, iv))
	})
	// ---- 上一次解析出的字段（阅读里由引擎维护，这里给空值兜底） ----
	_ = javaObj.Set("getUrl", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoResolveURL(state.ruleCtx.url, call.Argument(0).String()))
	})
	_ = javaObj.Set("timeFormatUTC", func(call goja.FunctionCall) goja.Value {
		millis := call.Argument(0).ToInteger()
		layout := "2006-01-02 15:04:05"
		if len(call.Arguments) > 1 && call.Argument(1).String() != "" {
			layout = javaTimeLayout(call.Argument(1).String())
		}
		return vm.ToValue(time.UnixMilli(millis).UTC().Format(layout))
	})
	// 搜索/登录类接口：没有浏览器与书城索引，给空值别抛 TypeError
	for _, name := range []string{
		"searchBook", "connect", "getZipStringContent", "queryBase64Img",
		"getLoginInfo", "getLoginHeader", "putLoginInfo", "putLoginHeader",
		"removeLoginHeader", "upLoginInfo", "getContent", "login", "logType",
	} {
		_ = javaObj.Set(name, func(call goja.FunctionCall) goja.Value {
			return vm.ToValue("")
		})
	}
	for _, name := range []string{"getLoginInfoMap", "getLoginHeaderMap"} {
		_ = javaObj.Set(name, func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(vm.NewObject())
		})
	}

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
	packagesObj, javaResolver := legadoPackagesObject(vm, req.BaseURL, client)
	_ = packagesObj.Set("org", orgObj)
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
	// 聚合源常用 cache.putMemory / getFromMemory 做进程内缓存
	_ = varsObj.Set("putMemory", varsObj.Get("put"))
	_ = varsObj.Set("getFromMemory", varsObj.Get("get"))
	_ = varsObj.Set("delete", func(call goja.FunctionCall) goja.Value {
		delete(state.variables, call.Argument(0).String())
		return goja.Undefined()
	})
	_ = varsObj.Set("remove", varsObj.Get("delete"))
	_ = vm.Set("cache", varsObj)

	// ---- CryptoJS：书源 jsLib 里常见，脚本直接 new/调用 ----
	_ = vm.Set("CryptoJS", legadoCryptoJsObject(vm))

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
	_ = sourceObj.Set("bookSourceName", req.Source.Name)
	_ = sourceObj.Set("header", req.Source.Header)
	_ = sourceObj.Set("loginUrl", "")
	_ = sourceObj.Set("loginUi", "")
	_ = sourceObj.Set("ruleSearch", "")
	_ = sourceObj.Set("exploreUrl", "")
	_ = sourceObj.Set("getKey", func(call goja.FunctionCall) goja.Value { return vm.ToValue(req.Source.Key) })
	_ = sourceObj.Set("getBookSourceUrl", func(call goja.FunctionCall) goja.Value { return vm.ToValue(req.Source.URL) })
	_ = sourceObj.Set("getBookSourceName", func(call goja.FunctionCall) goja.Value { return vm.ToValue(req.Source.Name) })
	_ = sourceObj.Set("getHeaderMap", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoHeaderObject(vm, req.Source.Header))
	})
	_ = sourceObj.Set("getVariable", func(call goja.FunctionCall) goja.Value {
		// 阅读的两种写法：getVariable() 取整份 JSON，getVariable(key) 取单项。
		if len(call.Arguments) == 0 || call.Argument(0).String() == "" {
			return vm.ToValue(legadoVariablesJSON(state.variables))
		}
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
	// Legado 3.x 的写法：source.put(k, v) 与 setVariable 等价。
	_ = sourceObj.Set("put", func(call goja.FunctionCall) goja.Value {
		state.variables[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = sourceObj.Set("putVariable", sourceObj.Get("put"))
	// 登录信息：本 App 没有内嵌浏览器登录，读写都当空，别让脚本 TypeError。
	_ = sourceObj.Set("getLoginInfoMap", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(vm.NewObject())
	})
	_ = sourceObj.Set("getLoginHeaderMap", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(vm.NewObject())
	})
	_ = sourceObj.Set("getLoginInfo", func(call goja.FunctionCall) goja.Value { return vm.ToValue("") })
	_ = sourceObj.Set("getLoginHeader", func(call goja.FunctionCall) goja.Value { return vm.ToValue("") })
	for _, name := range []string{
		"putLoginInfo", "putLoginHeader", "removeLoginInfo", "removeLoginHeader", "refreshExplore",
	} {
		_ = sourceObj.Set(name, func(call goja.FunctionCall) goja.Value { return goja.Undefined() })
	}
	_ = vm.Set("source", sourceObj)

	// ---- book 对象 ----
	bookObj := vm.NewObject()
	bookVars := map[string]string{}
	if req.Book != nil {
		for key, value := range req.Book.Vars {
			bookVars[key] = value
		}
		_ = bookObj.Set("name", req.Book.Name)
		_ = bookObj.Set("author", req.Book.Author)
		_ = bookObj.Set("bookUrl", req.Book.URL)
	}
	// 脚本常读 book.type / book.tocUrl 等属性，给空值兜底（setType 会改写 type）。
	_ = bookObj.Set("type", "")
	_ = bookObj.Set("tocUrl", "")
	_ = bookObj.Set("durChapterIndex", int64(0))
	_ = bookObj.Set("durChapterTitle", "")
	_ = bookObj.Set("readConfig", vm.NewObject())
	_ = bookObj.Set("setType", func(call goja.FunctionCall) goja.Value {
		_ = bookObj.Set("type", call.Argument(0).String())
		return goja.Undefined()
	})
	_ = bookObj.Set("getVariable", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) == 0 || call.Argument(0).String() == "" {
			return vm.ToValue(legadoVariablesJSON(bookVars))
		}
		return vm.ToValue(bookVars[call.Argument(0).String()])
	})
	_ = bookObj.Set("get", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(bookVars[call.Argument(0).String()])
	})
	_ = bookObj.Set("put", func(call goja.FunctionCall) goja.Value {
		bookVars[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = bookObj.Set("putVariable", bookObj.Get("put"))
	_ = bookObj.Set("setVariable", func(call goja.FunctionCall) goja.Value {
		bookVars[call.Argument(0).String()] = call.Argument(1).String()
		return goja.Undefined()
	})
	_ = vm.Set("book", bookObj)

	// ---- 执行 jsLib ----
	if strings.TrimSpace(jsLib) != "" {
		if _, err := vm.RunString(jsLib); err != nil {
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
	extras    map[string]string
	requests  int
	// ruleCtx 是 java.getString / getElements 这类扩展函数的作用域。
	ruleCtx *legadoRuleContext
}

// lookupExtra 取前置规则产出的字段（java.get('time') 之类）。
func (s *legadoRuntimeState) lookupExtra(key string) string {
	if s.extras == nil {
		return ""
	}
	return s.extras[key]
}

// legadoLooksLikeURL 判断 java.get 的第一个参数是地址还是字段名。
func legadoLooksLikeURL(address string) bool {
	if address == "" {
		return false
	}
	lower := strings.ToLower(address)
	return strings.HasPrefix(lower, "http://") ||
		strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "//") ||
		strings.HasPrefix(address, "/")
}

// legadoHeaderArgs 把脚本传的第二个参数转成请求头。
//
// 两种写法都支持：直接给 `{ "User-Agent": "..." }`，
// 或给完整的 `{ "headers": {...}, "charset": "gbk" }`。
func legadoHeaderArgs(value goja.Value) map[string]string {
	headers := map[string]string{}
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return headers
	}
	text := strings.TrimSpace(value.String())
	if strings.HasPrefix(text, "{") {
		var raw map[string]any
		if err := json.Unmarshal([]byte(text), &raw); err != nil {
			return headers
		}
		if nested, ok := raw["headers"]; ok {
			if typed, okCast := nested.(map[string]any); okCast {
				for key, item := range typed {
					headers[key] = fmt.Sprint(item)
				}
			}
			return headers
		}
		for key, item := range raw {
			switch item.(type) {
			case map[string]any, []any:
				continue
			}
			headers[key] = fmt.Sprint(item)
		}
		return headers
	}
	if object, ok := value.(*goja.Object); ok {
		for _, key := range object.Keys() {
			item := object.Get(key)
			if item == nil || goja.IsUndefined(item) || goja.IsNull(item) {
				continue
			}
			if _, isFunc := goja.AssertFunction(item); isFunc {
				continue
			}
			headers[key] = item.String()
		}
	}
	return headers
}

// legadoFetchResult 一次请求的完整结果（Response 对象的数据源）。
type legadoFetchResult struct {
	status  int
	body    string
	headers http.Header
}

// fetch 发一次请求；followRedirects 为假时把 3xx 原样返回给脚本。
func (s *legadoRuntimeState) fetch(method, address, body string, headers map[string]string, followRedirects bool) (*legadoFetchResult, error) {
	if strings.HasPrefix(address, "data:") {
		return &legadoFetchResult{status: 200, body: decodeLegadoDataURI(address), headers: http.Header{}}, nil
	}
	if !strings.Contains(address, "://") {
		address = resolveAgainst(s.source.URL, address)
	}
	build := func() (*http.Request, error) {
		var reader io.Reader
		if body != "" {
			reader = strings.NewReader(body)
		}
		request, err := http.NewRequest(strings.ToUpper(method), address, reader)
		if err != nil {
			return nil, err
		}
		if s.source.Header != "" {
			applyHeaderJSON(request, s.source.Header)
		}
		for key, value := range headers {
			request.Header.Set(key, value)
		}
		if request.Header.Get("User-Agent") == "" {
			request.Header.Set("User-Agent", legadoDefaultUA)
		}
		return request, nil
	}

	client := s.client
	if !followRedirects {
		clone := *s.client
		clone.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
		client = &clone
	}

	request, err := build()
	if err != nil {
		return nil, err
	}
	s.requests++
	response, err := client.Do(request)
	if err != nil && legadoIsTLSError(err) {
		// 证书过期/自签的老站：换宽松传输层再试一次
		if retry, retryErr := build(); retryErr == nil {
			insecure := &http.Client{Timeout: client.Timeout, Jar: client.Jar,
				Transport: legadoInsecureTransport, CheckRedirect: client.CheckRedirect}
			response, err = insecure.Do(retry)
		}
	}
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	return &legadoFetchResult{
		status:  response.StatusCode,
		body:    decodeLegadoBody(payload, response.Header.Get("Content-Type")),
		headers: response.Header,
	}, nil
}

// legadoResponseObject 复刻 Legado 的 Response（java.get / java.post 的返回值）。
func legadoResponseObject(vm *goja.Runtime, result *legadoFetchResult, address string) *goja.Object {
	object := vm.NewObject()
	_ = object.Set("body", func(goja.FunctionCall) goja.Value { return vm.ToValue(result.body) })
	_ = object.Set("raw", func(goja.FunctionCall) goja.Value { return vm.ToValue(result.body) })
	_ = object.Set("code", func(goja.FunctionCall) goja.Value { return vm.ToValue(int64(result.status)) })
	_ = object.Set("status", func(goja.FunctionCall) goja.Value { return vm.ToValue(int64(result.status)) })
	_ = object.Set("url", func(goja.FunctionCall) goja.Value { return vm.ToValue(address) })
	_ = object.Set("isSuccessful", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(result.status >= 200 && result.status < 300)
	})
	_ = object.Set("header", func(call goja.FunctionCall) goja.Value {
		if result.headers == nil {
			return vm.ToValue("")
		}
		return vm.ToValue(result.headers.Get(call.Argument(0).String()))
	})
	_ = object.Set("headers", func(goja.FunctionCall) goja.Value {
		headers := vm.NewObject()
		for key := range result.headers {
			_ = headers.Set(key, result.headers.Get(key))
		}
		return vm.ToValue(headers)
	})
	_ = object.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(result.body) })
	_ = object.Set("valueOf", func(goja.FunctionCall) goja.Value { return vm.ToValue(result.body) })
	// 老书源把返回值当字符串用，常见字符串方法一并代理过去
	for _, name := range []string{"trim", "indexOf", "lastIndexOf", "includes", "startsWith", "endsWith",
		"substring", "substr", "slice", "charAt", "split", "replace", "match", "search", "toLowerCase",
		"toUpperCase", "concat"} {
		method := name
		_ = object.Set(method, func(call goja.FunctionCall) goja.Value {
			text := vm.ToValue(result.body).ToObject(vm)
			function, ok := goja.AssertFunction(text.Get(method))
			if !ok {
				return goja.Undefined()
			}
			value, err := function(text, call.Arguments...)
			if err != nil {
				return goja.Undefined()
			}
			return value
		})
	}
	return object
}

// legadoVariablesJSON 把变量表序列化成 JSON（source.getVariable() 无参时的返回值）。
func legadoVariablesJSON(variables map[string]string) string {
	if len(variables) == 0 {
		return "{}"
	}
	encoded, err := json.Marshal(variables)
	if err != nil {
		return "{}"
	}
	return string(encoded)
}

// legadoHeaderObject 把书源的 header JSON 变成脚本可读的对象。
func legadoHeaderObject(vm *goja.Runtime, raw string) *goja.Object {
	object := vm.NewObject()
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return object
	}
	var headers map[string]string
	if err := json.Unmarshal([]byte(trimmed), &headers); err != nil {
		return object
	}
	for key, value := range headers {
		_ = object.Set(key, value)
	}
	return object
}

// legadoInsecureTransport 是「证书有问题也先接上」的传输层。
//
// 一批老书源站用的是过期/自签证书，正规校验下 TLS 握手直接失败，
// 但这些站点的内容本身是公开的，且阅读类 App 普遍允许放宽。
// 只在**首次请求因证书失败**时回退到它，正常站点仍走严格校验。
var legadoInsecureTransport = func() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	return transport
}()

// legadoIsTLSError 判断错误是不是「证书 / 握手」类问题。
func legadoIsTLSError(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "tls:") ||
		strings.Contains(text, "x509:") ||
		strings.Contains(text, "certificate") ||
		strings.Contains(text, "handshake failure")
}

// doRequest 解析 Legado 的 `url,{options}` 写法并同步请求。
func (s *legadoRuntimeState) doRequest(raw string) (string, error) {
	address, options := splitLegadoRequest(raw)
	if address == "" {
		return "", fmt.Errorf("空地址")
	}
	// data: 地址是内联内容（书源常用来塞常量），不需要发请求。
	if strings.HasPrefix(address, "data:") {
		return decodeLegadoDataURI(address), nil
	}
	if !strings.Contains(address, "://") {
		address = resolveAgainst(s.source.URL, address)
	}

	method := "GET"
	body := ""
	charset := ""
	var headers map[string]string
	if options != "" {
		var opt legadoHttpOptions
		if err := json.Unmarshal([]byte(options), &opt); err == nil {
			if opt.Method != "" {
				method = strings.ToUpper(opt.Method)
			}
			body = opt.Body
			charset = opt.Charset
			headers = opt.Headers
		}
	}
	result, err := s.fetch(method, address, body, headers, true)
	if err != nil {
		return "", err
	}
	if result.status >= 400 {
		return "", fmt.Errorf("HTTP %d", result.status)
	}
	// 显式指定 charset 时按它解码（有些源站响应头不带编码）
	if charset != "" {
		return decodeLegadoBody([]byte(result.body), charset), nil
	}
	return result.body, nil
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
	if strings.HasPrefix(link, "data:") {
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

// decodeLegadoDataURI 解 `data:;base64,xxx` 这类内联地址。
func decodeLegadoDataURI(address string) string {
	comma := strings.Index(address, ",")
	if comma < 0 {
		return ""
	}
	meta := strings.ToLower(address[5:comma])
	payload := address[comma+1:]
	if strings.HasSuffix(meta, "base64") {
		decoded, err := base64.StdEncoding.DecodeString(payload)
		if err != nil {
			if raw, rawErr := base64.RawStdEncoding.DecodeString(payload); rawErr == nil {
				return string(raw)
			}
			return ""
		}
		return string(decoded)
	}
	if unescaped, err := url.QueryUnescape(payload); err == nil {
		return unescaped
	}
	return payload
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
