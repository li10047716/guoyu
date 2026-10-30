import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/novel_models.dart';

/// 阅读进度：读到哪一章、章内滚动位置。
class NovelProgress {
  const NovelProgress({
    required this.chapterId,
    required this.chapterIndex,
    this.offset = 0,
    required this.updatedAt,
  });

  final String chapterId;
  final int chapterIndex;

  /// 章内滚动偏移（像素），用于恢复阅读位置。
  final double offset;
  final DateTime updatedAt;

  factory NovelProgress.fromJson(Map<String, dynamic> json) => NovelProgress(
    chapterId: '${json['chapterId'] ?? ''}',
    chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
    offset: (json['offset'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'chapterId': chapterId,
    'chapterIndex': chapterIndex,
    'offset': offset,
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 书架条目：书籍信息 + 阅读进度 + 所属分组 + 已知章节数。
class NovelShelfEntry {
  const NovelShelfEntry({
    required this.novel,
    this.progress,
    this.groups = const [],
    this.knownChapters = 0,
  });

  final Novel novel;
  final NovelProgress? progress;

  /// 所属自定义分组（NovelShelfGroup.id）。
  final List<String> groups;

  /// 上次已知的总章节数，用来判断"有新章"。
  final int knownChapters;

  /// 是否比上次多了章节（书架上的红点）。
  bool get hasUpdates => novel.chapters > knownChapters && knownChapters > 0;

  NovelShelfEntry copyWith({
    Novel? novel,
    NovelProgress? progress,
    List<String>? groups,
    int? knownChapters,
  }) => NovelShelfEntry(
    novel: novel ?? this.novel,
    progress: progress ?? this.progress,
    groups: groups ?? this.groups,
    knownChapters: knownChapters ?? this.knownChapters,
  );

  factory NovelShelfEntry.fromJson(Map<String, dynamic> json) =>
      NovelShelfEntry(
        novel: Novel.fromJson(Map<String, dynamic>.from(json['novel'] as Map)),
        progress: json['progress'] is Map
            ? NovelProgress.fromJson(
                Map<String, dynamic>.from(json['progress'] as Map),
              )
            : null,
        groups: [
          for (final item in (json['groups'] as List? ?? const []))
            if ('$item'.isNotEmpty) '$item',
        ],
        knownChapters: (json['knownChapters'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'novel': novel.toJson(),
    'progress': progress?.toJson(),
    'groups': groups,
    'knownChapters': knownChapters,
  };
}

/// 自定义书架分组（用户在「管理分组」里建的）。
class NovelShelfGroup {
  const NovelShelfGroup({required this.id, required this.name});

  final String id;
  final String name;

  factory NovelShelfGroup.fromJson(Map<String, dynamic> json) =>
      NovelShelfGroup(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// 翻页方式。
///
/// 0.7.86 起默认 [slide]（左右翻页）：手机阅读器的标准形态，也顺手解决了
/// 老版本「整章一页竖着滚、看着像浏览器网页」的问题。
enum NovelPageMode {
  slide('左右翻页'),
  scroll('上下滚动');

  const NovelPageMode(this.label);

  final String label;
}

/// 正文字体。
///
/// 字体名得按平台给：`Songti SC` / `Kaiti SC` 是 iOS / macOS 的名字，
/// Windows 上对应 `SimSun` / `KaiTi`，而 **Android 根本没有这几个商标字体**，
/// 只有 `serif` / `sans-serif` 两个通用族——0.7.86 之前统一写成苹果那套，
/// 在安卓上等于三个选项全都没生效，用户点了「楷体」看到的还是默认黑体。
enum NovelFontFamily {
  system('默认'),
  serif('宋体'),
  kai('楷体'),
  hei('黑体');

  const NovelFontFamily(this.label);

  final String label;

  /// 传给 TextStyle.fontFamily；null 表示跟随系统。
  String? get fontFamily {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final apple =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    switch (this) {
      case NovelFontFamily.system:
        return null;
      case NovelFontFamily.serif:
        if (android) return 'serif';
        return apple ? 'Songti SC' : 'SimSun';
      case NovelFontFamily.kai:
        // Android 没有楷体字族，退到衬线体——至少和默认黑体区分得开。
        if (android) return 'serif';
        return apple ? 'Kaiti SC' : 'KaiTi';
      case NovelFontFamily.hei:
        if (android) return 'sans-serif';
        return apple ? 'Heiti SC' : 'Microsoft YaHei';
    }
  }
}

/// 阅读器外观设置（字号 / 行距 / 主题 / 翻页 / 字体 / 亮度 / 背景图）。
class NovelReaderSettings {
  const NovelReaderSettings({
    this.fontScale = 1,
    this.lineHeight = 1.75,
    this.theme = NovelReaderTheme.night,
    this.pageMode = NovelPageMode.slide,
    this.fontFamily = NovelFontFamily.system,
    this.brightness = 1,
    this.backgroundImage,
  });

  /// 设置结构版本：0.7.86 重做了分页，老数据要强制升级一次翻页方式。
  static const int layoutVersion = 2;

  /// 字号倍率（0.8 ~ 1.8）。
  final double fontScale;

  /// 行高倍率（1.4 ~ 2.4）。
  final double lineHeight;

  final NovelReaderTheme theme;

  final NovelPageMode pageMode;
  final NovelFontFamily fontFamily;

  /// 亮度 0.35 ~ 1：小于 1 时在正文上盖一层黑色遮罩（不申请系统亮度权限）。
  final double brightness;

  /// 自定义背景图（本地文件路径），为空时用主题底色。
  final String? backgroundImage;

  NovelReaderSettings copyWith({
    double? fontScale,
    double? lineHeight,
    NovelReaderTheme? theme,
    NovelPageMode? pageMode,
    NovelFontFamily? fontFamily,
    double? brightness,
    String? backgroundImage,
    bool clearBackgroundImage = false,
  }) => NovelReaderSettings(
    fontScale: fontScale ?? this.fontScale,
    lineHeight: lineHeight ?? this.lineHeight,
    theme: theme ?? this.theme,
    pageMode: pageMode ?? this.pageMode,
    fontFamily: fontFamily ?? this.fontFamily,
    brightness: brightness ?? this.brightness,
    backgroundImage: clearBackgroundImage
        ? null
        : (backgroundImage ?? this.backgroundImage),
  );

  factory NovelReaderSettings.fromJson(Map<String, dynamic> json) =>
      NovelReaderSettings(
        fontScale: (json['fontScale'] as num?)?.toDouble() ?? 1,
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.75,
        theme: NovelReaderTheme.values.firstWhere(
          (item) => item.name == json['theme'],
          orElse: () => NovelReaderTheme.night,
        ),
        pageMode: _readPageMode(json),
        fontFamily: NovelFontFamily.values.firstWhere(
          (item) => item.name == json['fontFamily'],
          orElse: () => NovelFontFamily.system,
        ),
        brightness: ((json['brightness'] as num?)?.toDouble() ?? 1).clamp(
          .35,
          1.0,
        ),
        backgroundImage: _readBackgroundImage(json['backgroundImage']),
      );

  /// 0.7.86：分页重做后，旧设置里的「上下滚动」统一升级成「左右翻页」一次。
  ///
  /// 老版本默认就是滚动，用户多半没主动选过——直接改默认值他又不会重新读，
  /// 所以这里做一次性迁移：没写过 `layoutVersion` 的数据一律按新默认走。
  /// 之后再手动切回滚动会带上版本号，不会被反复改回去。
  static NovelPageMode _readPageMode(Map<String, dynamic> json) {
    final version = (json['layoutVersion'] as num?)?.toInt() ?? 0;
    if (version < layoutVersion) return NovelPageMode.slide;
    return NovelPageMode.values.firstWhere(
      (item) => item.name == json['pageMode'],
      orElse: () => NovelPageMode.slide,
    );
  }

  static String? _readBackgroundImage(Object? raw) {
    if (raw is! String) return null;
    return raw.isEmpty ? null : raw;
  }

  Map<String, dynamic> toJson() => {
    'fontScale': fontScale,
    'lineHeight': lineHeight,
    'theme': theme.name,
    'pageMode': pageMode.name,
    'fontFamily': fontFamily.name,
    'brightness': brightness,
    'backgroundImage': backgroundImage,
    'layoutVersion': layoutVersion,
  };
}

/// 阅读配色主题。
enum NovelReaderTheme {
  night('夜间', 0xFF0E1118, 0xFF8B97A8, 0xFF151A24),
  ink('墨色', 0xFF1A1A1A, 0xFFC9CFD8, 0xFF101317),
  paper('羊皮纸', 0xFFF3E9D6, 0xFF3B3428, 0xFFE9DCC3),
  green('护眼绿', 0xFFE3EEDF, 0xFF2F3A2C, 0xFFD7E5D2);

  const NovelReaderTheme(this.label, this.background, this.text, this.surface);

  final String label;
  final int background;
  final int text;

  /// 控件面板底色。
  final int surface;
}

/// 小说书架 / 进度 / 分组 / 阅读设置的本地存储（shared_preferences）。
///
/// 不并入 LocalStore：小说的持久化维度（书架、进度、外观）与短剧的
/// 观看记录互不相干，独立一份更简单，也不会影响既有快照结构。
class NovelStore extends ChangeNotifier {
  NovelStore._();

  static final NovelStore instance = NovelStore._();

  static const _shelfKey = 'novel.shelf.v1';
  static const _settingsKey = 'novel.settings.v1';
  static const _groupsKey = 'novel.groups.v1';

  final List<NovelShelfEntry> _shelf = [];
  final List<NovelShelfGroup> _groups = [];
  NovelReaderSettings _settings = const NovelReaderSettings();
  bool _loaded = false;

  List<NovelShelfEntry> get shelf => List.unmodifiable(_shelf);
  List<NovelShelfGroup> get groups => List.unmodifiable(_groups);
  NovelReaderSettings get settings => _settings;
  bool get loaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final shelfRaw = prefs.getString(_shelfKey);
      if (shelfRaw != null && shelfRaw.isNotEmpty) {
        final rows = jsonDecode(shelfRaw);
        if (rows is List) {
          _shelf
            ..clear()
            ..addAll(
              rows
                  .whereType<Map>()
                  .map(
                    (row) =>
                        NovelShelfEntry.fromJson(Map<String, dynamic>.from(row)),
                  ),
            );
        }
      }
      final groupsRaw = prefs.getString(_groupsKey);
      if (groupsRaw != null && groupsRaw.isNotEmpty) {
        final rows = jsonDecode(groupsRaw);
        if (rows is List) {
          _groups
            ..clear()
            ..addAll(
              rows
                  .whereType<Map>()
                  .map(
                    (row) =>
                        NovelShelfGroup.fromJson(Map<String, dynamic>.from(row)),
                  )
                  .where((group) => group.id.isNotEmpty && group.name.isNotEmpty),
            );
        }
      }
      final settingsRaw = prefs.getString(_settingsKey);
      if (settingsRaw != null && settingsRaw.isNotEmpty) {
        final row = jsonDecode(settingsRaw);
        if (row is Map) {
          _settings = NovelReaderSettings.fromJson(
            Map<String, dynamic>.from(row),
          );
        }
      }
    } catch (error) {
      debugPrint('小说书架读取失败：$error');
    }
    _loaded = true;
    notifyListeners();
  }

  NovelShelfEntry? entryOf(String key) {
    for (final entry in _shelf) {
      if (entry.novel.key == key) return entry;
    }
    return null;
  }

  bool inShelf(String key) => entryOf(key) != null;

  /// 某个自定义分组下的书（保持书架顺序）。
  List<NovelShelfEntry> entriesInGroup(String groupId) => [
    for (final entry in _shelf)
      if (entry.groups.contains(groupId)) entry,
  ];

  Future<void> addToShelf(Novel novel, {List<String> groups = const []}) async {
    await ensureLoaded();
    final existing = entryOf(novel.key);
    if (existing != null) {
      // 已经在架上：更新书籍信息（可能有了新章节）并合并分组。
      final merged = {...existing.groups, ...groups}.toList();
      _replace(
        existing.novel.key,
        existing.copyWith(novel: novel, groups: merged),
      );
      notifyListeners();
      await _persistShelf();
      return;
    }
    _shelf.insert(
      0,
      NovelShelfEntry(novel: novel, groups: groups, knownChapters: novel.chapters),
    );
    notifyListeners();
    await _persistShelf();
  }

  Future<void> removeFromShelf(String key) async {
    await ensureLoaded();
    _shelf.removeWhere((entry) => entry.novel.key == key);
    notifyListeners();
    await _persistShelf();
  }

  /// 批量移除（书架多选删除）。
  Future<void> removeMany(Iterable<String> keys) async {
    await ensureLoaded();
    final targets = keys.toSet();
    if (targets.isEmpty) return;
    _shelf.removeWhere((entry) => targets.contains(entry.novel.key));
    notifyListeners();
    await _persistShelf();
  }

  /// 更新阅读进度（同时把书放进书架——读书本身就是收藏行为）。
  Future<void> saveProgress(Novel novel, NovelProgress progress) async {
    await ensureLoaded();
    final index = _shelf.indexWhere((entry) => entry.novel.key == novel.key);
    if (index < 0) {
      _shelf.insert(
        0,
        NovelShelfEntry(
          novel: novel,
          progress: progress,
          knownChapters: novel.chapters,
        ),
      );
    } else {
      _shelf[index] = _shelf[index].copyWith(progress: progress);
    }
    notifyListeners();
    await _persistShelf();
  }

  NovelProgress? progressOf(String key) => entryOf(key)?.progress;

  /// 记录"已经知道多少章"，用于书架的新章红点。
  ///
  /// [chapters] 是最新的总章数；[seen] 为 true 表示用户刚打开过详情页，
  /// 不算未读更新。
  Future<void> markChapters(String key, int chapters, {bool seen = false}) async {
    await ensureLoaded();
    final entry = entryOf(key);
    if (entry == null) return;
    final next = seen ? chapters : entry.knownChapters;
    if (next == entry.knownChapters && entry.novel.chapters == chapters) return;
    _replace(
      key,
      entry.copyWith(
        novel: entry.novel.copyWith(chapters: chapters),
        knownChapters: next,
      ),
    );
    notifyListeners();
    await _persistShelf();
  }

  /// 批量移动/设置某本书的分组。
  Future<void> setGroups(String key, List<String> groups) async {
    await ensureLoaded();
    final entry = entryOf(key);
    if (entry == null) return;
    _replace(key, entry.copyWith(groups: groups));
    notifyListeners();
    await _persistShelf();
  }

  Future<void> addToGroup(String key, String groupId) async {
    final entry = entryOf(key);
    if (entry == null || entry.groups.contains(groupId)) return;
    await setGroups(key, [...entry.groups, groupId]);
  }

  // ── 自定义分组 ──────────────────────────────────────────────────────────

  Future<NovelShelfGroup> createGroup(String name) async {
    await ensureLoaded();
    final trimmed = name.trim();
    final group = NovelShelfGroup(
      id: 'g${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: trimmed.isEmpty ? '未命名分组' : trimmed,
    );
    _groups.add(group);
    notifyListeners();
    await _persistGroups();
    return group;
  }

  Future<void> renameGroup(String id, String name) async {
    await ensureLoaded();
    final index = _groups.indexWhere((group) => group.id == id);
    if (index < 0) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _groups[index] = NovelShelfGroup(id: id, name: trimmed);
    notifyListeners();
    await _persistGroups();
  }

  /// 删除分组：组里的书回到「全部」，书本身不删。
  Future<void> removeGroup(String id) async {
    await ensureLoaded();
    _groups.removeWhere((group) => group.id == id);
    var changed = false;
    for (var i = 0; i < _shelf.length; i++) {
      if (!_shelf[i].groups.contains(id)) continue;
      _shelf[i] = _shelf[i].copyWith(
        groups: [
          for (final item in _shelf[i].groups)
            if (item != id) item,
        ],
      );
      changed = true;
    }
    notifyListeners();
    await _persistGroups();
    if (changed) await _persistShelf();
  }

  Future<void> saveSettings(NovelReaderSettings settings) async {
    _settings = settings;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    } catch (error) {
      debugPrint('阅读设置保存失败：$error');
    }
  }

  /// 仅测试用：清空内存态，模拟冷启动（磁盘数据保留）。
  @visibleForTesting
  void debugReset() {
    _shelf.clear();
    _groups.clear();
    _settings = const NovelReaderSettings();
    _loaded = false;
  }

  void _replace(String key, NovelShelfEntry next) {
    final index = _shelf.indexWhere((entry) => entry.novel.key == key);
    if (index >= 0) _shelf[index] = next;
  }

  Future<void> _persistShelf() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _shelfKey,
        jsonEncode([for (final entry in _shelf) entry.toJson()]),
      );
    } catch (error) {
      debugPrint('小说书架保存失败：$error');
    }
  }

  Future<void> _persistGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _groupsKey,
        jsonEncode([for (final group in _groups) group.toJson()]),
      );
    } catch (error) {
      debugPrint('小说分组保存失败：$error');
    }
  }
}
