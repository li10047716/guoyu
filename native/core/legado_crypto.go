package core

// 书源脚本用到的加密能力。
//
// 除了 java.* 那套 Java 类库（见 legado_java.go），书源还常直接调
// CryptoJS（`CryptoJS.AES.decrypt(...)` / `CryptoJS.enc.Utf8.parse(...)`）和
// 阅读自己的 `java.createSymmetricCrypto(...)`。这里用 Go 标准库复刻这两套接口，
// 避免脚本因为 `CryptoJS is not defined` 直接挂掉。

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/des"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"hash"
	"strings"

	"github.com/dop251/goja"
)

// legadoHmac 按算法名算 HMAC。
func legadoHmac(algorithm string, key, payload []byte) []byte {
	var factory func() hash.Hash
	switch strings.ToUpper(strings.ReplaceAll(strings.ReplaceAll(algorithm, "-", ""), "_", "")) {
	case "HMACSHA1":
		factory = sha1.New
	case "HMACSHA256":
		factory = sha256.New
	case "HMACSHA512":
		factory = sha512.New
	case "HMACMD5":
		factory = md5.New
	default:
		factory = sha256.New
	}
	mac := hmac.New(factory, key)
	mac.Write(payload)
	return mac.Sum(nil)
}

// legadoBlockCipher 按算法名造分组密码。
func legadoBlockCipher(algorithm string, key []byte) (cipher.Block, error) {
	switch algorithm {
	case "", "AES":
		if len(key) != 16 && len(key) != 24 && len(key) != 32 {
			return nil, fmt.Errorf("AES 密钥长度不对：%d", len(key))
		}
		return aes.NewCipher(key)
	case "DES":
		if len(key) != 8 {
			return nil, fmt.Errorf("DES 密钥长度不对：%d", len(key))
		}
		return des.NewCipher(key)
	case "DESEDE", "TRIPLEDES":
		if len(key) == 16 {
			key = append(append([]byte{}, key...), key[:8]...)
		}
		if len(key) != 24 {
			return nil, fmt.Errorf("3DES 密钥长度不对：%d", len(key))
		}
		return des.NewTripleDESCipher(key)
	}
	return nil, fmt.Errorf("不支持的加密算法：%s", algorithm)
}

