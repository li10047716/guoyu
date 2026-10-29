/// 直接打原生核心验证书源脚本执行（开发用）。
///
///   dart run tool/legado_js_probe.dart <书源.json> [关键词]
///
/// 绕过 Flutter，用 dart:ffi 加载 duanju_core.dll，发 initialize + legadoJs，
/// 用来确认「Dart 组包 → Go goja → 返回」这条链路是通的。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

late final _DartRequest _request;
late final _DartFree _free;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/legado_js_probe.dart <书源.json> [关键词]');
    exit(64);
  }
  final library = DynamicLibrary.open('windows/runner/duanju_core.dll');
  _request = library.lookupFunction<_NativeRequest, _DartRequest>('DuanjuRequest');
  _free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');

  final init = call({'action': 'initialize', 'directory': Directory.systemTemp.path});
  stdout.writeln('initialize → $init');

  final raw = File(args[0]).readAsStringSync();
  final decoded = jsonDecode(raw);
  final row = (decoded is List ? decoded.first : decoded) as Map;
  final keyword = args.length > 1 ? args[1] : '诡秘之主';
  final searchUrl = '${row['searchUrl'] ?? ''}';
  if (!searchUrl.startsWith('@js:')) {
    stdout.writeln('这个源的 searchUrl 不是 @js:，跳过');
    return;
  }

  final response = call({
    'action': 'legadoJs',
    'legado': {
      'code': searchUrl.substring(4),
      'jsLib': '${row['jsLib'] ?? ''}',
      'key': keyword,
      'page': 1,
      'baseUrl': '${row['bookSourceUrl'] ?? ''}',
      'result': '',
      'extras': const <String, String>{},
      'source': {
        'key': 'probe',
        'name': '${row['bookSourceName'] ?? ''}',
        'url': '${row['bookSourceUrl'] ?? ''}',
        'header': '${row['header'] ?? ''}',
        'variables': const <String, String>{},
      },
      'book': {
        'name': '',
        'author': '',
        'url': '',
        'vars': const <String, String>{},
      },
    },
  });
  stdout.writeln('legadoJs → $response');
}

Map<String, dynamic> call(Map<String, dynamic> input) {
  final text = jsonEncode(input);
  final pointer = text.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = _request(pointer);
    final result = output.toDartString();
    final decoded = jsonDecode(result);
    if (decoded is Map && decoded['ok'] != true) {
      return {'ok': false, 'error': decoded['error']};
    }
    final data = decoded is Map ? decoded['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : {'ok': true};
  } finally {
    if (output != nullptr) _free(output);
    malloc.free(pointer);
  }
}
