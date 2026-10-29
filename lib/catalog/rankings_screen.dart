import 'package:flutter/material.dart';

import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/ui/detail_screen.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/catalog/ranking_models.dart';
import 'package:duanju_app/ui/widgets.dart';

/// 排行榜（0.7.31 重构）。
///
/// 用户要求：**不再跳到新页面**，改成和搜索一样在同一个页面里显示，
/// 榜单名竖排在内容**左侧**（对齐参考图的版式）：
///
/// ```
/// 红果 | 青空次元 | 韩小圈   ← 顶部一行切站源
/// ─────────────────────────────────────────
/// 推荐榜     │ 推荐榜  10月26日已更新 · 说明文字      ⟳
/// 热播榜     │ ① 封面  剧名 + 徽标 …………  [播放][详情]
/// 新剧榜     │ ② 封面  …
/// ```
///
/// 左列放的是**当前站源真实存在的榜单**（拿不到「演员榜」这种就不摆出来），
/// 而不是照抄参考图里固定九项、点不动的空榜。
class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.initialGroup,
    this.embedded = false,
    this.onPlay,
    this.onOpen,
  });

  final AppRepository repository;
  final LocalStore store;
  final String initialGroup;

  /// 嵌在其它页面里（无自己的 Scaffold / AppBar）。
  final bool embedded;

  /// 点「播放」：直接开播。为空时退化为打开详情。
  final ValueChanged<Drama>? onPlay;

  /// 点「详情」：打开详情页。为空时自己 push 详情页。
  final ValueChanged<Drama>? onOpen;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scroll = ScrollController();
  List<RankingBoard> _boards = [];
  RankingBoard? _board;
  List<RankingItem> _items = [];
  bool _loading = true;
  bool _more = false;
  bool _hasMore = false;
  bool _failedMore = false;
  int _page = 1;
  int _generation = 0;
  String? _error;
  String _updated = '';

  @override
  void initState() {
    super.initState();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _initialize();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  void _metadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final boards = (await widget.repository.rankingBoards())
          .where((board) => widget.store.allowsSource(board.source))
          .toList();
      if (!mounted || generation != _generation) return;
      setState(() {
        _boards = boards;
        _board =
            boards
                .where((board) => board.groupId == widget.initialGroup)
                .firstOrNull ??
            boards.firstOrNull;
        _loading = false;
      });
      if (_board != null) await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    final board = _board;
    if (board == null || more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = false;
    });
    try {
      final result = await widget.repository.rankings(
        board.id,
        page: more ? _page + 1 : 1,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final rows = <String, RankingItem>{
          if (more)
            for (final item in _items) item.drama.id: item,
          for (final item in result.items) item.drama.id: item,
        };
        _items = rows.values.toList()..sort((a, b) => a.rank.compareTo(b.rank));
        _page = result.page;
        _hasMore = result.hasMore;
        _updated = result.updatedText;
        _error = result.warning.isEmpty ? null : result.warning;
        _loading = false;
        _more = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString();
          _failedMore = more;
          _loading = false;
          _more = false;
        });
      }
    }
  }

  void _select(RankingBoard board) {
    if (_board?.id == board.id) return;
    setState(() {
      _board = board;
      _items = [];
      _updated = '';
      _page = 1;
      _hasMore = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _play(Drama drama) {
    if (widget.onPlay != null) {
      widget.onPlay!(drama);
      return;
    }
    _open(drama);
  }

  void _open(Drama drama) {
    if (widget.onOpen != null) {
      widget.onOpen!(drama);
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('榜单')),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _body(BuildContext context) {
    final groups = SourceGroup.fromSources(
      _boards.map((board) => SourceSite.byId(board.source)).toSet(),
    );
    final boards = _boards
        .where((board) => board.groupId == _board?.groupId)
        .toList();
    final items = _items
        .map(
          (item) => RankingItem(
            item.rank,
            widget.repository.catalogUpdates.current(item.drama),
            metric: item.metric,
          ),
        )
        .where((item) => widget.store.allowsSource(item.drama.source))
        .toList();
    return Column(
      children: [
        if (groups.length > 1) _groupTabs(groups),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (boards.length > 1) ...[
                _boardColumn(boards),
                VerticalDivider(
                  width: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ],
              Expanded(
                child: Column(
                  children: [
                    if (_board != null) _header(items.length),
                    if (_loading && items.isNotEmpty)
                      const LinearProgressIndicator(minHeight: 2),
                    if (_error != null && items.isNotEmpty) _warning(),
                    Expanded(child: _list(context, items)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部站源切换（有多个分组时才显示）。
  Widget _groupTabs(List<SourceGroup> groups) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final group in groups)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: InkWell(
                  key: ValueKey('ranking-group-${group.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    final board = _boards
                        .where((board) => board.groupId == group.id)
                        .firstOrNull;
                    if (board != null) _select(board);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: group.id == _board?.groupId
                          ? colors.primaryContainer
                          : null,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      group.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: group.id == _board?.groupId
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: group.id == _board?.groupId
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 左列榜单名（参考图左侧那一竖排）。
  Widget _boardColumn(List<RankingBoard> boards) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 132,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        children: [
          for (final board in boards)
            InkWell(
              key: ValueKey('ranking-board-${board.id}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _select(board),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  color: board.id == _board?.id
                      ? colors.primaryContainer.withValues(alpha: .55)
                      : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  board.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: board.id == _board?.id
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: board.id == _board?.id
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 右栏标题行：榜名 + 更新时间 + 说明，右侧是刷新。
  Widget _header(int count) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _board!.name,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                [
                  if (_updated.isNotEmpty) '$_updated已更新',
                  if (_board!.description.isNotEmpty) _board!.description,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: Text(
                '共 $count 部',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          IconButton(
            key: const ValueKey('ranking-refresh'),
            tooltip: '更新榜单',
            onPressed: _loading || _more
                ? null
                : () => _load(force: true),
            icon: Icon(
              Icons.refresh_rounded,
              size: 20,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _warning() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
        TextButton(
          onPressed: _loading || _more
              ? null
              : () => _load(more: _failedMore, force: true),
          child: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _list(BuildContext context, List<RankingItem> items) {
    if (_loading && items.isEmpty) {
      return const LoadingHint(message: '正在获取榜单…');
    }
    if (items.isEmpty) {
      return StatusPanel(
        title: _error == null ? '暂无榜单内容' : '榜单暂时无法加载',
        message: _error ?? '当前站源暂无可显示的榜单。',
        onRetry: _board == null ? _initialize : () => _load(force: true),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView.builder(
        key: ValueKey('ranking-${_board!.id}'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 0, 12, 24),
        itemCount: items.length + 1,
        itemBuilder: (context, index) {
          if (index == items.length) {
            return Center(
              child: _more
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: LoadingHint(
                        message: '正在加载更多…',
                        compact: true,
                      ),
                    )
                  : _hasMore
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: OutlinedButton(
                        onPressed: () => _load(more: true),
                        child: const Text('加载更多'),
                      ),
                    )
                  : const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('已显示全部榜单'),
                    ),
            );
          }
          return _row(context, items[index]);
        },
      ),
    );
  }

  /// 单条榜单（参考图版式）：序号 → 封面 → 标题/徽标/简介/数据 → 播放·详情。
  Widget _row(BuildContext context, RankingItem item) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final drama = item.drama;
    final badges = <String>[
      if (drama.category.isNotEmpty) drama.category,
      if (drama.episodes > 0) '全 ${drama.episodes} 集',
      ...drama.tags.take(2),
    ];
    final intro = drama.description.trim();
    return InkWell(
      key: ValueKey('rank-${item.rank}-${drama.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(drama),
      onFocusChange: (focused) {
        if (focused) Scrollable.ensureVisible(context, alignment: .4);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${item.rank}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: item.rank <= 3 ? 26 : 22,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    color: item.rank <= 3
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: .75),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 74,
              height: 104,
              child: DramaCover(
                drama: drama,
                repository: widget.repository,
                radius: 8,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  if (badges.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (final badge in badges)
                            Text(
                              badge,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (intro.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        intro,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (item.metric.isNotEmpty ||
                      drama.heat.isNotEmpty ||
                      drama.views.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (item.metric.isNotEmpty)
                            _stat(colors.primary, '🔥 ${item.metric}'),
                          if (drama.heat.isNotEmpty &&
                              drama.heat != item.metric)
                            _stat(
                              colors.onSurfaceVariant,
                              '热度 ${drama.heat}',
                            ),
                          if (drama.views.isNotEmpty)
                            _stat(colors.onSurfaceVariant, '${drama.views}播放'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: AppLayout.isTelevision(context) ? 96 : 84,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    key: ValueKey('rank-play-${drama.id}'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size.fromHeight(30),
                      textStyle: const TextStyle(fontSize: 12.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _play(drama),
                    child: const Text('播放'),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    key: ValueKey('rank-detail-${drama.id}'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size.fromHeight(30),
                      textStyle: const TextStyle(fontSize: 12.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _open(drama),
                    child: const Text('详情'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(Color color, String text) => Text(
    text,
    style: TextStyle(fontSize: 12, color: color),
  );
}
