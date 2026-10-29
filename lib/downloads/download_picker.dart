import 'package:flutter/material.dart';

import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/downloads/download_preferences.dart';
import 'package:duanju_app/catalog/episode_browser.dart';

class DownloadSelection {
  const DownloadSelection(this.episodes, this.quality);
  final List<Episode> episodes;
  final int quality;
}

class DownloadPicker extends StatefulWidget {
  const DownloadPicker({
    super.key,
    required this.detail,
    this.preferences = const DownloadPreferences(),
  });
  final DramaDetail detail;
  final DownloadPreferences preferences;

  @override
  State<DownloadPicker> createState() => _DownloadPickerState();
}

class _DownloadPickerState extends State<DownloadPicker> {
  late final _selected = widget.detail.episodes
      .where((episode) => widget.preferences.includeVip || !episode.vip)
      .take(500)
      .map((episode) => episode.number)
      .toSet();
  late int _quality = widget.preferences.quality;

  void _select(Iterable<Episode> episodes) {
    final choices = episodes.toList();
    setState(() {
      _selected.clear();
      _selected.addAll(choices.take(500).map((episode) => episode.number));
    });
    if (choices.length > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已选前 500 集；可清空后按分组选择其他集数，或从发现页使用整剧批量下载')),
      );
    }
  }

  void _toggle(Episode episode) {
    if (!_selected.contains(episode.number) && _selected.length >= 500) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多加入 500 集，请分批下载')));
      return;
    }
    setState(() {
      if (!_selected.remove(episode.number)) _selected.add(episode.number);
    });
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.detail.episodes;
    final hasVip = episodes.any(
      (episode) => episode.vip && _selected.contains(episode.number),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载选集'),
        // 0.7.27（用户要求）：去掉「全选」后面的三点菜单，
        // 换成「全不选」——两键并列，选/不选一眼可见。
        actions: [
          TextButton(
            key: const ValueKey('select-all-episodes'),
            onPressed: () => _select(episodes),
            child: const Text('全选'),
          ),
          TextButton(
            key: const ValueKey('select-none-episodes'),
            onPressed: _selected.isEmpty
                ? null
                : () => setState(_selected.clear),
            child: const Text('全不选'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                  child: Text(
                    widget.detail.drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('画质'),
                      DropdownButton<int>(
                        key: const ValueKey('download-quality'),
                        value: _quality,
                        onChanged: (value) =>
                            setState(() => _quality = value ?? 0),
                        items: [
                          const DropdownMenuItem(
                            value: 0,
                            child: Text('自动 · 优先高清'),
                          ),
                          for (final quality in [1080, 720, 480])
                            DropdownMenuItem(
                              value: quality,
                              child: Text('${quality}P'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    '保存源站原始视频；指定画质不可用时使用可用版本。下载时请保持应用运行。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (hasVip)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                    child: Text(
                      '已选 VIP 集可能只能下载试看内容。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  ),
                Expanded(
                  child: EpisodeBrowser(
                    episodes: episodes,
                    selectedNumbers: _selected,
                    keyPrefix: 'download-episode',
                    // 0.7.27（用户要求）：一行 10 集。
                    columns: 10,
                    onSelected: (index) => _toggle(episodes[index]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: FilledButton.icon(
                    key: const ValueKey('enqueue-downloads'),
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            DownloadSelection(
                              episodes
                                  .where(
                                    (episode) =>
                                        _selected.contains(episode.number),
                                  )
                                  .toList(),
                              _quality,
                            ),
                          ),
                    icon: const Icon(Icons.download_rounded),
                    label: Text('加入下载 · ${_selected.length} 集'),
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
