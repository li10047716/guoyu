package core

// 书源脚本里的 Java 类库子集。
//
// 部分书源（番茄、七猫、各种聚合源）不满足于 java.ajax，会直接
// `new Packages.java.security.MessageDigest(...)` 那样调 JVM 类做签名/加解密。
// 这里用 Go 标准库把这些类复刻成脚本可用的对象：
//
//	java.lang.String/StringBuilder/Integer/Long/System/Math
//	java.util.Arrays/Base64/UUID/Random
//	java.security.MessageDigest/SecureRandom
//	javax.crypto.Cipher + spec.SecretKeySpec/IvParameterSpec
//	java.math.BigInteger
//	java.nio.charset.Charset
//	java.io.ByteArrayOutputStream/ByteArrayInputStream + zip.GZIP*
//
// 字节数组统一用 JS 的整数数组（0..255）表示，和 legadoByteArray 一致。

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/text/encoding/simplifiedchinese"

	"github.com/dop251/goja"
)

// legadoBytesOf 从脚本值取出字节切片。
//
// 兼容三种入参：字符串（UTF-8）、整数数组（byte[]）、带 length 的类数组。
func legadoBytesOf(value goja.Value) []byte {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	switch typed := value.Export().(type) {
	case string:
		return []byte(typed)
	case []byte:
		return typed
	case []interface{}:
		out := make([]byte, 0, len(typed))
		for _, item := range typed {
			out = append(out, legadoByteOf(item))
		}
		return out
	}
	exported := value.Export()
	if numbers, ok := exported.([]int64); ok {
		out := make([]byte, len(numbers))
		for index, number := range numbers {
			out[index] = byte(number)
		}
		return out
	}
	return []byte(value.String())
}

func legadoByteOf(item interface{}) byte {
	switch typed := item.(type) {
	case int64:
		return byte(typed)
	case int32:
		return byte(typed)
	case int:
		return byte(typed)
	case float64:
		return byte(int64(typed))
	case byte:
		return typed
	case string:
		if len(typed) > 0 {
			return typed[0]
		}
	}
	return 0
}

// legadoStringOfBytes 把字节按 UTF-8 解成字符串。
func legadoStringOfBytes(bytes []byte, charset string) string {
	switch strings.ToLower(strings.TrimSpace(charset)) {
	case "", "utf-8", "utf8":
		return string(bytes)
	case "us-ascii", "iso-8859-1", "iso8859-1", "latin1", "8859_1":
		// 单字节字符集：每个字节直接对上一个码点，不能走 UTF-8 解码。
		var builder strings.Builder
		builder.Grow(len(bytes))
		for _, one := range bytes {
			builder.WriteRune(rune(one))
		}
		return builder.String()
	case "gbk", "gb2312", "gb18030":
		if decoded, err := decodeNovelBytes(bytes); err == nil {
			return decoded
		}
		return string(bytes)
	case "utf-16", "utf16", "utf-16be":
		units := make([]uint16, 0, len(bytes)/2)
		for index := 0; index+1 < len(bytes); index += 2 {
			units = append(units, uint16(bytes[index])<<8|uint16(bytes[index+1]))
		}
		return string(utf16.Decode(units))
	}
	return string(bytes)
}

// legadoBytesOfString 把字符串按指定字符集编码成字节，对应 Java 的 String.getBytes(charset)。
func legadoBytesOfString(text, charset string) []byte {
	switch strings.ToLower(strings.TrimSpace(charset)) {
	case "us-ascii", "iso-8859-1", "iso8859-1", "latin1", "8859_1":
		out := make([]byte, 0, len(text))
		for _, char := range text {
			if char > 0xff {
				out = append(out, '?')
				continue
			}
			out = append(out, byte(char))
		}
		return out
	case "gbk", "gb2312", "gb18030":
		if encoded, err := simplifiedchinese.GBK.NewEncoder().Bytes([]byte(text)); err == nil {
			return encoded
		}
	}
	return []byte(text)
}

// legadoCharsetName 取字符集参数的名字：既接受 'UTF-8' 这样的字符串，
// 也接受 Charset.forName() 返回的对象。
func legadoCharsetName(vm *goja.Runtime, value goja.Value) string {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return ""
	}
	if object := value.ToObject(vm); object != nil {
		if name := object.Get("name"); name != nil && !goja.IsUndefined(name) {
			if function, ok := goja.AssertFunction(name); ok {
				if result, err := function(value); err == nil && result != nil {
					return result.String()
				}
			} else if !goja.IsUndefined(name) {
				return name.String()
			}
		}
	}
	return value.String()
}

// legadoClassObject 是「类」的共同外壳。
//
// 关键：脚本里的 `new Packages.java.lang.String(bytes)` 要求这个对象本身
// 可以被 `new`，所以先造一个 goja 构造函数，再往它身上挂静态方法。
// statics 里的 `__ctor` 就是构造函数实现。
func legadoClassObject(vm *goja.Runtime, name string, statics map[string]interface{}) *goja.Object {
	var constructor func(goja.ConstructorCall) *goja.Object
	if raw, ok := statics["__ctor"]; ok {
		if typed, okCast := raw.(func(goja.ConstructorCall) *goja.Object); okCast {
			constructor = typed
		}
	}
	if constructor == nil {
		constructor = func(goja.ConstructorCall) *goja.Object { return vm.NewObject() }
	}

	object := vm.ToValue(constructor).ToObject(vm)
	_ = object.Set("className", name)
	for key, value := range statics {
		if key == "__ctor" {
			continue
		}
		_ = object.Set(key, value)
	}
	return object
}

