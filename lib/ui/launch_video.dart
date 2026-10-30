import 'dart:io';

import 'package:flutter/material.dart';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 开屏视频播放器（0.7.54）。
///
/// 把 media_kit 相关的一切隔离在这一个文件里：`AppSplash` 只看到
/// [layer]（可渲染的视频 widget）和 [done]（播完或失败）两个信号，
/// widget 测试因此不需要链接任何原生插件。
///
/// 行为约定：
/// - 静音播放，不留任何控制条——开屏就是一段纯画面。
/// - 首帧解码出来后 [layer] 才给出 Video，之前调用方继续用绘制场景兜底。
/// - 播放完成、出错、或者根本没得播（测试环境 / asset 缺失）都把
///   [done] 置 true：开屏不能因为视频坏了卡住启动。
class LaunchVideo {
  LaunchVideo(String asset)
      : done = ValueNotifier<bool>(_inTest),
        layer = ValueNotifier<Widget?>(null) {
    if (_inTest) return;

    final player = Player(
      configuration: const PlayerConfiguration(bufferSize: 8 << 20, muted: true),
    );
    _player = player;
    final controller = VideoController(player);
    _controller = controller;

    // 放行只认「真的播到了结尾」：
    // - completed == true（正常播完）；
    // - 或者进度推进到片长末尾 250ms 内（个别平台 completed 不可靠时的兜底）。
    // 中途的 error 事件**不再直接放行**——media_kit 播放中会吐出非致命
    // 错误（个别帧解码告警等），之前一刀切导致视频被中途切断进首页。
    // 只有视频压根没显示出来（layer 还是 null，等于没得播）才立即回退。
    player.stream.duration.listen((d) => _duration = d);
    player.stream.position.listen((p) {
      if (_duration <= Duration.zero) return;
      if (p >= _duration - const Duration(milliseconds: 250)) _settle();
    });
    player.stream.completed.listen((completed) {
      if (completed) _settle();
    });
    player.stream.error.listen((message) {
      assert(() {
        debugPrint('LaunchVideo: $message');
        return true;
      }());
      if (layer.value == null) _settle();
    });
    // 首帧尺寸就绪 = 解码管线已经出画面，这时才把视频层递给开屏页。
    player.stream.videoParams.listen((params) {
      if ((params.w ?? 0) <= 0 || (params.h ?? 0) <= 0) return;
      if (layer.value != null) return;
      layer.value = _LaunchVideoView(
        controller: _controller!,
        aspectRatio: params.w! / params.h!,
      );
    });

    player.open(Media('asset:///$asset'), play: true);
  }

  /// 播放已了结（完成 / 出错 / 不可用）——开屏页可以放行首页。
  final ValueNotifier<bool> done;

  /// 可渲染的视频层；就绪前置 null，调用方显示兜底场景。
  final ValueNotifier<Widget?> layer;

  Player? _player;
  VideoController? _controller;
  Duration _duration = Duration.zero;

  /// 测试环境没有可用的原生播放器，直接按"无视频"处理。
  static bool get _inTest => Platform.environment.containsKey('FLUTTER_TEST');

  void _settle() {
    if (done.value) return;
    done.value = true;
  }

  void dispose() {
    _player?.dispose();
    _player = null;
    _controller = null;
    done.dispose();
    layer.dispose();
  }
}

/// 开屏视频的自适应展示层。
///
/// 源视频是 16:9 横版（2560×1440），在竖屏手机上如果继续用
/// `BoxFit.cover`，视频会按高度撑满、宽度溢出屏幕外——iPhone 上只能
/// 看到原画面中间约 26% 的一条，月亮和孤岛全被裁掉（0.7.75 修）。
///
/// - **横屏**（桌面 / 平板横持）：维持原行为，cover 铺满 + 1.08 倍以
///   右下为锚点放大，把左上角的「AI生成」角标推出画面。
/// - **竖屏**（手机）：视频按宽等比完整居中显示（contain），上下不足
///   的部分用与画面同色系的夜空渐变补底，视频带上下边缘再渐隐一段，
///   让画面自然溶进底色里而不是一道硬边。
class _LaunchVideoView extends StatelessWidget {
  const _LaunchVideoView({required this.controller, required this.aspectRatio});

  final VideoController controller;

  /// 源视频宽高比（来自首帧 videoParams）。
  final double aspectRatio;

  /// 左上角「AI生成」角标的裁切系数：以右下为锚点放大 1.08 倍，
  /// 角标区域（约左 6.5% × 上 5.2%）被推出可视范围。
  static const _watermarkCrop = 1.08;

  /// 竖屏下视频带上下边缘的渐隐高度（占视频带高）。
  static const _edgeFade = 0.035;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width;
    if (!portrait) {
      return ClipRect(
        child: Transform.scale(
          scale: _watermarkCrop,
          alignment: const Alignment(1, 1),
          child: _plainVideo(BoxFit.cover),
        ),
      );
    }

    final bandH = size.width / aspectRatio;
    final bandTop = (size.height - bandH) / 2;
    final t1 = (bandTop / size.height).clamp(0.0, 1.0);
    final t2 = ((bandTop + bandH) / size.height).clamp(0.0, 1.0);

    // 补底渐变：贴着视频带上缘用「视频天空近顶部」的深蓝，
    // 贴着下缘用「视频海面底部」的深蓝，向两端各自沉入近黑。
    // 视频边缘本身有 [_edgeFade] 的渐隐，两层叠起来没有硬接缝。
    final backdrop = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Color(0xFF010614),
            Color(0xFF041040),
            Color(0xFF061B62),
            Color(0xFF021E7B),
            Color(0xFF010818),
          ],
          stops: [
            0,
            t1 > 0.001 ? t1 - 0.001 : t1,
            t2 < 0.999 ? t2 - 0.001 : t2,
            t2 < 0.98 ? t2 + 0.02 : 1,
            1,
          ],
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        backdrop,
        Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: ShaderMask(
              // dstIn：让视频带上下边缘按渐变透明度淡出，露出补底。
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x00000000),
                  Color(0xFFFFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0x00000000),
                ],
                stops: [0, _edgeFade, 1 - _edgeFade, 1],
              ).createShader(bounds),
              child: ClipRect(
                child: Transform.scale(
                  scale: _watermarkCrop,
                  alignment: const Alignment(1, 1),
                  child: _plainVideo(BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _plainVideo(BoxFit fit) => Video(
        controller: controller,
        fit: fit,
        controls: NoVideoControls,
      );
}
