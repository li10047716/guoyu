import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/novel_models.dart';
import 'package:duanju_app/novel/booksource/novel_gateway.dart';
import 'package:duanju_app/novel/novel_library.dart';
import 'package:duanju_app/novel/novel_pagination.dart';
import 'package:duanju_app/novel/novel_store.dart';
import 'package:duanju_app/platform/desktop_title_bar.dart';

/// 小说阅读页。
///
/// 0.7.86 按手机阅读器的形态重做：
/// - **默认左右翻页**：整章精确分页（[NovelPagination]），一屏一页，不再像
///   浏览器那样整章竖着滚。
/// - **点屏幕翻页**：左侧三分之一上一页、右侧三分之一下一页、中间呼出控件，
///   和主流阅读 App 一致；也能直接左右滑动。
/// - **跨章衔接**：本章最后一页再往后翻自动进下一章；第一页往前翻回上一章末页。
/// - **沉浸式**：手机上隐藏状态栏与导航栏，桌面上连标题栏一起收起。
/// - **进度记忆**：分页模式下记「第几页」，滚动模式下仍记像素偏移。
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
    this.gateway,
  });

  final Novel novel;
  final List<NovelChapterItem> chapters;
  final AppRepository repository;
  final int initialIndex;
  final double initialOffset;

  /// 测试注入用；生产环境留空，自己建一个。
  final NovelGateway? gateway;

  @override
  State<NovelReaderScreen> createState() => _NovelReaderScreenState();
}

class _NovelReaderScreenState extends State<NovelReaderScreen> {
  late final NovelGateway _gateway = widget.gateway ?? NovelGateway();
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

  /// 0.7.86：进来就是沉浸阅读，点屏幕中间才呼出顶栏 / 底栏。
  bool _controls = false;
  double _pendingOffset = 0;

  /// 左右翻页模式下的页码与总页数（由 [_slideBody] 计算后回填）。
  int _pageIndex = 0;
  int _pageCount = 1;

  /// 当前章的排版结果缓存：窗口尺寸 / 字号 / 行距 / 配色任一变化就重排。
  NovelPagination? _paging;
  String _pagingSignature = '';

  /// 切章后要落到「最后一页」（往回翻上一章时用）。
  bool _pendingLastPage = false;

  /// 续读时要定位到的页码（分页模式）。
  int? _pendingPage;

  /// 本页作为持有者隐藏桌面标题栏，退出时释放。
  ///
  /// 只在手机端隐藏：桌面端标题栏是唯一的关闭按钮入口，藏了就没法关窗口
  /// （阅读页不像播放页那样有全屏概念）。
  final Object _titleBarOwner = Object();

  /// 上一次见到的设置快照，用来区分「改外观」和「只更新了进度」。
  NovelReaderSettings? _lastSettings;

  NovelStore get _store => NovelStore.instance;
  NovelReaderTheme get _theme => _store.settings.theme;

  @override
  void initState() {
    super.initState();
    _pendingOffset = widget.initialOffset;
    _lastSettings = _store.settings;
    _store.addListener(_onSettingsChanged);
    _enterImmersive();
    // 桌面端不藏标题栏：那是唯一的关闭窗口入口（阅读页没有全屏概念）。
    if (Platform.isAndroid || Platform.isIOS) {
      TitleBarSlot.instance.setHidden(_titleBarOwner, true);
    }
    _load(_index);
  }

  @override
  void dispose() {
    _store.removeListener(_onSettingsChanged);
    _persistProgress();
    _exitImmersive();
    TitleBarSlot.instance.setHidden(_titleBarOwner, false);
    _scroll.dispose();
    _pager.dispose();
    _paging?.dispose();
    super.dispose();
  }