// legadoPackagesObject 构造完整的 `Packages` 树，并返回按全名查类的函数。
func legadoPackagesObject(vm *goja.Runtime, baseURL string, client *http.Client) (*goja.Object, func(string) goja.Value) {
	registry := map[string]*goja.Object{}

	register := func(name string, statics map[string]interface{}) *goja.Object {
		class := legadoClassObject(vm, name, statics)
		registry[name] = class
		return class
	}

	// ---- java.lang.String ----
	register("java.lang.String", map[string]interface{}{
		"valueOf": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(call.Argument(0).String())
		},
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			var text string
			switch len(call.Arguments) {
			case 0:
				text = ""
			case 1:
				text = legadoStringOfBytes(legadoBytesOf(call.Argument(0)), "")
			default:
				text = legadoStringOfBytes(
					legadoBytesOf(call.Argument(0)),
					legadoCharsetName(vm, call.Argument(1)),
				)
			}
			wrapper := vm.NewObject()
			_ = wrapper.Set("value", text)
			_ = wrapper.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(text) })
			_ = wrapper.Set("valueOf", func(goja.FunctionCall) goja.Value { return vm.ToValue(text) })
			_ = wrapper.Set("getBytes", func(call goja.FunctionCall) goja.Value {
				charset := ""
				if len(call.Arguments) > 0 {
					charset = legadoCharsetName(vm, call.Argument(0))
				}
				return vm.ToValue(legadoByteArray(vm, legadoBytesOfString(text, charset)))
			})
			_ = wrapper.Set("length", func(goja.FunctionCall) goja.Value { return vm.ToValue(len([]rune(text))) })
			_ = wrapper.Set("toLowerCase", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(strings.ToLower(text))
			})
			return wrapper
		},
	})

	// ---- java.lang.StringBuilder / StringBuffer ----
	builderStatics := map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			buffer := &strings.Builder{}
			if len(call.Arguments) > 0 {
				buffer.WriteString(call.Argument(0).String())
			}
			object := vm.NewObject()
			_ = object.Set("append", func(call goja.FunctionCall) goja.Value {
				argument := call.Argument(0)
				if bytesValue, ok := argument.Export().([]interface{}); ok {
					buffer.Write(legadoBytesOf(argument))
					_ = bytesValue
				} else {
					buffer.WriteString(argument.String())
				}
				return vm.ToValue(object)
			})
			_ = object.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(buffer.String()) })
			_ = object.Set("length", func(goja.FunctionCall) goja.Value { return vm.ToValue(buffer.Len()) })
			return object
		},
	}
	register("java.lang.StringBuilder", builderStatics)
	register("java.lang.StringBuffer", builderStatics)

	// ---- java.lang.Integer / Long ----
	integerStatics := map[string]interface{}{
		"toHexString": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(fmt.Sprintf("%x", uint32(call.Argument(0).ToInteger())))
		},
		"toBinaryString": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(fmt.Sprintf("%b", uint32(call.Argument(0).ToInteger())))
		},
		"toOctalString": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(fmt.Sprintf("%o", uint32(call.Argument(0).ToInteger())))
		},
		"parseInt": func(call goja.FunctionCall) goja.Value {
			radix := int64(10)
			if len(call.Arguments) > 1 {
				radix = call.Argument(1).ToInteger()
			}
			parsed, err := parseInt64(strings.TrimSpace(call.Argument(0).String()), int(radix))
			if err != nil {
				panic(vm.NewTypeError("NumberFormatException: " + call.Argument(0).String()))
			}
			return vm.ToValue(parsed)
		},
		"toString": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(call.Argument(0).String())
		},
		"valueOf": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(call.Argument(0).ToInteger())
		},
		"MAX_VALUE": int64(2147483647),
		"MIN_VALUE": int64(-2147483648),
	}
	register("java.lang.Integer", integerStatics)
	longStatics := map[string]interface{}{}
	for key, value := range integerStatics {
		longStatics[key] = value
	}
	longStatics["MAX_VALUE"] = int64(9223372036854775807)
	register("java.lang.Long", longStatics)

	// ---- java.lang.System ----
	register("java.lang.System", map[string]interface{}{
		"currentTimeMillis": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoNowMillis())
		},
		"nanoTime": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoNowNanos())
		},
		"arraycopy": func(call goja.FunctionCall) goja.Value {
			source := legadoBytesOf(call.Argument(0))
			sourceStart := int(call.Argument(1).ToInteger())
			destination := legadoBytesOf(call.Argument(2))
			destinationStart := int(call.Argument(3).ToInteger())
			length := int(call.Argument(4).ToInteger())
			for index := 0; index < length; index++ {
				if sourceStart+index >= len(source) {
					break
				}
				if destinationStart+index >= len(destination) {
					break
				}
				destination[destinationStart+index] = source[sourceStart+index]
			}
			return goja.Undefined()
		},
		"getProperty": func(call goja.FunctionCall) goja.Value {
			switch call.Argument(0).String() {
			case "line.separator":
				return vm.ToValue("\n")
			case "file.separator":
				return vm.ToValue("/")
			}
			return vm.ToValue("")
		},
	})

	// ---- java.lang.Math ----
	register("java.lang.Math", map[string]interface{}{
		"random": func(call goja.FunctionCall) goja.Value {
			buffer := make([]byte, 8)
			_, _ = rand.Read(buffer)
			var value uint64
			for _, item := range buffer {
				value = value<<8 | uint64(item)
			}
			return vm.ToValue(float64(value>>11) / float64(1<<53))
		},
		"abs": func(call goja.FunctionCall) goja.Value {
			value := call.Argument(0).ToFloat()
			if value < 0 {
				value = -value
			}
			return vm.ToValue(value)
		},
		"floor": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(float64(int64(call.Argument(0).ToFloat())))
		},
		"ceil": func(call goja.FunctionCall) goja.Value {
			value := call.Argument(0).ToFloat()
			truncated := float64(int64(value))
			if value > truncated {
				truncated++
			}
			return vm.ToValue(truncated)
		},
		"max": func(call goja.FunctionCall) goja.Value {
			left, right := call.Argument(0).ToFloat(), call.Argument(1).ToFloat()
			if left > right {
				return vm.ToValue(left)
			}
			return vm.ToValue(right)
		},
		"min": func(call goja.FunctionCall) goja.Value {
			left, right := call.Argument(0).ToFloat(), call.Argument(1).ToFloat()
			if left < right {
				return vm.ToValue(left)
			}
			return vm.ToValue(right)
		},
		"pow": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(pow(call.Argument(0).ToFloat(), call.Argument(1).ToFloat()))
		},
	})

	// ---- java.util.Arrays ----
	register("java.util.Arrays", map[string]interface{}{
		"copyOfRange": func(call goja.FunctionCall) goja.Value {
			source := legadoBytesOf(call.Argument(0))
			from := int(call.Argument(1).ToInteger())
			to := int(call.Argument(2).ToInteger())
			if from < 0 {
				from = 0
			}
			if from > len(source) {
				panic(vm.NewTypeError("ArrayIndexOutOfBounds: " + fmt.Sprint(from)))
			}
			size := to - from
			if size < 0 {
				size = 0
			}
			out := make([]byte, size)
			for index := 0; index < size; index++ {
				if from+index < len(source) {
					out[index] = source[from+index]
				}
			}
			return vm.ToValue(legadoByteArray(vm, out))
		},
		"copyOf": func(call goja.FunctionCall) goja.Value {
			source := legadoBytesOf(call.Argument(0))
			size := int(call.Argument(1).ToInteger())
			if size < 0 {
				size = 0
			}
			out := make([]byte, size)
			copy(out, source)
			return vm.ToValue(legadoByteArray(vm, out))
		},
		"equals": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(bytes.Equal(legadoBytesOf(call.Argument(0)), legadoBytesOf(call.Argument(1))))
		},
		"toString": func(call goja.FunctionCall) goja.Value {
			source := legadoBytesOf(call.Argument(0))
			parts := make([]string, len(source))
			for index, item := range source {
				parts[index] = fmt.Sprint(item)
			}
			return vm.ToValue("[" + strings.Join(parts, ", ") + "]")
		},
		"hashCode": func(call goja.FunctionCall) goja.Value {
			sum := md5.Sum(legadoBytesOf(call.Argument(0)))
			return vm.ToValue(int64(int32(uint32(sum[0])<<24 | uint32(sum[1])<<16 | uint32(sum[2])<<8 | uint32(sum[3]))))
		},
	})

	// ---- java.util.Base64 ----
	var base64Encoder func(urlSafe, padding bool) *goja.Object
	base64Encoder = func(urlSafe, padding bool) *goja.Object {
		encoder := base64.StdEncoding
		switch {
		case urlSafe && padding:
			encoder = base64.URLEncoding
		case urlSafe:
			encoder = base64.RawURLEncoding
		case !padding:
			encoder = base64.RawStdEncoding
		}
		object := vm.NewObject()
		_ = object.Set("encodeToString", func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(encoder.EncodeToString(legadoBytesOf(call.Argument(0))))
		})
		_ = object.Set("encode", func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoByteArray(vm, []byte(encoder.EncodeToString(legadoBytesOf(call.Argument(0))))))
		})
		_ = object.Set("withoutPadding", func(goja.FunctionCall) goja.Value {
			return vm.ToValue(base64Encoder(urlSafe, false))
		})
		return object
	}
	base64Decoder := func(urlSafe bool) *goja.Object {
		object := vm.NewObject()
		_ = object.Set("decode", func(call goja.FunctionCall) goja.Value {
			text := strings.TrimSpace(call.Argument(0).String())
			decoded, err := base64.StdEncoding.DecodeString(text)
			if err != nil && urlSafe {
				decoded, err = base64.URLEncoding.DecodeString(text)
			}
			if err != nil {
				decoded, err = base64.RawStdEncoding.DecodeString(text)
			}
			if err != nil {
				panic(vm.NewTypeError("Illegal base64: " + shortErr(err)))
			}
			return vm.ToValue(legadoByteArray(vm, decoded))
		})
		return object
	}
	register("java.util.Base64", map[string]interface{}{
		"getEncoder":     func(goja.FunctionCall) goja.Value { return vm.ToValue(base64Encoder(false, true)) },
		"getUrlEncoder":  func(goja.FunctionCall) goja.Value { return vm.ToValue(base64Encoder(true, true)) },
		"getDecoder":     func(goja.FunctionCall) goja.Value { return vm.ToValue(base64Decoder(false)) },
		"getUrlDecoder":  func(goja.FunctionCall) goja.Value { return vm.ToValue(base64Decoder(true)) },
		"getMimeEncoder": func(goja.FunctionCall) goja.Value { return vm.ToValue(base64Encoder(false, true)) },
	})

	// ---- java.util.UUID ----
	register("java.util.UUID", map[string]interface{}{
		"randomUUID": func(goja.FunctionCall) goja.Value {
			buffer := make([]byte, 16)
			_, _ = rand.Read(buffer)
			buffer[6] = (buffer[6] & 0x0f) | 0x40
			buffer[8] = (buffer[8] & 0x3f) | 0x80
			text := fmt.Sprintf("%s-%s-%s-%s-%s",
				hex.EncodeToString(buffer[0:4]), hex.EncodeToString(buffer[4:6]),
				hex.EncodeToString(buffer[6:8]), hex.EncodeToString(buffer[8:10]),
				hex.EncodeToString(buffer[10:16]))
			object := vm.NewObject()
			_ = object.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(text) })
			_ = object.Set("valueOf", func(goja.FunctionCall) goja.Value { return vm.ToValue(text) })
			return vm.ToValue(object)
		},
	})

	// ---- java.util.Random ----
	randomStatics := map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			object := vm.NewObject()
			_ = object.Set("nextInt", func(call goja.FunctionCall) goja.Value {
				limit := int64(2147483647)
				if len(call.Arguments) > 0 {
					limit = call.Argument(0).ToInteger()
				}
				if limit <= 0 {
					return vm.ToValue(int64(0))
				}
				buffer := make([]byte, 8)
				_, _ = rand.Read(buffer)
				var value uint64
				for _, item := range buffer {
					value = value<<8 | uint64(item)
				}
				return vm.ToValue(int64(value % uint64(limit)))
			})
			_ = object.Set("nextBytes", func(call goja.FunctionCall) goja.Value {
				buffer := make([]byte, 0)
				if length := len(legadoBytesOf(call.Argument(0))); length > 0 {
					buffer = make([]byte, length)
					_, _ = rand.Read(buffer)
				}
				return vm.ToValue(legadoByteArray(vm, buffer))
			})
			_ = object.Set("nextDouble", func(goja.FunctionCall) goja.Value {
				buffer := make([]byte, 8)
				_, _ = rand.Read(buffer)
				var value uint64
				for _, item := range buffer {
					value = value<<8 | uint64(item)
				}
				return vm.ToValue(float64(value>>11) / float64(1<<53))
			})
			return object
		},
	}
	register("java.util.Random", randomStatics)

	// ---- java.security.MessageDigest ----
	register("java.security.MessageDigest", map[string]interface{}{
		"getInstance": func(call goja.FunctionCall) goja.Value {
			algorithm := strings.ToUpper(strings.ReplaceAll(call.Argument(0).String(), "-", ""))
			object := vm.NewObject()
			var buffer bytes.Buffer
			_ = object.Set("update", func(call goja.FunctionCall) goja.Value {
				buffer.Write(legadoBytesOf(call.Argument(0)))
				return goja.Undefined()
			})
			_ = object.Set("digest", func(call goja.FunctionCall) goja.Value {
				payload := buffer.Bytes()
				if len(call.Arguments) > 0 {
					payload = append(append([]byte{}, payload...), legadoBytesOf(call.Argument(0))...)
				}
				return vm.ToValue(legadoByteArray(vm, legadoDigestBytes(algorithm, payload)))
			})
			_ = object.Set("reset", func(goja.FunctionCall) goja.Value {
				buffer.Reset()
				return goja.Undefined()
			})
			return vm.ToValue(object)
		},
	})

	// ---- java.security.SecureRandom ----
	register("java.security.SecureRandom", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			object := vm.NewObject()
			// generateSeed(n)：返回 n 字节随机种子（DH 交换里当 IV 用）。
			_ = object.Set("generateSeed", func(call goja.FunctionCall) goja.Value {
				length := int(call.Argument(0).ToInteger())
				if length <= 0 {
					length = 16
				}
				if length > 4096 {
					length = 4096
				}
				buffer := make([]byte, length)
				_, _ = rand.Read(buffer)
				return vm.ToValue(legadoByteArray(vm, buffer))
			})
			_ = object.Set("nextBytes", func(call goja.FunctionCall) goja.Value {
				length := len(legadoBytesOf(call.Argument(0)))
				buffer := make([]byte, length)
				_, _ = rand.Read(buffer)
				return vm.ToValue(legadoByteArray(vm, buffer))
			})
			_ = object.Set("nextInt", func(call goja.FunctionCall) goja.Value {
				limit := int64(2147483647)
				if len(call.Arguments) > 0 {
					limit = call.Argument(0).ToInteger()
				}
				if limit <= 0 {
					return vm.ToValue(int64(0))
				}
				buffer := make([]byte, 8)
				_, _ = rand.Read(buffer)
				var value uint64
				for _, item := range buffer {
					value = value<<8 | uint64(item)
				}
				return vm.ToValue(int64(value % uint64(limit)))
			})
			return object
		},
		"getInstanceStrong": func(goja.FunctionCall) goja.Value { return goja.Undefined() },
	})

	// ---- javax.crypto.spec ----
	register("javax.crypto.spec.SecretKeySpec", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			key := legadoBytesOf(call.Argument(0))
			object := vm.NewObject()
			_ = object.Set("__key", legadoByteArray(vm, key))
			_ = object.Set("getEncoded", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(legadoByteArray(vm, key))
			})
			return object
		},
	})
	register("javax.crypto.spec.IvParameterSpec", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			iv := legadoBytesOf(call.Argument(0))
			object := vm.NewObject()
			_ = object.Set("__iv", legadoByteArray(vm, iv))
			_ = object.Set("getIV", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(legadoByteArray(vm, iv))
			})
			return object
		},
	})

	// ---- javax.crypto.Cipher ----
	register("javax.crypto.Cipher", map[string]interface{}{
		"ENCRYPT_MODE": int64(1),
		"DECRYPT_MODE": int64(2),
		"getInstance": func(call goja.FunctionCall) goja.Value {
			transformation := strings.ToUpper(call.Argument(0).String())
			object := vm.NewObject()
			var key, iv []byte
			mode := int64(1)
			_ = object.Set("init", func(call goja.FunctionCall) goja.Value {
				mode = call.Argument(0).ToInteger()
				if len(call.Arguments) > 1 {
					key = legadoBytesOf(call.Argument(1).ToObject(vm).Get("__key"))
				}
				if len(call.Arguments) > 2 {
					iv = legadoBytesOf(call.Argument(2).ToObject(vm).Get("__iv"))
				}
				return goja.Undefined()
			})
			_ = object.Set("doFinal", func(call goja.FunctionCall) goja.Value {
				payload := legadoBytesOf(call.Argument(0))
				result, err := legadoCipher(transformation, mode, key, iv, payload)
				if err != nil {
					panic(vm.NewGoError(fmt.Errorf("%v（输入 %d 字节）%s", err, len(payload), legadoCallStack(vm))))
				}
				return vm.ToValue(legadoByteArray(vm, result))
			})
			_ = object.Set("update", func(call goja.FunctionCall) goja.Value {
				return vm.ToValue(vm.NewArray())
			})
			_ = object.Set("getBlockSize", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(int64(16))
			})
			return vm.ToValue(object)
		},
	})

	// ---- java.math.BigInteger ----
	bigStatics := map[string]interface{}{
		"valueOf": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoWrapBigInt(vm, big.NewInt(call.Argument(0).ToInteger())))
		},
		"ONE":  legadoWrapBigInt(vm, big.NewInt(1)),
		"ZERO": legadoWrapBigInt(vm, big.NewInt(0)),
		"TWO":  legadoWrapBigInt(vm, big.NewInt(2)),
		"TEN":  legadoWrapBigInt(vm, big.NewInt(10)),
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			value := new(big.Int)
			first := call.Argument(0)
			if len(call.Arguments) > 1 {
				raw := legadoBytesOf(call.Argument(1))
				value.SetBytes(raw)
				if first.ToInteger() < 0 {
					value.Neg(value)
				}
			} else if _, ok := first.Export().(string); ok {
				value.SetString(strings.TrimSpace(first.String()), 10)
			} else {
				raw := legadoBytesOf(first)
				if len(raw) > 0 {
					value.SetBytes(raw)
				} else {
					value.SetInt64(first.ToInteger())
				}
			}
			if value == nil {
				value = new(big.Int)
			}
			return legadoWrapBigInt(vm, value)
		},
	}
	register("java.math.BigInteger", bigStatics)

	// ---- java.net.URL / HttpURLConnection ----
	register("java.net.URL", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			address := strings.TrimSpace(call.Argument(0).String())
			object := vm.NewObject()
			_ = object.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(address) })
			_ = object.Set("openConnection", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(legadoURLConnection(vm, client, address))
			})
			return object
		},
	})

	// ---- java.nio.charset.Charset ----
	charsetStatics := map[string]interface{}{
		"forName": func(call goja.FunctionCall) goja.Value {
			name := call.Argument(0).String()
			object := vm.NewObject()
			_ = object.Set("name", func(goja.FunctionCall) goja.Value { return vm.ToValue(name) })
			_ = object.Set("toString", func(goja.FunctionCall) goja.Value { return vm.ToValue(name) })
			return vm.ToValue(object)
		},
	}
	register("java.nio.charset.Charset", charsetStatics)
	register("java.nio.charset.StandardCharsets", map[string]interface{}{
		"UTF_8": "UTF-8",
		"GBK":   "GBK",
		"ASCII": "US-ASCII",
	})

	// ---- java.io ----
	register("java.io.ByteArrayOutputStream", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			var buffer bytes.Buffer
			object := vm.NewObject()
			_ = object.Set("write", func(call goja.FunctionCall) goja.Value {
				buffer.Write(legadoBytesOf(call.Argument(0)))
				return goja.Undefined()
			})
			_ = object.Set("toByteArray", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(legadoByteArray(vm, buffer.Bytes()))
			})
			_ = object.Set("toString", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(buffer.String())
			})
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})
	register("java.io.ByteArrayInputStream", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			payload := legadoBytesOf(call.Argument(0))
			offset := 0
			object := vm.NewObject()
			_ = object.Set("__bytes", legadoByteArray(vm, payload))
			_ = object.Set("read", func(call goja.FunctionCall) goja.Value {
				if offset >= len(payload) {
					return vm.ToValue(int64(-1))
				}
				if len(call.Arguments) == 0 {
					value := payload[offset]
					offset++
					return vm.ToValue(int64(value))
				}
				target := legadoBytesOf(call.Argument(0))
				start := 0
				if len(call.Arguments) > 1 {
					start = int(call.Argument(1).ToInteger())
				}
				length := len(target) - start
				if len(call.Arguments) > 2 {
					length = int(call.Argument(2).ToInteger())
				}
				copied := 0
				for copied < length && offset < len(payload) && start+copied < len(target) {
					target[start+copied] = payload[offset]
					copied++
					offset++
				}
				if copied == 0 {
					return vm.ToValue(int64(-1))
				}
				return vm.ToValue(int64(copied))
			})
			_ = object.Set("available", func(goja.FunctionCall) goja.Value {
				return vm.ToValue(int64(len(payload) - offset))
			})
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})
	register("java.io.InputStreamReader", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			object := vm.NewObject()
			_ = object.Set("__bytes", call.Argument(0).ToObject(vm).Get("__bytes"))
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})
	register("java.io.BufferedReader", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			payload := legadoBytesOf(call.Argument(0).ToObject(vm).Get("__bytes"))
			reader := strings.NewReader(string(payload))
			object := vm.NewObject()
			_ = object.Set("readLine", func(goja.FunctionCall) goja.Value {
				var builder strings.Builder
				for {
					runeValue, _, err := reader.ReadRune()
					if err != nil {
						if builder.Len() == 0 {
							return goja.Null()
						}
						break
					}
					if runeValue == '\n' {
						break
					}
					if runeValue == '\r' {
						continue
					}
					builder.WriteRune(runeValue)
				}
				return vm.ToValue(builder.String())
			})
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})

	// ---- java.util.zip ----
	register("java.util.zip.GZIPInputStream", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			payload := legadoBytesOf(call.Argument(0).ToObject(vm).Get("__bytes"))
			var out []byte
			if reader, err := gzip.NewReader(bytes.NewReader(payload)); err == nil {
				out, _ = io.ReadAll(reader)
				_ = reader.Close()
			}
			object := vm.NewObject()
			_ = object.Set("__bytes", legadoByteArray(vm, out))
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})
	register("java.util.zip.GZIPOutputStream", map[string]interface{}{
		"__ctor": func(call goja.ConstructorCall) *goja.Object {
			target := call.Argument(0)
			object := vm.NewObject()
			_ = object.Set("write", func(call goja.FunctionCall) goja.Value {
				payload := legadoBytesOf(call.Argument(0))
				var buffer bytes.Buffer
				writer := gzip.NewWriter(&buffer)
				_, _ = writer.Write(payload)
				_ = writer.Close()
				if finish, ok := goja.AssertFunction(target.ToObject(vm).Get("write")); ok {
					_, _ = finish(goja.Undefined(), vm.ToValue(legadoByteArray(vm, buffer.Bytes())))
				}
				return goja.Undefined()
			})
			_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
			return object
		},
	})

	packages := vm.NewObject()
	buildPath := func(full string, object *goja.Object) {
		parts := strings.Split(full, ".")
		if len(parts) < 2 {
			return
		}
		current := packages
		for _, part := range parts[:len(parts)-1] {
			next := current.Get(part)
			if next == nil || goja.IsUndefined(next) {
				created := vm.NewObject()
				_ = current.Set(part, created)
				current = created
				continue
			}
			object, ok := next.(*goja.Object)
			if !ok {
				created := vm.NewObject()
				_ = current.Set(part, created)
				current = created
				continue
			}
			current = object
		}
		_ = current.Set(parts[len(parts)-1], object)
	}
	for name, object := range registry {
		buildPath(name, object)
	}

	// 末尾补一层宽松兜底：org.jsoup 之外再访问未知包/类时不要直接 TypeError
	resolver := func(full string) goja.Value {
		if object, ok := registry[full]; ok {
			return vm.ToValue(object)
		}
		created := legadoClassObject(vm, full, nil)
		registry[full] = created
		buildPath(full, created)
		return vm.ToValue(created)
	}
	_ = baseURL
	return packages, resolver
}