// legadoBlockCrypt 是 Cipher / CryptoJS 共用的分组加解密实现。
//
// transformation 形如 `AES/CBC/PKCS5Padding`，mode 1=加密、2=解密。
func legadoBlockCrypt(transformation string, mode int64, key, iv, payload []byte) ([]byte, error) {
	parts := strings.Split(strings.ToUpper(strings.ReplaceAll(transformation, "-", "")), "/")
	algorithm := strings.TrimSpace(parts[0])
	modeName := "CBC"
	if len(parts) > 1 && strings.TrimSpace(parts[1]) != "" {
		modeName = strings.TrimSpace(parts[1])
	}
	padding := "PKCS5PADDING"
	if len(parts) > 2 && strings.TrimSpace(parts[2]) != "" {
		padding = strings.ReplaceAll(strings.TrimSpace(parts[2]), "-", "")
	}
	block, err := legadoBlockCipher(algorithm, key)
	if err != nil {
		return nil, err
	}
	encrypting := mode != 2
	blockSize := block.BlockSize()
	padded := padding == "PKCS5PADDING" || padding == "PKCS7PADDING"

	switch modeName {
	case "CBC", "":
		if len(iv) < blockSize {
			return nil, fmt.Errorf("%s/CBC 缺少 IV", algorithm)
		}
		if encrypting {
			if padded {
				payload = legadoPKCS7Pad(payload, blockSize)
			}
			if len(payload)%blockSize != 0 {
				return nil, fmt.Errorf("数据长度不是块大小的整数倍：%d", len(payload))
			}
			out := make([]byte, len(payload))
			cipher.NewCBCEncrypter(block, iv[:blockSize]).CryptBlocks(out, payload)
			return out, nil
		}
		if len(payload)%blockSize != 0 {
			return nil, fmt.Errorf("密文长度不是块大小的整数倍：%d", len(payload))
		}
		out := make([]byte, len(payload))
		cipher.NewCBCDecrypter(block, iv[:blockSize]).CryptBlocks(out, payload)
		if padded {
			out = legadoPKCS7Unpad(out)
		}
		return out, nil
	case "ECB":
		if encrypting {
			if padded {
				payload = legadoPKCS7Pad(payload, blockSize)
			}
			if len(payload)%blockSize != 0 {
				return nil, fmt.Errorf("数据长度不是块大小的整数倍：%d", len(payload))
			}
		} else if len(payload)%blockSize != 0 {
			return nil, fmt.Errorf("密文长度不是块大小的整数倍：%d", len(payload))
		}
		out := make([]byte, len(payload))
		for offset := 0; offset < len(payload); offset += blockSize {
			if encrypting {
				block.Encrypt(out[offset:offset+blockSize], payload[offset:offset+blockSize])
			} else {
				block.Decrypt(out[offset:offset+blockSize], payload[offset:offset+blockSize])
			}
		}
		if !encrypting && padded {
			out = legadoPKCS7Unpad(out)
		}
		return out, nil
	case "CTR":
		if len(iv) < blockSize {
			return nil, fmt.Errorf("%s/CTR 缺少 IV", algorithm)
		}
		out := make([]byte, len(payload))
		cipher.NewCTR(block, iv[:blockSize]).XORKeyStream(out, payload)
		return out, nil
	case "CFB":
		if len(iv) < blockSize {
			return nil, fmt.Errorf("%s/CFB 缺少 IV", algorithm)
		}
		out := make([]byte, len(payload))
		if encrypting {
			cipher.NewCFBEncrypter(block, iv[:blockSize]).XORKeyStream(out, payload)
		} else {
			cipher.NewCFBDecrypter(block, iv[:blockSize]).XORKeyStream(out, payload)
		}
		return out, nil
	case "OFB":
		if len(iv) < blockSize {
			return nil, fmt.Errorf("%s/OFB 缺少 IV", algorithm)
		}
		out := make([]byte, len(payload))
		cipher.NewOFB(block, iv[:blockSize]).XORKeyStream(out, payload)
		return out, nil
	case "GCM":
		// GCM 的 nonce 一般 12 字节，少数书源用 16 字节，两种都支持。
		var mode cipher.AEAD
		var err error
		if len(iv) == 12 {
			mode, err = cipher.NewGCM(block)
		} else {
			mode, err = cipher.NewGCMWithNonceSize(block, len(iv))
		}
		if err != nil {
			return nil, err
		}
		if encrypting {
			return mode.Seal(nil, iv, payload, nil), nil
		}
		out, err := mode.Open(nil, iv, payload, nil)
		if err != nil {
			return nil, fmt.Errorf("GCM 解密失败：%v", err)
		}
		return out, nil
	}
	return nil, fmt.Errorf("不支持的加密模式：%s", transformation)
}

// ------------------------------------------------------------------ WordArray

// legadoWordArray 造一个 CryptoJS 的 WordArray。
//
// CryptoJS 的 WordArray 用 words/sigBytes 表示字节串，书源脚本基本只用
// `toString()` / `toString(CryptoJS.enc.Utf8)` / `concat()` / `sigBytes`，
// 所以这里存原始字节，接口按需模拟。
func legadoWordArray(vm *goja.Runtime, data []byte) *goja.Object {
	object := vm.NewObject()
	_ = object.Set("__bytes", legadoByteArray(vm, data))
	_ = object.Set("__wordArray", true)
	_ = object.Set("sigBytes", len(data))
	_ = object.Set("toString", func(call goja.FunctionCall) goja.Value {
		if len(call.Arguments) > 0 {
			if name := legadoWordEncoderName(call.Argument(0)); name != "" {
				return vm.ToValue(legadoWordEncode(data, name))
			}
		}
		return vm.ToValue(hex.EncodeToString(data))
	})
	_ = object.Set("concat", func(call goja.FunctionCall) goja.Value {
		joined := append([]byte{}, data...)
		joined = append(joined, legadoWordBytes(vm, call.Argument(0))...)
		return vm.ToValue(legadoWordArray(vm, joined))
	})
	_ = object.Set("clone", func(goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWordArray(vm, append([]byte{}, data...)))
	})
	return object
}

