import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 「Glass Noir 深空」设计体系（0.7.35 UI 改版，用户已确认 12 屏预览）。
///
/// 令牌与画布预览稿一一对应：
/// - 页面底色   #060A16（近黑深空蓝）
/// - 卡片底色   #121B30（细白描边 8%）
/// - 主色       #2E5FBF（选中态 / 主按钮实心）
/// - 星光蓝     #58A5FB（焦点框 / 链接 / 强调图标）
/// - 文字       #F2F5FA 主文字 / #8B95AA 次级 / #5A657C 弱化
abstract final class AppTheme {
  /// 深空底色（页面背景）。
  static const Color space = Color(0xFF060A16);

  /// 卡片底色。
  static const Color card = Color(0xFF121B30);

  /// 卡片细白描边（8% 白）。
  static const Color cardStroke = Color(0x14FFFFFF);

  /// 主色：选中态 / 主按钮。
  static const Color primary = Color(0xFF2E5FBF);

  /// 星光蓝：焦点框、强调、链接。
  static const Color starlight = Color(0xFF58A5FB);

  /// 侧栏 / 胶囊悬停底色。
  static const Color hoverFill = Color(0xFF1A2338);

  /// 主文字。
  static const Color textPrimary = Color(0xFFF2F5FA);

  /// 次级文字。
  static const Color textSecondary = Color(0xFF8B95AA);

  /// 弱化文字 / 占位。
  static const Color textDim = Color(0xFF5A657C);

  static final light = _theme(Brightness.light);
  static final dark = _theme(Brightness.dark);

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// 全局按钮规格：44px 高、圆角 22 胶囊（0.7.35 预览稿 D06 控件规范）。
  static ButtonStyle _pillButton(ColorScheme scheme) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 22),
    ),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
    ),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
    ),
    foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
  );

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? space : const Color(0xFFF2F4F9);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: dark ? primary : const Color(0xFF2E5FBF),
      onPrimary: Colors.white,
      primaryContainer: dark ? const Color(0xFF1B3A6B) : const Color(0xFFDCE7FA),
      onPrimaryContainer: dark ? const Color(0xFFBBD4FB) : const Color(0xFF12315F),
      secondary: starlight,
      onSecondary: dark ? const Color(0xFF06122A) : Colors.white,
      tertiary: starlight,
      surface: dark ? card : Colors.white,
      onSurface: dark ? textPrimary : const Color(0xFF1A2233),
      onSurfaceVariant: dark ? textSecondary : const Color(0xFF5A657C),
      outline: dark ? const Color(0xFF39435C) : const Color(0xFFAEB6C6),
      outlineVariant: dark ? cardStroke : const Color(0xFFE2E7F0),
      surfaceContainerLowest: dark ? const Color(0xFF04070F) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF0D1424) : const Color(0xFFF6F8FC),
      surfaceContainer: dark ? card : const Color(0xFFEEF1F7),
      surfaceContainerHigh: dark ? hoverFill : const Color(0xFFE5EAF3),
      surfaceContainerHighest: dark ? const Color(0xFF222C46) : const Color(0xFFDCE2ED),
      surfaceTint: Colors.transparent,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        // 深色下卡片带一圈 8% 细白描边，浅色下用极淡的蓝灰线。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? card : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        barrierColor: dark ? const Color(0xB3000000) : null,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark ? const Color(0xFF222C46) : const Color(0xFF2A3448),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: .7)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(23),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(23),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(23),
          borderSide: BorderSide(color: scheme.secondary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: _pillButton(scheme)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: _pillButton(scheme)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _pillButton(scheme).copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outline ?? scheme.outlineVariant),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _pillButton(scheme).copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.secondary),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          highlightColor: scheme.surfaceContainerHigh,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.secondary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          dark ? const Color(0x33FFFFFF) : const Color(0x33000000),
        ),
      ),
    );
  }
}