// legadoJavaType 实现 Java.type("java.lang.String") 这种写法。
func legadoJavaType(vm *goja.Runtime, resolver func(string) goja.Value) goja.Value {
	return vm.ToValue(func(call goja.FunctionCall) goja.Value {
		return resolver(call.Argument(0).String())
	})
}

// legadoWrapBigInt 把 big.Int 包成带常用方法的 JS 对象。
func legadoWrapBigInt(vm *goja.Runtime, value *big.Int) *goja.Object {
	object := vm.NewObject()
	copyValue := func() *big.Int {
		return new(big.Int).Set(value)
	}
	_ = object.Set("toString", func(call goja.FunctionCall) goja.Value {
		radix := 10
		if len(call.Arguments) > 0 {
			radix = int(call.Argument(0).ToInteger())
		}
		return vm.ToValue(value.Text(radix))
	})
	_ = object.Set("valueOf", func(goja.FunctionCall) goja.Value {
		floatValue, _ := new(big.Float).SetInt(value).Float64()
		return vm.ToValue(floatValue)
	})
	_ = object.Set("toByteArray", func(goja.FunctionCall) goja.Value {
		raw := value.Bytes()
		if len(raw) == 0 {
			raw = []byte{0}
		}
		return vm.ToValue(legadoByteArray(vm, raw))
	})
	_ = object.Set("intValue", func(goja.FunctionCall) goja.Value { return vm.ToValue(value.Int64()) })
	_ = object.Set("longValue", func(goja.FunctionCall) goja.Value { return vm.ToValue(value.Int64()) })
	_ = object.Set("doubleValue", func(goja.FunctionCall) goja.Value {
		floatValue, _ := new(big.Float).SetInt(value).Float64()
		return vm.ToValue(floatValue)
	})
	_ = object.Set("bitLength", func(goja.FunctionCall) goja.Value { return vm.ToValue(int64(value.BitLen())) })

	binary := func(name string, apply func(out, left, right *big.Int) *big.Int) {
		_ = object.Set(name, func(call goja.FunctionCall) goja.Value {
			other := legadoBigIntOf(call.Argument(0))
			return vm.ToValue(legadoWrapBigInt(vm, apply(new(big.Int), copyValue(), other)))
		})
	}
	binary("add", (*big.Int).Add)
	binary("subtract", (*big.Int).Sub)
	binary("multiply", (*big.Int).Mul)
	binary("divide", (*big.Int).Quo)
	binary("mod", (*big.Int).Mod)
	binary("and", (*big.Int).And)
	binary("or", (*big.Int).Or)
	binary("xor", (*big.Int).Xor)
	binary("remainder", (*big.Int).Rem)
	binary("pow", func(out, left, right *big.Int) *big.Int { return out.Exp(left, right, nil) })
	// modPow(exponent, modulus)：DH 交换里必用。
	_ = object.Set("modPow", func(call goja.FunctionCall) goja.Value {
		exponent := legadoBigIntOf(call.Argument(0))
		modulus := legadoBigIntOf(call.Argument(1))
		return vm.ToValue(legadoWrapBigInt(vm, new(big.Int).Exp(copyValue(), exponent, modulus)))
	})
	_ = object.Set("modInverse", func(call goja.FunctionCall) goja.Value {
		modulus := legadoBigIntOf(call.Argument(0))
		inverse := new(big.Int).ModInverse(copyValue(), modulus)
		if inverse == nil {
			panic(vm.NewGoError(fmt.Errorf("BigInteger 没有模逆元")))
		}
		return vm.ToValue(legadoWrapBigInt(vm, inverse))
	})
	_ = object.Set("signum", func(goja.FunctionCall) goja.Value { return vm.ToValue(int64(value.Sign())) })
	_ = object.Set("testBit", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(value.Bit(int(call.Argument(0).ToInteger())) != 0)
	})
	binary("shiftLeft", func(out, left, right *big.Int) *big.Int { return out.Lsh(left, uint(right.Int64())) })
	binary("shiftRight", func(out, left, right *big.Int) *big.Int { return out.Rsh(left, uint(right.Int64())) })
	_ = object.Set("negate", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWrapBigInt(vm, value.Neg(copyValue())))
	})
	_ = object.Set("abs", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWrapBigInt(vm, value.Abs(copyValue())))
	})
	_ = object.Set("compareTo", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(int64(value.Cmp(legadoBigIntOf(call.Argument(0)))))
	})
	_ = object.Set("equals", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(value.Cmp(legadoBigIntOf(call.Argument(0))) == 0)
	})
	return object
}

