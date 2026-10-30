import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/ui/app_theme.dart';
import 'package:duanju_app/platform/app_updater.dart';
import 'package:duanju_app/platform/desktop_title_bar.dart';
import 'package:duanju_app/ui/about_credit.dart';
import 'package:duanju_app/ui/app_bottom_navigation.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/catalog/catalog_filters.dart';
import 'package:duanju_app/catalog/catalog_browser.dart';
import 'package:duanju_app/catalog/catalog_auto_updater.dart';
import 'package:duanju_app/catalog/catalog_sort.dart';
import 'package:duanju_app/catalog/catalog_sort_sheet.dart';
import 'package:duanju_app/catalog/recommendations_screen.dart';
import 'package:duanju_app/catalog/rankings_screen.dart';
import 'package:duanju_app/ui/detail_screen.dart';
import 'package:duanju_app/downloads/downloads_screen.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/lan/lan_screen.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/music/music_home_screen.dart';
import 'package:duanju_app/novel/novel_home_screen.dart';
import 'package:duanju_app/ui/module_switch_bar.dart';
import 'package:duanju_app/ui/remote_widgets.dart';
import 'package:duanju_app/ui/widgets.dart';
import 'package:duanju_app/ui/vip_icon.dart';
import 'package:duanju_app/ui/settings_screen.dart';
import 'package:duanju_app/ui/profiles_screen.dart';
import 'package:duanju_app/catalog/search_input.dart';
import 'package:duanju_app/catalog/sources_screen.dart';
import 'package:duanju_app/downloads/batch_download_screen.dart';
import 'package:duanju_app/downloads/batch_downloads.dart';
import 'package:duanju_app/ui/drama_actions.dart';
import 'package:duanju_app/downloads/library_updater.dart';
import 'package:duanju_app/core/saved_library.dart';
import 'package:duanju_app/player/vertical_feed_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialTab,
  });
  final AppRepository repository;
  final LocalStore store;

  /// 初始标签下标。为空时默认打开「发现」（分类浏览）。
  ///
  /// 0.7.21（用户要求）：首页竖滑流入口已移除，默认页改为「发现」。
  final int? initialTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  late SourceSite _source;
  bool _allSources = false;

  /// 多选站源（非空时优先于单源/全部，作为当前浏览范围）。
  List<String> _multiSources = const [];
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  bool _failedMore = false;
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  late final CatalogAutoUpdater _autoUpdater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _updateNotice = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;

  /// 「找剧」页的筛选面板展开状态（0.7.31）。
  bool _filtersOpen = false;

  /// 状态筛选：'' = 全部，'finished' / 'ongoing'。
  String _statusFilter = '';

  /// 上新时间筛选：0 = 不限，其余为天数。
  int _daysFilter = 0;

  /// 标签筛选（取剧集真实标签，空 = 全部）。
  String _tagFilter = '';

  /// 当前是否停在「找剧」页（0.7.33：找剧已升级为与推荐/追剧同级的标签页）。
  bool get _searchVisible => _tab == _findIndex;

  List<SourceGroup> get _sourceGroups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return groups;
  }

  /// 多选模式下自定义的站源分组。
  SourceGroup? get _multiGroup {
    if (_multiSources.isEmpty) return null;
    final sites = widget.store.sources
        .where((site) => _multiSources.contains(site.id))
        .toList();
    if (sites.isEmpty) return null;
    // 0.6.11 修复（用户反馈"仅选两个播放器也会提示切换到全部源"）：
    //
    // 原先判据是 `sites.length == widget.store.sources.length` —— 只比**数量**，
    // 数量相等时会被误判为「全部站源」。正确判据必须是
    // **选中的 id 集合 == 可用的 id 集合**，而不是数量相等。
    final allIds = widget.store.sources.map((site) => site.id).toSet();
    final pickedIds = sites.map((site) => site.id).toSet();
    final isAll =
        allIds.length == pickedIds.length && allIds.containsAll(pickedIds);
    final name = isAll ? '全部站源' : sites.map((site) => site.entryName).join('+');
    return SourceGroup('multi', name, sites);
  }

  SourceGroup get _group {
    final multi = _multiGroup;
    if (multi != null) return multi;
    return _sourceGroups
            .where((group) => group.id == _source.groupId)
            .firstOrNull ??
        SourceGroup(_source.groupId, _source.groupName, [_source]);
  }

  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    final online = _group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) {
      return '筛选本机已更新剧库';
    }
    final names = online.map((source) => source.name).join('、');
    return online.length == _group.sources.length
        ? '搜索${names}短剧'
        : '搜索${names}及本机剧库';
  }

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      setState(() => _updateNotice = true);
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _autoUpdateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  /// AppBar 的站源入口：点开**弹窗**，勾选后按「确定」才生效。
  ///
  /// 0.6.11 改版（用户反馈）：底部弹窗 + 勾选 + 确定/取消。
  /// 0.7.35（预览稿 01）：外观改成卡底胶囊，挂在品牌行右侧。
  Widget _sourceMenu() {
    final enabled = widget.store.sources.isNotEmpty;
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('source-switch'),
      borderRadius: BorderRadius.circular(22),
      onTap: enabled ? _openSourceSheet : null,
      child: Container(
        height: 36,
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _group.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (enabled)
              Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  /// 品牌行（0.7.35，预览稿 01）：小 logo + 应用名，替代原站源标题位。
  ///
  /// 窄屏（320 等）下操作区占满时标题空间不足，用 FittedBox
  /// 整体缩放而不是溢出报错。
  Widget _brandTitle() => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/branding/logo.png', width: 26, height: 26),
        const SizedBox(width: 8),
        const Text(
          appName,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  /// 打开站源选择弹窗（0.6.11 新增）。
  ///
  /// 0.7.58（用户要求）：站源只做**互斥单选**——弹窗改为单选列表，
  /// 点一项立即切换并关闭，去掉「全选 / 清空 / 确定」多选操作。
  Future<void> _openSourceSheet() async {
    final groups = _sourceGroups;
    if (groups.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _SourcePickerSheet(
        groups: groups,
        currentId: _multiSources.isEmpty ? _group.id : null,
      ),
    );
    if (picked == null || !mounted) return;
    final ids = <String>[
      for (final site in widget.store.sources)
        if (site.groupId == picked) site.id,
    ];
    if (ids.isEmpty) return;
    await _applyMultiSources(ids);
  }

  /// 切换到「多选站源」状态：同时聚合勾选的若干个源。
  ///
  /// 勾选数量语义：
  /// - 0 个：回到单选（使用 [_source]）。
  /// - 1 个：等价单选，直接切到该源。
  /// - ≥2 个：多选聚合，`_multiSources` 生效。
  Future<void> _applyMultiSources(List<String> ids) async {
    final available = widget.store.sources
        .where((site) => ids.contains(site.id))
        .map((site) => site.id)
        .toList();
    if (available.isEmpty) {
      setState(() {
        _multiSources = const [];
        _allSources = false;
      });
      await widget.store.setMultiSources(const []);
      return;
    }
    if (available.length == 1) {
      setState(() {
        _multiSources = const [];
        _allSources = false;
      });
      await widget.store.setMultiSources(const []);
      _changeSource(SourceSite.byId(available.first));
      return;
    }
    setState(() {
      _multiSources = available;
      _allSources = false;
      _selectionMode = false;
      _selectedDramas.clear();
    });
    await widget.store.setMultiSources(available);
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
    _loadCategories();
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _submittedQuery = '';
      });
      return;
    }
    if (_category == category && !_showRecommendations) return;
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    }
  }

  /// 打开「找剧」页（0.7.33：等同于点侧栏/底栏的「找剧」，是一个标签页切换）。
  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    _changeTab(_findIndex);
  }

  /// 离开找剧页，回到推荐（0.7.32；0.7.33 改为切标签）。
  ///
  /// 与普通切标签的差别：顺手清掉搜索词与筛选面板展开态，
  /// 否则下次进来会沿用上一次的条件，看起来像没重置。
  void _leaveFind() {
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _tab = _discoverIndex;
      _search.clear();
      _filtersOpen = false;
    });
    if (hadQuery) _searchChanged('');
  }

  /// 打开榜单。
  ///
  /// - 桌面（左侧栏）：和推荐/追剧一样**切标签页**，侧栏「榜单」跟着高亮；
  /// - 手机 / 电视：底部标签里没有榜单的位置，`push` 一个自带 AppBar 的页面，
  ///   否则会出现「哪个标签都没选中」的怪状态。
  void _openRankings() {
    if (widget.store.sources.isEmpty) return;
    final television = AppLayout.isTelevision(context);
    final rail = !television && MediaQuery.sizeOf(context).width >= 840;
    if (rail) {
      _changeTab(_rankingsIndex);
      return;
    }
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Future<void> _chooseDisplayMode() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('界面模式'),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const {
                  'auto': '自动识别设备',
                  'television': '电视 / 遥控器',
                  'standard': '手机 / 电脑',
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _multiSources.isNotEmpty
            ? '搜索已选站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != _discoverIndex) {
      setState(() => _tab = _discoverIndex);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _source = SourceSite.byId(widget.store.source);
    _allSources = widget.store.catalogView.allSources;
    _multiSources = widget.store.multiSources;
    if (_allSources &&
        _multiSources.isEmpty &&
        widget.store.sources.length > 1) {
      // 旧版「全部站源」在单选模型下没有对应状态，但我们已恢复多选，
      // 这里保持多选语义：若历史配置是 allSources，不强制改写，交给用户再次选择。
    }
    // 0.7.21：进软件默认打开「发现」页（首页竖滑流入口已移除）。
    _tab = widget.initialTab ?? _discoverIndex;
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    // 剧库自适应自动更新：打开 App 后延迟 2 分钟，默认每 2 小时一轮，
    // 连续无新剧后降级为 6 小时；设置里可完全关闭。
    _autoUpdater = CatalogAutoUpdater(widget.repository, widget.store)
      ..addListener(_autoUpdateChanged)
      ..start();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _autoUpdater.removeListener(_autoUpdateChanged);
    _autoUpdater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      _failedMore = false;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(CatalogPage result) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        // 只要已经有内容（无论是磁盘缓存还是网络返回），就立刻结束加载态。
        // 之前写成 cached && !result.fresh 会让"缓存命中但待刷新"时
        // 仍然显示加载指示，用户感知就是"一直在转圈"。
        // 新鲜度由后台刷新负责，不再阻塞界面。
        _loading = false;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
        _failedMore = more;
      });
    }
  }

  void _changeSource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id &&
        _allSources == allSources &&
        _multiSources.isEmpty) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _updateNotice = false;
      _source = source;
      _allSources = allSources;
      _multiSources = const [];
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(context, () async {
        await widget.store.setMultiSources(const []);
        await widget.store.setCatalogSource(source.id, allSources: allSources);
      }),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          resumeOnOpen: resume,
          downloadOnOpen: download,
        ),
      ),
    );
  }

  /// 点视频卡片 → **直接开播**（0.7.24，用户要求）。
  ///
  /// 用户原话："点击视频卡片直接播放，然后点击剧名出现这个页面（详情页）"。
  /// 走单剧模式播放器：上滑=下一集、下滑=上一集；
  /// `resumeWatch` 让它按观看记录落到上次那一集、那一秒。
  void _playDrama(Drama drama) {
    if (!widget.store.allowsSource(drama.source)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前用户无权播放该站源内容')));
      return;
    }
    _pauseCatalog();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VerticalFeedScreen(
          repository: widget.repository,
          store: widget.store,
          singleDrama: drama,
          resumeWatch: true,
        ),
      ),
    );
  }

  void _changeTab(int tab) {
    if (tab == _tab) return;
    // 离开找剧时把搜索词与筛选面板收起，下次进来是干净的（0.7.32 的约定）。
    final leavingFind = _tab == _findIndex;
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _tab = tab;
      _selectionMode = false;
      _selectedDramas.clear();
      // 榜单页按需构建：没进过就不建，避免一启动就去拉榜单数据。
      if (tab == _rankingsIndex) _rankingsVisited = true;
      if (leavingFind) {
        _search.clear();
        _filtersOpen = false;
      }
    });
    if (leavingFind && hadQuery) _searchChanged('');
  }

  /// 进入非看剧模块（小说 / 听歌，0.7.63 用户要求）。
  ///
  /// 三个模块是**平级的整屏界面**——进入后左侧栏、手机底栏、品牌标题栏里
  /// 的看剧元素全部收起，整页交给模块自己；切换靠页面底端的
  /// [ModuleSwitchBar]，另外标题栏还留一个 `←` 直接回看剧。
  /// 进模块前先记住当前看剧标签，回看剧时原路返回。
  void _enterModule(int tab) {
    if (tab == _tab) return;
    if (!_isModuleTab(_tab)) _tabBeforeModule = _tab;
    _changeTab(tab);
  }

  /// 从小说/听歌回到看剧（回到进入前那个标签，不是固定推荐页）。
  void _exitModule() {
    final back = _isModuleTab(_tabBeforeModule)
        ? _discoverIndex
        : _tabBeforeModule;
    _changeTab(back);
  }

  /// 前后台切换（0.2.26 新增；0.2.27 修正；0.7.21 首页移除后仅保留占位）。
  ///
  /// 历史上这里曾在回到前台时刷新首页竖滑流，后按用户要求
  /// **彻底移除生命周期驱动的刷新**：从桌面切回（进程存活）不刷新，
  /// 冷启动走正常初始化。首页已移除，此处只保留观察者生命周期钩子。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 0.2.27：不再根据前后台状态刷新内容。
    // 保留该方法以免影响 `WidgetsBindingObserver` 的注册/注销。
  }

  /// 各功能标签在导航中的下标（0.7.21：首页竖滑流入口已移除，
  /// 「发现」成为第一个标签，其后再依次后移）。
  ///
  /// 0.7.33（用户要求）：找剧、榜单升级为**与推荐/追剧平级的标签页**，
  /// 各自占一个下标——点侧栏/底栏的入口就是切页，和切「追剧」完全一样，
  /// 不再挂在推荐页里靠模式变量渲染。
  ///
  /// 下标一旦写进 `IndexedStack` 就不能再动：`_downloadIndex` 恒定 3，
  /// 下载页不可用时该位置放一个空占位，避免下标整体前移。
  int get _discoverIndex => 0;
  int get _followIndex => 1;
  int get _historyIndex => 2;
  int get _downloadIndex => 3;
  int get _findIndex => 4;
  int get _rankingsIndex => 5;
  // 0.7.62（用户要求）：点「小说」= 切到**独立的小说界面**（不是看剧主界面
  // 里的一个格子）：进入后侧栏/底栏/品牌顶栏都收起。
  // 0.7.63：小说与「听歌」一起升为一级模块，切换入口在页面底端。
  int get _novelIndex => 6;
  int get _musicIndex => 7;

  bool _isModuleTab(int tab) => tab == _novelIndex || tab == _musicIndex;

  /// 是否处在非看剧模块（小说 / 听歌）：整页是模块自己，看剧外壳全部收起。
  bool get _moduleMode => _isModuleTab(_tab);

  /// 当前模块（给底端切换条判断高亮）。
  AppModule get _currentModule => _tab == _novelIndex
      ? AppModule.novel
      : _tab == _musicIndex
      ? AppModule.music
      : AppModule.watch;

  /// 进入模块前所在的看剧标签，回看剧时回到这里。
  int _tabBeforeModule = 0;

  /// 榜单页是否被打开过（0.7.33）。
  ///
  /// `IndexedStack` 会把所有子页一起构建，榜单页一构建就会去拉榜单数据；
  /// 没进过榜单就白拉一次网络，还会打乱测试里的请求断言，所以按需构建。
  bool _rankingsVisited = false;

  /// 手机底部导航的位置 → 标签下标（位置顺序即视觉顺序）。
  ///
  /// 0.7.63：这里只放**看剧模块内部**的标签；小说/听歌已经挪到页面底端的
  /// [ModuleSwitchBar]，不再占底栏位置（少一格，底栏也没那么挤）。
  List<int> get _bottomTabs => [
    _discoverIndex,
    _findIndex,
    _followIndex,
    _historyIndex,
    if (widget.store.canDownload) _downloadIndex,
  ];

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        widget.store.canDownload && widget.repository.supportsDownloads;
    // 0.7.24（用户要求）：卡片直接开播，剧名进详情页。
    // 电视端遥控器只能整体聚焦卡片、无法单独选中剧名，故沿用旧行为（卡片 → 详情）。
    final television = AppLayout.isTelevision(context);
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _selectionMode
          ? _selectDrama(drama)
          : television
          ? _openDrama(drama)
          : _playDrama(drama),
      onTitleTap: television || _selectionMode ? null : () => _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      // 0.7.27（用户要求）：卡片右上角的三个点去掉，卡面更干净；
      // 右键 / 长按仍然能叫出同一套操作菜单。
      onMore: () => _dramaActions(drama),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      // 找剧页带「播放量 / 共 N 集」角标，推荐页保持干净。
      showStats: _searchVisible,
      badge: following == null
          ? null
          : '${following.status.label}${following.newEpisodes > 0 ? ' · 更新 ${following.newEpisodes} 集' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  /// 0.7.48：VIP 标记以前只由黄豆站源产生，VIP 过滤按钮也只对黄豆显示。
  /// 黄豆移除后，红果 / 青空次元 / 韩小圈 都不会给出 VIP 标记，再挂一个
  /// 永远不起作用的按钮只会误导用户，因此整体收起；本地保存的旧开关保留
  /// 不动，老配置升级后不会被判无效。
  static const _supportsVipFilter = false;

  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible {
    final query = _search.text.trim().toLowerCase();
    final since = _daysFilter <= 0
        ? null
        : DateTime.now().subtract(Duration(days: _daysFilter));
    return sortCatalog(
      _items.where((drama) {
        if (!widget.store.allowsSource(drama.source)) return false;
        if (_category.startsWith('local:') &&
            categoryName(drama.category) != _category.substring(6)) {
          return false;
        }
        if (_hideVip && drama.vip) {
          return false;
        }
        // 「找剧」页的筛选面板（0.7.31）：状态 / 上新时间 / 标签。
        if (_statusFilter.isNotEmpty &&
            (drama.releaseStatus == 'completed'
                    ? 'finished'
                    : drama.releaseStatus) !=
                _statusFilter) {
          return false;
        }
        if (since != null) {
          final date = DateTime.tryParse(drama.onlineDate);
          // 没有上线日期的剧在「N 天内上新」里排除：宁可少显示，也不要混进
          // 一部年代不明的老剧。
          if (date == null || date.isBefore(since)) return false;
        }
        if (_tagFilter.isNotEmpty && !drama.tags.contains(_tagFilter)) {
          return false;
        }
        return _onlineSearch ||
            query.isEmpty ||
            matchesDramaQuery(drama, query);
      }),
      widget.store.catalogView,
    );
  }

  /// 筛选摘要（参考图那行「筛选：全部」）。
  String get _filterSummary {
    final parts = <String>[
      if (_displayCategory != '')
        _displayCategories
                .where((entry) => entry.id == _displayCategory)
                .map((entry) => entry.name)
                .firstOrNull ??
            '',
      if (widget.store.catalogView.sort != CatalogSort.source)
        widget.store.catalogView.sort.label,
      if (_statusFilter.isNotEmpty) _statusFilter == 'finished' ? '已完结' : '连载中',
      if (_daysFilter > 0) '$_daysFilter 天内上新',
      if (_tagFilter.isNotEmpty) _tagFilter,
    ].where((text) => text.isNotEmpty).toList();
    return parts.isEmpty ? '全部' : parts.join(' · ');
  }

  /// 当前已加载内容里出现过的标签（按出现次数排序，取前 18 个）。
  List<String> get _availableTags {
    final counts = <String, int>{};
    for (final drama in _items) {
      for (final tag in drama.tags) {
        if (tag.trim().isEmpty) continue;
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in sorted.take(18)) entry.key];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        // 桌面端（非电视）用左侧栏承载导航 + 站源 + 操作按钮。
        final railMode = desktop && !television;
        // 0.7.33（用户要求）：找剧与榜单都是**独立标签页**，和追剧/最近观看一样
        // 各自占 IndexedStack 的一格。进入这两页后手机端不再显示全局顶栏，
        // 页面顶部完全由自己的头部构成——看起来就是换了一页，而不是推荐页上叠控件。
        final ownHeader = _tab == _findIndex || _tab == _rankingsIndex;
        // 0.7.35（预览稿 01）：手机端推荐页顶栏改成品牌行——
        // 左侧 logo + 应用名，站源胶囊与操作钮统一挂到右侧；
        // 桌面/电视与其他标签维持原状。
        final Widget titleContent = _selectionMode
            ? const Text('选择短剧', maxLines: 1, overflow: TextOverflow.ellipsis)
            : railMode
            // 站源选择已移到左侧栏，桌面顶栏只显示应用名。
            ? const Text(appName)
            : _tab == _discoverIndex
            ? _brandTitle()
            : const Text(appName);
        // 0.7.22（用户要求）：桌面端把这一排按钮整体搬进**左侧栏**竖排，
        // 顶栏只留标题。手机端仍放在顶栏（0.7.35 起移到右侧）。
        final barActions = _headerActions(
          rail: railMode,
          constraints: constraints,
        );
        // 0.7.55（用户要求）：站源胶囊移出标题栏（不美观），改为左侧栏
        // 「站源」入口弹出选择菜单；标题栏只留品牌行。
        if (_usesTitleBar) {
          TitleBarSlot.instance.put(
            !railMode
                ? null
                // 0.7.62：小说模式标题栏也换成小说自己的（返回 + 页名），
                // 不再挂看剧的品牌行。
                : _moduleMode
                ? _moduleTitleBarLeading()
                : _titleBarLeading(),
          );
        }
        final scaffold = Scaffold(
          // 0.7.28（用户要求）：桌面端不再显示「真果鉴」这条标题栏，
          // 导航与操作都在左侧栏里，内容整体上移。
          // 0.7.62：小说模式也不用外层 AppBar，由小说页自己提供头部。
          appBar: railMode || ownHeader || _moduleMode
              ? null
              : AppBar(
                  toolbarHeight: television ? 64 : null,
                  titleSpacing: 12,
                  title: Row(
                    children: [
                      Expanded(child: titleContent),
                      // 0.7.35：手机端操作钮与站源胶囊排在品牌行右侧（预览稿 01）。
                      if (!railMode) ...[
                        const SizedBox(width: 4),
                        ...barActions,
                      ],
                    ],
                  ),
                ),
          body: SafeArea(
            top: false,
            child: Row(
              children: [
                if (!_moduleMode && television) ...[
                  SizedBox(
                    width: 164,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final entry in [
                            (Icons.explore_rounded, '推荐'),
                            (Icons.bookmark_rounded, '追剧'),
                            (Icons.history_rounded, '最近观看'),
                            if (widget.store.canDownload)
                              (Icons.download_rounded, '下载'),
                          ].indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: RemoteButton(
                                key: ValueKey('tv-nav-${entry.$1}'),
                                label: entry.$2.$2,
                                icon: entry.$2.$1,
                                selected: _tab == entry.$1,
                                autofocus: entry.$1 == 0,
                                onPressed: () => _changeTab(entry.$1),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (!_moduleMode && railMode) ...[
                  _sidebar(barActions),
                ],
                Expanded(
                  // 0.2.26 修正：原先用三元表达式直接构建当前页，切换标签时
                  // **未选中的页面会被销毁**，切回来时重建，丢失滚动位置。
                  // 改用 `IndexedStack`：所有页面同时存在于树中，只显示当前一个。
                  //
                  // 0.7.21（用户要求）：首页竖滑流入口移除，第一页改为「发现」。
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      // 0：推荐页（分类浏览 + 剧卡网格）。
                      widget.store.sources.isEmpty
                          ? const StatusPanel(
                              title: '暂无可用站源',
                              message: '请联系管理员为当前用户开放站源。',
                            )
                          : _catalog(selectionInBody: desktop || television),
                      // 1：追剧页。
                      SavedLibrary(
                        key: const ValueKey('saved-tab-follow'),
                        repository: widget.repository,
                        store: widget.store,
                        history: false,
                        onOpen: _openDrama,
                        onContinue: (drama) => _openDrama(drama, resume: true),
                        onDownload:
                            widget.repository.supportsDownloads &&
                                widget.store.canDownload
                            ? (drama) => _openDrama(drama, download: true)
                            : null,
                      ),
                      // 2：最近观看。
                      SavedLibrary(
                        key: const ValueKey('saved-tab-history'),
                        repository: widget.repository,
                        store: widget.store,
                        history: true,
                        onOpen: _openDrama,
                        onContinue: (drama) => _openDrama(drama, resume: true),
                        onDownload:
                            widget.repository.supportsDownloads &&
                                widget.store.canDownload
                            ? (drama) => _openDrama(drama, download: true)
                            : null,
                      ),
                      // 3：下载。不可下载时占位，保证后面的下标不整体前移。
                      if (widget.store.canDownload)
                        DownloadsScreen(
                          repository: widget.repository,
                          store: widget.store,
                          embedded: true,
                        )
                      else
                        const SizedBox.shrink(),
                      // 4：找剧（0.7.33：独立标签页）。
                      widget.store.sources.isEmpty
                          ? const StatusPanel(
                              title: '暂无可用站源',
                              message: '请联系管理员为当前用户开放站源。',
                            )
                          : _findPage(selectionInBody: desktop || television),
                      // 5：榜单（0.7.33：独立标签页，按需构建）。
                      if (!_rankingsVisited || widget.store.sources.isEmpty)
                        const SizedBox.shrink()
                      else
                        RankingsScreen(
                          repository: widget.repository,
                          store: widget.store,
                          initialGroup: _group.id,
                          embedded: true,
                          onPlay: _playDrama,
                          onOpen: _openDrama,
                        ),
                      // 6：小说（0.7.61；0.7.62 起是独立界面）。
                      //
                      // 只有「窗口标题栏由我们自己渲染」时才把头部也交给它
                      // （embedded），否则页面自带 AppBar 显示模块名。
                      NovelHomeScreen(
                        repository: widget.repository,
                        embedded: railMode && _usesTitleBar,
                        // 0.7.74：手机端模块切换条挂在小说页头部标签行尾。
                        headerActions: [
                          ModuleSwitchBar.compact(
                            current: _currentModule,
                            onChanged: _onModuleChanged,
                          ),
                        ],
                      ),
                      // 7：听歌（0.7.63）。目前是筹备中的界面，入口先落地。
                      //
                      // 只有「窗口标题栏由我们自己渲染」时才把头部也交给它
                      // （embedded），否则页面自带 AppBar 显示模块名。
                      MusicHomeScreen(
                        embedded: railMode && _usesTitleBar,
                        headerActions: [
                          ModuleSwitchBar.compact(
                            current: _currentModule,
                            onChanged: _onModuleChanged,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 0.7.63（用户要求）：页面底端常驻「看剧 / 小说 / 听歌」切换条。
          bottomNavigationBar: _bottomArea(
            desktop: desktop,
            television: television,
          ),
        );
        // 0.7.33：找剧/榜单是独立标签页，系统返回 / Esc 先退回推荐，而不是直接退出。
        // 0.7.63：小说/听歌是模块页，返回同理先回看剧。
        final inOwnPage =
            _tab == _findIndex || _tab == _rankingsIndex || _moduleMode;
        if (!television && !_selectionMode && !inOwnPage) {
          return scaffold;
        }
        return PopScope(
          canPop:
              !_selectionMode &&
              !inOwnPage &&
              (!television || _tab == _discoverIndex && _search.text.isEmpty),
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (_tab == _findIndex) {
              _leaveFind();
              return;
            }
            if (_tab == _rankingsIndex) {
              setState(() => _tab = _discoverIndex);
              return;
            }
            // 0.7.65（用户要求）：小说/听歌里按返回键 / Esc **什么都不做**。
            // 三个模块只允许用页面底端那行按钮切换，返回键不能把人送回看剧；
            // 也不能落到 _televisionBack()（那会把标签改成推荐，等于又一次
            // 偷偷换页）。所以这里直接吞掉。
            if (_moduleMode) return;
            _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  /// 左侧栏宽度（桌面端，0.7.22）。
  static const double _railWidth = 78;

  /// 0.7.45（用户要求）：Windows 桌面端把品牌行与站源胶囊抬进窗口标题栏，
  /// 与最小化 / 最大化 / 关闭排在同一行；其它平台保持内容区顶部。
  static bool get _usesTitleBar =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// 左侧栏里操作按钮的统一尺寸。
  static const double _railActionSize = 36;

  /// 顶栏 / 左侧栏共用的操作按钮列表（0.7.22 重构）。
  ///
  /// 同一份按钮按 `rail` 切换外观，避免两处维护：
  /// - `rail = false`：手机/电视顶栏用的普通图标按钮；
  /// - `rail = true`：桌面左侧栏用的 36×36 按钮，图标统一 20px，
  ///   一列竖排时大小、间距完全对齐。
  List<Widget> _headerActions({
    required bool rail,
    required BoxConstraints constraints,
  }) {
    Widget icon({
      Key? key,
      required IconData glyph,
      required String tooltip,
      VoidCallback? onPressed,
      bool active = false,
    }) => _actionIcon(
      rail: rail,
      key: key,
      glyph: glyph,
      tooltip: tooltip,
      onPressed: onPressed,
      active: active,
    );
    final television = AppLayout.isTelevision(context);
    return [
      if (_selectionMode) ...[
        icon(
          key: const ValueKey('clear-catalog-selection'),
          glyph: Icons.layers_clear_rounded,
          tooltip: '清空已选',
          onPressed: _selectedDramas.isEmpty
              ? null
              : () => setState(_selectedDramas.clear),
        ),
        icon(
          key: const ValueKey('cancel-catalog-selection'),
          glyph: Icons.close_rounded,
          tooltip: '取消选择',
          onPressed: _cancelSelection,
        ),
      ] else ...[
        // 0.7.74（用户要求）：手机顶栏加「看剧 / 小说 / 听歌」紧凑切换，
        // 取代原底端那排切换条（底栏回归单排）。桌面/电视仍用底端条，
        // 不在此显示，免得同一屏出现两个切换入口。
        if (!rail && !AppLayout.isTelevision(context)) ...[
          ModuleSwitchBar.compact(
            current: _currentModule,
            onChanged: _onModuleChanged,
          ),
          const SizedBox(width: 2),
        ],
        if (_tab == _followIndex)
          icon(
            key: const ValueKey('follow-lan-sync'),
            glyph: Icons.sync_rounded,
            tooltip: '追剧同步',
            onPressed: () => openLanSync(context),
          ),
        // 0.7.28（用户要求）：桌面左侧栏去掉「排序与筛选」「多选下载」，
        // 搜索与榜单改为侧栏顶部的独立条目，刷新按钮也取消（改拖拽刷新）。
        // 0.7.74（用户要求）：手机顶栏的「排序 / 榜单 / 多选下载」三个图标
        // 也撤掉（和底栏功能重叠、把顶栏挤满），功能挪进「更多」菜单。
        if (_tab == _discoverIndex && !rail) ...[
          // 0.7.35：站源入口从标题位挪到操作区，仍是胶囊外观。
          _sourceMenu(),
          icon(
            key: const ValueKey('toggle-search'),
            glyph: Icons.search_rounded,
            tooltip: '找剧',
            onPressed: _toggleSearch,
          ),
        ],
        // 「更新剧库」按钮删除（0.7.28，用户要求：改为向下拖动界面刷新）。
        // 电视端拖不动，仍留一个刷新入口。
        if (television &&
            _tab == _discoverIndex &&
            !_showRecommendations &&
            constraints.maxWidth >= 400)
          RefreshAction(
            key: const ValueKey('catalog-refresh'),
            loading:
                _loading ||
                _loadingMore ||
                _categoriesLoading ||
                _group.sources.any((source) => _updater.busy(source.id)),
            tooltip: '更新剧库',
            onPressed: widget.store.sources.isEmpty ? null : _refreshCatalog,
          ),
        // 桌面侧栏底部是「设置」，不再有「更多」菜单。
        if (!rail) _moreMenu(rail: rail, constraints: constraints),
      ],
    ];
  }

  /// 顶栏/侧栏通用图标按钮。
  ///
  /// 侧栏模式固定 36×36、图标 20px、圆角 11，保证一列竖排时**大小对齐**；
  /// 选中态用主色圆角底色标出（如「排序已生效」「搜索已展开」）。
  Widget _actionIcon({
    required bool rail,
    Key? key,
    required IconData glyph,
    required String tooltip,
    VoidCallback? onPressed,
    bool active = false,
  }) {
    if (!rail) {
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        color: active ? Theme.of(context).colorScheme.primary : null,
        icon: Icon(glyph),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final disabled = onPressed == null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkResponse(
        key: key,
        onTap: onPressed,
        radius: 24,
        child: Container(
          width: _railActionSize,
          height: _railActionSize,
          alignment: Alignment.center,
          // 0.7.35（D06）：激活态用星光蓝图标 + 悬停底色，选中胶囊只留给导航。
          decoration: BoxDecoration(
            color: active ? colors.surfaceContainerHigh : null,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            glyph,
            size: 20,
            color: disabled
                ? colors.onSurfaceVariant.withValues(alpha: 0.4)
                : active
                ? colors.secondary
                : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 「更多」菜单（0.7.22 抽出，顶栏与左侧栏共用）。
  Widget _moreMenu({required bool rail, required BoxConstraints constraints}) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      key: const ValueKey('more-menu'),
      tooltip: '更多',
      // 侧栏模式用统一尺寸的自定义图标，保证与其它按钮对齐。
      child: rail
          ? SizedBox(
              width: _railActionSize,
              height: _railActionSize,
              child: Icon(
                Icons.more_vert_rounded,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            )
          : null,
      onSelected: (value) {
        if (value == 'update') {
          _refreshCatalog();
        } else if (value == 'sources') {
          _manageSources();
        } else if (value == 'catalog-sort') {
          // 0.7.74：顶栏「排序与筛选」图标撤掉后的新入口。
          _chooseCatalogView();
        } else if (value == 'open-rankings') {
          _openRankings();
        } else if (value == 'select-catalog-dramas') {
          setState(() => _selectionMode = true);
        } else if (value == 'settings') {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                repository: widget.repository,
                store: widget.store,
              ),
            ),
          );
        } else if (value == 'users') {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ProfilesScreen(store: widget.store),
            ),
          );
        } else if (value == 'display') {
          _chooseDisplayMode();
        } else if (value == 'about') {
          showAboutDialog(
            context: context,
            applicationName: appName,
            applicationVersion: AppLayout.versionOf(context),
            applicationIcon: const Icon(
              Icons.play_circle_filled_rounded,
              size: 48,
              color: AppTheme.starlight,
            ),
            children: [
              const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
              const SizedBox(height: 12),
              // 作者信息（0.2.30 新增，用户要求）：
              // 名字蓝色可点击，跳转各自 GitHub 页面，并标明身份。
              const AboutCredit(
                name: 'Topkill',
                role: '开源项目 guoapp3 原作者',
                url: 'https://github.com/Topkill/guoapp3',
              ),
              const AboutCredit(
                name: '软萌小正太',
                role: '本应用改版与维护',
                url: 'https://github.com/kuoluoss/zhenguojian',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('about-check-update'),
                  onPressed: () => AppUpdater.checkManually(context),
                  icon: const Icon(Icons.system_update_rounded, size: 18),
                  label: const Text('检测新版本'),
                ),
              ),
            ],
          );
        }
      },
      itemBuilder: (_) => [
        // 0.7.74：顶栏撤掉的「排序 / 榜单 / 多选下载」挪进这里（手机端）。
        if (!rail && _tab == _discoverIndex && !_showRecommendations)
          const PopupMenuItem(value: 'catalog-sort', child: Text('排序与筛选')),
        if (!rail && _tab == _discoverIndex && widget.store.sources.isNotEmpty)
          const PopupMenuItem(value: 'open-rankings', child: Text('榜单')),
        if (!rail &&
            _tab == _discoverIndex &&
            !_showRecommendations &&
            widget.store.canDownload &&
            widget.repository.supportsDownloads)
          const PopupMenuItem(
            value: 'select-catalog-dramas',
            child: Text('多选下载'),
          ),
        if (_tab == _discoverIndex &&
            !_showRecommendations &&
            constraints.maxWidth < 400)
          PopupMenuItem(
            value: 'update',
            enabled:
                widget.store.sources.isNotEmpty &&
                !_group.sources.any((source) => _updater.busy(source.id)),
            child: const Text('更新剧库'),
          ),
        if (widget.repository.supportsSourceManagement)
          const PopupMenuItem(value: 'sources', child: Text('站源管理')),
        const PopupMenuItem(value: 'users', child: Text('用户管理')),
        const PopupMenuItem(value: 'settings', child: Text('设置与备份')),
        // 「界面模式」入口已隐藏（0.2.26）。
        //
        // 用户要求：下个版本仅保留手机版，暂停 TV 版。
        // 该入口用于手动在「自动/电视/手机」之间切换显示模式，
        // 隐藏后应用统一按手机版渲染（相关 TV 代码保留，不删除，
        // 便于日后恢复；见 JC-0002 与项目决策记录）。
        const PopupMenuItem(value: 'about', child: Text('关于$appName')),
      ],
    );
  }

  /// 桌面左侧栏（0.7.22；0.7.35 Glass Noir 改版）。
  ///
  /// 预览稿 D01/D06：侧栏与页面同底色，条目全部胶囊化——
  /// 选中 = 实心主色胶囊，顶部加果屿 logo；栏底「设置」保留。
  Widget _sidebar(List<Widget> actions) {
    final colors = Theme.of(context).colorScheme;
    // 0.7.28（用户要求）：
    // - 搜索挪到「发现」下面，榜单紧跟搜索；
    // - 「排序与筛选」「多选下载」「更新剧库」三个按钮删除；
    // - 「更多」换成「设置」，钉在栏底。
    final navItems = <(int, IconData, IconData, String)>[
      (
        _followIndex,
        Icons.bookmark_border_rounded,
        Icons.bookmark_rounded,
        '追剧',
      ),
      (_historyIndex, Icons.history_rounded, Icons.history_rounded, '最近观看'),
      if (widget.store.canDownload)
        (_downloadIndex, Icons.download_outlined, Icons.download_rounded, '下载'),
    ];
    return Container(
      width: _railWidth,
      // Row 默认 crossAxisAlignment.center，这里必须显式撑满高度，
      // 否则侧栏会变成一条内容高度的"浮条"。
      height: double.infinity,
      color: colors.surfaceContainerLowest,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 0.7.36（用户截图）：品牌行 = logo + 「果屿」横排。
                  // 侧栏 78px 很窄，整体 FittedBox 缩放防溢出。
                  // 0.7.45：Windows 下品牌行已抬进窗口标题栏，侧栏不再重复。
                  if (!_usesTitleBar)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        children: [
                          Image.asset(
                            'assets/branding/logo.png',
                            width: 26,
                            height: 26,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            appName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  // 0.7.36：站源选择从侧栏移到内容区顶部的胶囊行
                  // （用户截图：全部站源 / 红果 / … 横排胶囊）。
                  const SizedBox(height: 10),
                  _railNav(
                    index: _discoverIndex,
                    glyph: Icons.explore_outlined,
                    selectedGlyph: Icons.explore,
                    label: '推荐',
                  ),
                  _railNav(
                    key: const ValueKey('toggle-search'),
                    index: _findIndex,
                    glyph: Icons.search_rounded,
                    selectedGlyph: Icons.search_rounded,
                    label: '找剧',
                  ),
                  _railNav(
                    key: const ValueKey('open-rankings'),
                    index: _rankingsIndex,
                    glyph: Icons.leaderboard_outlined,
                    selectedGlyph: Icons.leaderboard_rounded,
                    label: '榜单',
                  ),
                  // 0.7.63：小说 / 听歌不再挂在看剧侧栏里——它们是一级模块，
                  // 入口统一在页面底端的切换条上，侧栏只留看剧自己的导航。
                  for (final item in navItems)
                    _railNav(
                      index: item.$1,
                      glyph: item.$2,
                      selectedGlyph: item.$3,
                      label: item.$4,
                    ),
                  // 0.7.55（用户要求）：站源选择收进侧栏入口，点击弹出菜单。
                  // 0.7.56（用户要求）：条目直接显示**当前站源名**
                  // （多选时 _group.name 已是「全部站源」/「红果+黄豆」），
                  // 悬停 tooltip 显示全名（条目只有 36 宽，长名会被省略）。
                  const SizedBox(height: 4),
                  Builder(
                    builder: (tileContext) => Tooltip(
                      message: _group.name,
                      child: _railTile(
                        key: const ValueKey('rail-sources'),
                        glyph: Icons.apps_rounded,
                        selectedGlyph: Icons.apps_rounded,
                        label: _group.name,
                        selected: false,
                        onTap: () => _pickSourceGroup(tileContext),
                      ),
                    ),
                  ),
                  // 选择模式下的「清空 / 取消」等临时动作。
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Divider(height: 1, color: colors.outlineVariant),
                    const SizedBox(height: 4),
                    for (final action in actions)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: SizedBox(
                          width: _railActionSize,
                          height: _railActionSize,
                          child: action,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
            child: SizedBox(
              width: _railActionSize,
              height: _railActionSize,
              child: _actionIcon(
                rail: true,
                key: const ValueKey('open-settings'),
                glyph: Icons.settings_rounded,
                tooltip: '设置',
                onPressed: _openSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openSettings() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) =>
          SettingsScreen(repository: widget.repository, store: widget.store),
    ),
  );

  /// 侧栏导航项：图标 + 小字标签，选中态用主色胶囊底。
  ///
  /// `key` 可覆盖默认的 `rail-nav-<index>`（找剧/榜单沿用旧 key，
  /// 免得测试与外部脚本按 key 找入口时失效）。
  Widget _railNav({
    Key? key,
    required int index,
    required IconData glyph,
    required IconData selectedGlyph,
    required String label,
  }) => _railTile(
    key: key ?? ValueKey('rail-nav-$index'),
    glyph: glyph,
    selectedGlyph: selectedGlyph,
    label: label,
    selected: _tab == index,
    onTap: () => _changeTab(index),
  );

  /// 侧栏通用条目（导航项与动作项共用同一套外观）。
  ///
  /// 0.7.35（预览稿 D06 侧栏三态）：选中 = 实心主色胶囊（图标/文字反白），
  /// 未选中默认透明、悬停用 `hoverFill` 浅深空底。
  Widget _railTile({
    required Key key,
    required IconData glyph,
    required IconData selectedGlyph,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    final disabled = onTap == null;
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(16),
      hoverColor: colors.surfaceContainerHigh,
      onTap: onTap,
      child: Container(
        height: 50,
        width: double.infinity,
        decoration: BoxDecoration(
          color: selected ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? selectedGlyph : glyph,
              size: 20,
              color: disabled
                  ? colors.onSurfaceVariant.withValues(alpha: .38)
                  : selected
                  ? colors.onPrimary
                  : colors.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              // 站源条目显示当前源名（0.7.56），可能比 36px 条目宽，
              // 超长省略而不是硬裁半个字。
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.05,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: disabled
                    ? colors.onSurfaceVariant.withValues(alpha: .38)
                    : selected
                    ? colors.onPrimary
                    : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 侧栏「站源」入口（0.7.55，用户要求）：站源胶囊移出标题栏后，
  /// 桌面端改从这里弹出菜单选择。语义与旧胶囊行完全一致：
  /// 「全部站源」= 选中所有源，单个分组 = 该分组的全部源。
  ///
  /// 0.7.58（用户要求）：站源只做**互斥单选**——去掉「全部站源」多选
  /// 入口，菜单里点谁就只启用谁，之前启用的站源自动让位。
  ///
  /// [anchor] 是侧栏条目的 context，菜单贴着它向右下展开。
  Future<void> _pickSourceGroup(BuildContext anchor) async {
    final colors = Theme.of(context).colorScheme;
    final groups = _sourceGroups;
    // 当前态：单选时勾在当前源上；多源聚合是旧版残留（新 UI 不再提供
    // 多选入口），此时不勾任何项，点任意一项即回到单选。
    final currentId = _multiSources.isEmpty ? _group.id : '';

    final box = anchor.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(anchor).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(
      Offset(box.size.width - 8, 0),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, topLeft.translate(240, box.size.height)),
      Offset.zero & overlay.size,
    );

    final entries = <(String, String)>[
      for (final group in groups) (group.id, group.name),
    ];
    final picked = await showMenu<String>(
      context: context,
      position: position,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(minWidth: 168, maxWidth: 240),
      items: [
        for (final entry in entries)
          PopupMenuItem<String>(
            key: ValueKey('source-menu-${entry.$1}'),
            value: entry.$1,
            height: 42,
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  child: entry.$1 == currentId
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: colors.primary,
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    entry.$2,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: entry.$1 == currentId
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked == null || picked == currentId) return;
    final ids = <String>[
      for (final site in widget.store.sources)
        if (site.groupId == picked) site.id,
    ];
    if (ids.isEmpty) return;
    if (!mounted) return;
    saveUserChange(context, () => _applyMultiSources(ids));
  }

  /// 站源胶囊行（0.7.36，用户截图）：内容区顶部横排——
  /// 各站源分组胶囊，选中项实心主色胶囊。
  ///
  /// 0.7.45：Windows 桌面端改成由窗口标题栏渲染（[_titleBarLeading]），
  /// 0.7.55：标题栏不再放胶囊，桌面端改走侧栏「站源」入口
  /// （[_pickSourceGroup]），这里只留给手机端/其它平台使用。
  /// 0.7.58（用户要求）：站源只做互斥单选，去掉「全部站源」多选胶囊。
  Widget _sourcePillRow() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 4, 24, 6),
    child: _sourcePills(),
  );

  /// Windows 标题栏左侧内容（0.7.45）：logo + 应用名。
  ///
  /// 0.7.55（用户要求）：站源胶囊从这里移走（顶栏不美观），
  /// 站源选择改为左侧栏「站源」入口弹出菜单。
  Widget _titleBarLeading() => Padding(
    padding: const EdgeInsets.only(left: 12, right: 10),
    child: Row(
      children: [
        TitleBarDragHandle(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/branding/logo.png', width: 22, height: 22),
              const SizedBox(width: 8),
              Text(
                appName,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
      ],
    ),
  );

  /// 模块页（小说 / 听歌）的窗口标题栏（0.7.62；0.7.63 起两个模块共用）。
  ///
  /// 看剧的品牌行（logo + 果屿）在这里换掉——模块是独立界面，
  /// 顶行不该再挂看剧的身份；窗口的最小化/最大化/关闭由标题栏自己保留。
  ///
  /// 0.7.64（用户要求）：**不再放返回箭头**。三个模块完全平级，
  /// 唯一的切换入口是页面底端那条按钮行，别处不出现第二个按钮。
  Widget _moduleTitleBarLeading() {
    final module = _currentModule;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Icon(
            module.selectedGlyph,
            size: 16,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          const SizedBox(width: 6),
          Text(
            module.label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  /// 站源胶囊横排本体。
  ///
  /// [compact] 用于窗口标题栏：胶囊矮一点（30px），文字略小，
  /// 保证 40px 的标题栏里不溢出。
  Widget _sourcePills({bool compact = false}) {
    final groups = _sourceGroups;
    final colors = Theme.of(context).colorScheme;
    // 0.7.58：互斥单选——单选时当前源高亮；多源聚合是旧版残留
    // （新 UI 不再提供多选入口），此时不亮任何胶囊。
    final currentId = _multiSources.isEmpty ? _group.id : '';
    Widget pill(String id, String label) {
      final selected = id == currentId;
      return InkWell(
        key: ValueKey('source-pill-$id'),
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          final ids = <String>[
            for (final site in widget.store.sources)
              if (site.groupId == id) site.id,
          ];
          if (ids.isEmpty) return;
          saveUserChange(context, () => _applyMultiSources(ids));
        },
        child: Container(
          height: compact ? 30 : 34,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.primary : colors.surfaceContainer,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: compact ? 12 : 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : colors.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final group in groups) ...[
            pill(group.id, group.name),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// 「找剧」页头部（0.7.31）。
  ///
  /// 版式对齐参考图：左边大标题「找剧」，右边搜索框 + 红色「搜索」按钮；
  /// 下面一行是「筛选：全部 … 展开筛选」，展开后是分组标签面板。
  Widget _findHeader() {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    // 桌面端（侧栏模式）不需要返回箭头与站源胶囊：侧栏已经有「推荐」和站源入口。
    final rail = size.width >= 840 && !AppLayout.isTelevision(context);
    final wide = size.width >= 620;
    final field = SearchInput(
      key: ValueKey('search-${_group.id}'),
      controller: _search,
      autofocus: true,
      hint: _searchHint,
      showSubmit: false,
      suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      onChanged: _searchChanged,
      onCancel: () => unawaited(widget.repository.cancelSuggestions()),
      onSearch: _submitSearch,
    );
    // 0.7.38（预览稿 D02）：搜索钮改为方形圆角蓝钮（画布里搜索栏尾部
    // 只有一个蓝色图标钮，不是带文字的胶囊）。tooltip 保留「搜索」语义。
    final submit = Tooltip(
      message: '搜索',
      child: Material(
        color: colors.primary,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('find-submit'),
          onTap: () => _submitSearch(_search.text),
          child: const SizedBox(
            width: 46,
            height: 46,
            child: Icon(Icons.search_rounded, size: 22, color: Colors.white),
          ),
        ),
      ),
    );
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 文字可收缩：320px + 2x 字号下标题会被挤压，必须允许省略。
        Flexible(
          child: Text(
            '找剧',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: colors.onSurface,
            ),
          ),
        ),
        // 0.7.38（预览稿 D02）：页头右侧的「排行榜」胶囊入口。
        // 窄屏（<480）整组不显示，避免与站源胶囊抢宽度。
        if (size.width >= 480) ...[
          const SizedBox(width: 10),
          InkWell(
            key: const ValueKey('find-rankings'),
            borderRadius: BorderRadius.circular(999),
            onTap: _openRankings,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppTheme.hoverFill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppTheme.cardStroke),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.leaderboard_rounded,
                    size: 15,
                    color: AppTheme.starlight,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '排行榜',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
    final searchRow = Row(
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        submit,
      ],
    );
    // 手机端顶栏被撤掉后，站源切换就落在这个胶囊上（桌面端侧栏已有入口）。
    final sourceChip = widget.store.sources.isEmpty
        ? const SizedBox.shrink()
        : InkWell(
            key: const ValueKey('find-source'),
            borderRadius: BorderRadius.circular(999),
            onTap: _openSourceSheet,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 108),
                    child: Text(
                      _group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          );
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: rail
                ? // 0.7.35（预览稿 D02）：桌面侧栏模式下搜索框**独占一行、
                  // 全宽 46px**，不再挤在标题右侧（预览稿里它是一整条
                  // 深空搜索栏 + 右端蓝色搜索钮）。
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [title]),
                      const SizedBox(height: 10),
                      SizedBox(height: 46, child: searchRow),
                    ],
                  )
                : wide
                ? Row(
                    children: [
                      title,
                      const SizedBox(width: 24),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: searchRow,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('find-back'),
                            tooltip: '返回推荐',
                            onPressed: _leaveFind,
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              size: 22,
                            ),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(36, 36),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          const SizedBox(width: 2),
                          // 0.7.38：窄屏隐藏「排行榜」胶囊并允许标题收缩，
                          // 否则 320 宽度下会横向溢出（实测 53px）。
                          Flexible(child: title),
                          const Spacer(),
                          if (!rail) sourceChip,
                        ],
                      ),
                      const SizedBox(height: 8),
                      searchRow,
                    ],
                  ),
          ),
          if (_search.text.trim().isEmpty &&
              widget.store.recentSearches.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final query in widget.store.recentSearches)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                avatar: const Icon(
                                  Icons.history_rounded,
                                  size: 16,
                                ),
                                label: Text(query),
                                onPressed: () => _submitSearch(query),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '清空最近搜索',
                    onPressed: () => saveUserChange(
                      context,
                      widget.store.clearRecentSearches,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  ),
                ],
              ),
            ),
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            padding: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.outlineVariant, width: .6),
              ),
            ),
            child: Row(
              children: [
                Text(
                  '筛选：',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Text(
                    _filterSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('toggle-filters'),
                  onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _filtersOpen ? '收起' : '展开筛选',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      Icon(
                        _filtersOpen
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_filtersOpen) _filterPanel(),
        ],
      ),
    );
  }

  /// 展开后的筛选面板：体裁 / 推荐 / 状态 / 时间 / 标签（0.7.31）。
  ///
  /// 只放**站源真有的维度**——参考图里的「主题 / 设定 / 背景 / 受众」我们没有
  /// 对应数据，摆上去就是点不动的死按钮，所以不摆。
  Widget _filterPanel() {
    final colors = Theme.of(context).colorScheme;
    // 站源分类里第一个通常是「全部」，id 为空串；这里再补一个「全部」会撞 key，
    // 所以按 id 去重（0.7.31 首版就这么踩了一次）。
    final seen = <String>{''};
    final categoryOptions = <(String, String)>[('', '全部')];
    for (final entry in _displayCategories) {
      if (entry.id.startsWith('app:')) continue;
      if (seen.add(entry.id)) categoryOptions.add((entry.id, entry.name));
    }
    final tags = _availableTags;
    final sort = widget.store.catalogView.sort;
    final rows = <Widget>[
      _facetRow('体裁', categoryOptions, _displayCategory, (value) {
        if (value == _displayCategory) return;
        _changeCategory(value);
      }),
      _facetRow(
        '推荐',
        const [
          (CatalogSort.source, '默认'),
          (CatalogSort.date, '最新上架'),
          (CatalogSort.heat, '最高热度'),
          (CatalogSort.views, '最高播放'),
        ],
        sort,
        (value) {
          if (value == sort) return;
          unawaited(
            saveUserChange(
              context,
              () => widget.store.setCatalogView(
                widget.store.catalogView.copyWith(sort: value),
              ),
            ),
          );
        },
      ),
      _facetRow(
        '状态',
        const [('', '全部'), ('finished', '已完结'), ('ongoing', '连载中')],
        _statusFilter,
        (value) => setState(() => _statusFilter = value),
      ),
      _facetRow(
        '时间',
        const [
          (0, '全部'),
          (7, '7天内上新'),
          (14, '14天内上新'),
          (30, '30天内上新'),
          (90, '90天内上新'),
        ],
        _daysFilter,
        (value) => setState(() => _daysFilter = value),
      ),
      if (tags.isNotEmpty)
        _facetRow(
          '标签',
          [('', '全部'), for (final tag in tags) (tag, tag)],
          _tagFilter,
          (value) => setState(() => _tagFilter = value),
        ),
    ];
    return Container(
      key: const ValueKey('find-filters'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .7)),
      ),
      child: Column(
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0)
              Divider(
                height: 1,
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            row,
          ],
        ],
      ),
    );
  }

  Widget _facetRow<T extends Object>(
    String label,
    List<(T, String)> options,
    T selected,
    ValueChanged<T> onSelect,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 12),
            child: SizedBox(
              width: 30,
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (value, text) in options)
                  _facetChip(
                    // 「全部」的值是空串（时间行是 0），统一记作 all，
                    // 免得 key 变成 `facet-状态-` 这种半截东西。
                    label: _facetKey(label, value),
                    text: text,
                    selected: value == selected,
                    // 再点一次选中项＝回到「全部」。
                    onTap: () => onSelect(
                      value == selected ? (options.first.$1) : value,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选胶囊的稳定 key（供测试与无障碍定位用）。
  String _facetKey(String row, Object value) {
    final raw = '$value';
    return 'facet-$row-${raw.isEmpty || raw == '0' ? 'all' : raw}';
  }

  Widget _facetChip({
    required String label,
    required String text,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey(label),
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: .08) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? colors.primary
                : colors.outlineVariant.withValues(alpha: .9),
            width: selected ? 1 : .8,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.25,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _catalog({required bool selectionInBody}) {
    final television = AppLayout.isTelevision(context);
    final items = _visible;
    final rail = MediaQuery.sizeOf(context).width >= 840 && !television;
    // 0.7.36（用户截图 D01）：桌面推荐页取目录第一部做「本周主推」横幅，
    // 网格上方加「大家都在看 · 查看全部」标题行（查看全部 → 找剧页）。
    Widget? banner;
    if (rail && !_showRecommendations && items.isNotEmpty) {
      final featured = items.first;
      banner = Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
        child: FeaturedBanner(
          drama: featured,
          repository: widget.repository,
          onPlay: () => _openDrama(featured, resume: true),
          onDetail: () => _openDrama(featured),
        ),
      );
    }
    return Column(
      children: [
        // 0.7.36：站源切换入口统一为顶部胶囊行（侧栏里已移除）。
        // 0.7.45：Windows 桌面端已抬进窗口标题栏，这里不再重复渲染。
        if (rail && !_usesTitleBar) _sourcePillRow(),
        CatalogFilters(
          key: ValueKey('filters-${_group.id}'),
          categories: _displayCategories,
          category: _displayCategory,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: _supportsVipFilter
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                      onPressed: () => saveUserChange(
                        context,
                        () => widget.store.setHideVip(!widget.store.hideVip),
                      ),
                      icon: VipIcon(hidden: widget.store.hideVip),
                    ),
                  ],
                )
              : null,
        ),
        if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                embedded: true,
                onBrowseAll: rail ? () => _changeTab(_findIndex) : null,
              ),
            ),
          )
        else
          ..._catalogBody(
            items: items,
            television: television,
            selectionInBody: selectionInBody,
            banner: banner,
            onBrowseAll: rail ? () => _changeTab(_findIndex) : null,
          ),
      ],
    );
  }

  /// 找剧页（0.7.31 新增；0.7.32 按用户要求改为**独立页面**）。
  ///
  /// 「独立页面」指与推荐页没有共用版式：
  /// - 进入后不再显示推荐页那条顶栏（手机端 AppBar 直接隐藏，见 build）；
  /// - 头部只属于本页：返回 + 「找剧」+ 站源 + 搜索框 + 筛选摘要/面板；
  /// - 正文复用 [_catalogBody]，网格、加载更多、空态、错误条保持一致。
  Widget _findPage({required bool selectionInBody}) {
    final television = AppLayout.isTelevision(context);
    final items = _visible;
    final rail = MediaQuery.sizeOf(context).width >= 840 && !television;
    return Column(
      children: [
        // 0.7.36：站源切换入口统一为顶部胶囊行（侧栏里已移除）。
        // 0.7.45：Windows 桌面端已抬进窗口标题栏，这里不再重复渲染。
        if (rail && !_usesTitleBar) _sourcePillRow(),
        _findHeader(),
        ..._catalogBody(
          items: items,
          television: television,
          selectionInBody: selectionInBody,
        ),
      ],
    );
  }

  /// 目录正文（更新状态 / 进度条 / 错误条 / 空态 / 网格 / 选择条）。
  ///
  /// 0.7.32 从 `_catalog` 抽出：推荐页与找剧页各自组装头部，正文共用一份，
  /// 避免两套网格逻辑各自演化。
  /// 0.7.36：桌面推荐页可传入 [banner]（主推横幅）与 [onBrowseAll]
  /// （「大家都在看 · 查看全部」标题行），插在网格上方。
  List<Widget> _catalogBody({
    required List<Drama> items,
    required bool television,
    required bool selectionInBody,
    Widget? banner,
    VoidCallback? onBrowseAll,
  }) => [
    if (widget.repository.supportsSourceManagement &&
        (_updateNotice ||
            _group.sources.any((source) => _updater.busy(source.id))))
      _updateStatus(),
    if (_loading && _items.isNotEmpty)
      const LinearProgressIndicator(minHeight: 2),
    if (_error != null && _items.isNotEmpty)
      Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: _loading || _loadingMore
                  ? null
                  : () => _load(more: _failedMore, force: true),
              child: const Text('重试'),
            ),
            if (widget.repository.supportsSourceManagement)
              IconButton(
                tooltip: '站源诊断',
                onPressed: _manageSources,
                icon: const Icon(Icons.network_check),
              ),
          ],
        ),
      ),
    Expanded(
      child: GestureDetector(
        onHorizontalDragEnd: television ? null : _swipeCategory,
        child: _loading && _items.isEmpty
            ? const DramaGridSkeleton()
            : _items.isEmpty && _error != null
            ? StatusPanel(
                title: '暂时无法加载',
                message: _error!,
                onRetry: () => _load(force: true),
                secondaryAction: widget.repository.supportsSourceManagement
                    ? TextButton(
                        onPressed: _manageSources,
                        child: const Text('站源诊断'),
                      )
                    : null,
                icon: Icons.wifi_off_rounded,
              )
            : items.isEmpty
            ? StatusPanel(
                title: '没有找到匹配的短剧',
                message: _hideVip
                    ? '可以换个搜索词，或显示 VIP 内容。'
                    : widget.store.sources.length > 1
                    ? '可以换个搜索词或切换站源。'
                    : '可以换个搜索词，或刷新后重试。',
                onRetry:
                    _hasMore &&
                        !_loadingMore &&
                        (!_onlineSearch ||
                            _search.text.isEmpty ||
                            _group.sources.any((source) => source.pagedSearch))
                    ? () => _load(more: true)
                    : null,
                action: '加载更多',
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  if (television) {
                    return _televisionGrid(
                      items,
                      constraints.maxWidth,
                      key: 'catalog-${_group.id}-$_category-$_submittedQuery',
                      controller: _scroll,
                      footer: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                        child: Center(
                          child: _loadingMore
                              ? const LoadingHint(
                                  message: '正在加载更多剧集…',
                                  compact: true,
                                )
                              : _hasMore
                              ? RemoteButton(
                                  label: '加载更多',
                                  icon: Icons.expand_more,
                                  onPressed: () => _load(more: true),
                                )
                              : const Text('已经看到这里的全部剧集'),
                        ),
                      ),
                    );
                  }
                  final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
                  return RefreshIndicator(
                    onRefresh: _refreshCatalog,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // 0.7.36（用户截图 D01）：桌面推荐页网格上方插
                        // 主推横幅 + 「大家都在看 · 查看全部」标题行。
                        if (banner != null) SliverToBoxAdapter(child: banner!),
                        if (banner != null && onBrowseAll != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                              child: Row(
                                children: [
                                  Text(
                                    '大家都在看',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    key: const ValueKey('browse-all'),
                                    onPressed: onBrowseAll,
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    child: const Text('查看全部'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
                          sliver: SliverGrid(
                            gridDelegate: dramaGridDelegate(
                              context,
                              constraints.maxWidth - 2 * padding,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (_, index) => _catalogTile(items[index]),
                              childCount: items.length,
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Center(
                              child: _loadingMore
                                  ? const LoadingHint(
                                      message: '正在加载更多剧集…',
                                      compact: true,
                                    )
                                  : _hasMore
                                  ? OutlinedButton.icon(
                                      onPressed: () => _load(more: true),
                                      icon: const Icon(
                                        Icons.expand_more_rounded,
                                      ),
                                      label: const Text('加载更多'),
                                    )
                                  : Text(
                                      '已经看到这里的全部剧集',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ),
    if (_selectionMode && selectionInBody) _selectionBar(safeBottom: false),
  ];

  /// 页面底端：（桌面/电视）模块切换条 +（手机端）看剧自己的底部导航。
  ///
  /// 0.7.63：底端常驻「看剧 / 小说 / 听歌」切换条。0.7.74（用户要求）：
  /// 手机端底部出现「底栏 + 切换条」两排太挤——手机改成**顶栏紧凑切换**
  /// （[_headerActions]），底栏回归单排；小说/听歌页的切换入口在它们自己
  /// 的头部（[NovelHomeScreen.headerActions] / [MusicHomeScreen.headerActions]）。
  /// 桌面/电视没有顶栏操作区，仍保留底端切换条。
  Widget? _bottomArea({required bool desktop, required bool television}) {
    // 批量选择时底端换成操作条，切换条暂时让位，免得误触切走。
    if (_selectionMode) {
      return desktop || television ? null : _selectionBar();
    }
    if (!desktop && !television) {
      // 手机：小说/听歌模块页有自己的头部切换，底端什么都不放。
      if (_moduleMode) return null;
      return SafeArea(
        top: false,
        child: AppBottomNavigation(
          // `AppBottomNavigation` 用的是**位置**而不是标签下标，
          // 所以这里要按 `_bottomTabs` 做一次映射，否则加进「找剧」后
          // 点「追剧」会跳到找剧去。
          selectedIndex: _bottomTabs.indexOf(_tab),
          onDestinationSelected: (position) =>
              _changeTab(_bottomTabs[position]),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.explore_outlined),
              selectedIcon: const Icon(Icons.explore),
              label: '推荐',
            ),
            NavigationDestination(
              icon: const Icon(Icons.search_rounded),
              selectedIcon: const Icon(Icons.search_rounded),
              label: '找剧',
            ),
            NavigationDestination(
              icon: const Icon(Icons.bookmark_border_rounded),
              selectedIcon: const Icon(Icons.bookmark_rounded),
              label: '追剧',
            ),
            NavigationDestination(
              icon: const Icon(Icons.history_rounded),
              label: '最近观看',
            ),
            if (widget.store.canDownload)
              NavigationDestination(
                icon: const Icon(Icons.download_outlined),
                selectedIcon: const Icon(Icons.download_rounded),
                label: '下载',
              ),
          ],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: ModuleSwitchBar(
        current: _currentModule,
        onChanged: _onModuleChanged,
      ),
    );
  }

  /// 底端切换条的回调：看剧 = 回进入前的标签，小说/听歌 = 进对应模块。
  void _onModuleChanged(AppModule module) {
    if (module == AppModule.watch) {
      if (_moduleMode) _exitModule();
      return;
    }
    _enterModule(module == AppModule.novel ? _novelIndex : _musicIndex);
  }

  Widget _selectionBar({bool safeBottom = true}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: safeBottom,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final summary = Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      count == 0
                          ? '最多 ${BatchDownloads.maxDramas} 部'
                          : '下一步选择分集和画质',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
              final next = FilledButton(
                key: const ValueKey('download-selected-dramas'),
                onPressed: count == 0 ? null : _downloadSelected,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text('下一步'),
              );
              if (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [summary, const SizedBox(height: 12), next],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 16),
                  next,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _updateStatus() {
    final sources = _group.sources;
    final busy = sources.any((source) => _updater.busy(source.id));
    final messages = <String>[];
    var failed = false;
    for (final source in sources) {
      final status = _updater.status(source.id);
      final error = [
        _updater.error(source.id),
        status?.error ?? '',
        status?.storageError ?? '',
      ].where((value) => value.isNotEmpty).toSet().join('；');
      if (error.isNotEmpty) {
        failed = true;
        messages.add('${source.name}：$error');
      } else if (status != null) {
        messages.add(
          '${source.name}：${status.stage.isEmpty ? '准备更新' : status.stage}'
          '${status.total > 0 ? ' ${status.completed}/${status.total}' : ''}'
          '${!status.running && status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
        );
      } else if (busy) {
        messages.add('${source.name}：正在启动');
      }
    }
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: failed ? colors.errorContainer : colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                messages.isEmpty ? '准备更新剧库' : messages.join('；'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: failed ? colors.onErrorContainer : colors.onSurface,
                ),
              ),
            ),
            if (busy)
              TextButton(
                onPressed: () => _updater.stop(sources),
                child: const Text('停止'),
              ),
            IconButton(
              tooltip: '查看更新详情',
              onPressed: _manageSources,
              icon: const Icon(Icons.info_outline_rounded, size: 20),
            ),
            if (!busy)
              IconButton(
                tooltip: '收起更新提示',
                onPressed: () => setState(() => _updateNotice = false),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    required String key,
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: ValueKey('tv-grid-$key'),
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}

/// 站源选择弹窗（0.6.11 新增；0.7.58 改互斥单选）。
///
/// 用户反馈原下拉菜单"点一下就修改、多选要多点很多次"，0.6.11 曾改为
/// 弹窗内自由勾选、按「确定」才生效；0.7.58（用户要求）站源只做互斥
/// 单选——恢复"点一下立即切换"，列表每项点中即 `Navigator.pop(id)`，
/// 不再有勾选集合与全选/清空/确定按钮。
class _SourcePickerSheet extends StatelessWidget {
  const _SourcePickerSheet({required this.groups, required this.currentId});

  final List<SourceGroup> groups;

  /// 当前单选生效的分组 id；多源聚合残留态为 null（不标高亮）。
  final String? currentId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '选择站源',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.45,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final group in groups)
                      ListTile(
                        key: ValueKey('source-sheet-${group.id}'),
                        dense: true,
                        leading: group.id == currentId
                            ? Icon(Icons.check_rounded, color: accent)
                            : const SizedBox(width: 24),
                        title: Text(
                          group.name,
                          style: TextStyle(
                            fontWeight: group.id == currentId
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(group.id),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
