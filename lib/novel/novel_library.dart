import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:duanju_app/core/novel_models.dart';

/// 本地书的落盘目录（0.7.67）。
///
/// Go 核心不猜 Flutter 的路径：导入时把 `NovelLibrary.resolve()` 的结果
/// 作为 `libraryDir` 传下去，核心在 `<dir>/novel-books/` 里放
/// `<id>.txt`（UTF-8 全文）和 `<id>.json`（章节偏移索引）。
class NovelLibrary {
  NovelLibrary._();

  static String? _cached;

  /// 目录拿不到时（插件缺失、平台不支持）标记一次，后续直接跳过缓存，
  /// 不让每一章都白等一次超时。
  static bool _unavailable = false;

  /// 应用数据目录下的小说根目录，首次调用时创建。
  static Future<String> resolve() async {
    if (_cached != null) return _cached!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'novels'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cached = dir.path;
    return _cached!;
  }

  /// 带超时的解析：拿不到就返回 null，调用方按「没有缓存」处理。
  ///
  /// 缓存只是加速手段，任何情况下都不该卡住正文加载——阅读器优先用它，
  /// 但超时（或插件不可用）必须立刻退化到网络。
  static Future<String?> tryResolve({
    Duration timeout = const Duration(milliseconds: 400),
  }) async {
    if (_cached != null) return _cached;
    if (_unavailable) return null;
    try {
      return await resolve().timeout(timeout);
    } catch (error) {
      debugPrint('小说目录不可用，缓存功能关闭：$error');
      _unavailable = true;
      return null;
    }
  }

  /// 读本地书时用的目录。
  ///
  /// 和 [resolve] 的区别：这里允许「拿不到真实目录」——那种情况下退到临时目录，
  /// 让核心直接报「书不存在」（一句话的错误），而不是让阅读器永远转圈。
  static Future<String> localDir() async {
    final dir = await tryResolve();
    if (dir != null) return dir;
    return p.join(Directory.systemTemp.path, 'guoyu-novels');
  }

  /// 仅测试用：绕开 path_provider，直接指定目录；
  /// 传 null 表示**关掉缓存**（widget 测试里没有真实文件 IO 的事件循环，
  /// 正文读取不能依赖磁盘）。
  @visibleForTesting
  static void debugSetDir(String? dir) {
    _cached = dir;
    _unavailable = dir == null;
    NovelCache.debugReset();
  }
}

/// 章节缓存（0.7.67）：把抓到的正文按「站源_书号/章节号」落到本地。
///
/// 只做单章 JSON，不做数据库——一章一个文件，读的时候直接反序列化，
/// 删书时整个目录删掉即可，不需要维护索引一致性。
class NovelCache {
  NovelCache._();

  static String? _root;

  static Future<String?> _rootDir() async {
    if (_root != null) return _root;
    final base = await NovelLibrary.tryResolve();
    if (base == null) return null;
    final dir = Directory(p.join(base, 'cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir.path;
    return _root;
  }

  static Future<String?> _bookDir(String bookKey) async {
    final root = await _rootDir();
    if (root == null) return null;
    final safe = bookKey.replaceAll(RegExp(r'[^\w\-]'), '_');
    return p.join(root, safe);
  }

  static Future<NovelText?> read(String bookKey, String chapterId) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return null;
      final file = File(p.join(dir, '${_safeChapter(chapterId)}.json'));
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      return NovelText.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (error) {
      debugPrint('读章节缓存失败：$error');
      return null;
    }
  }

  static Future<void> write(String bookKey, NovelText text) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return;
      final folder = Directory(dir);
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }
      final file = File(p.join(dir, '${_safeChapter(text.chapterId)}.json'));
      await file.writeAsString(
        jsonEncode({
          'bookId': text.bookId,
          'chapterId': text.chapterId,
          'title': text.title,
          'paragraphs': text.paragraphs,
        }),
      );
    } catch (error) {
      debugPrint('写章节缓存失败：$error');
    }
  }

  static Future<bool> has(String bookKey, String chapterId) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return false;
      return await File(p.join(dir, '${_safeChapter(chapterId)}.json')).exists();
    } catch (_) {
      return false;
    }
  }

  /// 已经缓存了多少章（详情页用来显示缓存进度）。
  static Future<int> count(String bookKey) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return 0;
      final folder = Directory(dir);
      if (!await folder.exists()) return 0;
      var total = 0;
      await for (final entity in folder.list()) {
        if (entity is File && entity.path.endsWith('.json')) total++;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear(String bookKey) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return;
      final folder = Directory(dir);
      if (await folder.exists()) await folder.delete(recursive: true);
    } catch (error) {
      debugPrint('清空章节缓存失败：$error');
    }
  }

  /// 缓存目录大小（字节），详情页显示占用。
  static Future<int> size(String bookKey) async {
    try {
      final dir = await _bookDir(bookKey);
      if (dir == null) return 0;
      final folder = Directory(dir);
      if (!await folder.exists()) return 0;
      var total = 0;
      await for (final entity in folder.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 章节号里可能有 `/` 之类（本地书用序号，安全；远端是数字）。
  static String _safeChapter(String chapterId) =>
      chapterId.replaceAll(RegExp(r'[^\w\-]'), '_');

  @visibleForTesting
  static void debugReset() => _root = null;
}