// legadoBigIntOf 从脚本值还原 big.Int。
func legadoBigIntOf(value goja.Value) *big.Int {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return new(big.Int)
	}
	if object, ok := value.(*goja.Object); ok {
		if text := object.Get("toString"); text != nil && !goja.IsUndefined(text) {
			if callable, ok := goja.AssertFunction(text); ok {
				if result, err := callable(object); err == nil {
					parsed, okParse := new(big.Int).SetString(strings.TrimSpace(result.String()), 10)
					if okParse {
						return parsed
					}
				}
			}
		}
	}
	raw := legadoBytesOf(value)
	if len(raw) > 0 {
		return new(big.Int).SetBytes(raw)
	}
	return big.NewInt(value.ToInteger())
}

// legadoDigestBytes 按算法名做摘要。
func legadoDigestBytes(algorithm string, payload []byte) []byte {
	switch strings.ToUpper(strings.ReplaceAll(algorithm, "-", "")) {
	case "MD5":
		sum := md5.Sum(payload)
		return sum[:]
	case "SHA1":
		sum := sha1.Sum(payload)
		return sum[:]
	case "SHA256":
		sum := sha256.Sum256(payload)
		return sum[:]
	case "SHA512":
		sum := sha512.Sum512(payload)
		return sum[:]
	}
	sum := md5.Sum(payload)
	return sum[:]
}

