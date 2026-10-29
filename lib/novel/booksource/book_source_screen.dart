/// 书源管理界面（0.7.68）。
///
/// 支持导入「阅读 / Legado」格式的书源：本地 JSON 文件、JSON 直链、
/// 剪贴板里的 `yuedu://` 一键导入链接。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'book_source.dart';
import 'book_source_parser.dart';
import 'book_source_store.dart';

class BookSourceScreen extends StatefulWidget {
  const BookSourceScreen({super.key});

  @override
  State<BookSourceScreen> createState() => _BookSourceScreenState();
}

class _BookSourceScreenState extends State<BookSourceScreen> {
  final BookSourceStore _store = BookSourceStore.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(colors),
            Expanded(
              child: AnimatedBuilder(
                animation: _store,
                builder: (context, _) {
                  final sources = _store.sources;
                  if (sources.isEmpty) return _empty(colors);
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                    itemCount: sources.length + 1,
                    separatorBuilder: (_, index) =>
                        SizedBox(height: index == 0 ? 12 : 10),
                    itemBuilder: (context, index) {
                      if (index == 0) return _hint(colors);
                      final source = sources[index - 1];
                      return _card(colors, source);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: '返回',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '书源管理',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                AnimatedBuilder(
                  animation: _store,
                  builder: (context, _) => Text(
                    '共 ${_store.sources.length} 个 · 可用 ${_store.usableSources.length} 个',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _openImportSheet(colors),
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 18),
            label: const Text('导入'),
          ),
        ],
      ),
    );
  }

  Widget _hint(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '支持「阅读 / Legado」格式书源，带 @js: 规则的源也能跑（本地内置 JS 引擎，'
              'java.ajax 等接口已实现）。只有用到 XPath、或脚本里直接 new Java 类'
              '（Packages.java.*）的源才会标成不可用。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 46,
            color: colors.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 14),
          Text(
            '还没有书源',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '点右上角「导入」添加书源 JSON 或链接',
            style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _card(ColorScheme colors, BookSource source) {
    final usable = source.status.usable;
    final statusColor = usable
        ? const Color(0xFF3BA55D)
        : (source.status == BookSourceStatus.needsJs
              ? const Color(0xFFD98B2B)
              : colors.error);
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _badge(statusColor, source.status.label),
                      if (source.group.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(child: _badge(colors.primary, source.group)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    source.url.isEmpty ? '（未填写地址）' : source.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (source.statusDetail.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      source.statusDetail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: usable
                            ? colors.onSurfaceVariant
                            : statusColor.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: source.enabled,
              onChanged: usable
                  ? (value) => _store.setEnabled(source.key, value)
                  : null,
            ),
            IconButton(
              tooltip: '详情',
              icon: const Icon(Icons.article_outlined, size: 19),
              onPressed: () => _showDetail(source),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
              onPressed: () => _confirmRemove(source),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(Color color, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  // ------------------------------------------------------------ 导入流程

  Future<void> _openImportSheet(ColorScheme colors) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: colors.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择导入方式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            _sheetTile(
              Icons.folder_open_rounded,
              '本地文件',
              '选择 .json / .txt 书源文件',
              () => Navigator.pop(context, 'file'),
            ),
            _sheetTile(
              Icons.link_rounded,
              '网址导入',
              '粘贴书源 JSON 直链',
              () => Navigator.pop(context, 'url'),
            ),
            _sheetTile(
              Icons.content_paste_rounded,
              '从剪贴板导入',
              '支持 yuedu:// 一键导入链接或整段 JSON',
              () => Navigator.pop(context, 'clipboard'),
            ),
            _sheetTile(
              Icons.qr_code_scanner_rounded,
              '扫码导入',
              '手机上扫码后把链接复制过来（桌面端没有摄像头）',
              () => Navigator.pop(context, 'qr'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'file':
        await _importFile();
      case 'url':
        await _importUrl();
      case 'clipboard':
        await _importClipboard();
      case 'qr':
        await _showQrHint();
    }
  }

  Widget _sheetTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Icon(icon, size: 21),
      title: Text(title, style: const TextStyle(fontSize: 14.5)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11.5)),
      onTap: onTap,
    );
  }

  Future<void> _importFile() async {
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
        dialogTitle: '选择书源文件',
      );
      if (files.isEmpty) return;
      final path = files.first.path;
      if (path == null) return;
      final text = await File(path).readAsString();
      final result = await _store.importText(text);
      if (!mounted) return;
      await _reportResult(result);
    } catch (error) {
      if (mounted) _toast('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importUrl() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('网址导入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'https://…/booksource.json 或 yuedu://booksource/importonline?src=…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.isEmpty) return;

    setState(() => _busy = true);
    try {
      final result = await _importAny(input);
      if (!mounted) return;
      await _reportResult(result);
    } catch (error) {
      if (mounted) _toast('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importClipboard() async {
    setState(() => _busy = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        if (mounted) _toast('剪贴板是空的');
        return;
      }
      final result = await _importAny(text);
      if (!mounted) return;
      await _reportResult(result);
    } catch (error) {
      if (mounted) _toast('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一段文本可能是 JSON，也可能是链接，这里统一处理。
  Future<BookSourceImport> _importAny(String text) async {
    final url = extractSourceUrl(text);
    if (url != null) return _store.importUrl(url);
    return _store.importText(text);
  }

  Future<void> _showQrHint() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('扫码导入'),
        content: const Text(
          '桌面端没有摄像头，用手机扫 yckceo.com 之类站点上的二维码后，'
          '把得到的 yuedu:// 链接复制到电脑，再用「从剪贴板导入」即可。\n\n'
          '链接形如：yuedu://booksource/importonline?src=https%3A%2F%2F…',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _reportResult(BookSourceImport result) async {
    if (result.isEmpty && result.duplicated == 0) {
      final reason = result.warnings.isEmpty ? '没有解析到书源' : result.warnings.first;
      _toast('导入失败：$reason');
      return;
    }
    final names = result.parsed.take(8).map((s) => '· ${s.name}').join('\n');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入完成'),
        content: SingleChildScrollView(
          child: Text(
            [
              result.summary,
              if (names.isNotEmpty) '',
              if (names.isNotEmpty) names,
              if (result.parsed.length > 8) '… 还有 ${result.parsed.length - 8} 个',
              if (result.warnings.isNotEmpty) '',
              ...result.warnings,
            ].join('\n'),
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _showDetail(BookSource source) {
    final rules = <String>[
      ...source.searchRules.entries.map((e) => '搜索.${e.key}: ${e.value}'),
      ...source.bookInfoRules.entries.map((e) => '详情.${e.key}: ${e.value}'),
      ...source.tocRules.entries.map((e) => '目录.${e.key}: ${e.value}'),
      ...source.contentRules.entries.map((e) => '正文.${e.key}: ${e.value}'),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  '${source.url}\n分组：${source.group.isEmpty ? '无' : source.group}'
                  '\n状态：${source.status.label}',
                  style: const TextStyle(fontSize: 12.5, height: 1.6),
                ),
                const SizedBox(height: 12),
                for (final rule in rules)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SelectableText(
                      rule,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BookSource source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除「${source.name}」吗？书架里来自这个源的书将无法继续更新。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.remove(source.key);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }
}