  /// 手机上进入沉浸式：隐藏状态栏和底部手势条，只留正文。
  void _enterImmersive() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _syncStatusBarStyle();
  }

  void _exitImmersive() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 深色主题用白色状态栏图标，浅色主题（羊皮纸/护眼绿）用黑色。
  void _syncStatusBarStyle() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final palette = _theme;
    // 背景亮度 > .5 视为浅色底。
    final luminance =
        (0.299 * ((palette.background >> 16) & 0xff) +
            0.587 * ((palette.background >> 8) & 0xff) +
            0.114 * (palette.background & 0xff)) /
        255;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: luminance > .5
            ? Brightness.dark
            : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
  }

  void _onSettingsChanged() {
    final next = _store.settings;
    // 翻页时也会 saveProgress → notifyListeners，那不是外观改动，
    // 没必要整页重建（分页缓存虽在，PageView 重建仍有掉帧风险）。
    if (identical(next, _lastSettings)) return;
    _lastSettings = next;
    // 换配色后状态栏图标要跟着反色，否则浅色底上白图标看不见。
    _syncStatusBarStyle();
    if (mounted) setState(() {});
  }

  Future<void> _load(
    int index, {
    double offset = 0,
    bool jumpToLast = false,
  }) async {
    if (_chapters.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _index = index.clamp(0, _chapters.length - 1);
      _pendingOffset = offset;
      _pageIndex = 0;
      _pendingLastPage = jumpToLast;
      // 分页模式下 initialOffset 存的是页码，滚动模式才是像素。
      _pendingPage = (!jumpToLast && offset > 0) ? offset.round() : null;
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
        if (!mounted) return;
        if (_store.settings.pageMode == NovelPageMode.slide) {
          // 分页模式下由 _slideBody 排完版再定位，这里只处理滚动模式的偏移。
          return;
        }
        if (!_scroll.hasClients) return;
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
    final text = await _gateway.content(widget.novel.id, chapter.id);
    unawaited(NovelCache.write(widget.novel.key, text));
    return text;
  }

  void _goTo(int index) {
    if (index < 0 || index >= _chapters.length) return;
    _persistProgress();
    _load(index);
  }

  /// 落盘阅读进度。[offsetOverride] 用于刚切章时（滚动位置尚未归位）。
  ///
  /// 分页模式下 `offset` 字段存的是页码——两种模式的取值范围不重叠，
  /// 续读时按当前模式解释即可，不用再拆一个新字段。
  void _persistProgress([double? offsetOverride]) {
    final text = _text;
    if (text == null) return;
    final offset = _store.settings.pageMode == NovelPageMode.slide
        ? _pageIndex.toDouble()
        : (offsetOverride ?? (_scroll.hasClients ? _scroll.offset : 0.0));
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

  /// 上一页；已在首页则回上一章的最后一页。
  void _prevPage() {
    if (_pageIndex > 0) {
      _pager.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    if (_index > 0) {
      _persistProgress();
      _load(_index - 1, jumpToLast: true);
      return;
    }
    _toggleControls();
  }

  /// 下一页；已在末页则进下一章。已经是全书最后一页时呼出控件。
  void _nextPage() {
    if (_pageIndex < _pageCount - 1) {
      _pager.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    if (_index < _chapters.length - 1) {
      _goTo(_index + 1);
      return;
    }
    _toggleControls();
  }

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
          // 阅读区自己处理点击（滚动模式点哪都呼出控件，分页模式分三个热区），
          // 外层不再套 GestureDetector，免得两个 tap 识别器抢同一个手势。
          SafeArea(
            bottom: true,
            child: _readerArea(fontSize, textColor, media),
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
      return _slideBody(text, fontSize, textColor);
    }
    return _scrollBody(text, fontSize, textColor, media);
  }

  /// 阅读区：滚动模式点哪都只是呼出控件；分页模式按手机习惯分三个热区。
  Widget _readerArea(double fontSize, Color textColor, MediaQueryData media) {
    final body = _body(fontSize, textColor, media);
    if (_store.settings.pageMode != NovelPageMode.slide) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: body,
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: Row(
            children: [
              Expanded(flex: 3, child: _tapZone(_prevPage)),
              Expanded(flex: 4, child: _tapZone(_toggleControls)),
              Expanded(flex: 3, child: _tapZone(_nextPage)),
            ],
          ),
        ),
      ],
    );
  }

  /// 透明的点击热区：只抢 tap，横向滑动仍然交给下层 PageView。
  Widget _tapZone(VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: const SizedBox.expand(),
    );
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
                fontFamilyFallback: novelFontFallback,
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
                    fontFamilyFallback: novelFontFallback,
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

  /// 左右翻页（0.7.86 重做）：整章精确排版后一屏一页。
  ///
  /// 页面结构：正文用 [CustomPaint] 按「行窗口」平移绘制——整章只排一次版，
  /// 翻页只是移动画布，既不会裁掉半行，也不会在滑动时重排卡顿。首页顶部叠
  /// 章节标题，右下角叠页码；最后一页之后接一张「下一章」过渡页，滑过去就
  /// 直接往下读，不用先退回去找按钮。
  Widget _slideBody(NovelText text, double fontSize, Color textColor) {
    final settings = _store.settings;
    final fontFamily = settings.fontFamily.fontFamily;
    final title = text.title.isNotEmpty
        ? text.title
        : (_chapters.length > _index ? _chapters[_index].title : '');
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        // 宽屏（桌面 / 平板）限制正文行宽：一行铺满 2560px 根本没法读。
        final sidePad = width >= 760 ? (width - 680) / 2 : 22.0;
        final contentWidth = math.max(160.0, width - sidePad * 2);
        // 底部留一条给页码，正文最后一行不贴边。
        const pageGap = 30.0;
        final contentHeight = math.max(120.0, height - 18 - pageGap);
        final titleInset = title.isEmpty ? 0.0 : fontSize * 1.45 + 20;

        final paging = _resolvePaging(
          text: text,
          title: title,
          width: contentWidth,
          height: contentHeight,
          fontSize: fontSize,
          lineHeight: settings.lineHeight,
          fontFamily: fontFamily,
          color: textColor,
          titleInset: titleInset,
        );

        final pageCount = paging.pageCount;
        if (_pageCount != pageCount) {
          final previous = _pageIndex;
          _pageCount = pageCount;
          // 底栏进度依赖页数，排完版补一帧重建（不能在 build 里 setState）。
          // 改字号 / 转屏都会重排，原页码可能超出新页数，顺手夹回来。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final fixed = math.min(previous, pageCount - 1);
            if (fixed != previous && _pager.hasClients) {
              _pager.jumpToPage(fixed);
            }
            setState(() => _pageIndex = fixed);
          });
        }
        _applyPendingPage(pageCount);

        final canNext = _index < _chapters.length - 1;
        // 桌面端默认只有触控设备能拖动滚动视图；这里把鼠标 / 触控板也放开，
        // 否则 Windows 上翻页只能点热区，拖不动。
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            dragDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
          ),
          child: PageView.builder(
            key: const ValueKey('novel-page-view'),
            controller: _pager,
            itemCount: pageCount + (canNext ? 1 : 0),
            onPageChanged: (value) {
              if (value >= pageCount) {
                // 滑到过渡页 = 用户明确要往下读，直接进下一章。
                _goTo(_index + 1);
                return;
              }
              _pageIndex = value;
              _persistProgress();
              // 无条件刷新：底栏进度即使在隐藏状态也要保持正确，
              // 否则用户在别处（如呼出控件瞬间）会看到上一页的数字。
              setState(() {});
            },
            itemBuilder: (context, index) {
              if (index >= pageCount) {
                return _chapterBridge(textColor, fontSize);
              }
              final slice = paging.slices[index];
              // 正文按「本页实际用到的高度」裁剪，不能用整页高度：
              // 页尾通常会剩不到一行的空隙，按整页裁就会把下一行的上半截
              // 漏出来，和下一页开头那行重复，看着像串行乱码。
              final canvas = SizedBox(
                height: slice.height,
                child: ClipRect(
                  child: CustomPaint(
                    painter: NovelPagePainter(
                      painter: paging.painter,
                      top: slice.top,
                    ),
                  ),
                ),
              );
              return Padding(
                padding: EdgeInsets.fromLTRB(sidePad, 18, sidePad, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (index == 0 && title.isNotEmpty)
                            SizedBox(
                              height: titleInset,
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: fontSize + 3,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                  fontFamily: fontFamily,
                                  fontFamilyFallback: novelFontFallback,
                                ),
                              ),
                            ),
                          canvas,
                        ],
                      ),
                    ),
                    // 页码单独占一条，不参与正文区高度，免得页尾只剩几像素时挤爆。
                    SizedBox(
                      height: pageGap,
                      child: pageCount > 1
                          ? Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                '${index + 1}/$pageCount',
                                style: TextStyle(
                                  color: textColor.withValues(alpha: .3),
                                  fontSize: 11.5,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 章末过渡页：滑到这里就进下一章，也可以点一下「继续阅读」。
  Widget _chapterBridge(Color textColor, double fontSize) {
    final next = _index + 1;
    final title = next < _chapters.length ? _chapters[next].title : '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '下一章',
              style: TextStyle(
                color: textColor.withValues(alpha: .45),
                fontSize: 12.5,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              key: const ValueKey('novel-chapter-bridge'),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: fontSize + 1,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => _goTo(next),
              style: OutlinedButton.styleFrom(
                foregroundColor: textColor,
                side: BorderSide(color: textColor.withValues(alpha: .25)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 12,
                ),
              ),
              child: const Text('继续阅读'),
            ),
          ],
        ),
      ),
    );
  }

  /// 取当前章的排版结果；窗口尺寸 / 字号 / 行距 / 配色变了才重排。
  NovelPagination _resolvePaging({
    required NovelText text,
    required String title,
    required double width,
    required double height,
    required double fontSize,
    required double lineHeight,
    required String? fontFamily,
    required Color color,
    required double titleInset,
  }) {
    final signature = [
      text.chapterId,
      width.toStringAsFixed(1),
      height.toStringAsFixed(1),
      fontSize.toStringAsFixed(2),
      lineHeight.toStringAsFixed(2),
      fontFamily ?? '',
      color.toString(),
      titleInset.toStringAsFixed(1),
    ].join('|');
    if (_paging != null && _pagingSignature == signature) return _paging!;
    final old = _paging;
    final next = NovelPagination.build(
      paragraphs: text.paragraphs,
      width: width,
      height: height,
      fontSize: fontSize,
      lineHeight: lineHeight,
      fontFamily: fontFamily,
      color: color,
      titleInset: titleInset,
    );
    _paging = next;
    _pagingSignature = signature;
    if (old != null) {
      // 旧的 painter 可能还在这一帧被画到，延后一帧再释放，避免野指针。
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    return next;
  }

  /// 切章 / 续读后把 PageView 定位到目标页。
  void _applyPendingPage(int pageCount) {
    final toLast = _pendingLastPage;
    final target = _pendingPage;
    if (!toLast && target == null) return;
    _pendingLastPage = false;
    _pendingPage = null;
    if (!toLast && target! >= pageCount) {
      // 旧版本（滚动模式）存的是像素偏移，当成页码会一下跳到最后一页；
      // 出现这种情况说明是升级上来的老进度，直接从第一页开始。
      return;
    }
    final page = math.min(
      math.max(toLast ? pageCount - 1 : target!, 0),
      math.max(0, pageCount - 1),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pager.hasClients) return;
      _pager.jumpToPage(page);
      if (mounted) setState(() => _pageIndex = page);
    });
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