// legadoCipher 实现 javax.crypto.Cipher 的 AES 加解密。
func legadoCipher(transformation string, mode int64, key, iv, payload []byte) ([]byte, error) {
	parts := strings.Split(transformation, "/")
	algorithm := parts[0]
	if algorithm != "AES" {
		return nil, fmt.Errorf("不支持的加密算法：%s", transformation)
	}
	modeName := "CBC"
	if len(parts) > 1 {
		modeName = parts[1]
	}
	padding := "PKCS5PADDING"
	if len(parts) > 2 {
		padding = strings.ReplaceAll(parts[2], "-", "")
	}
	if len(key) != 16 && len(key) != 24 && len(key) != 32 {
		return nil, fmt.Errorf("AES 密钥长度不对：%d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	encrypting := mode != 2

	switch modeName {
	case "CBC":
		if len(iv) == 0 {
			return nil, fmt.Errorf("AES/CBC 缺少 IV")
		}
		if encrypting && padding == "PKCS5PADDING" {
			payload = legadoPKCS7Pad(payload, block.BlockSize())
		}
		if len(payload)%block.BlockSize() != 0 {
			return nil, fmt.Errorf("AES/CBC 数据长度不是块大小的整数倍：%d", len(payload))
		}
		out := make([]byte, len(payload))
		if encrypting {
			cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, payload)
			return out, nil
		}
		cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, payload)
		if padding == "PKCS5PADDING" {
			out = legadoPKCS7Unpad(out)
		}
		return out, nil
	case "ECB":
		if encrypting && padding == "PKCS5PADDING" {
			payload = legadoPKCS7Pad(payload, block.BlockSize())
		}
		if len(payload)%block.BlockSize() != 0 {
			return nil, fmt.Errorf("AES/ECB 数据长度不是块大小的整数倍：%d", len(payload))
		}
		out := make([]byte, len(payload))
		for offset := 0; offset < len(payload); offset += block.BlockSize() {
			if encrypting {
				block.Encrypt(out[offset:offset+block.BlockSize()], payload[offset:offset+block.BlockSize()])
			} else {
				block.Decrypt(out[offset:offset+block.BlockSize()], payload[offset:offset+block.BlockSize()])
			}
		}
		if !encrypting && padding == "PKCS5PADDING" {
			out = legadoPKCS7Unpad(out)
		}
		return out, nil
	case "CTR":
		if len(iv) == 0 {
			return nil, fmt.Errorf("AES/CTR 缺少 IV")
		}
		out := make([]byte, len(payload))
		cipher.NewCTR(block, iv).XORKeyStream(out, payload)
		return out, nil
	}
	return nil, fmt.Errorf("不支持的加密模式：%s", transformation)
}

