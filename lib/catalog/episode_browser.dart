import 'dart:math';

import 'package:flutter/material.dart';

import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/ui/remote_widgets.dart';

const episodePageSize = 50;

class EpisodeRangeBar extends StatelessWidget {
  const EpisodeRangeBar({
    super.key,
    required this.episodes,
    required this.page,
    required this.onLocate,
    this.currentNumber,
    this.title = '选集',
    this.horizontalPadding = 18,
  });
  final List<Episode> episodes;
  final int page;
  final ValueChanged<int> onLocate;
  final int? currentNumber;
  final String title;

  /// 左右留白。默认 18 与 `RemoteGrid` 的 `padding` 一致，
  /// 这样分组按钮的左边缘与选集格子严格对齐（0.7.26）。
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final count = (episodes.length / episodePageSize).ceil();
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 6, horizontalPadding, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title · ${episodes.length} 集',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          // 0.7.26（用户要求）：分组选择由「下拉框 + 左右箭头」改为
          // **横向按钮组**（如 `1-50`、`51-77`），左对齐选集列表；
          // 同时去掉「定位当前」与「跳转集数」两个入口。
          if (count > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < count; i++) _rangeChip(context, i),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _rangeChip(BuildContext context, int index) {
    final start = index * episodePageSize;
    final end = min((index + 1) * episodePageSize, episodes.length) - 1;
    final label = '${episodes[start].number}-${episodes[end].number}';
    final selected = index == page;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '第 $label 集',
      child: Material(
        key: ValueKey('episode-range-$index'),
        color: selected
            ? colors.primary
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selected ? null : () => onLocate(start),
          // 注意：这里不能用 `alignment` / `Center`——在 Wrap 的松约束下
          // `Container(alignment:)` 会被撑满整行，按钮变成通栏。
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EpisodeBrowser extends StatefulWidget {
  const EpisodeBrowser({
    super.key,
    required this.episodes,
    required this.onSelected,
    this.currentNumber,
    this.selectedNumbers,
    this.keyPrefix = 'episode',
    this.title = '选集',
    this.columns,
  });
  final List<Episode> episodes;
  final ValueChanged<int> onSelected;
  final int? currentNumber;
  final Set<int>? selectedNumbers;
  final String keyPrefix;
  final String title;

  /// 期望的一行集数（0.7.27，下载选集页用它固定成 10 集）。
  ///
  /// 只是"上限"：窗口窄到格子放不下时会自动减少列数，
  /// 避免集号被挤成省略号。
  final int? columns;
  @override
  State<EpisodeBrowser> createState() => _EpisodeBrowserState();
}

class _EpisodeBrowserState extends State<EpisodeBrowser> {
  final _scroll = ScrollController();
  String _layout = '';
  late int _page =
      max(
        0,
        widget.episodes.indexWhere((e) => e.number == widget.currentNumber),
      ) ~/
      episodePageSize;
  int? _located;

  @override
  void didUpdateWidget(EpisodeBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentNumber != widget.currentNumber) {
      _page =
          max(
            0,
            widget.episodes.indexWhere(
              (episode) => episode.number == widget.currentNumber,
            ),
          ) ~/
          episodePageSize;
      _located = null;
    }
    _page = _page.clamp(
      0,
      max(0, (widget.episodes.length - 1) ~/ episodePageSize),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = _page * episodePageSize;
    final visible = widget.episodes.skip(start).take(episodePageSize).toList();
    final television = AppLayout.isTelevision(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EpisodeRangeBar(
          episodes: widget.episodes,
          page: _page,
          title: widget.title,
          currentNumber: widget.currentNumber,
          // 与 RemoteGrid 默认 padding（18）保持一致，按钮左边缘对齐格子。
          horizontalPadding: 18,
          onLocate: (index) => setState(() {
            _page = index ~/ episodePageSize;
            _located = widget.episodes[index].number;
          }),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final digits = visible.fold<int>(
                1,
                (value, episode) =>
                    max(value, episode.number.toString().length),
              );
              final scale = MediaQuery.textScalerOf(context);
              // 指定了 [EpisodeBrowser.columns] 时按它排，但格子最小 52 宽：
              // 放不下就回退，宁可少几列也不让三位数集号被截断。
              final fit = ((constraints.maxWidth - 36) / 52).floor();
              final wanted = widget.columns;
              final columns = wanted == null
                  ? ((constraints.maxWidth - 36) /
                            max(
                              television ? 100 : 82,
                              scale.scale(20) * digits * .65 + 40,
                            ))
                        .floor()
                        .clamp(1, 12)
                  : min(wanted, max(1, fit));
              final extent = max(56.0, scale.scale(20) + 30);
              final target = max(
                0,
                visible.indexWhere(
                  (episode) =>
                      episode.number == (_located ?? widget.currentNumber),
                ),
              );
              final layout =
                  '$_page:$_located:${widget.currentNumber}:$columns:$extent:${constraints.maxHeight}';
              if (layout != _layout) {
                _layout = layout;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_scroll.hasClients || _layout != layout) {
                    return;
                  }
                  _scroll.jumpTo(
                    (18 +
                            target ~/ columns * (extent + 8) -
                            constraints.maxHeight / 2 +
                            extent / 2)
                        .clamp(0.0, _scroll.position.maxScrollExtent),
                  );
                });
              }
              return RemoteGrid(
                key: ValueKey('episode-page-$_page-$_located'),
                controller: _scroll,
                autofocus: television && _located != null,
                initialIndex: target,
                itemKeys: visible
                    .map((episode) => '${episode.number}')
                    .toList(),
                columns: columns,
                itemExtent: extent,
                spacing: 8,
                itemBuilder: (_, index, node, onFocus) {
                  final episode = visible[index];
                  return RemoteEpisodeButton(
                    key: ValueKey('${widget.keyPrefix}-${episode.number}'),
                    number: episode.number,
                    vip: episode.vip,
                    current:
                        widget.selectedNumbers?.contains(episode.number) ??
                        (episode.number == widget.currentNumber ||
                            episode.number == _located),
                    focusNode: node,
                    onFocus: onFocus,
                    onPressed: () => widget.onSelected(start + index),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
