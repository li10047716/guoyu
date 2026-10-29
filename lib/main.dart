import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/ui/app_layout.dart';
import 'package:duanju_app/ui/app_splash.dart';
import 'package:duanju_app/ui/app_theme.dart';
import 'package:duanju_app/ui/launch_video.dart';
import 'package:duanju_app/platform/app_updater.dart';
import 'package:duanju_app/platform/brand_migration.dart';
import 'package:duanju_app/platform/desktop_title_bar.dart';
import 'package:duanju_app/ui/home_screen.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/ui/profiles_screen.dart';
import 'package:duanju_app/downloads/media_library.dart';
import 'package:duanju_app/core/package_smoke.dart';
import 'package:duanju_app/lan/lan_controller.dart';
import 'package:duanju_app/player/vertical_feed_screen.dart';
import 'package:duanju_app/ui/widgets.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    // 0.7.43（用户要求）：隐藏系统标题栏，最小化/最大化/关闭改用应用内按钮
    // （DesktopTitleBar）。
    // 注意 ensureInitialized 不能省：插件靠它拿到根窗口句柄（native_window），
    // 缺了它后续所有窗口调用都在空句柄上打转（实测 getSize 直接抛空指针）。
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(titleBarStyle: TitleBarStyle.hidden),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  MediaKit.ensureInitialized();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  // 0.7.34 改名「果屿」：本地数据目录随之变化，必须赶在任何本地存储被读取之前搬完。
  await migrateLegacyBrandData();
  runApp(const AppBootstrap());
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  final navigator = GlobalKey<NavigatorState>();

  /// 开屏页就绪信号（控制开屏页淡出）。
  ///
  /// 0.7.21：首页竖滑流入口已移除，不再等待"第一批可播放视频"；
  /// 主界面首帧渲染完成即视为就绪（最短展示时长仍由开屏页保证）。
  final _feedReady = ValueNotifier<bool>(false);

  /// 开屏视频（0.7.54）。media_kit 的生命周期在这里管理，
  /// 测试环境（FLUTTER_TEST）里 LaunchVideo 会自动按"无视频"处理。
  LaunchVideo? _launchVideo;

  LocalStore? store;
  Object? error;
  AppDevice device = const AppDevice();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _feedReady.dispose();
    _launchVideo?.dispose();
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    store?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _launchVideo = LaunchVideo('assets/branding/app_launch.mp4');
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  Future<void> _initialize() async {
    setState(() {
      error = null;
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      device = await AppDevice.detect();
      await repository.initialize();
      if (mounted) {
        setState(() {
          store = LocalStore(preferences);
          repository.access = store;
          MediaLibrary.attach(repository, store!);
          LanController.current?.dispose();
          final link = LanController(
            repository,
            store!,
            kind: device.television
                ? 'tv'
                : Platform.isWindows
                ? 'computer'
                : 'phone',
          );
          LanController.current = link;
          link.openPlayback = (request) async {
            final epoch = request.profileEpoch;
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                !link.receiving ||
                store!.profileEpoch != epoch ||
                !store!.allowsSource(request.detail.drama.source)) {
              throw StateError('当前用户不能接收播放');
            }
            await link.playbackHost?.stop();
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                store!.profileEpoch != epoch ||
                !link.receiving) {
              throw StateError('播放接收已取消');
            }
            final navigation = navigator.currentState;
            if (navigation == null) throw StateError('接收设备界面尚未就绪');
            unawaited(
              navigation.pushAndRemoveUntil<void>(
                MaterialPageRoute<void>(
                  // 0.6.4：局域网推送接收播放改用**新播放器**（竖滑播放器）。
                  //
                  // 迁移原因：老播放器 `player_screen.dart` 即将删除（XF-0003），
                  // 它最后的独有能力就是这条接收链路。
                  // 用 `singleDrama` 走"单剧模式"：上滑下一集、下滑上一集，
                  // 到边界只提示，与老播放器"这是一部剧"的语义一致；
                  // `initialEpisodeIndex` / `initialPosition` 承接发送端的续播点。
                  builder: (_) => VerticalFeedScreen(
                    repository: repository,
                    store: store!,
                    singleDrama: request.detail.drama,
                    initialEpisodeIndex: request.index,
                    initialPosition: request.position,
                    handoff: request,
                  ),
                ),
                (route) => route.isFirst,
              ),
            );
          };
        });
        // 界面就绪后检查更新（仅 Android；失败静默跳过，不阻塞启动）。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = navigator.currentContext;
          if (target != null) {
            unawaited(AppUpdater.checkOnStartup(target));
          }
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
    navigatorKey: navigator,
    feedReady: _feedReady,
    launchVideo: _launchVideo,
  );
}