// legadoWordBytes 从 CryptoJS 的各种输入里取出字节。
func legadoWordBytes(vm *goja.Runtime, value goja.Value) []byte {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	if object, ok := value.(*goja.Object); ok {
		if raw := object.Get("__bytes"); raw != nil && !goja.IsUndefined(raw) && !goja.IsNull(raw) {
			return legadoBytesOf(raw)
		}
		if ciphertext := object.Get("ciphertext"); ciphertext != nil && !goja.IsUndefined(ciphertext) {
			return legadoWordBytes(vm, ciphertext)
		}
		if function, okCast := goja.AssertFunction(object.Get("toString")); okCast {
			if result, err := function(object); err == nil && result != nil {
				text := strings.TrimSpace(result.String())
				if decoded, errHex := hex.DecodeString(text); errHex == nil && len(decoded) > 0 {
					return decoded
				}
				if decoded, errBase64 := base64.StdEncoding.DecodeString(text); errBase64 == nil && len(decoded) > 0 {
					return decoded
				}
				return []byte(text)
			}
		}
	}
	return legadoBytesOf(value)
}

// legadoWordEncoderName 取 encoder 的名字（Hex / Base64 / Utf8 / Latin1）。
func legadoWordEncoderName(value goja.Value) string {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return ""
	}
	if object, ok := value.(*goja.Object); ok {
		if name := object.Get("__enc"); name != nil && !goja.IsUndefined(name) {
			return name.String()
		}
	}
	switch strings.ToLower(value.String()) {
	case "hex":
		return "Hex"
	case "base64":
		return "Base64"
	case "utf8", "utf-8":
		return "Utf8"
	}
	return ""
}

func legadoWordEncode(data []byte, name string) string {
	switch name {
	case "Base64":
		return base64.StdEncoding.EncodeToString(data)
	case "Utf8":
		return string(data)
	case "Latin1":
		return string(data)
	}
	return hex.EncodeToString(data)
}

func legadoWordDecode(text, name string) []byte {
	switch name {
	case "Base64":
		trimmed := strings.TrimSpace(text)
		if decoded, err := base64.StdEncoding.DecodeString(trimmed); err == nil {
			return decoded
		}
		if decoded, err := base64.RawStdEncoding.DecodeString(trimmed); err == nil {
			return decoded
		}
		if decoded, err := base64.URLEncoding.DecodeString(trimmed); err == nil {
			return decoded
		}
		return nil
	case "Utf8", "Latin1":
		return []byte(text)
	}
	trimmed := strings.TrimSpace(text)
	if decoded, err := hex.DecodeString(trimmed); err == nil {
		return decoded
	}
	return nil
}

