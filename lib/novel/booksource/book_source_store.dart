/// 自定义书源的存储与导入编排（0.7.68）。
///
/// 落盘位置：`<应用数据目录>/novels/book-sources.json`，
/// 和本地书共用一个目录，方便一起备份。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../novel_library.dart';
import 'book_source.dart';
import 'book_source_http.dart';
import 'book_source_parser.dart';

/// 书源仓库（单例）。
class BookSourceStore extends ChangeNotifier {
  BookSourceStore._();

  static final BookSourceStore instance = BookSourceStore._();

  static const String fileName = 'book-sources.json';

  final List<BookSource> _sources = [];
  bool _loaded = false;
  String? _dirOverride;
  bool _persistDisabled = false;

  List<BookSource> get sources => List.unmodifiable(_sources);
  bool get loaded => _loaded;

  /// 启用中的源（界面列表用）。
  List<BookSource> get enabledSources =>
      _sources.where((s) => s.enabled).toList(growable: false);

  /// 启用且本地引擎能跑的源（搜索时会用它）。
  List<BookSource> get usableSources => _sources
      .where((s) => s.enabled && s.status.usable)
      .toList(growable: false);

  BookSource? byKey(String key) {
    for (final source in _sources) {
      if (source.key == key) return source;
    }
    return null;
  }

  /// 仅测试用：指定落盘目录；传 null 表示关闭持久化（内存态）。
  @visibleForTesting
  void debugSetDir(String? dir) {
    _dirOverride = dir;
    _persistDisabled = dir == null;
    _loaded = false;
    _sources.clear();
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final file = await _file();
    if (file == null || !await file.exists()) return;
    try {
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      _sources
        ..clear()
        ..addAll([
          for (final row in decoded)
            if (row is Map) BookSource.fromJson(Map<String, dynamic>.from(row)),
        ]);
      notifyListeners();
    } catch (error) {
      debugPrint('读取书源失败：$error');
    }
  }

  /// 导入一段文本（书源 JSON）。返回本次新增的源。
  Future<BookSourceImport> importText(
    String text, {
    bool overwrite = false,
  }) async {
    await ensureLoaded();
    final result = parseBookSources(
      text,
      existing: _sources,
      overwriteExisting: overwrite,
    );
    if (result.isEmpty) return result;

    for (final source in result.parsed) {
      final index = _sources.indexWhere((s) => s.key == source.key);
      if (index >= 0) {
        // 覆盖时保留用户原有的启用状态
        _sources[index] = source.copyWith(enabled: _sources[index].enabled);
      } else {
        _sources.add(source);
      }
    }
    await _save();
    notifyListeners();
    return result;
  }

  /// 从网址导入（书源 JSON 直链）。
  Future<BookSourceImport> importUrl(
    String url, {
    bool overwrite = false,
  }) async {
    await ensureLoaded();
    final result = await BookSourceHttp.fetch(
      url,
      timeout: const Duration(seconds: 25),
    );
    if (!result.ok) {
      throw FetchFailure('下载书源失败（HTTP ${result.status}）', status: result.status);
    }
    return importText(result.body, overwrite: overwrite);
  }

  Future<void> remove(String key) async {
    _sources.removeWhere((s) => s.key == key);
    await _save();
    notifyListeners();
  }

  Future<void> removeMany(Iterable<String> keys) async {
    final set = keys.toSet();
    _sources.removeWhere((s) => set.contains(s.key));
    await _save();
    notifyListeners();
  }

  /// 合并脚本写下的变量（`java.put` / `source.setVariable`）。
  ///
  /// 不触发 notifyListeners：变量变化不影响列表展示，避免搜索时频繁重建界面。
  Future<void> mergeVariables(String key, Map<String, String> vars) async {
    if (vars.isEmpty) return;
    final index = _sources.indexWhere((s) => s.key == key);
    if (index < 0) return;
    final merged = {..._sources[index].variables, ...vars};
    if (merged.length == _sources[index].variables.length) {
      var same = true;
      for (final entry in vars.entries) {
        if (_sources[index].variables[entry.key] != entry.value) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _sources[index] = _sources[index].copyWith(variables: merged);
    await _save();
  }

  Future<void> setEnabled(String key, bool enabled) async {
    final index = _sources.indexWhere((s) => s.key == key);
    if (index < 0) return;
    _sources[index] = _sources[index].copyWith(enabled: enabled);
    await _save();
    notifyListeners();
  }

  Future<void> setGroup(String key, String group) async {
    final index = _sources.indexWhere((s) => s.key == key);
    if (index < 0) return;
    _sources[index] = _sources[index].copyWith(group: group);
    await _save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 落盘

  Future<File?> _file() async {
    if (_persistDisabled) return null;
    final dir = _dirOverride ?? await NovelLibrary.tryResolve();
    if (dir == null) return null;
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return File(p.join(dir, fileName));
    } catch (error) {
      debugPrint('书源目录不可用：$error');
      return null;
    }
  }

  Future<void> _save() async {
    final file = await _file();
    if (file == null) return;
    try {
      final payload = jsonEncode([for (final s in _sources) s.toJson()]);
      await file.writeAsString(payload, flush: true);
    } catch (error) {
      debugPrint('保存书源失败：$error');
    }
  }
}