func legadoPKCS7Pad(payload []byte, blockSize int) []byte {
	padding := blockSize - len(payload)%blockSize
	out := make([]byte, len(payload)+padding)
	copy(out, payload)
	for index := len(payload); index < len(out); index++ {
		out[index] = byte(padding)
	}
	return out
}

func legadoPKCS7Unpad(payload []byte) []byte {
	if len(payload) == 0 {
		return payload
	}
	last := int(payload[len(payload)-1])
	if last <= 0 || last > len(payload) || last > 32 {
		return payload
	}
	return payload[:len(payload)-last]
}

// legadoResolveURL 把相对地址按 base 补全（jsoup 的 abs: 语义）。
func legadoResolveURL(base, reference string) string {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	if strings.Contains(reference, "://") {
		return reference
	}
	parsedBase, err := url.Parse(strings.TrimSpace(base))
	if err != nil || parsedBase.Scheme == "" {
		return reference
	}
	if strings.HasPrefix(reference, "//") {
		return parsedBase.Scheme + ":" + reference
	}
	parsedRef, err := url.Parse(reference)
	if err != nil {
		return reference
	}
	return parsedBase.ResolveReference(parsedRef).String()
}

func parseInt64(text string, radix int) (int64, error) {
	if radix == 10 {
		return strconv.ParseInt(text, 10, 64)
	}
	return strconv.ParseInt(text, radix, 64)
}

