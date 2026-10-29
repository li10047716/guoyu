import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/novel_detail_screen.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_store.dart';

/// 小说模块内的二级分区（0.7.66）。
///
/// 参考成熟阅读器的信息架构：书架 / 发现 / 探索 / 我的。
/// 之前只有「书架 / 搜书」两个 Tab，搜书是并列入口；现在搜索收进
/// 右上角的放大镜（以及发现页的大搜索框），分区留给真正的内容聚合。
enum _NovelSection {
  shelf('书架', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  discover('发现', Icons.explore_outlined, Icons.explore_rounded),
  explore('探索', Icons.grid_view_rounded, Icons.grid_view_rounded),
  mine('我的', Icons.person_outline_rounded, Icons.person_rounded);

  const _NovelSection(this.label, this.glyph, this.selectedGlyph);

  final String label;
  final IconData glyph;
  final IconData selectedGlyph;

  String get key => 'novel-section-$name';
}

/// 书架筛选范围：三个内置状态 + 任意自定义分组。
enum _ShelfScope { all, reading, unread, custom }

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
  });

  final AppRepository repository;
  final bool embedded;

  @override
  State<NovelHomeScreen> createState() => _NovelHomeScreenState();
}

class _NovelHomeScreenState extends State<NovelHomeScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();

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

  static const _hotKeywords = ['玄幻', '都市', '穿越', '重生', '系统', '剑来', '诡秘'];

  /// 宽屏阈值：够宽就竖排导航，窄了退回顶部横排。
  static const _wideBreakpoint = 840.0;

  @override
  void initState() {
    super.initState();
    NovelStore.instance.ensureLoaded();
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

  /// 从发现/探索页点分类或热词：直接带着关键词进入搜索并出结果。
  void _searchKeyword(String keyword) {
    setState(() => _searchOpen = true);
    _runSearch(keyword);
  }

  Future<void> _runSearch(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return;
    _search.text = query;
    _focus.unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _searched = true;
    });
    try {
      final items = await widget.repository.novelSearch(query);
      if (!mounted) return;
      setState(() {
        _results = items;
        _searching = false;
      });
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

  void _notYet(String label) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('$label：即将支持'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
              _topTabs(context),
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
          right: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
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
              Flexible(
                child: Text(
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
              ),
            const Spacer(),
            if (!_searchOpen) _toolbar(context),
          ],
        ),
      ),
    );
  }

  /// 右上工具区：一枚胶囊装「分组 / 视图 / 搜索」，旁边单独一枚「更多」。
  Widget _toolbar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onShelf = _section == _NovelSection.shelf;
    final pill = BoxDecoration(
      color: colors.surfaceContainerHighest.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(18),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 36,
          decoration: pill,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 分组筛选与视图切换只对书架有意义。
              if (onShelf) ...[_groupMenu(context), _toolDivider(colors)],
              if (onShelf) ...[
                _toolIcon(
                  context,
                  key: const ValueKey('novel-view-toggle'),
                  icon: _listView
                      ? Icons.view_module_rounded
                      : Icons.view_list_rounded,
                  tooltip: _listView ? '切换为网格' : '切换为列表',
                  onTap: () => setState(() => _listView = !_listView),
                ),
                _toolDivider(colors),
              ],
              _toolIcon(
                context,
                key: const ValueKey('novel-search-open'),
                icon: Icons.search_rounded,
                tooltip: '搜索',
                onTap: _openSearch,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(height: 36, width: 36, decoration: pill, child: _moreMenu(context)),
      ],
    );
  }

  Widget _toolDivider(ColorScheme colors) => Container(
    width: .8,
    height: 16,
    color: colors.outlineVariant.withValues(alpha: .7),
  );

  Widget _toolIcon(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: key,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: colors.onSurfaceVariant),
    );
  }

  Widget _groupMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = NovelStore.instance.groups;
    return PopupMenuButton<String>(
      key: const ValueKey('novel-shelf-group'),
      tooltip: '筛选书架',
      position: PopupMenuPosition.under,
      onSelected: _onScopeSelected,
      itemBuilder: (context) => [
        for (final scope in const [
          _ShelfScope.all,
          _ShelfScope.reading,
          _ShelfScope.unread,
        ])
          PopupMenuItem(
            value: scope.name,
            child: Text(
              _scopeLabelOf(scope),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        if (groups.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final group in groups)
            PopupMenuItem(
              value: 'group:${group.id}',
              child: Text(group.name, style: const TextStyle(fontSize: 13)),
            ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'manage',
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 16),
              SizedBox(width: 8),
              Text('管理分组…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _scopeLabel,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _moreMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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
            _notYet(value);
        }
      },
      itemBuilder: (context) => const [
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

  String _scopeLabelOf(_ShelfScope scope) => switch (scope) {
    _ShelfScope.all => '全部',
    _ShelfScope.reading => '在读',
    _ShelfScope.unread => '未开始',
    _ShelfScope.custom => '分组',
  };

  String get _scopeLabel {
    if (_scope != _ShelfScope.custom) return _scopeLabelOf(_scope);
    for (final group in NovelStore.instance.groups) {
      if (group.id == _customGroupId) return group.name;
    }
    return '全部';
  }

  void _onScopeSelected(String value) {
    if (value == 'manage') {
      unawaited(_manageGroups());
      return;
    }
    setState(() {
      if (value.startsWith('group:')) {
        _scope = _ShelfScope.custom;
        _customGroupId = value.substring('group:'.length);
        return;
      }
      _customGroupId = null;
      _scope = switch (value) {
        'reading' => _ShelfScope.reading,
        'unread' => _ShelfScope.unread,
        _ => _ShelfScope.all,
      };
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
        content: Text('确定移除选中的 ${_selected.length} 本书？阅读进度会一起清掉，本地导入的书会删除磁盘文件。'),
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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('打开文件选择器失败：$error')),
      );
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
      _ShelfScope.reading => [
        for (final entry in entries)
          if (entry.progress != null) entry,
      ],
      _ShelfScope.unread => [
        for (final entry in entries)
          if (entry.progress == null) entry,
      ],
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
          repository: widget.repository,
          onOpenSearch: _openSearch,
          onOpenNovel: _openNovel,
        );
      case _NovelSection.explore:
        return _ExplorePage(
          keywords: _hotKeywords,
          onKeyword: _searchKeyword,
          onNotYet: _notYet,
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
        hint: '内置书源：笔趣阁',
      );
    }
    if (_results.isEmpty) {
      return _EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到这本书',
        hint: '换个关键词试试，或者直接搜作者名',
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
          leading: const Icon(Icons.menu_book_rounded),
          title: Text(
            novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [novel.author.isEmpty ? '佚名' : novel.author, novel.category]
                .where((item) => item.isNotEmpty)
                .join(' · '),
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
          _ShelfScope.reading => [
            for (final entry in entries)
              if (entry.progress != null) entry,
          ],
          _ShelfScope.unread => [
            for (final entry in entries)
              if (entry.progress == null) entry,
          ],
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
            hint: '右上角切回「全部」看看',
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _cover(context, novel, colors),
                  ),
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
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 46,
                  height: 62,
                  child: _cover(context, novel, colors),
                ),
              ),
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

Widget _cover(BuildContext context, Novel novel, ColorScheme colors) {
  final placeholder = Container(
    color: colors.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(
      Icons.menu_book_rounded,
      color: colors.onSurfaceVariant.withValues(alpha: .45),
    ),
  );
  if (novel.cover.isEmpty) return placeholder;
  return Image.network(
    novel.cover,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => placeholder,
    loadingBuilder: (context, child, loading) =>
        loading == null ? child : placeholder,
  );
}

// ── 发现 / 探索 / 我的 ────────────────────────────────────────────────────

/// 发现：搜索入口 + 真实分类浏览 + 该分类的收藏排行。
///
/// 0.7.67 起分类走站点的 `/sort/<id>_<page>/`，每类上千页真实书目，
/// 不再是"拿关键词冒充分类"；侧栏的「收藏排行」也接上了。
class _DiscoverPage extends StatefulWidget {
  const _DiscoverPage({
    required this.repository,
    required this.onOpenSearch,
    required this.onOpenNovel,
  });

  final AppRepository repository;
  final VoidCallback onOpenSearch;
  final ValueChanged<Novel> onOpenNovel;

  @override
  State<_DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<_DiscoverPage> {
  final _scroll = ScrollController();

  List<NovelCategory> _categories = const [];
  int? _categoryId;
  List<Novel> _ranking = const [];
  List<Novel> _books = const [];
  int _page = 1;
  int _pages = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

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
      unawaited(_loadMore());
    }
  }

  Future<void> _bootstrap() async {
    try {
      final categories = await widget.repository.novelCategories();
      if (!mounted) return;
      if (categories.isEmpty) {
        setState(() {
          _loading = false;
          _error = '书源没有返回分类，稍后再试';
        });
        return;
      }
      setState(() {
        _categories = categories;
        _categoryId = categories.first.id;
      });
      await _loadCategory(categories.first.id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error'.replaceFirst('AppFailure: ', '');
      });
    }
  }

  Future<void> _loadCategory(int id) async {
    setState(() {
      _categoryId = id;
      _loading = true;
      _error = null;
      _ranking = const [];
      _books = const [];
      _page = 1;
      _pages = 0;
    });
    try {
      // 排行挂了不影响书籍列表，各自兜底。
      final ranking = await widget.repository
          .novelRanking(id)
          .catchError((Object _) => <Novel>[]);
      final page = await widget.repository.novelCategoryBooks(id, page: 1);
      if (!mounted || _categoryId != id) return;
      setState(() {
        _ranking = ranking;
        _books = page.items;
        _page = page.page;
        _pages = page.pages;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || _categoryId != id) return;
      setState(() {
        _loading = false;
        _error = '$error'.replaceFirst('AppFailure: ', '');
      });
    }
  }

  Future<void> _loadMore() async {
    final id = _categoryId;
    if (id == null || _loading || _loadingMore) return;
    if (_pages == 0 || _page >= _pages) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.repository.novelCategoryBooks(
        id,
        page: _page + 1,
      );
      if (!mounted || _categoryId != id) return;
      setState(() {
        _books = [..._books, ...page.items];
        _page = page.page;
        _pages = page.pages;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        Material(
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
        ),
        if (_categories.isNotEmpty) ...[
          const _SectionTitle('分类'),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = _categories[index];
                final selected = category.id == _categoryId;
                return Material(
                  color: selected
                      ? colors.primary.withValues(alpha: .16)
                      : colors.surfaceContainerHighest.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(17),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('discover-category-${category.id}'),
                    onTap: () => _loadCategory(category.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      child: Center(
                        child: Text(
                          category.name,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: () => _bootstrap(),
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        else ...[
          if (_ranking.isNotEmpty) ...[
            const _SectionTitle('收藏排行'),
            for (var i = 0; i < _ranking.length && i < 10; i++)
              _RankRow(
                index: i,
                novel: _ranking[i],
                onTap: () => widget.onOpenNovel(_ranking[i]),
              ),
          ],
          const _SectionTitle('更多书籍'),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 132,
              mainAxisSpacing: 14,
              crossAxisSpacing: 12,
              childAspectRatio: .52,
            ),
            itemCount: _books.length,
            itemBuilder: (context, index) {
              final novel = _books[index];
              return InkWell(
                key: ValueKey('discover-book-$index'),
                onTap: () => widget.onOpenNovel(novel),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: double.infinity,
                          child: _cover(context, novel, colors),
                        ),
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
          ),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_pages > 0 && _page >= _pages)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Center(
                child: Text(
                  '已经到底了 · 共 $_pages 页',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant.withValues(alpha: .7),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// 收藏排行的一行：序号 + 书名，前三名用主色。
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.index,
    required this.novel,
    required this.onTap,
  });

  final int index;
  final Novel novel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final top = index < 3;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: top
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: .55),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  novel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: colors.onSurfaceVariant.withValues(alpha: .5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// 探索：热词墙 + 榜单占位。
class _ExplorePage extends StatelessWidget {
  const _ExplorePage({
    required this.keywords,
    required this.onKeyword,
    required this.onNotYet,
  });

  final List<String> keywords;
  final ValueChanged<String> onKeyword;
  final ValueChanged<String> onNotYet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        const _SectionTitle('热门关键词'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final keyword in keywords)
              ActionChip(
                key: ValueKey('explore-keyword-$keyword'),
                label: Text(keyword, style: const TextStyle(fontSize: 12.5)),
                onPressed: () => onKeyword(keyword),
                backgroundColor: colors.surfaceContainerHighest.withValues(
                  alpha: .5,
                ),
                side: BorderSide.none,
              ),
          ],
        ),
        const _SectionTitle('书单'),
        _PlaceholderCard(
          icon: Icons.collections_bookmark_outlined,
          title: '精选书单筹备中',
          message: '后续会按分类整理一批能读的书单，点进去直接开始读。',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const ValueKey('explore-shuffle'),
          onPressed: () => onNotYet('随机推荐'),
          icon: const Icon(Icons.shuffle_rounded, size: 18),
          label: const Text('随机推荐一本'),
        ),
      ],
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
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .42),
                borderRadius: BorderRadius.circular(14),
              ),
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
                      Icons.menu_book_rounded,
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
                          '笔趣阁',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '内置 · 搜索 / 详情 / 目录 / 正文',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.onSurfaceVariant.withValues(
                              alpha: .85,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '在用',
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
                ],
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

class _PlaceholderCard extends StatelessWidget {
  const _PlaceholderCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .32),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: .6),
          style: BorderStyle.solid,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: colors.onSurfaceVariant.withValues(alpha: .85),
                  ),
                ),
              ],
            ),
          ),
        ],
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
