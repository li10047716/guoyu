import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_store.dart';

/// 小说阅读页（0.7.61）。
///
/// 设计要点：
/// - **一页到底的竖向滚动**：不做仿真翻页（桌面端滚轮/触屏都更自然），
///   章末给「下一章」按钮，读完不用退回目录。
/// - **点一下画面呼出控件**：顶栏（返回 + 章节名）与底栏（上一章/目录/下一章/
///   设置/进度）平时隐藏，避免阅读时被 UI 干扰。
/// - **进度记忆**：切章与退出时把「章节 + 章内滚动偏移」写进 [NovelStore]，
///   下次从书架点进来直接续读。
/// - **外观设置**：字号 / 行距 / 四种配色（夜间、墨色、羊皮纸、护眼绿），
///   存在本地，全局生效。
class NovelReaderScreen extends StatefulWidget {
  const NovelReaderScreen({
    super.key,
    required this.novel,
    required this.chapters,
    required this.repository,
    this.initialIndex = 0,
    this.initialOffset = 0,
  });

  final Novel novel;
  final List<NovelChapterItem> chapters;
  final AppRepository repository;
  final int initialIndex;
  final double initialOffset;

  @override
  State<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends State<NovelReaderScreen> {
  final _scroll = ScrollController();
  final _pager = PageController();
  late final List<NovelChapterItem> _chapters = widget.chapters;
  late int _index = widget.initialIndex.clamp(
    0,
    math.max(0, _chapters.length - 1),
  );
  NovelText? _text;
  String? _error;
  bool _loading = true;
  bool _controls = true;
  double _pendingOffset = 0;

  /// 左右翻页模式下的页码与总页数（由 [_slideBody] 计算后回填）。
  int _pageIndex = 0;
  int _pageCount = 1;

  NovelStore get _store => NovelStore.instance;
  NovelReaderTheme get _theme => _store.settings.theme;

  @override
  void initState() {
    super.initState();
    _pendingOffset = widget.initialOffset;
    _store.addListener(_onSettingsChanged);
    _load(_index);
  }

  @override
  void dispose() {
    _store.removeListener(_onSettingsChanged);
    _persistProgress();
    _scroll.dispose();
    _pager.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load(int index, {double offset = 0}) async {
    if (_chapters.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _index = index.clamp(0, _chapters.length - 1);
      _pendingOffset = offset;
      _pageIndex = 0;
    });
    try {
      final chapter = _chapters[_index];
      final text = await _fetchText(chapter);
      if (!mounted) return;
      setState(() {
        _text = text;
        _loading = false;
      });
      if (_pager.hasClients) _pager.jumpToPage(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final target = _pendingOffset.clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        );
        _scroll.jumpTo(target);
      });
      // 0.7.61：切章后立刻把进度改成新章（偏移用请求时的 pendingOffset，
      // 此时滚动位置还是上一章的旧值）。这样即使进程被直接杀掉，
      // 书架上的「读到第 N 章」也不会退回上一章。
      _persistProgress(_pendingOffset);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// 取一章正文：本地书读磁盘，远端书先看缓存再走网络（拿到就顺手缓存）。
  Future<NovelText> _fetchText(NovelChapterItem chapter) async {
    if (widget.novel.isLocal) {
      final dir = await NovelLibrary.localDir();
      return widget.repository.localNovelText(dir, widget.novel.id, chapter.id);
    }
    final cached = await NovelCache.read(widget.novel.key, chapter.id);
    if (cached != null) return cached;
    final text = await widget.repository.novelContent(
      widget.novel.id,
      chapter.id,
    );
    unawaited(NovelCache.write(widget.novel.key, text));
    return text;
  }

  void _goTo(int index) {
    if (index < 0 || index >= _chapters.length) return;
    _persistProgress();
    _load(index);
  }

  /// 落盘阅读进度。[offsetOverride] 用于刚切章时（滚动位置尚未归位）。
  void _persistProgress([double? offsetOverride]) {
    final text = _text;
    if (text == null) return;
    final offset =
        offsetOverride ?? (_scroll.hasClients ? _scroll.offset : 0.0);
    unawaited(
      _store.saveProgress(
        widget.novel,
        NovelProgress(
          chapterId: text.chapterId,
          chapterIndex: _index,
          offset: offset,
          updatedAt: DateTime.now(),
        ),
      ),
    );
  }

  void _toggleControls() => setState(() => _controls = !_controls);

  Future<void> _openCatalog() async {
    final chapter = await showModalBottomSheet<NovelChapterItem>(
      context: context,
      backgroundColor: Color(_theme.surface),
      isScrollControlled: true,
      builder: (sheetContext) => _CatalogSheet(
        chapters: _chapters,
        currentIndex: _index,
        theme: _theme,
      ),
    );
    if (chapter == null || !mounted) return;
    _goTo(chapter.index);
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Color(_theme.surface),
      // 面板内部订阅 NovelStore 自绘，这里不再传快照。
      builder: (sheetContext) => const _ReaderSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = _theme;
    final settings = _store.settings;
    final background = Color(palette.background);
    final textColor = Color(palette.text);
    final media = MediaQuery.of(context);
    final fontSize = 17.0 * settings.fontScale;
    final custom = settings.backgroundImage;

    return Scaffold(
      backgroundColor: background,
      body: Stack(
        children: [
          // 自定义背景图：铺满后压一层主题底色，保证正文对比度不被照片吃掉。
          if (custom != null)
            Positioned.fill(
              child: Image.file(
                File(custom),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(color: background),
              ),
            ),
          Positioned.fill(
            child: ColoredBox(
              color: background.withValues(alpha: custom == null ? 1 : .86),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            child: SafeArea(
              bottom: false,
              child: _body(fontSize, textColor, media),
            ),
          ),
          // 亮度：不碰系统亮度（免得要权限），直接盖一层黑遮罩。
          if (settings.brightness < .999)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: (1 - settings.brightness).clamp(0.0, .65),
                  ),
                ),
              ),
            ),
          // 顶栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            top: _controls ? 0 : -80,
            left: 0,
            right: 0,
            child: _topBar(background),
          ),
          // 底栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            bottom: _controls ? 0 : -110,
            left: 0,
            right: 0,
            child: _bottomBar(background),
          ),
        ],
      ),
    );
  }

  Widget _body(double fontSize, Color textColor, MediaQueryData media) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: textColor.withValues(alpha: .5)),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error.replaceFirst('AppFailure: ', ''),
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor.withValues(alpha: .8)),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _load(_index),
                style: OutlinedButton.styleFrom(
                  foregroundColor: textColor,
                  side: BorderSide(color: textColor.withValues(alpha: .3)),
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final text = _text!;
    if (_store.settings.pageMode == NovelPageMode.slide) {
      return _slideBody(text, fontSize, textColor, media);
    }
    return _scrollBody(text, fontSize, textColor, media);
  }

  /// 上下滚动模式（0.7.61 的版式，一页到底）。
  Widget _scrollBody(
    NovelText text,
    double fontSize,
    Color textColor,
    MediaQueryData media,
  ) {
    final paragraphs = text.paragraphs;
    final fontFamily = _store.settings.fontFamily.fontFamily;
    // 0.7.61：宽屏（桌面/平板）限制正文行宽——超过 760 逻辑像素后
    // 改用左右留白居中，否则一行铺满 2560px 窗口根本没法读。
    final sidePad = math.max(22.0, (media.size.width - 760) / 2);
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(sidePad, 24, sidePad, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _chapters.length > _index
                  ? _chapters[_index].title
                  : text.title,
              style: TextStyle(
                color: textColor,
                fontSize: fontSize + 3,
                fontWeight: FontWeight.w700,
                height: 1.4,
                fontFamily: fontFamily,
              ),
            ),
            const SizedBox(height: 18),
            for (final paragraph in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  paragraph,
                  style: TextStyle(
                    color: textColor,
                    fontSize: fontSize,
                    height: _store.settings.lineHeight,
                    fontFamily: fontFamily,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            // 章末：上一章 / 下一章
            Row(
              children: [
                Expanded(
                  child: _footerButton(
                    '上一章',
                    textColor,
                    _index > 0 ? () => _goTo(_index - 1) : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _footerButton(
                    _index < _chapters.length - 1 ? '下一章' : '已是最后一章',
                    textColor,
                    _index < _chapters.length - 1
                        ? () => _goTo(_index + 1)
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '${_index + 1} / ${_chapters.length}',
                style: TextStyle(
                  color: textColor.withValues(alpha: .45),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左右翻页模式（0.7.67）：按可用面积把一章切成若干屏，PageView 承载。
  ///
  /// 不做仿真翻书（shader 成本高、桌面端没必要），用标准的横向滑动，
  /// 鼠标拖拽 / 触屏滑动 / 方向键都能走。
  Widget _slideBody(
    NovelText text,
    double fontSize,
    Color textColor,
    MediaQueryData media,
  ) {
    final settings = _store.settings;
    final fontFamily = settings.fontFamily.fontFamily;
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidePad = math.max(22.0, (constraints.maxWidth - 760) / 2);
        final pages = _paginate(
          paragraphs: text.paragraphs,
          width: math.max(120.0, constraints.maxWidth - sidePad * 2),
          height: math.max(160.0, constraints.maxHeight),
          fontSize: fontSize,
          lineHeight: settings.lineHeight,
        );
        if (_pageCount != pages.length) {
          // 分页结果可能随窗口尺寸变化，这里只同步计数，不在 build 里 setState。
          _pageCount = pages.length;
        }
        return PageView.builder(
          key: const ValueKey('novel-page-view'),
          controller: _pager,
          itemCount: pages.length,
          onPageChanged: (value) {
            _pageIndex = value;
            if (_controls) setState(() {});
          },
          itemBuilder: (context, index) {
            final rows = pages[index];
            return Padding(
              padding: EdgeInsets.fromLTRB(sidePad, 18, sidePad, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (index == 0) ...[
                    Text(
                      text.title.isNotEmpty
                          ? text.title
                          : _chapters[_index].title,
                      style: TextStyle(
                        color: textColor,
                        fontSize: fontSize + 3,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        fontFamily: fontFamily,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  for (final paragraph in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        paragraph,
                        style: TextStyle(
                          color: textColor,
                          fontSize: fontSize,
                          height: settings.lineHeight,
                          fontFamily: fontFamily,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${index + 1} / ${pages.length}',
                      style: TextStyle(
                        color: textColor.withValues(alpha: .38),
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 按可用面积把段落切成屏（不拆段，按行数估算）。
  ///
  /// 中文是等宽方块字，用 `可用宽度 / 字号` 估每行字数足够准确；
  /// 用 TextPainter 逐段精确测量会让翻页时有明显卡顿，这里不值得。
  List<List<String>> _paginate({
    required List<String> paragraphs,
    required double width,
    required double height,
    required double fontSize,
    required double lineHeight,
  }) {
    final charsPerLine = math.max(8, (width / fontSize).floor());
    final rowHeight = fontSize * lineHeight + 12;
    final capacity = math.max(3, (height / rowHeight).floor());
    // 首页要放章节标题，少排三行。
    final pages = <List<String>>[];
    var current = <String>[];
    var rowsLeft = math.max(2, capacity - 3);
    for (final paragraph in paragraphs) {
      final rows = math.max(1, (paragraph.length / charsPerLine).ceil());
      if (current.isNotEmpty && rows > rowsLeft) {
        pages.add(current);
        current = <String>[];
        rowsLeft = capacity;
      }
      current.add(paragraph);
      rowsLeft -= rows;
    }
    if (current.isNotEmpty) pages.add(current);
    if (pages.isEmpty) pages.add(const <String>[]);
    return pages;
  }

  Widget _footerButton(String label, Color textColor, VoidCallback? onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: textColor,
        side: BorderSide(color: textColor.withValues(alpha: .25)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(label),
    );
  }

  Widget _topBar(Color background) {
    return Container(
      decoration: BoxDecoration(
        color: background.withValues(alpha: .96),
        border: Border(
          bottom: BorderSide(color: Color(_theme.text).withValues(alpha: .08)),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(
                  Icons.arrow_back_rounded,
                  color: Color(_theme.text),
                ),
              ),
              Expanded(
                child: Text(
                  widget.novel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(_theme.text),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '目录',
                onPressed: _openCatalog,
                icon: Icon(Icons.list_rounded, color: Color(_theme.text)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(Color background) {
    final textColor = Color(_theme.text);
    return Container(
      decoration: BoxDecoration(
        color: background.withValues(alpha: .97),
        border: Border(
          top: BorderSide(color: textColor.withValues(alpha: .08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              _barAction('上一章', textColor, _index > 0 ? () => _goTo(_index - 1) : null),
              _barAction('目录', textColor, _openCatalog),
              _barAction(
                '下一章',
                textColor,
                _index < _chapters.length - 1 ? () => _goTo(_index + 1) : null,
              ),
              _barAction('设置', textColor, _openSettings),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Text(
                    // 翻页模式下多给一个页内进度，滚动模式只看章节。
                    _store.settings.pageMode == NovelPageMode.slide
                        ? '${_pageIndex + 1}/$_pageCount 页 · 第 ${_index + 1} 章'
                        : '${_index + 1}/${_chapters.length}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: textColor.withValues(alpha: .55),
                      fontSize: 12,
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

  Widget _barAction(String label, Color textColor, VoidCallback? onTap) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(foregroundColor: textColor),
      child: Text(label),
    );
  }
}

/// 目录抽屉：定位当前章，点章节跳转。
class _CatalogSheet extends StatefulWidget {
  const _CatalogSheet({
    required this.chapters,
    required this.currentIndex,
    required this.theme,
  });

  final List<NovelChapterItem> chapters;
  final int currentIndex;
  final NovelReaderTheme theme;

  @override
  State<_CatalogSheet> createState() => _CatalogSheetState();
}

class _CatalogSheetState extends State<_CatalogSheet> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: math.max(0, (widget.currentIndex - 6) * 52),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Color(widget.theme.text);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '目录 · ${widget.chapters.length} 章',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: textColor),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: textColor.withValues(alpha: .08)),
            Expanded(
              child: ListView.builder(
                controller: _controller,
                itemCount: widget.chapters.length,
                itemExtent: 52,
                itemBuilder: (context, index) {
                  final chapter = widget.chapters[index];
                  final current = index == widget.currentIndex;
                  return ListTile(
                    onTap: () => Navigator.of(context).pop(chapter),
                    title: Text(
                      chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: current
                            ? Theme.of(context).colorScheme.primary
                            : textColor.withValues(alpha: .86),
                        fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                    trailing: current
                        ? Icon(
                            Icons.play_arrow_rounded,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读外观设置：字号、行距、配色。
///
/// 面板直接订阅 [NovelStore]：拖滑块时既要立即重绘正文，也要让面板
/// 自己的滑块位置/选中配色跟着动（0.7.61 修正——原先面板拿的是
/// 构造时的快照，拖完手指松了值也回弹）。
class _ReaderSettingsSheet extends StatelessWidget {
  const _ReaderSettingsSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NovelStore.instance,
      builder: (context, _) {
        final store = NovelStore.instance;
        final settings = store.settings;
        final textColor = Color(settings.theme.text);
        void save(NovelReaderSettings next) => store.saveSettings(next);
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            // 面板条目变多了，小屏上要能滚。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .78,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '阅读设置',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('翻页方式', '', textColor),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in NovelPageMode.values)
                        _chip(
                          context,
                          label: mode.label,
                          selected: settings.pageMode == mode,
                          textColor: textColor,
                          onTap: () => save(settings.copyWith(pageMode: mode)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _label('字号', '${(settings.fontScale * 17).round()}', textColor),
                  Slider(
                    value: settings.fontScale,
                    min: .8,
                    max: 1.8,
                    divisions: 10,
                    onChanged: (value) =>
                        save(settings.copyWith(fontScale: value)),
                  ),
                  _label('行距', settings.lineHeight.toStringAsFixed(2), textColor),
                  Slider(
                    value: settings.lineHeight,
                    min: 1.4,
                    max: 2.4,
                    divisions: 10,
                    onChanged: (value) =>
                        save(settings.copyWith(lineHeight: value)),
                  ),
                  _label(
                    '亮度',
                    '${(settings.brightness * 100).round()}%',
                    textColor,
                  ),
                  Slider(
                    value: settings.brightness,
                    min: .35,
                    max: 1,
                    divisions: 13,
                    onChanged: (value) =>
                        save(settings.copyWith(brightness: value)),
                  ),
                  const SizedBox(height: 6),
                  _label('字体', '', textColor),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final font in NovelFontFamily.values)
                        _chip(
                          context,
                          label: font.label,
                          selected: settings.fontFamily == font,
                          textColor: textColor,
                          onTap: () =>
                              save(settings.copyWith(fontFamily: font)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _label('配色', '', textColor),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final option in NovelReaderTheme.values)
                        GestureDetector(
                          onTap: () => save(settings.copyWith(theme: option)),
                          child: Container(
                            width: 74,
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Color(option.background),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: option == settings.theme
                                    ? Theme.of(context).colorScheme.primary
                                    : Color(option.text).withValues(alpha: .2),
                                width: option == settings.theme ? 1.6 : .8,
                              ),
                            ),
                            child: Text(
                              option.label,
                              style: TextStyle(
                                color: Color(option.text),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text(
                        '背景图',
                        style: TextStyle(
                          color: textColor.withValues(alpha: .7),
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        key: const ValueKey('novel-pick-background'),
                        onPressed: () => _pickBackground(context),
                        icon: const Icon(Icons.image_outlined, size: 17),
                        style: TextButton.styleFrom(
                          foregroundColor: textColor.withValues(alpha: .85),
                        ),
                        label: Text(
                          settings.backgroundImage == null ? '选择图片' : '换一张',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      if (settings.backgroundImage != null)
                        IconButton(
                          tooltip: '移除背景图',
                          iconSize: 17,
                          visualDensity: VisualDensity.compact,
                          color: textColor.withValues(alpha: .7),
                          onPressed: () => save(
                            settings.copyWith(clearBackgroundImage: true),
                          ),
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _chip(
    BuildContext context, {
    required String label,
    required bool selected,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: .18)
              : textColor.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? primary : textColor.withValues(alpha: .12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: textColor,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 选一张本地图片做背景：复制进应用目录，避免用户挪走源文件后失效。
  Future<void> _pickBackground(BuildContext context) async {
    var files = const <PlatformFile>[];
    try {
      files = await FilePicker.pickFiles(
        type: FileType.image,
        dialogTitle: '选择阅读背景图',
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('打开图片选择器失败：$error')));
      return;
    }
    if (files.isEmpty) return;
    final source = files.first.path;
    if (source == null) return;
    try {
      final base = await NovelLibrary.resolve();
      final dir = Directory(p.join(base, 'backgrounds'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = p.extension(source).isEmpty ? '.jpg' : p.extension(source);
      final target = p.join(
        dir.path,
        'bg-${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(source).copy(target);
      await NovelStore.instance.saveSettings(
        NovelStore.instance.settings.copyWith(backgroundImage: target),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('设置背景图失败：$error')));
    }
  }

  Widget _label(String title, String value, Color textColor) => Row(
    children: [
      Text(
        title,
        style: TextStyle(color: textColor.withValues(alpha: .7), fontSize: 13),
      ),
      const Spacer(),
      if (value.isNotEmpty)
        Text(
          value,
          style: TextStyle(color: textColor.withValues(alpha: .5), fontSize: 12),
        ),
    ],
  );
}
