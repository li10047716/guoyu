import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/booksource/book_source.dart';
import 'package:duanju_app/novel/booksource/book_source_screen.dart';
import 'package:duanju_app/novel/booksource/book_source_store.dart';
import 'package:duanju_app/novel/booksource/novel_gateway.dart';
import 'package:duanju_app/novel/novel_cover.dart';
import 'package:duanju_app/novel/novel_detail_screen.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_store.dart';

/// 小说模块内的二级分区（0.7.66；0.7.81 起去掉「探索」）。
///
/// 参考成熟阅读器的信息架构：书架 / 发现 / 我的。
/// 之前只有「书架 / 搜书」两个 Tab，搜书是并列入口；现在搜索收进
/// 右上角的放大镜（以及发现页的大搜索框），分区留给真正的内容聚合。
enum _NovelSection {
  shelf('书架', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  discover('发现', Icons.explore_outlined, Icons.explore_rounded),
  mine('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const _NovelSection(this.label, this.glyph, this.selectedGlyph);

  final String label;
  final IconData glyph;
  final IconData selectedGlyph;

  String get key => 'novel-section-$name';
}

/// 书架筛选范围：默认全部，或某个自定义分组。
///
/// 0.7.82（用户要求）：去掉「在读 / 未开始」两个内置筛选项，书架只按
/// 自定义分组筛选。
enum _ShelfScope { all, custom }

/// 小说界面（0.7.61 起；0.7.66 重排版式；0.7.67 加导入/批量/分组/红点）。
///
/// 版式参考桌面阅读器：左侧竖向二级导航 + 内容区大标题 + 右上工具胶囊
/// （分组 / 视图切换 / 搜索 / 更多）+ 大面积留白空态。
///
/// [embedded] 为 true（Windows 桌面）时不套 Scaffold：窗口标题栏已经显示
/// 模块名，页面内容直接铺开；否则自带一层 Scaffold。**没有返回按钮**
/// （0.7.64 用户要求）：看剧 / 小说 / 听歌是三个平级模块，切换只走页面
/// 底端那条按钮行。
class NovelHomeScreen extends StatefulWidget {
  const NovelHomeScreen({
    super.key,
    required this.repository,
    this.embedded = false,
    this.headerActions = const [],
    this.gateway,
  });

  final AppRepository repository;
  final bool embedded;

  /// 测试注入用；生产环境留空，自己建一个。
  final NovelGateway? gateway;

  /// 页头右侧的额外操作（0.7.74）：手机端模块切换条挪进顶栏后，
  /// 小说页在窄屏布局里把这几个控件拼在顶部标签行尾，
  /// 保证在小说里也能直接切去看剧 / 听歌。
  final List<Widget> headerActions;

  @override
  State<NovelHomeScreen> createState() => _NovelHomeScreenState();
}

class _NovelHomeScreenState extends State<NovelHomeScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  /// 数据入口：内置站源走核心，自定义书源走本地规则引擎（0.7.68）。
  late final NovelGateway _gateway = widget.gateway ?? NovelGateway();

  List<Novel> _results = const [];
  bool _searching = false;
  String? _error;
  bool _searched = false;

  _NovelSection _section = _NovelSection.shelf;
  _ShelfScope _scope = _ShelfScope.all;

  /// 当前选中的自定义分组（scope == custom 时有效）。
  String? _customGroupId;

  /// 书架多选：进入后卡片变成可勾选，顶栏换成批量操作条。
  bool _selectionMode = false;
  final Set<String> _selected = {};

  /// 本地书导入进行中（避免重复触发，也给个可见反馈）。
  bool _importing = false;

  /// 书架视图：false = 封面网格，true = 单行列表。
  bool _listView = false;

  /// 搜索以覆盖层方式占满内容区（不是独立页面，切分区时自动关掉）。
  bool _searchOpen = false;

  /// 搜索用的书源选择：自定义源选哪几个（null = 全部启用的源）。
  /// 0.7.85：内置源已移除，这里只剩自定义源。
  Set<String>? _searchCustomKeys;

  /// 上次搜索实际用到的源数量，结果区下面用来提示。
  int _searchSourceCount = 0;

  static const _hotKeywords = ['玄幻', '都市', '穿越', '重生', '系统', '剑来', '诡秘'];

  /// 宽屏阈值：够宽就竖排导航，窄了退回顶部横排。
  static const _wideBreakpoint = 840.0;

  @override
  void initState() {
    super.initState();
    NovelStore.instance.ensureLoaded();
    unawaited(_loadSearchSources());
  }

  /// 搜索源选择的偏好键（记住上次选了哪些源）。
  static const _searchPrefsKey = 'novel.searchSources.v1';

  Future<void> _loadSearchSources() async {
    await BookSourceStore.instance.ensureLoaded();
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_searchPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      if (!mounted) return;
      setState(() {
        final custom = data['custom'];
        // `*` 表示「全部启用的自定义源」，不记具体 key，新增源自动纳入。
        _searchCustomKeys = custom == '*'
            ? null
            : custom is List
            ? {for (final item in custom) '$item'}
            : null;
      });
    } catch (_) {
      // 偏好坏了就当全选，不影响搜索。
    }
  }

