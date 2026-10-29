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
      layer.value = Video(
        controller: _controller!,
        fit: BoxFit.cover,
        controls: NoVideoControls,
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
