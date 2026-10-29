import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 改名前的品牌名（0.7.33 及更早）。
const _legacyBrandNames = ['真果鉴', '红果鉴'];

/// 品牌改名后的数据目录迁移。
///
/// Windows 上 path_provider 把应用数据放在 `%APPDATA%\<CompanyName>\<ProductName>`，
/// 这两个值来自 exe 的版本资源（windows/runner/Runner.rc）。0.7.34 改名「果屿」后
/// 目录变成 `%APPDATA%\果屿\果屿`，而旧目录里的收藏、观看记录、下载队列、
/// 播放偏好不会跟着搬——用户升级后会发现"我的一切都没了"。
///
/// 这里只在新目录还空的时候把旧目录整份复制过去；**只复制不删除**，
/// 万一新名字要回滚，旧数据仍原样躺在那里。
///
/// 复制失败时把已经复制的内容清回去，保证下次启动还能重试，
/// 而不是留下半份数据被当成"用户自己的数据"。
Future<void> migrateLegacyBrandData() async {
  if (!Platform.isWindows) return;
  try {
    final target = await getApplicationSupportDirectory();
    if (await _hasEntries(target)) return;
    final roaming = Platform.environment['APPDATA'];
    if (roaming == null || roaming.isEmpty) return;
    for (final brand in _legacyBrandNames) {
      final legacy = Directory(p.join(roaming, brand, brand));
      if (!await _hasEntries(legacy)) continue;
      try {
        await _copyDirectory(legacy, target);
        await File(
          p.join(target.path, '.migrated-from'),
        ).writeAsString(brand, flush: true);
        debugPrint('已把「$brand」的数据迁移到「果屿」目录');
      } catch (_) {
        await _clear(target);
        rethrow;
      }
      return;
    }
  } catch (error) {
    // 迁移失败不能挡住启动，按"像新装一样"继续跑。
    debugPrint('品牌数据迁移失败，按新装处理：$error');
  }
}

/// 目录里是否有真实文件（递归判断，忽略只有空壳目录的情况）。
Future<bool> _hasEntries(Directory directory) async {
  try {
    if (!await directory.exists()) return false;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) return true;
      if (entity is Directory && await _hasEntries(entity)) return true;
    }
  } catch (_) {
    return false;
  }
  return false;
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final destination = p.join(target.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(destination));
    } else if (entity is File) {
      await entity.copy(destination);
    }
  }
}

/// 回滚：目标目录此前已确认是空的，删掉的只会是刚复制进去的内容。
Future<void> _clear(Directory directory) async {
  try {
    await for (final entity in directory.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  } catch (_) {
    // 清不掉就让它去，反正下次启动会因为"非空"而跳过迁移。
  }
}