class DuanjuApp extends StatelessWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
    this.feedReady,
    this.launchVideo,
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 主界面是否已就绪（控制开屏页）。为空时不开开屏页（如测试）。
  final ValueNotifier<bool>? feedReady;

  /// 开屏视频（0.7.54）。生命周期归 [_AppBootstrapState] 管理，
  /// 这里只把信号转发给 [AppSplash]。
  final LaunchVideo? launchVideo;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([store]),
    builder: (_, _) => _application(),
  );

  Widget _application() => MaterialApp(
    navigatorKey: navigatorKey,
    title: appName,
    debugShowCheckedModeBanner: false,
    // 0.7.28（用户要求）：桌面端也能"按住界面往下拖"来刷新/滚动。
    // Flutter 默认把鼠标排除在可拖拽设备之外，这里放开。
    scrollBehavior: const AppScrollBehavior(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: AppTheme.mode(store?.themeMode ?? 'dark'),
    builder: (context, child) {
      final mode = store?.displayMode ?? 'auto';
      final tv = mode == 'television' || mode == 'auto' && television;
      final theme = Theme.of(context);
      final content = AppLayout(
        television: tv,
        version: version,
        child: Theme(
          data: tv ? televisionTheme(theme) : theme,
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(
                LogicalKeyboardKey.select,
                includeRepeats: false,
              ): ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.gameButtonA,
                includeRepeats: false,
              ): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
            },
            child: FocusTraversalGroup(child: child!),
          ),
        ),
      );
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(theme.brightness),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          // 0.7.43（用户要求）：Windows 隐藏系统标题栏后，应用内标题栏
          // （DesktopTitleBar）放在所有页面之上，窗口按钮与拖动全局可用。
          child: Platform.isWindows
              ? Column(
                  children: [
                    const DesktopTitleBar(),
                    Expanded(child: content),
                  ],
                )
              : content,
        ),
      );
    },
    home: store != null
        ? store!.locked
              ? ProfilesScreen(store: store!, locked: true)
              : _withSplash(
                  HomeScreen(
                    key: ValueKey(
                      'profile-${store!.profile.id}-${store!.profileEpoch}',
                    ),
                    repository: repository,
                    store: store!,
                  ),
                )
        : Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_circle_fill_rounded,
                      color: AppTheme.starlight,
                      size: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      bootstrapError ?? '正在打开$appName',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 24),
                    if (bootstrapError == null)
                      const CircularProgressIndicator()
                    else
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('重新打开'),
                      ),
                  ],
                ),
              ),
            ),
          ),
  );

  /// 用开屏页盖住主界面，等主界面首帧就绪后淡出。
  ///
  /// 测试或未注入就绪信号时直接返回主界面（不显示开屏页）。
  Widget _withSplash(Widget child) {
    final ready = feedReady;
    if (ready == null) return child;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ready.value) ready.value = true;
    });
    // 0.7.54：开屏改为播放 assets/branding/app_launch.mp4（media_kit），
    // 播完才放行首页；视频加载失败自动回退到纯绘制场景。
    return AppSplash(
      ready: ready,
      videoLayer: launchVideo?.layer,
      videoDone: launchVideo?.done,
      child: child,
    );
  }
}