// legadoCryptoJsObject 造 CryptoJS 命名空间。
func legadoCryptoJsObject(vm *goja.Runtime) *goja.Object {
	cryptoJs := vm.NewObject()

	encoder := func(name string) *goja.Object {
		object := vm.NewObject()
		_ = object.Set("__enc", name)
		_ = object.Set("parse", func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoWordArray(vm, legadoWordDecode(call.Argument(0).String(), name)))
		})
		_ = object.Set("stringify", func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoWordEncode(legadoWordBytes(vm, call.Argument(0)), name))
		})
		return object
	}
	enc := vm.NewObject()
	_ = enc.Set("Hex", encoder("Hex"))
	_ = enc.Set("Base64", encoder("Base64"))
	_ = enc.Set("Utf8", encoder("Utf8"))
	_ = enc.Set("Latin1", encoder("Latin1"))
	_ = cryptoJs.Set("enc", enc)

	// pad / mode 只是标记，真正的填充与模式在加解密时按名字处理
	newMarker := func(name string, field string) *goja.Object {
		object := vm.NewObject()
		_ = object.Set(field, name)
		return object
	}
	pad := vm.NewObject()
	_ = pad.Set("Pkcs7", newMarker("Pkcs7", "__pad"))
	_ = pad.Set("NoPadding", newMarker("NoPadding", "__pad"))
	_ = pad.Set("ZeroPadding", newMarker("ZeroPadding", "__pad"))
	_ = cryptoJs.Set("pad", pad)
	mode := vm.NewObject()
	for _, name := range []string{"CBC", "ECB", "CTR", "CFB", "OFB"} {
		_ = mode.Set(name, newMarker(name, "__mode"))
	}
	_ = cryptoJs.Set("mode", mode)

	lib := vm.NewObject()
	wordArray := vm.NewObject()
	_ = wordArray.Set("create", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoWordArray(vm, legadoWordBytes(vm, call.Argument(0))))
	})
	_ = lib.Set("WordArray", wordArray)
	_ = cryptoJs.Set("lib", lib)

	// ---- 摘要 ----
	digest := func(algorithm string) func(goja.FunctionCall) goja.Value {
		return func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(legadoWordArray(vm, legadoDigestBytes(algorithm, legadoWordBytes(vm, call.Argument(0)))))
		}
	}
	_ = cryptoJs.Set("MD5", digest("MD5"))
	_ = cryptoJs.Set("SHA1", digest("SHA1"))
	_ = cryptoJs.Set("SHA256", digest("SHA256"))
	_ = cryptoJs.Set("SHA512", digest("SHA512"))

	hmacFn := func(algorithm string) func(goja.FunctionCall) goja.Value {
		return func(call goja.FunctionCall) goja.Value {
			payload := legadoWordBytes(vm, call.Argument(0))
			key := legadoWordBytes(vm, call.Argument(1))
			return vm.ToValue(legadoWordArray(vm, legadoHmac(algorithm, key, payload)))
		}
	}
	_ = cryptoJs.Set("HmacMD5", hmacFn("HmacMD5"))
	_ = cryptoJs.Set("HmacSHA1", hmacFn("HmacSHA1"))
	_ = cryptoJs.Set("HmacSHA256", hmacFn("HmacSHA256"))
	_ = cryptoJs.Set("HmacSHA512", hmacFn("HmacSHA512"))

	// ---- 对称加解密 ----
	cipherApi := func(algorithm string) *goja.Object {
		object := vm.NewObject()
		_ = object.Set("encrypt", func(call goja.FunctionCall) goja.Value {
			payload := legadoWordBytes(vm, call.Argument(0))
			key, iv, modeName, padding := legadoCryptoJsParts(vm, algorithm, call.Argument(1), call.Argument(2))
			result, err := legadoBlockCrypt(algorithm+"/"+modeName+"/"+padding, 1, key, iv, payload)
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return vm.ToValue(legadoCipherParams(vm, result))
		})
		_ = object.Set("decrypt", func(call goja.FunctionCall) goja.Value {
			payload := legadoWordBytes(vm, call.Argument(0))
			key, iv, modeName, padding := legadoCryptoJsParts(vm, algorithm, call.Argument(1), call.Argument(2))
			result, err := legadoBlockCrypt(algorithm+"/"+modeName+"/"+padding, 2, key, iv, payload)
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return vm.ToValue(legadoWordArray(vm, result))
		})
		return object
	}
	_ = cryptoJs.Set("AES", cipherApi("AES"))
	_ = cryptoJs.Set("DES", cipherApi("DES"))
	_ = cryptoJs.Set("TripleDES", cipherApi("DESede"))

	return cryptoJs
}

// legadoCipherParams 是 CryptoJS.encrypt 的结果：toString() 给 base64。
func legadoCipherParams(vm *goja.Runtime, data []byte) *goja.Object {
	object := vm.NewObject()
	_ = object.Set("__bytes", legadoByteArray(vm, data))
	_ = object.Set("ciphertext", legadoWordArray(vm, data))
	_ = object.Set("sigBytes", len(data))
	_ = object.Set("toString", func(call goja.FunctionCall) goja.Value {
		name := "Base64"
		if len(call.Arguments) > 0 {
			if custom := legadoWordEncoderName(call.Argument(0)); custom != "" {
				name = custom
			}
		}
		return vm.ToValue(legadoWordEncode(data, name))
	})
	return object
}