  Future<void> _saveSearchSources() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _searchPrefsKey,
        jsonEncode({
          'custom': _searchCustomKeys == null
              ? '*'
              : _searchCustomKeys!.toList(),
        }),
      );
    } catch (_) {
      // 存不下只是下次要重选，不影响本次搜索。
    }
  }

  /// 实际生效的自定义源 key（null = 全部可用源）。
  Set<String>? _effectiveCustomKeys() {
    if (_searchCustomKeys == null) return null;
    final available = {
      for (final source in BookSourceStore.instance.usableSources) source.key,
    };
    return _searchCustomKeys!.where(available.contains).toSet();
  }

  void _toggleSearchSource(String key) {
    final available = [
      for (final source in BookSourceStore.instance.usableSources) source.key,
    ];
    final current = _searchCustomKeys ?? available.toSet();
    final next = {...current};
    if (!next.remove(key)) next.add(key);
    setState(() {
      // 全选也存成 null，这样以后新加的源默认参与。
      _searchCustomKeys = next.length == available.length ? null : next;
    });
    unawaited(_saveSearchSources());
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _closeSearch() {
    _focus.unfocus();
    setState(() => _searchOpen = false);
  }

  Future<void> _runSearch(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;
    await BookSourceStore.instance.ensureLoaded();
    if (!mounted) return;
    final customKeys = _effectiveCustomKeys();
    final customCount = customKeys == null
        ? BookSourceStore.instance.usableSources.length
        : customKeys.length;
    if (customCount == 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('还没有可用的书源，先在「我的 → 书源」里导入'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _search.text = query;
    _focus.unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _searched = true;
    });
    try {
      final items = await _gateway.search(query, customKeys: customKeys);
      if (!mounted) return;
      setState(() {
        _results = items;
        _searching = false;
        _searchSourceCount = _gateway.lastSources.length;
      });
      if (_gateway.lastFailures.isNotEmpty) {
        final names = _gateway.lastFailures
            .take(3)
            .map((f) => f.sourceName)
            .join('、');
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('$names 没有返回结果'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error'.replaceFirst('AppFailure: ', '');
        _searching = false;
      });
    }
  }

  Future<void> _openNovel(Novel novel) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            NovelDetailScreen(novel: novel, repository: widget.repository),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 搜索结果副标题里显示书源名（自定义源才显示）。
  String _sourceLabel(Novel novel) {
    if (!novel.source.startsWith('bs:')) return '';
    final key = novel.source.substring(3);
    return BookSourceStore.instance.byKey(key)?.name ?? '自定义源';
  }

  Future<void> _openBookSources() async {
    await BookSourceStore.instance.ensureLoaded();
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const BookSourceScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final body = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _rail(context),
              Expanded(child: _stage(context, wide: true)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: _topTabs(context)),
                  // 0.7.74：模块切换（看剧 / 小说 / 听歌）挂在标签行尾。
                  if (widget.headerActions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: widget.headerActions,
                      ),
                    ),
                ],
              ),
              Expanded(child: _stage(context, wide: false)),
            ],
          );
    final content = SafeArea(bottom: false, child: body);
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: content,
    );
  }

  // ── 二级导航 ────────────────────────────────────────────────────────────

  Widget _rail(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 76,
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: colors.outlineVariant.withValues(alpha: .55),
          ),
        ),
      ),
      child: Column(
        children: [
          for (final section in _NovelSection.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _railItem(context, section),
            ),
        ],
      ),
    );
  }

  Widget _railItem(BuildContext context, _NovelSection section) {
    final colors = Theme.of(context).colorScheme;
    final selected = !_searchOpen && _section == section;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Material(
      // 底色交给 Material 自己，InkWell 的涟漪才不会被上层容器盖住。
      color: selected
          ? colors.secondaryContainer.withValues(alpha: .62)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey(section.key),
        onTap: () => setState(() {
          _section = section;
          _searchOpen = false;
        }),
        child: SizedBox(
          width: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? section.selectedGlyph : section.glyph,
                  size: 21,
                  color: foreground,
                ),
                const SizedBox(height: 4),
                Text(
                  section.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 窄屏的二级导航：一排可横滑的胶囊。
  Widget _topTabs(BuildContext context) {
    return SizedBox(
      height: 50,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        children: [
          for (final section in _NovelSection.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _tabChip(context, section),
            ),
        ],
      ),
    );
  }

  Widget _tabChip(BuildContext context, _NovelSection section) {
    final colors = Theme.of(context).colorScheme;
    final selected = !_searchOpen && _section == section;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return Material(
      color: selected
          ? colors.secondaryContainer.withValues(alpha: .62)
          : colors.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('${section.key}-chip'),
        onTap: () => setState(() {
          _section = section;
          _searchOpen = false;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? section.selectedGlyph : section.glyph,
                size: 15,
                color: foreground,
              ),
              const SizedBox(width: 5),
              Text(
                section.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 内容区骨架 ──────────────────────────────────────────────────────────

  Widget _stage(BuildContext context, {required bool wide}) {
    return Center(
      child: ConstrainedBox(
        // 超宽窗口下内容限宽，避免页头和书架被拉成一条过长的大横条。
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, wide: wide),
            Expanded(
              child: _searchOpen ? _searchPane(context) : _sectionBody(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, {required bool wide}) {
    if (_selectionMode) return _selectionHeader(context);
    final colors = Theme.of(context).colorScheme;
    // 窄屏时分区名已经在顶部胶囊上，页头只留工具条，省一行高度。
    final showTitle = wide || _searchOpen;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        wide ? 26 : 14,
        wide ? 18 : 4,
        wide ? 26 : 12,
        6,
      ),
      child: SizedBox(
        height: wide ? 46 : 40,
        child: Row(
          children: [
            if (_searchOpen)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: IconButton(
                  key: const ValueKey('novel-search-close'),
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeSearch,
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
              ),
            if (showTitle)
              // 0.7.81 修复：这里以前是 `Flexible`（默认 flex:1），会和后面的
              // `Spacer` 平分剩余空间；标题文字用不完那份额度，空间就地丢失，
              // 工具条永远推不到最右（所有平台都中招）。改为不参与 flex 的
              // 普通文本——分区名只有两三个字，不存在溢出问题。
              Text(
                _searchOpen ? '搜索' : _section.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: wide ? 26 : 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.4,
                  color: colors.onSurface,
                ),
              ),
            const Spacer(),
            if (!_searchOpen) _toolbar(context),
          ],
        ),
      ),
    );
  }

  /// 右上工具区（0.7.82，用户要求）：视图切换 / 搜索 / 更多 各自一枚
  /// **独立圆形按钮**，不再挤在一个长胶囊里。
  Widget _toolbar(BuildContext context) {
    final onShelf = _section == _NovelSection.shelf;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 视图切换只对书架有意义。
        if (onShelf) ...[
          _roundTool(
            context,
            key: const ValueKey('novel-view-toggle'),
            icon: _listView
                ? Icons.view_module_rounded
                : Icons.view_list_rounded,
            tooltip: _listView ? '切换为网格' : '切换为列表',
            onTap: () => setState(() => _listView = !_listView),
          ),
          const SizedBox(width: 8),
        ],
        _roundTool(
          context,
          key: const ValueKey('novel-search-open'),
          icon: Icons.search_rounded,
          tooltip: '搜索',
          onTap: _openSearch,
        ),
        const SizedBox(width: 8),
        Container(
          height: 36,
          width: 36,
          decoration: _roundDecoration(context),
          child: _moreMenu(context),
        ),
      ],
    );
  }

  BoxDecoration _roundDecoration(BuildContext context) => BoxDecoration(
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: .5),
    shape: BoxShape.circle,
  );

  Widget _roundTool(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      width: 36,
      decoration: _roundDecoration(context),
      child: IconButton(
        key: key,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: colors.onSurfaceVariant),
      ),
    );
  }

  Widget _moreMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onShelf = _section == _NovelSection.shelf;
    final groups = NovelStore.instance.groups;
    return PopupMenuButton<String>(
      key: const ValueKey('novel-more'),
      tooltip: '更多',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: colors.onSurfaceVariant,
      ),
      onSelected: (value) {
        switch (value) {
          case 'import':
            unawaited(_importLocalBooks());
          case 'batch':
            _enterSelection();
          case 'manage-groups':
            unawaited(_manageGroups());
          default:
            _onScopeSelected(value);
        }
      },
      itemBuilder: (context) => [
        // 书架筛选（0.7.82 用户要求）：只留自定义分组，「全部 / 在读 /
        // 未开始」三个内置项已删除；没建过分组时整块都不出现。
        if (onShelf && groups.isNotEmpty) ...[
          for (final group in groups)
            PopupMenuItem(
              value: 'group:${group.id}',
              child: Row(
                children: [
                  SizedBox(
                    width: 26,
                    child: _scope == _ShelfScope.custom &&
                            _customGroupId == group.id
                        ? Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: colors.primary,
                          )
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      group.name,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: 'import',
          child: Row(
            children: [
              Icon(Icons.file_open_outlined, size: 16),
              SizedBox(width: 8),
              Text('导入本地书籍…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'batch',
          child: Row(
            children: [
              Icon(Icons.checklist_rounded, size: 16),
              SizedBox(width: 8),
              Text('批量管理', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'manage-groups',
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 16),
              SizedBox(width: 8),
              Text('管理分组…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: '书架排序',
          child: Row(
            children: [
              Icon(Icons.sort_rounded, size: 16),
              SizedBox(width: 8),
              Text('书架排序', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  // ── 书架筛选 / 多选 / 导入 ──────────────────────────────────────────────

  void _onScopeSelected(String value) {
    setState(() {
      if (value.startsWith('group:')) {
        _scope = _ShelfScope.custom;
        _customGroupId = value.substring('group:'.length);
        return;
      }
      _customGroupId = null;
      _scope = _ShelfScope.all;
    });
  }

  void _enterSelection([String? key]) {
    setState(() {
      _selectionMode = true;
      _selected.clear();
      if (key != null) _selected.add(key);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelect(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _toggleSelectAll(List<NovelShelfEntry> visible) {
    final keys = [for (final entry in visible) entry.novel.key];
    setState(() {
      if (_selected.length == keys.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(keys);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从书架移除'),
        content: Text(
          '确定移除选中的 ${_selected.length} 本书？阅读进度会一起清掉，本地导入的书会删除磁盘文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final targets = [..._selected];
    // 本地书连磁盘文件一起删，否则会留下一堆读不到的占位。
    try {
      final dir = await NovelLibrary.resolve();
      for (final key in targets) {
        final entry = NovelStore.instance.entryOf(key);
        if (entry == null || !entry.novel.isLocal) continue;
        await widget.repository.removeLocalNovel(dir, entry.novel.id);
      }
    } catch (_) {
      // 文件删不掉不影响从书架移除。
    }
    await NovelStore.instance.removeMany(targets);
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _manageGroups() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _GroupManagerDialog(),
    );
    if (!mounted) return;
    // 分组可能被删了，当前筛选要退回「全部」。
    if (_scope == _ShelfScope.custom &&
        !NovelStore.instance.groups.any((g) => g.id == _customGroupId)) {
      setState(() {
        _scope = _ShelfScope.all;
        _customGroupId = null;
      });
    }
  }

  Future<void> _importLocalBooks() async {
    if (_importing) return;
    var files = const <PlatformFile>[];
    try {
      // file_picker 13 起是静态方法，pickFiles 本身就是多选。
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'epub'],
        dialogTitle: '选择要导入的书籍',
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('打开文件选择器失败：$error')));
      return;
    }
    if (files.isEmpty || !mounted) return;

    setState(() => _importing = true);
    final dir = await NovelLibrary.resolve();
    var imported = 0;
    final failures = <String>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      try {
        final book = await widget.repository.importLocalNovel(dir, path);
        await NovelStore.instance.addToShelf(book.novel);
        imported++;
      } catch (error) {
        failures.add(
          '${file.name}：${'$error'.replaceFirst('AppFailure: ', '')}',
        );
      }
    }
    if (!mounted) return;
    setState(() => _importing = false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? '导入完成，共 $imported 本'
              : '导入 $imported 本，失败 ${failures.length} 本：${failures.first}',
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 多选模式的顶栏：退出 / 已选计数 / 全选 / 删除。
  Widget _selectionHeader(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visible = _visibleShelfEntries();
    final allSelected =
        visible.isNotEmpty && _selected.length == visible.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('novel-selection-close'),
              visualDensity: VisualDensity.compact,
              onPressed: _exitSelection,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
            Text(
              '已选 ${_selected.length} 项',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton(
              key: const ValueKey('novel-selection-all'),
              onPressed: () => _toggleSelectAll(visible),
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
            IconButton(
              key: const ValueKey('novel-selection-delete'),
              tooltip: '从书架移除',
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: Icon(
                Icons.delete_outline_rounded,
                color: _selected.isEmpty
                    ? colors.onSurfaceVariant.withValues(alpha: .4)
                    : colors.error,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<NovelShelfEntry> _visibleShelfEntries() {
    final entries = NovelStore.instance.shelf;
    return switch (_scope) {
      _ShelfScope.all => entries,
      _ShelfScope.custom => [
        for (final entry in entries)
          if (_customGroupId != null && entry.groups.contains(_customGroupId))
            entry,
      ],
    };
  }

  // ── 分区内容 ────────────────────────────────────────────────────────────

  Widget _sectionBody(BuildContext context) {
    switch (_section) {
      case _NovelSection.shelf:
        return _ShelfTab(
          scope: _scope,
          customGroupId: _customGroupId,
          listView: _listView,
          selectionMode: _selectionMode,
          selected: _selected,
          onOpen: _openNovel,
          onFind: _openSearch,
          onLongPress: _enterSelection,
          onToggle: _toggleSelect,
        );
      case _NovelSection.discover:
        return _DiscoverPage(
          gateway: _gateway,
          onOpenSearch: _openSearch,
          onOpenNovel: _openNovel,
        );
      case _NovelSection.mine:
        return const _MinePage();
    }
  }

  Widget _searchPane(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: TextField(
            key: const ValueKey('novel-search-field'),
            controller: _search,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onSubmitted: _runSearch,
            decoration: InputDecoration(
              hintText: '搜书名或作者',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              filled: true,
              fillColor: colors.surfaceContainerHighest.withValues(alpha: .5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                tooltip: '搜索',
                onPressed: () => _runSearch(_search.text),
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
            ),
          ),
        ),
        _searchSourceBar(colors),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final keyword in _hotKeywords)
                ActionChip(
                  label: Text(keyword, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _runSearch(keyword),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        Expanded(child: _searchBody(colors)),
      ],
    );
  }

  /// 搜索框下面那行「搜索哪些源」：内置 + 每个可用自定义源，点一下切换。
  Widget _searchSourceBar(ColorScheme colors) {
    final store = BookSourceStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final custom = store.usableSources;
        final chosen = _searchCustomKeys;
        return SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            children: [
              for (final source in custom) ...[
                const SizedBox(width: 8),
                FilterChip(
                  key: ValueKey('novel-search-source-${source.key}'),
                  label: Text(
                    source.name,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: chosen == null || chosen.contains(source.key),
                  onSelected: (_) => _toggleSearchSource(source.key),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
              if (custom.isEmpty) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => unawaited(_openBookSources()),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加书源', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colors.primary,
                  ),
                ),
              ] else ...[
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('novel-search-source-manage'),
                  tooltip: '管理书源',
                  onPressed: () => unawaited(_openBookSources()),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
              // 有源因为规则问题跑不了时给个明示，否则用户会以为「只搜了内置」。
              if (store.enabledSources.length > custom.length) ...[
                const SizedBox(width: 4),
                TextButton(
                  key: const ValueKey('novel-search-source-unusable'),
                  onPressed: () => unawaited(_openBookSources()),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colors.onSurfaceVariant,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: Text(
                    '${store.enabledSources.length - custom.length} 个源不可用',
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 空态里那句「当前搜索范围」。
  String _sourceSummary() {
    final custom = BookSourceStore.instance.usableSources;
    final picked = _searchCustomKeys == null
        ? custom.length
        : (_effectiveCustomKeys()?.length ?? 0);
    if (picked == 0) return '还没有可用的书源，先到「我的 → 书源」导入';
    return '当前搜索范围：$picked 个自定义源';
  }

  Widget _searchBody(ColorScheme colors) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () => _runSearch(_search.text),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!_searched) {
      return _EmptyState(
        icon: Icons.search_rounded,
        title: '输入书名或作者开始找书',
        hint: _sourceSummary(),
      );
    }
    if (_results.isEmpty) {
      return _EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到这本书',
        hint: _searchSourceCount > 0
            ? '已在 $_searchSourceCount 个书源里搜过：换个关键词，或者在上面多勾几个源'
            : '换个关键词试试，或者直接搜作者名',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final novel = _results[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: 8,
          // 0.7.88：搜索结果也给封面，跟书架/发现一致；拿不到就落回书本图标。
          leading: NovelCover(url: novel.cover, width: 44, height: 60),
          title: Text(
            novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              novel.author.isEmpty ? '佚名' : novel.author,
              novel.category,
              _sourceLabel(novel),
            ].where((item) => item.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _openNovel(novel),
        );
      },
    );
  }
}

// ── 书架 ──────────────────────────────────────────────────────────────────

class _ShelfTab extends StatelessWidget {
  const _ShelfTab({
    required this.scope,
    required this.customGroupId,
    required this.listView,
    required this.selectionMode,
    required this.selected,
    required this.onOpen,
    required this.onFind,
    required this.onLongPress,
    required this.onToggle,
  });

  final _ShelfScope scope;
  final String? customGroupId;
  final bool listView;
  final bool selectionMode;
  final Set<String> selected;
  final ValueChanged<Novel> onOpen;
  final VoidCallback onFind;
  final ValueChanged<String> onLongPress;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NovelStore.instance,
      builder: (context, _) {
        final store = NovelStore.instance;
        if (!store.loaded) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = store.shelf;
        if (entries.isEmpty) {
          return _EmptyState(
            icon: Icons.bookmark_border_rounded,
            title: '书架还是空的',
            hint: '点右上角的搜索，或从「⋮」导入本地 txt / epub :)',
            action: TextButton(onPressed: onFind, child: const Text('去找一本')),
          );
        }
        final visible = switch (scope) {
          _ShelfScope.all => entries,
          _ShelfScope.custom => [
            for (final entry in entries)
              if (customGroupId != null && entry.groups.contains(customGroupId))
                entry,
          ],
        };
        if (visible.isEmpty) {
          return const _EmptyState(
            icon: Icons.filter_alt_off_rounded,
            title: '这个分组还没有书',
            hint: '「⋮」里切回「全部」看看',
          );
        }
        void tap(NovelShelfEntry entry) {
          // 多选态下点卡片 = 勾选，而不是打开。
          if (selectionMode) {
            onToggle(entry.novel.key);
          } else {
            onOpen(entry.novel);
          }
        }

        if (listView) {
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final entry = visible[index];
              return _ShelfRow(
                entry: entry,
                selectionMode: selectionMode,
                selected: selected.contains(entry.novel.key),
                onTap: () => tap(entry),
                onLongPress: () => onLongPress(entry.novel.key),
              );
            },
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 150,
            mainAxisSpacing: 18,
            crossAxisSpacing: 14,
            childAspectRatio: .56,
          ),
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final entry = visible[index];
            return _ShelfCard(
              entry: entry,
              selectionMode: selectionMode,
              selected: selected.contains(entry.novel.key),
              onTap: () => tap(entry),
              onLongPress: () => onLongPress(entry.novel.key),
            );
          },
        );
      },
    );
  }
}

class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
  });

  final NovelShelfEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final novel = entry.novel;
    final progress = entry.progress;
    return GestureDetector(
      onLongPress: onLongPress,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NovelCover(url: novel.cover, radius: 10),
                  if (selected)
                    Container(
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: colors.primary, width: 2),
                      ),
                    ),
                  if (selectionMode)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _selectBadge(colors, selected),
                    )
                  // 有新章：封面左上角一个小红点，不抢文字信息。
                  else if (entry.hasUpdates)
                    Positioned(
                      top: 7,
                      left: 7,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors.error,
                          shape: BoxShape.circle,
                          border: Border.all(color: colors.surface, width: 1.5),
                        ),
                      ),
                    ),
                  if (novel.isLocal)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '本地',
                          style: TextStyle(fontSize: 9, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              novel.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              entry.hasUpdates
                  ? '更新至第 ${novel.chapters} 章'
                  : progress == null
                  ? '未开始'
                  : '读到第 ${progress.chapterIndex + 1} 章',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: entry.hasUpdates
                    ? colors.error
                    : colors.onSurfaceVariant.withValues(alpha: .85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _selectBadge(ColorScheme colors, bool selected) => Container(
  width: 20,
  height: 20,
  decoration: BoxDecoration(
    color: selected ? colors.primary : Colors.black.withValues(alpha: .35),
    shape: BoxShape.circle,
    border: Border.all(color: Colors.white.withValues(alpha: .9), width: 1.5),
  ),
  child: selected
      ? Icon(Icons.check_rounded, size: 13, color: colors.onPrimary)
      : null,
);

/// 书架列表视图的一行。
class _ShelfRow extends StatelessWidget {
  const _ShelfRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
  });

  final NovelShelfEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final novel = entry.novel;
    final progress = entry.progress;
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: .12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            children: [
              NovelCover(url: novel.cover, width: 46, height: 62),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        novel.author.isEmpty ? '佚名' : novel.author,
                        novel.category,
                      ].where((item) => item.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colors.onSurfaceVariant.withValues(alpha: .9),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.hasUpdates
                          ? '更新至第 ${novel.chapters} 章'
                          : progress == null
                          ? '未开始'
                          : '读到第 ${progress.chapterIndex + 1} 章',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: entry.hasUpdates
                            ? colors.error
                            : progress == null
                            ? colors.onSurfaceVariant.withValues(alpha: .7)
                            : colors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (selectionMode)
                _selectBadge(colors, selected)
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: colors.onSurfaceVariant.withValues(alpha: .6),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 发现 / 探索 / 我的 ────────────────────────────────────────────────────

/// 发现：搜索入口 + 真实分类浏览 + 该分类的收藏排行。
///
/// 0.7.67 起分类走站点的 `/sort/<id>_<page>/`，每类上千页真实书目，
/// 不再是"拿关键词冒充分类"；侧栏的「收藏排行」也接上了。
///
/// 0.7.73 起顶部可以切到自定义书源（走它的 `exploreUrl` / `ruleExplore`），
/// 内置源和自定义源的发现页各走一套数据。
class _DiscoverPage extends StatefulWidget {
  const _DiscoverPage({
    required this.gateway,
    required this.onOpenSearch,
    required this.onOpenNovel,
  });

  final NovelGateway gateway;
  final VoidCallback onOpenSearch;
  final ValueChanged<Novel> onOpenNovel;

  @override
  State<_DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<_DiscoverPage> {
  final _scroll = ScrollController();

  /// 上次选的发现源（自定义书源的 key）。持久化，下次进来还是它。
  static const String _sourcePrefKey = 'novel.discoverSource.v1';

  // ── 自定义书源的发现 ────────────────────────────────────────────────
  List<BookSource> _sources = const [];
  bool _sourcesLoaded = false;
  String _sourceKey = '';
  List<BookSourceExploreEntry> _entries = const [];
  String _entryUrl = '';
  String _entryName = '';
  List<Novel> _customBooks = const [];
  int _customPage = 1;
  bool _customHasMore = false;
  bool _customLoading = false;
  bool _customLoadingMore = false;
  String? _customError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 420) {
      unawaited(_loadCustomMore());
    }
  }

  BookSource? get _currentSource {
    for (final source in _sources) {
      if (source.key == _sourceKey) return source;
    }
    return null;
  }

  Future<void> _bootstrap() => _loadSources();

  Future<void> _loadSources() async {
    try {
      final sources = await widget.gateway.exploreSources();
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_sourcePrefKey) ?? '';
      setState(() {
        _sources = sources;
        _sourcesLoaded = true;
      });
      if (sources.isEmpty) return;
      // 记着的源还在就用它，否则（首次进入 / 源被删）落到第一个可用源。
      final target = sources.any((s) => s.key == saved)
          ? saved
          : sources.first.key;
      await _selectSource(target);
    } catch (error) {
      if (mounted) setState(() => _sourcesLoaded = true);
      debugPrint('发现页书源列表加载失败：$error');
    }
  }

  /// 切发现源（自定义书源的 key）。
  Future<void> _selectSource(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sourcePrefKey, key);
    if (!mounted) return;
    final source = _sources.firstWhere(
      (s) => s.key == key,
      orElse: () => const BookSource(key: '', name: '', url: ''),
    );
    // 0.7.83：`exploreUrl` 是脚本的源要异步求值才有分类。
    final entries = source.key.isEmpty
        ? const <BookSourceExploreEntry>[]
        : await widget.gateway.exploreEntries(source);
    if (!mounted) return;
    final first = entries.isEmpty
        ? null
        : entries.firstWhere((e) => !e.isHeader, orElse: () => entries.first);
    setState(() {
      _sourceKey = key;
      _entries = entries;
      _entryUrl = '';
      _entryName = '';
      _customBooks = const [];
      _customPage = 1;
      _customHasMore = false;
      _customError = null;
    });
    if (first != null && !first.isHeader) {
      await _loadEntry(first.url, first.name);
    }
  }

  /// 加载（或翻页）某个发现条目。
  Future<void> _loadEntry(String url, String name, {bool more = false}) async {
    if (_sourceKey.isEmpty || url.isEmpty) return;
    setState(() {
      _entryUrl = url;
      _entryName = name;
      if (more) {
        _customLoadingMore = true;
      } else {
        _customLoading = true;
        _customBooks = const [];
        _customPage = 1;
        _customHasMore = false;
        _customError = null;
      }
    });
    final page = more ? _customPage + 1 : 1;
    try {
      final items = await widget.gateway.explore(_sourceKey, url, page: page);
      if (!mounted || _entryUrl != url) return;
      setState(() {
        // 0.7.82：有些源的发现地址里没有 `{{page}}`（页码写死在 URL 里），
        // 翻页会拿回同一批书。这里按 key 去重，并在一页没有新书时判定到底，
        // 避免「加载更多」无限重复同一批内容。
        final merged = more ? [..._customBooks, ...items] : items;
        final seen = <String>{};
        final deduped = <Novel>[
          for (final novel in merged)
            if (seen.add(novel.key)) novel,
        ];
        final added = deduped.length - (more ? _customBooks.length : 0);
        _customBooks = deduped;
        _customPage = page;
        // 返回空页或者不足一页时就没有下一页了，避免无限翻。
        _customHasMore = items.length >= 10 && added > 0;
        _customLoading = false;
        _customLoadingMore = false;
      });
    } catch (error) {
      if (!mounted || _entryUrl != url) return;
      setState(() {
        _customLoading = false;
        _customLoadingMore = false;
        if (!more) {
          _customError = '$error'
              .replaceFirst('FetchFailure: ', '')
              .replaceFirst('AppFailure: ', '');
        }
      });
    }
  }

  Future<void> _loadCustomMore() async {
    if (!_customHasMore || _customLoading || _customLoadingMore) return;
    if (_entryUrl.isEmpty) return;
    await _loadEntry(_entryUrl, _entryName, more: true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _searchBox(colors),
        if (_sources.length > 1) _sourceBar(colors),
        ..._body(colors),
      ],
    );
  }

  List<Widget> _body(ColorScheme colors) {
    if (!_sourcesLoaded) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_sources.isEmpty) {
      return [
        const _SectionTitle('发现'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 12),
          child: Column(
            children: [
              Icon(
                Icons.travel_explore_rounded,
                size: 34,
                color: colors.onSurfaceVariant.withValues(alpha: .45),
              ),
              const SizedBox(height: 12),
              const Text(
                '还没有带「发现」入口的书源',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                '在「我的 → 书源」导入书源后，这里会列出它自己的分类和书单；'
                '也可以直接用上面的搜索找书。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ];
    }
    return _customSections(colors);
  }

  Widget _searchBox(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('discover-search-box'),
        onTap: widget.onOpenSearch,
        child: SizedBox(
          height: 46,
          child: Row(
            children: [
              const SizedBox(width: 14),
              Icon(
                Icons.search_rounded,
                size: 19,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Text(
                '搜书名、作者或分类',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.onSurfaceVariant.withValues(alpha: .85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部发现源切换：每个带发现入口的自定义书源。
  Widget _sourceBar(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        height: 32,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final source in _sources)
              _sourceChip(source.key, source.name, colors),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(String key, String label, ColorScheme colors) {
    final selected = _sourceKey == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .16)
            : colors.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('discover-source-$key'),
          onTap: () => unawaited(_selectSource(key)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 自定义书源：它自己的发现分类 + 书单 ──────────────────────────────
  List<Widget> _customSections(ColorScheme colors) {
    final source = _currentSource;
    final out = <Widget>[
      _SectionTitle(source == null ? '发现' : '${source.name} · 发现'),
    ];

    if (_entries.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Text(
            '这个书源没有配置发现分类，用搜索找书吧',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      );
      return out;
    }

    // 分组标题 + 该组的条目按钮
    var chips = <Widget>[];
    void flushChips() {
      if (chips.isEmpty) return;
      out.add(Wrap(spacing: 8, runSpacing: 8, children: List.of(chips)));
      chips = <Widget>[];
    }

    for (final entry in _entries) {
      if (entry.isHeader) {
        flushChips();
        out.add(_SectionTitle(entry.name));
        continue;
      }
      chips.add(_entryChip(entry, colors));
    }
    flushChips();

    if (_customLoading) {
      out.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (_customError != null) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              Text(
                _customError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => unawaited(_loadEntry(_entryUrl, _entryName)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    } else if (_customBooks.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Text(
            '这个分类暂时没有书，换个分类试试',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      );
    } else {
      if (_entryName.isNotEmpty) out.add(_SectionTitle(_entryName));
      out.add(
        _bookGrid(_customBooks, colors, keyPrefix: 'discover-custom-book'),
      );
      if (_customLoadingMore) {
        out.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        );
      } else if (!_customHasMore) {
        out.add(_endNote('没有更多了', colors));
      }
    }
    return out;
  }

  Widget _entryChip(BookSourceExploreEntry entry, ColorScheme colors) {
    final selected = _entryUrl == entry.url;
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: .16)
          : colors.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('discover-entry-${entry.url}'),
        onTap: () => unawaited(_loadEntry(entry.url, entry.name)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          child: Text(
            entry.name,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bookGrid(
    List<Novel> books,
    ColorScheme colors, {
    required String keyPrefix,
  }) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: .52,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final novel = books[index];
        return InkWell(
          key: ValueKey('$keyPrefix-$index'),
          onTap: () => widget.onOpenNovel(novel),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: NovelCover(
                  url: novel.cover,
                  width: double.infinity,
                  radius: 10,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                novel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _endNote(String text, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: colors.onSurfaceVariant.withValues(alpha: .7),
          ),
        ),
      ),
    );
  }
}

/// 我的：书源信息 + 阅读偏好概览。
class _MinePage extends StatelessWidget {
  const _MinePage();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: NovelStore.instance,
      builder: (context, _) {
        final store = NovelStore.instance;
        final shelf = store.shelf;
        final reading = shelf.where((entry) => entry.progress != null).length;
        final settings = store.settings;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Row(
              children: [
                _statCard(context, '${shelf.length}', '书架藏书'),
                const SizedBox(width: 10),
                _statCard(context, '$reading', '正在读'),
              ],
            ),
            const _SectionTitle('书源'),
            Material(
              key: const ValueKey('novel-mine-book-sources'),
              color: colors.surfaceContainerHighest.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () async {
                  await BookSourceStore.instance.ensureLoaded();
                  if (!context.mounted) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BookSourceScreen()),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.tune_rounded,
                          size: 19,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '书源管理',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            AnimatedBuilder(
                              animation: BookSourceStore.instance,
                              builder: (context, _) {
                                final store = BookSourceStore.instance;
                                final usable = store.usableSources.length;
                                return Text(
                                  store.sources.isEmpty
                                      ? '导入「阅读 / Legado」格式书源'
                                      : '已导入 ${store.sources.length} 个 · 可用 $usable 个',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: colors.onSurfaceVariant.withValues(
                                      alpha: .85,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const _SectionTitle('阅读偏好'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .42),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _prefItem(
                    context,
                    '字号',
                    '${(settings.fontScale * 17).round()}',
                  ),
                  _prefItem(
                    context,
                    '行距',
                    settings.lineHeight.toStringAsFixed(2),
                  ),
                  _prefItem(context, '配色', settings.theme.label),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '阅读器里可以随时改这些，改完自动记住。',
              style: TextStyle(
                fontSize: 11.5,
                color: colors.onSurfaceVariant.withValues(alpha: .8),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _statCard(BuildContext context, String value, String label) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: .42),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: colors.onSurfaceVariant.withValues(alpha: .85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _prefItem(BuildContext context, String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: colors.onSurfaceVariant.withValues(alpha: .85),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 通用小件 ──────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 22, 2, 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 62,
              color: colors.onSurfaceVariant.withValues(alpha: .22),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.onSurfaceVariant.withValues(alpha: .8),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 10), action!],
          ],
        ),
      ),
    );
  }
}

/// 分组管理弹窗（0.7.67）：新建 / 重命名 / 删除。
///
/// 分组只是书架上的分类标签，一本书可以同时挂在多个分组里，
/// 删除分组不会删书，只是把书退回「全部」。
class _GroupManagerDialog extends StatelessWidget {
  const _GroupManagerDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('管理分组'),
      content: SizedBox(
        width: 380,
        child: ListenableBuilder(
          listenable: NovelStore.instance,
          builder: (context, _) {
            final store = NovelStore.instance;
            final groups = store.groups;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '还没有分组。分组只是书架上的分类标签，一本书可以同时在多个分组里。',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final group in groups)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.folder_outlined,
                                size: 18,
                              ),
                              title: Text(
                                group.name,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                              subtitle: Text(
                                '${store.entriesInGroup(group.id).length} 本',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '重命名',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 17,
                                    onPressed: () => _rename(context, group),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: '删除分组',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 17,
                                    onPressed: () => _remove(context, group),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('novel-group-create'),
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建分组'),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Future<void> _create(BuildContext context) async {
    final name = await _promptGroupName(context, title: '新建分组');
    if (name == null || name.trim().isEmpty) return;
    await NovelStore.instance.createGroup(name);
  }

  Future<void> _rename(BuildContext context, NovelShelfGroup group) async {
    final name = await _promptGroupName(
      context,
      title: '重命名分组',
      initial: group.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await NovelStore.instance.renameGroup(group.id, name);
  }

  Future<void> _remove(BuildContext context, NovelShelfGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除「${group.name}」'),
        content: const Text('分组里的书不会被删除，会回到「全部」。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await NovelStore.instance.removeGroup(group.id);
  }
}

/// 输入分组名的小弹窗（不占 controller，避免对话框关掉后没释放）。
Future<String?> _promptGroupName(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  var value = initial;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        initialValue: initial,
        autofocus: true,
        maxLength: 12,
        decoration: const InputDecoration(
          hintText: '例如：在追 / 看完 / 玄幻',
          counterText: '',
        ),
        onChanged: (text) => value = text,
        onFieldSubmitted: (text) => Navigator.of(dialogContext).pop(text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(value),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
