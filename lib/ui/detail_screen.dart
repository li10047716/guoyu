import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/downloads/download_picker.dart';
import 'package:duanju_app/downloads/downloads_screen.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/ui/remote_widgets.dart';
import 'package:duanju_app/ui/widgets.dart';
import 'package:duanju_app/catalog/sources_screen.dart';
import 'package:duanju_app/catalog/episode_browser.dart';
import 'package:duanju_app/core/follow_state.dart';
import 'package:duanju_app/player/vertical_feed_screen.dart';

/// 面板模式下"播放某一集"的委托（0.7.25）。
///
/// 面板是从播放器里滑出来的，点某一集不该再 push 一层播放器
/// （那会出现两个播放器实例同时活着、声音叠在一起），
/// 而是让宿主原地换集，因此必须把动作交回宿主。
typedef DetailPlayRequest = void Function(int index, {required bool resume});

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.resumeOnOpen = false,
    this.downloadOnOpen = false,
    this.panelMode = false,
    this.initialDetail,
    this.onPlay,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;
  final bool downloadOnOpen;

  /// true = 作为右侧面板嵌在播放器里（0.7.25）。
  ///
  /// 与整页模式的区别只有两处：顶部换成紧凑标题栏（关闭按钮，无返回箭头）、
  /// 播放交给 [onPlay] 而不是 push 新路由。
  final bool panelMode;

  /// 调用方已经拉到的剧集数据，传入后省掉一次重复请求
  /// （否则面板一打开会先闪一下"正在获取剧集列表…"）。
  final DramaDetail? initialDetail;

  /// 非空时由宿主接手播放（见 [DetailPlayRequest]）。
  final DetailPlayRequest? onPlay;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  DramaDetail? _detail;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  int _episodePage = 0;
  int? _locatedNumber;
  bool _expandedDescription = false;
  final _episodeAnchor = GlobalKey();
  final _detailScroll = ScrollController();
  bool _initialActionHandled = false;
  late final int _profileEpoch;
  Widget? get _sourceDiagnostics => widget.repository.supportsSourceManagement
      ? SourceDiagnosticsButton(
          repository: widget.repository,
          store: widget.store,
          drama: widget.drama,
        )
      : null;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    widget.store.addListener(_onStoreChanged);
    final seeded = widget.initialDetail;
    if (seeded == null) {
      _load();
    } else {
      // 面板模式：宿主刚拉过一次详情，直接复用，不再重复请求。
      _detail = seeded;
      _loading = false;
      _error = null;
      _episodePage =
          resumeEpisodeIndex(
            seeded.episodes,
            widget.store.watched(seeded.drama.id),
          ) ~/
          episodePageSize;
    }
  }

  @override
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    _detailScroll.dispose();
    widget.store.removeListener(_onStoreChanged);
    _generation++;
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.repository.detail(widget.drama);
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final merged = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(detail.drama);
      setState(() {
        _detail = DramaDetail(merged, detail.episodes, warning: detail.warning);
        _loading = false;
        _episodePage =
            resumeEpisodeIndex(
              detail.episodes,
              widget.store.watched(merged.id),
            ) ~/
            episodePageSize;
      });
      widget.repository.catalogUpdates.publish(merged, retryCover: true);
      unawaited(_supplement(merged, generation));
      await saveUserChange(context, () => widget.store.refreshDrama(merged));
      if (mounted &&
          generation == _generation &&
          _profileEpoch == widget.store.profileEpoch &&
          !_initialActionHandled &&
          detail.episodes.isNotEmpty) {
        _initialActionHandled = true;
        if (widget.resumeOnOpen) {
          unawaited(
            _play(
              resumeEpisodeIndex(
                detail.episodes,
                widget.store.watched(merged.id),
              ),
              resume: true,
            ),
          );
        } else if (widget.downloadOnOpen && widget.store.canDownload) {
          unawaited(_download());
        }
      }
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
      widget.repository.catalogUpdates.publish(
        widget.repository.catalogUpdates.current(widget.drama),
        retryCover: true,
      );
    }
  }

  Future<void> _supplement(Drama drama, int generation) async {
    try {
      final fresh = await widget.repository.supplementMetadata(drama);
      if (!mounted ||
          generation != _generation ||
          fresh == null ||
          _detail == null) {
        return;
      }
      final updated = _detail!.drama.merge(fresh);
      setState(() {
        _detail = DramaDetail(
          updated,
          _detail!.episodes,
          warning: _detail!.warning,
        );
      });
      widget.repository.catalogUpdates.publish(updated);
      await saveUserChange(context, () => widget.store.refreshDrama(updated));
    } catch (_) {}
  }

  Future<void> _download() async {
    final detail = _detail;
    if (detail == null ||
        !widget.store.canDownload ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    final selection = await Navigator.of(context).push<DownloadSelection>(
      MaterialPageRoute(
        builder: (_) => DownloadPicker(
          detail: detail,
          preferences: widget.store.downloadPreferences,
        ),
      ),
    );
    if (selection == null ||
        !mounted ||
        !widget.store.canDownload ||
        _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    try {
      final added = await widget.repository.enqueueDownloads(
        detail,
        selection.episodes,
        quality: selection.quality,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
          action: SnackBarAction(
            label: '查看',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DownloadsScreen(
                    repository: widget.repository,
                    store: widget.store,
                  ),
                ),
              );
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _play(int index, {bool resume = false}) async {
    final detail = _detail;
    if (detail == null ||
        index < 0 ||
        index >= detail.episodes.length ||
        _profileEpoch != widget.store.profileEpoch ||
        !widget.store.allowsSource(detail.drama.source)) {
      return;
    }
    if (detail.episodes[index].vip) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这是一集 VIP 内容'),
          content: const Text('站源可能只提供试看或限制播放。'),
          actions: [
            TextButton(
              autofocus: AppLayout.isTelevision(context),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('尝试播放'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) {
        return;
      }
    }
    final handoff = widget.onPlay;
    if (handoff != null) {
      // 面板模式（0.7.25）：播放交给宿主（播放器页）原地换集。
      // 先关掉面板，否则用户会在面板后面听到换集后的声音、却看不到画面。
      final navigator = Navigator.of(context);
      if (widget.panelMode) navigator.pop();
      handoff(index, resume: resume);
      return;
    }
    final saved = widget.store.watched(detail.drama.id);
    final position =
        resume &&
            saved?.episode == detail.episodes[index].number &&
            !saved!.finished
        ? saved.position
        : 0.0;
    if (!mounted || _profileEpoch != widget.store.profileEpoch) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        // 0.2.29：详情页点播放改为竖屏上滑/下滑式播放器（与首页同一套 UI）。
        //
        // 进入的是"单剧模式"：只在这部剧内滑动，
        // 上滑 = 下一集、下滑 = 上一集，到首/尾集只提示、不跳到别的剧。
        builder: (_) => VerticalFeedScreen(
          repository: widget.repository,
          store: widget.store,
          singleDrama: detail.drama,
          initialEpisodeIndex: index,
          initialPosition: position,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final drama = _detail?.drama ?? widget.drama;
    final watched = widget.store.watched(drama.id);
    final episodes = _detail?.episodes ?? <Episode>[];
    final television = AppLayout.isTelevision(context);
    final allowed =
        widget.store.profileEpoch == _profileEpoch &&
        widget.store.allowsSource(drama.source);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          // 面板模式（0.7.25）：标题栏矮一些，且**不显示返回箭头**——
          // 面板是滑出来的浮层，右上角有关闭按钮，返回箭头会让人以为还有上一页。
          toolbarHeight: widget.panelMode ? 52 : (television ? 64 : null),
          automaticallyImplyLeading: !widget.panelMode,
          title: Text(drama.title, overflow: TextOverflow.ellipsis),
          actions: [
            RefreshAction(
              loading: _loading,
              tooltip: '更新剧集信息',
              onPressed: allowed ? _load : null,
            ),
            if (widget.panelMode)
              IconButton(
                key: const ValueKey('detail-panel-close'),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!allowed) {
                    return const StatusPanel(
                      title: '当前用户无权访问',
                      message: '请返回剧库后重新选择。',
                    );
                  }
                  if (television) {
                    // 电视端保留「上下两段」（0.7.24）：信息段自身可滚动 +
                    // 选集占满剩余高度——遥控器焦点导航需要固定的两块结构。
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: (constraints.maxHeight * .44).clamp(
                              180.0,
                              360.0,
                            ),
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                            // 左对齐（不居中）：让封面左边缘与下方选集网格对齐。
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: _overview(drama),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _loading || _error != null || episodes.isEmpty
                              ? _episodeStatus()
                              : EpisodeBrowser(
                                  episodes: episodes,
                                  currentNumber: watched?.episode,
                                  onSelected: (index) => _play(index),
                                ),
                        ),
                      ],
                    );
                  }
                  // 桌面端（0.7.56，用户要求）：整页**一体滚动**。
                  //
                  // 此前宽屏走「上下两段」布局，信息段与选集是两个独立
                  // 滚动区，滚轮只会滚光标所在的那块，看起来像页面断成
                  // 两截。现在桌面端与窄屏/详情面板一样用单个
                  // CustomScrollView：信息区、分组条、选集网格在同一滚动
                  // 流里，简介展开变长会自然把选集往下推。
                  final start = _episodePage * episodePageSize;
                  final visible = episodes
                      .skip(start)
                      .take(episodePageSize)
                      .toList();
                  return CustomScrollView(
                    controller: _detailScroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: _overview(drama),
                        ),
                      ),
                      if (_loading || _error != null || episodes.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _episodeStatus(),
                        )
                      else ...[
                        SliverToBoxAdapter(
                          child: EpisodeRangeBar(
                            key: _episodeAnchor,
                            episodes: episodes,
                            page: _episodePage,
                            currentNumber: watched?.episode,
                            onLocate: _locateEpisode,
                            // 与下方 SliverGrid 的 20 padding 对齐。
                            horizontalPadding: 20,
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _episodeColumns(
                                    constraints.maxWidth,
                                    episodes,
                                  ),
                                  mainAxisExtent: math.max(
                                    54,
                                    MediaQuery.textScalerOf(context).scale(20) +
                                        30,
                                  ),
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final episode = visible[index];
                              return RemoteEpisodeButton(
                                key: ValueKey('episode-${episode.number}'),
                                number: episode.number,
                                vip: episode.vip,
                                current:
                                    episode.number == watched?.episode ||
                                    episode.number == _locatedNumber,
                                onPressed: () => _play(start + index),
                              );
                            }, childCount: visible.length),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodeStatus() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: LoadingHint(message: '正在获取剧集列表…'),
      );
    }
    return StatusPanel(
      title: _error != null ? '剧集信息暂时不可用' : '暂时没有可播放的集数',
      message: _error ?? '可以更新剧集信息后重试。',
      onRetry: _load,
      secondaryAction: _sourceDiagnostics,
    );
  }

  void _locateEpisode(int index) {
    final episodes = _detail!.episodes;
    setState(() {
      _episodePage = index ~/ episodePageSize;
      _locatedNumber = episodes[index].number;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _episodeAnchor.currentContext;
      if (!mounted || anchor == null || !_detailScroll.hasClients) return;
      final render = anchor.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      final viewport = RenderAbstractViewport.maybeOf(render);
      if (viewport == null) return;
      final start = viewport.getOffsetToReveal(render, 0).offset;
      final extent = math.max(
        54,
        MediaQuery.textScalerOf(context).scale(20) + 30,
      );
      final columns = _episodeColumns(render.size.width, episodes);
      final target =
          start +
          render.size.height +
          (index % episodePageSize ~/ columns) * (extent + 10) -
          _detailScroll.position.viewportDimension * .3;
      _detailScroll.animateTo(
        target.clamp(0.0, _detailScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  int _episodeColumns(double width, List<Episode> episodes) {
    final digits = episodes.fold<int>(
      1,
      (value, episode) => math.max(value, episode.number.toString().length),
    );
    final scale = MediaQuery.textScalerOf(context);
    // 0.7.27（用户要求）：右侧详情面板改为**一行 10 集**。
    //
    // 面板宽度 360~720，10 列时格子约 50~68 宽（三位数集号也放得下）；
    // 窄屏放不下就按可用宽度回退，绝不让格子里挤成省略号。
    if (widget.panelMode) {
      return ((width - 40) / 52).floor().clamp(1, 10);
    }
    final minimum = math.max(82, scale.scale(20) * digits * .65 + 40);
    return ((width - 40) / minimum).floor().clamp(1, 12);
  }

  Widget _overview(Drama drama) {
    final colors = Theme.of(context).colorScheme;
    // 0.7.35（预览稿 D04）：宽屏信息区放大——海报 170×238、剧名 28px；
    // 窄屏维持原来的紧凑尺寸。
    final wide = MediaQuery.sizeOf(context).width >= 960;
    final posterWidth = wide ? 170.0 : 92.0;
    final posterHeight = wide ? 238.0 : 138.0;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
    ];
    // 上线 / 热度 / 播放（0.7.28：位置从「追剧按钮下方」挪到标签下方）。
    final stats = [
      if (drama.onlineDate.isNotEmpty) '${drama.onlineDate} 上线',
      if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
      if (drama.views.isNotEmpty) '播放 ${drama.views}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: posterWidth,
              height: posterHeight,
              child: DramaCover(drama: drama, repository: widget.repository),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: wide ? 28 : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    meta.join(' · '),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  // 0.7.28（用户要求）：原先这一行只写剧类（如「成长」），
                  // 与「热度」下面那排标签重复。现在把这排标签搬上来占它的位置，
                  // 剧类小字删掉；热度那一行顺延到标签下方。
                  if (drama.tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _tagChips(drama),
                    ),
                  if (stats.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        stats,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 0.7.38（预览稿 D04）：信息区主按钮 —— 继续/开始播放。
        // 画布里是「白色实心播放 + 次级胶囊」双按钮结构，
        // 追剧/下载仍由 _followingControls 提供。
        _playButton(drama),
        const SizedBox(height: 4),
        _followingControls(drama),
        if (drama.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          // 上下布局里信息区是整行宽度，简介限宽 760 以免一行过长难读。
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Text(
              drama.description,
              maxLines: _expandedDescription ? null : 3,
              overflow: _expandedDescription
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _expandedDescription = !_expandedDescription),
              child: Text(_expandedDescription ? '收起简介' : '展开简介'),
            ),
          ),
        ],
        if (_detail?.warning.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _detail!.warning,
              style: TextStyle(color: colors.error),
            ),
          ),
      ],
    );
  }

  /// 标签胶囊（0.7.28 从「热度」下方搬到信息区顶部）。
  Widget _tagChips(Drama drama) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in drama.tags.take(12))
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Text(tag, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
      ],
    );
  }

  /// 「加入追剧」/「下载」两个次级操作。
  ///
  /// 0.7.27（用户要求）：
  /// - 去掉追剧按钮上的下拉框，点一下直接加入追剧（已追剧再点取消）；
  /// - 两个按钮**左右宽度一致**，所以统一走这一套 `minWidth` 外壳，
  ///   图标 + 文字组合居中，谁的字多字少都不会让按钮一宽一窄。
  static const double _actionPillMinWidth = 116;

  Widget _actionPill({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Color? background,
    String? tooltip,
  }) {
    final colors = Theme.of(context).colorScheme;
    final foreground = onTap == null
        ? colors.onSurface.withValues(alpha: .38)
        : null;
    final pill = Material(
      key: key,
      color: background ?? colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: 48,
            minWidth: _actionPillMinWidth,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip, child: pill);
  }

  Widget _downloadPill({required bool enabled}) => _actionPill(
    key: const ValueKey('detail-download'),
    icon: Icons.download_rounded,
    label: '下载',
    tooltip: '下载选集',
    onTap: enabled ? _download : null,
  );

  /// 追剧按钮：点一下即加入追剧，再点取消（0.7.27 去掉下拉菜单）。
  Widget _followPill(Drama drama, FollowState? state) {
    final colors = Theme.of(context).colorScheme;
    final following = state != null;
    final watched = state?.status == FollowStatus.watched;
    return _actionPill(
      key: const ValueKey('follow-status'),
      icon: watched
          ? Icons.check_circle_outline
          : following
          ? Icons.bookmark_rounded
          : Icons.bookmark_add_outlined,
      label: state?.label ?? '加入追剧',
      tooltip: following ? '取消追剧' : '加入追剧',
      background: following ? colors.secondaryContainer : null,
      onTap: () => _toggleFollow(drama),
    );
  }

  Future<void> _toggleFollow(Drama drama) async {
    if (_profileEpoch != widget.store.profileEpoch) return;
    await saveUserChange(context, () => widget.store.toggleFavorite(drama));
  }

  /// 主播放按钮（0.7.38，预览稿 D04 的信息区双按钮之一）。
  ///
  /// 有观看记录 → 「继续播放 · 第 N 集」（从记录处续播）；
  /// 看完了 → 「重看 · 第 N 集」；没有记录 → 「立即播放」。
  Widget _playButton(Drama drama) {
    final episodes = _detail?.episodes ?? const <Episode>[];
    final watched = widget.store.watched(drama.id);
    final allowed =
        widget.store.profileEpoch == _profileEpoch &&
        widget.store.allowsSource(drama.source);
    var index = 0;
    var resume = false;
    if (watched != null && episodes.isNotEmpty) {
      final found = episodes.indexWhere((e) => e.number == watched.episode);
      if (found >= 0) {
        index = found;
        resume = !watched.finished;
      }
    }
    final label = watched == null
        ? '立即播放'
        : resume
        ? '继续播放 · 第 ${watched.episode} 集'
        : '重看 · 第 ${watched.episode} 集';
    return FilledButton.icon(
      key: const ValueKey('detail-play'),
      onPressed: episodes.isEmpty || !allowed
          ? null
          : () => _play(index, resume: resume),
      icon: const Icon(Icons.play_arrow_rounded, size: 22),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    );
  }

  Widget _followingControls(Drama drama) {
    final state = widget.store.following(drama.id);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _followPill(drama, state),
        // 0.7.26（用户要求）：下载入口在「加入追剧」后面，
        // 0.7.27 起与追剧按钮等宽。
        if (widget.repository.supportsDownloads && widget.store.canDownload)
          _downloadPill(
            enabled:
                _profileEpoch == widget.store.profileEpoch &&
                !_loading &&
                (_detail?.episodes.isNotEmpty ?? false),
          ),
        if (state != null && state.newEpisodes > 0)
          ActionChip(
            label: Text('${state.newEpisodes} 集更新 · 标为已读'),
            onPressed: () => saveUserChange(
              context,
              () => widget.store.markUpdatesRead(drama.id),
            ),
          ),
      ],
    );
  }
}