// legadoCryptoJsParts 解析 CryptoJS 的 key 与 cfg（{iv, mode, padding}）。
func legadoCryptoJsParts(vm *goja.Runtime, algorithm string, keyValue, cfgValue goja.Value) ([]byte, []byte, string, string) {
	key := legadoWordBytes(vm, keyValue)
	modeName := "CBC"
	padding := "PKCS5Padding"
	if cfgValue == nil || goja.IsUndefined(cfgValue) || goja.IsNull(cfgValue) {
		return key, nil, modeName, padding
	}
	cfg, ok := cfgValue.(*goja.Object)
	if !ok {
		return key, nil, modeName, padding
	}
	var iv []byte
	if raw := cfg.Get("iv"); raw != nil && !goja.IsUndefined(raw) && !goja.IsNull(raw) {
		iv = legadoWordBytes(vm, raw)
	}
	if raw := cfg.Get("mode"); raw != nil && !goja.IsUndefined(raw) {
		if object, okCast := raw.(*goja.Object); okCast {
			if name := object.Get("__mode"); name != nil && !goja.IsUndefined(name) {
				modeName = name.String()
			}
		}
	}
	if raw := cfg.Get("padding"); raw != nil && !goja.IsUndefined(raw) {
		if object, okCast := raw.(*goja.Object); okCast {
			if name := object.Get("__pad"); name != nil && !goja.IsUndefined(name) {
				switch name.String() {
				case "Pkcs7":
					padding = "PKCS5Padding"
				case "NoPadding":
					padding = "NoPadding"
				case "ZeroPadding":
					padding = "NoPadding"
				}
			}
		}
	}
	// GCM 没有 PKCS 填充，脚本里写 Pkcs7 也按无填充处理
	if modeName == "GCM" || modeName == "CTR" || modeName == "CFB" || modeName == "OFB" {
		padding = "NoPadding"
	}
	_ = algorithm
	return key, iv, modeName, padding
}

// legadoSymmetricCrypto 实现 java.createSymmetricCrypto(...)。
//
// 返回值对应 Legado 的 SymmetricCrypto：encrypt / decrypt 走 byte[]，
// encryptBase64 / encryptHex / decryptStr 走字符串，书源两种写法都有。
func legadoSymmetricCrypto(vm *goja.Runtime, transformation string, key, iv []byte) *goja.Object {
	object := vm.NewObject()
	encrypt := func(payload []byte) []byte {
		out, err := legadoBlockCrypt(transformation, 1, key, iv, payload)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return out
	}
	decrypt := func(payload []byte) []byte {
		out, err := legadoBlockCrypt(transformation, 2, key, iv, payload)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return out
	}
	_ = object.Set("encrypt", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoByteArray(vm, encrypt(legadoWordBytes(vm, call.Argument(0)))))
	})
	_ = object.Set("decrypt", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(legadoByteArray(vm, decrypt(legadoWordBytes(vm, call.Argument(0)))))
	})
	_ = object.Set("encryptBase64", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(base64.StdEncoding.EncodeToString(encrypt(legadoWordBytes(vm, call.Argument(0)))))
	})
	_ = object.Set("encryptHex", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(hex.EncodeToString(encrypt(legadoWordBytes(vm, call.Argument(0)))))
	})
	_ = object.Set("decryptStr", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(string(decrypt(legadoBase64OrRawBytes(vm, call.Argument(0)))))
	})
	_ = object.Set("decryptBase64", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(string(decrypt(legadoBase64OrRawBytes(vm, call.Argument(0)))))
	})
	return object
}

// legadoBase64OrRawBytes 解密入参既可能是 base64 字符串，也可能是 byte[]。
func legadoBase64OrRawBytes(vm *goja.Runtime, value goja.Value) []byte {
	if object, ok := value.(*goja.Object); ok {
		if raw := object.Get("__bytes"); raw != nil && !goja.IsUndefined(raw) {
			return legadoBytesOf(raw)
		}
	}
	text := strings.TrimSpace(value.String())
	if decoded, err := base64.StdEncoding.DecodeString(text); err == nil && len(decoded) > 0 {
		return decoded
	}
	return []byte(text)
}

// legadoPkcs7UnpadBytes 供 CryptoJS NoPadding 之外的场景兜底。
func legadoPkcs7UnpadBytes(data []byte) []byte {
	return legadoPKCS7Unpad(append([]byte{}, data...))
}

// legadoBytesEqual 判断两段字节是否相同（脚本里偶有比较需求）。
func legadoBytesEqual(left, right []byte) bool {
	return bytes.Equal(left, right)
}
