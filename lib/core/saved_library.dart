import 'package:flutter/material.dart';

import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/ui/app_theme.dart';
import 'package:duanju_app/catalog/catalog_sort.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/ui/drama_actions.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/ui/remote_widgets.dart';
import 'package:duanju_app/ui/widgets.dart';

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('这会删除当前用户的观看进度，追剧状态和手动已看标记会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    history: widget.history,
    onContinue: () => widget.onContinue(drama),
    onDownload: widget.onDownload == null
        ? null
        : () => widget.onDownload!(drama),
  );

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final watched = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final badge = state == null
        ? null
        : '${state.label}${state.newEpisodes > 0 ? ' · 更新 ${state.newEpisodes} 集' : ''}';
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => widget.onOpen(drama),
      onMore: () => _actions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _actions(drama),
      ),
      badge: badge,
      subtitle: watched == null
          ? SourceSite.byId(drama.source).name
          : '第 ${watched.episode} 集 · ${formatPosition(watched.position)}',
    );
  }

  /// 继续观看卡（0.7.35，预览稿 D03）。
  ///
  /// 桌面宽屏：横卡 = 左侧封面 132×118 + 中间剧名/进度信息 + 4px 进度条
  /// + 右侧 64px 圆形播放钮；窄屏回退为紧凑 ListTile。
  /// 进度按「集数」估算（时长未必可查）：第 e 集 / 共 N 集。
  Widget _continueCard(WatchEntry resume) {
    final colors = Theme.of(context).colorScheme;
    final drama = resume.drama;
    final subtitle =
        '看到第 ${resume.episode} 集 · ${formatPosition(resume.position)}';
    final fraction = drama.episodes > 0
        ? (resume.episode / drama.episodes).clamp(0.0, 1.0)
        : 0.0;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (!wide) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: const ValueKey('continue-watching'),
          leading: const Icon(Icons.play_circle_outline),
          title: Text(
            '继续观看 · ${drama.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(subtitle),
          onTap: () => widget.onContinue(drama),
        ),
      );
    }
    return Material(
      key: const ValueKey('continue-watching'),
      color: AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppTheme.cardStroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onContinue(drama),
        child: SizedBox(
          height: 118,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 132,
                child: DramaCover(
                  drama: drama,
                  repository: widget.repository,
                  radius: 0,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '继续观看',
                        style: TextStyle(
                          color: AppTheme.starlight,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        drama.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      const Spacer(),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 4,
                          backgroundColor: colors.onSurface.withValues(
                            alpha: .12,
                          ),
                          valueColor: const AlwaysStoppedAnimation(
                            AppTheme.starlight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 24),
                  child: Material(
                    color: AppTheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => widget.onContinue(drama),
                      child: const SizedBox(
                        width: 64,
                        height: 64,
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 34,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final history = widget.store.history;
      final all = widget.history
          ? history.map((entry) => entry.drama).toList()
          : widget.store.favorites;
      final items = all
          .where((drama) => matchesDramaQuery(drama, _search.text))
          .toList();
      final ids = items.map((drama) => drama.id).toSet();
      final resume = history
          .where(
            (entry) =>
                ids.contains(entry.drama.id) &&
                (!entry.finished ||
                    entry.drama.episodes <= 0 ||
                    entry.episode < entry.drama.episodes),
          )
          .firstOrNull;
      final header = [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
          child: Row(
            children: [
              // 0.7.38（预览稿 D03）：标题 22px 粗体，数量用次级灰蓝。
              Text(
                widget.history ? '最近观看' : '我的追剧',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${all.length}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
              const Spacer(),
              if (widget.history && all.isNotEmpty)
                IconButton(
                  tooltip: '清空观看记录',
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: ValueKey(
              widget.history ? 'history-search' : 'favorites-search',
            ),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.history ? '搜索观看记录' : '搜索追剧',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _continueCard(resume),
          ),
      ];
      final empty = StatusPanel(
        title: all.isEmpty
            ? widget.history
                  ? '还没有观看记录'
                  : '还没有追剧'
            : '没有匹配的记录',
        message: all.isEmpty ? '去推荐页，挑一部喜欢的短剧。' : '可以更换搜索词再试。',
        icon: widget.history
            ? Icons.history_rounded
            : Icons.bookmark_border_rounded,
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          if (AppLayout.isTelevision(context)) {
            final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
              1,
              8,
            );
            final tileWidth =
                (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .5,
                  ),
                  child: SingleChildScrollView(child: Column(children: header)),
                ),
                Expanded(
                  child: items.isEmpty
                      ? empty
                      : RemoteGrid(
                          key: ValueKey(
                            'saved-tv-${widget.history}-${_search.text}',
                          ),
                          itemKeys: items.map((item) => item.id).toList(),
                          columns: columns,
                          itemExtent:
                              DramaTile.extentFor(context, tileWidth - 14) + 14,
                          itemBuilder: (_, index, node, onFocus) => _tile(
                            items[index],
                            focusNode: node,
                            onFocus: onFocus,
                          ),
                        ),
                ),
              ],
            );
          }
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return CustomScrollView(
            key: PageStorageKey('saved-${widget.history}-${_search.text}'),
            slivers: [
              SliverToBoxAdapter(child: Column(children: header)),
              if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: empty)
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _tile(items[index]),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}