func legadoNowMillis() int64 { return time.Now().UnixMilli() }
func legadoNowNanos() int64  { return time.Now().UnixNano() }

func pow(base, exponent float64) float64 { return math.Pow(base, exponent) }

// legadoStreamObject 把一段字节包成 InputStream（InputStreamReader 只认 __bytes）。
func legadoStreamObject(vm *goja.Runtime, data []byte) *goja.Object {
	object := vm.NewObject()
	_ = object.Set("__bytes", legadoByteArray(vm, data))
	_ = object.Set("close", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
	_ = object.Set("available", func(goja.FunctionCall) goja.Value { return vm.ToValue(int64(len(data))) })
	return object
}

// legadoURLConnection 复刻 java.net.HttpURLConnection 的常用子集。
//
// 脚本的写法是「先 setRequestMethod / setRequestProperty / getOutputStream 写 body，
// 再 getResponseCode 取状态」，所以真正的请求在第一次读响应时才发出去。
func legadoURLConnection(vm *goja.Runtime, client *http.Client, address string) *goja.Object {
	if client == nil {
		client = http.DefaultClient
	}
	method := "GET"
	headers := map[string]string{}
	var body bytes.Buffer
	var response *http.Response
	var payload, failurePayload []byte
	sent := false

	send := func() error {
		if sent {
			return nil
		}
		sent = true
		var reader io.Reader
		if body.Len() > 0 {
			reader = bytes.NewReader(body.Bytes())
		}
		request, err := http.NewRequest(method, address, reader)
		if err != nil {
			return err
		}
		for key, value := range headers {
			request.Header.Set(key, value)
		}
		if request.Header.Get("User-Agent") == "" {
			request.Header.Set("User-Agent", legadoDefaultUA)
		}
		result, err := client.Do(request)
		if err != nil {
			return err
		}
		response = result
		raw, readErr := io.ReadAll(io.LimitReader(result.Body, 32<<20))
		_ = result.Body.Close()
		if readErr != nil {
			return readErr
		}
		if result.StatusCode >= 400 {
			failurePayload = raw
		} else {
			payload = raw
		}
		return nil
	}

	noop := func(goja.FunctionCall) goja.Value { return goja.Undefined() }
	connection := vm.NewObject()
	_ = connection.Set("setRequestMethod", func(call goja.FunctionCall) goja.Value {
		method = strings.ToUpper(strings.TrimSpace(call.Argument(0).String()))
		return goja.Undefined()
	})
	_ = connection.Set("getRequestMethod", func(goja.FunctionCall) goja.Value { return vm.ToValue(method) })
	for _, name := range []string{
		"setDoOutput", "setDoInput", "setUseCaches", "setInstanceFollowRedirects",
		"setConnectTimeout", "setReadTimeout", "setDefaultUseCaches", "disconnect",
	} {
		_ = connection.Set(name, noop)
	}
	setProperty := func(call goja.FunctionCall) goja.Value {
		name := strings.TrimSpace(call.Argument(0).String())
		value := call.Argument(1).String()
		if name == "" {
			return goja.Undefined()
		}
		if existing, ok := headers[name]; ok && existing != "" {
			headers[name] = existing + ", " + value
			return goja.Undefined()
		}
		headers[name] = value
		return goja.Undefined()
	}
	_ = connection.Set("setRequestProperty", func(call goja.FunctionCall) goja.Value {
		name := strings.TrimSpace(call.Argument(0).String())
		if name != "" {
			headers[name] = call.Argument(1).String()
		}
		return goja.Undefined()
	})
	_ = connection.Set("addRequestProperty", setProperty)
	_ = connection.Set("getOutputStream", func(goja.FunctionCall) goja.Value {
		stream := vm.NewObject()
		_ = stream.Set("write", func(call goja.FunctionCall) goja.Value {
			data := legadoBytesOf(call.Argument(0))
			if len(call.Arguments) >= 3 {
				offset := int(call.Argument(1).ToInteger())
				length := int(call.Argument(2).ToInteger())
				if offset < 0 {
					offset = 0
				}
				if offset > len(data) {
					offset = len(data)
				}
				end := offset + length
				if end > len(data) || end < offset {
					end = len(data)
				}
				data = data[offset:end]
			}
			body.Write(data)
			return goja.Undefined()
		})
		_ = stream.Set("flush", noop)
		_ = stream.Set("close", noop)
		return vm.ToValue(stream)
	})
	_ = connection.Set("getResponseCode", func(goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(int64(response.StatusCode))
	})
	_ = connection.Set("getResponseMessage", func(goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(response.Status)
	})
	_ = connection.Set("getHeaderField", func(call goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			return goja.Null()
		}
		value := response.Header.Get(call.Argument(0).String())
		if value == "" {
			return goja.Null()
		}
		return vm.ToValue(value)
	})
	_ = connection.Set("getContentLength", func(goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			return vm.ToValue(int64(-1))
		}
		return vm.ToValue(response.ContentLength)
	})
	_ = connection.Set("getInputStream", func(goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(legadoStreamObject(vm, payload))
	})
	_ = connection.Set("getErrorStream", func(goja.FunctionCall) goja.Value {
		if err := send(); err != nil {
			return goja.Null()
		}
		if len(failurePayload) == 0 {
			return goja.Null()
		}
		return vm.ToValue(legadoStreamObject(vm, failurePayload))
	})
	return connection
}

// legadoCallStack 把当前 JS 调用栈拼成一行，脚本里报错时用来定位是谁调用的。
func legadoCallStack(vm *goja.Runtime) string {
	frames := vm.CaptureCallStack(3, nil)
	if len(frames) == 0 {
		return ""
	}
	var builder strings.Builder
	builder.WriteString(" | 调用栈:")
	for index, frame := range frames {
		if index >= 6 {
			break
		}
		position := frame.Position()
		builder.WriteString(fmt.Sprintf(" %s@%d:%d", frame.FuncName(), position.Line, position.Column))
	}
	return builder.String()
}
