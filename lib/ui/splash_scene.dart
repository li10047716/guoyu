import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 开屏页入场动画时长。
///
/// 与 `_SplashSurface` 的 AnimationController 共用，测试也引用它，
/// 避免再出现「改了时长忘了改断言」的情况。
const splashIntroDuration = Duration(milliseconds: 1600);

const double _introMs = 1600;

/// 环境动效（星闪、水波、月晕、星芒）循环一轮的秒数。
const double _ambientCycle = 9;

/// 场景底色，与 logo 的夜空同色系。
///
/// 也是 Flutter 首帧与原生启动画面共用的颜色，换成别的会「跳色」。
const splashSky = Color(0xFF060A16);

/// 地平线位置（占屏高）。
///
/// logo 里是 0.670；这里上移一点，把下半部让给字标，否则标题正好压在
/// 那条最亮的水面上，怎么调阴影都显得脏。
const double _horizonRatio = 0.610;

/// 主岛山脊：`dx` 以构图宽为 1，`dy` 以短边为单位、地平线为 0、向上为负。
///
/// 数值是照着 `assets/branding/logo.png` 逐列量出来的：左边缓坡 →
/// x0.36 的鞍部 → x0.47 的主峰尖顶 → 右侧陡崖 → x0.69 的小峰 → 平滩。
/// 刻意用低多边形折线而不是贝塞尔曲线：直线段在深空剪影里更像山，
/// 平滑曲线反而像沙丘。两端延伸到构图外，宽屏上不会在两侧露出空海面。
const List<Offset> _ridge = [
  // 两端**正好落在地平线上**，也不延伸到画面外：
  // 山体一旦横贯全屏、或者两端沉到水面下，多边形那条水平的
  // 闭合底边就会在海平线上拉出一条深色带子，看着像一道裂缝。
  Offset(0.040, 0.000),
  Offset(0.075, 0.000),
  Offset(0.100, 0.000),
  Offset(0.140, -0.005),
  Offset(0.180, -0.021),
  Offset(0.220, -0.038),
  Offset(0.260, -0.064),
  Offset(0.290, -0.096),
  Offset(0.330, -0.125),
  // 鞍部：主峰与左坡之间的凹口，没有它山就是一整块斜三角。
  Offset(0.360, -0.109),
  Offset(0.400, -0.142),
  Offset(0.440, -0.203),
  Offset(0.470, -0.261),
  // 主峰右侧是陡崖：水平 3% 掉 13% 高度，这个陡度是「尖峰」的关键。
  Offset(0.492, -0.164),
  Offset(0.505, -0.091),
  Offset(0.530, -0.052),
  Offset(0.570, -0.013),
  Offset(0.600, -0.003),
  Offset(0.630, -0.019),
  Offset(0.660, -0.055),
  Offset(0.690, -0.083),
  Offset(0.720, -0.042),
  Offset(0.750, -0.010),
  Offset(0.800, 0.000),
  Offset(0.862, 0.000),
  Offset(0.920, 0.000),
];

/// 启动页「星夜孤岛」动态场景。
///
/// 构图与 `assets/branding/logo.png` 一一对应，元素只有图标里有的那些：
///
/// - **宝蓝夜空**：顶部深、近海平线亮，月牙一侧再叠一层暖色水汽
/// - **星野**：64 颗点星 + 60 粒星尘 + 5 颗小四角星，各自正弦呼吸
/// - **粗月牙**：占左侧三分之一的大月牙，两层月晕缓慢脉动
/// - **大四角星**：图标右侧那颗主星，光晕呼吸、尖角微伸缩、极缓自转
/// - **三峰山**：左坡 / 主峰 / 小峰，左暗右亮的橙金受光面
/// - **亮蓝海面**：横向波纹以不同速度漂移
/// - **S 形月光带**：从地平线中央蜿蜒向下的一整条，水波在上面切开横纹
///
/// 上一版（0.7.52）里的流星、远山剪影已经去掉——图标里没有这两样东西，
/// 加进来反而冲淡了「图标活了」的直觉。
///
/// 实现上只用一个 CustomPainter 画满屏，每帧约 220 次绘制调用；
/// 山体等静态形状每帧按尺寸重算路径，成本很低。
///
/// 无障碍：系统开启「减少动态效果」（`MediaQuery.disableAnimations`）时，
/// 场景直接定格在完成态，不做任何循环动效。
class SplashScene extends StatelessWidget {
  const SplashScene({super.key, required this.intro, required this.ambient});

  /// 入场进度（0~1，1600ms）。
  final Animation<double> intro;

  /// 环境动效时钟（0~1，9 秒一轮）。
  final Animation<double> ambient;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScenePainter(
          intro: intro,
          ambient: ambient,
          stars: _splashStars,
          dust: _splashDust,
          sparks: _splashSparks,
          reduceMotion: MediaQuery.of(context).disableAnimations,
        ),
      ),
    );
  }
}

/// 构图坐标系：短边 `s` 为一个单位，画面水平居中；宽屏时横向按 [spread] 展开。
class _Frame {
  const _Frame({
    required this.w,
    required this.h,
    required this.s,
    required this.horizon,
    required this.originX,
    required this.width,
  });

  final double w;
  final double h;
  final double s;
  final double horizon;
  final double originX;

  /// 构图宽（= 一个单位 × 横向展开系数）。
  final double width;

  /// 构图坐标 → 屏幕坐标。`u` 以构图宽为 1，`v` 以短边为单位、地平线为 0。
  Offset at(double u, double v) =>
      Offset(originX + u * width, horizon + v * s);
}

/// 一颗星：位置是相对**屏幕**的 0~1 归一坐标。
class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.phase,
    required this.speed,
    required this.peak,
    required this.delay,
  });

  final double x;
  final double y;
  final double radius;
  final double phase;
  final double speed;
  final double peak;

  /// 入场时的点亮延迟（毫秒）。
  final int delay;
}

/// 一颗小四角星：位置用**构图**坐标，和月牙、山保持相对关系。
class _Spark {
  const _Spark({
    required this.u,
    required this.v,
    required this.size,
    required this.phase,
    required this.peak,
    required this.delay,
  });

  final double u;
  final double v;
  final double size;
  final double phase;
  final double peak;
  final int delay;
}

/// 星野用固定种子生成：每次启动看到的是同一片星空，
/// 不会因为「这次星星位置又变了」而显得廉价。
final List<_Star> _splashStars = _buildStars();

/// 星尘：比星星更小更暗、几乎不闪的一层，用来把天空"填实"。
final List<_Star> _splashDust = _buildDust();

/// 小四角星：图标里散在天空的几颗 sparkle，位置照抄图标。
final List<_Spark> _splashSparks = const [
  _Spark(u: 0.862, v: -0.415, size: 0.030, phase: 1.4, peak: 0.92, delay: 300),
  _Spark(u: 0.585, v: -0.595, size: 0.024, phase: 3.1, peak: 0.78, delay: 190),
  _Spark(u: 0.150, v: -0.195, size: 0.022, phase: 5.2, peak: 0.74, delay: 380),
  _Spark(u: 0.300, v: -0.480, size: 0.017, phase: 0.6, peak: 0.60, delay: 250),
  _Spark(u: 0.420, v: -0.250, size: 0.014, phase: 2.3, peak: 0.52, delay: 450),
];

List<_Star> _buildStars() {
  final rnd = math.Random(20261028);
  final stars = <_Star>[];
  while (stars.length < 92) {
    stars.add(
      _Star(
        x: rnd.nextDouble(),
        // 只铺在地平线以上，留 1% 余量给海平线雾带。
        y: rnd.nextDouble() * (_horizonRatio - 0.01),
        radius: 0.55 + rnd.nextDouble() * 1.35,
        phase: rnd.nextDouble() * math.pi * 2,
        speed: 0.55 + rnd.nextDouble() * 1.7,
        peak: 0.28 + rnd.nextDouble() * 0.62,
        delay: rnd.nextInt(520),
      ),
    );
  }
  return stars;
}

List<_Star> _buildDust() {
  final rnd = math.Random(77023);
  return List<_Star>.generate(90, (_) {
    return _Star(
      x: rnd.nextDouble(),
      y: rnd.nextDouble() * (_horizonRatio - 0.01),
      radius: 0.22 + rnd.nextDouble() * 0.42,
      phase: rnd.nextDouble() * math.pi * 2,
      speed: 0.25 + rnd.nextDouble() * 0.6,
      peak: 0.08 + rnd.nextDouble() * 0.16,
      delay: rnd.nextInt(680),
    );
  });
}

/// 稳定的伪随机（0~1）：给水波切割的间距、粗细做"不均匀"。
double _hash(double seed) {
  final v = math.sin(seed * 12.9898) * 43758.5453;
  return v - v.floorToDouble();
}

/// 把 [t] 在 [start, end] 区间内映射成 0~1 并做 easeOutCubic。
double _ease(double t, double start, double end) {
  if (t <= start) return 0;
  if (t >= end) return 1;
  return Curves.easeOutCubic.transform((t - start) / (end - start));
}

Color _alpha(Color color, double value) =>
    color.withValues(alpha: value.clamp(0.0, 1.0));

class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.intro,
    required this.ambient,
    required this.stars,
    required this.dust,
    required this.sparks,
    required this.reduceMotion,
  }) : super(repaint: Listenable.merge([intro, ambient]));

  final Animation<double> intro;
  final Animation<double> ambient;
  final List<_Star> stars;
  final List<_Star> dust;
  final List<_Spark> sparks;
  final bool reduceMotion;

  @override
  bool shouldRepaint(_ScenePainter oldDelegate) =>
      oldDelegate.reduceMotion != reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w < 2 || h < 2) return;

    final clock = reduceMotion ? 0.0 : ambient.value * _ambientCycle;
    final t = reduceMotion ? 1.0 : intro.value;
    final s = math.min(w, h);
    // 宽屏时把构图横向摊开一点（1:1 为 1，16:9 约 1.17），
    // 否则月牙、大星、山尖会挤在中轴附近，两侧空得像没画完。
    final spread = 1 + 0.22 * ((w / h) - 1).clamp(0.0, 1.0).toDouble();
    final frame = _Frame(
      w: w,
      h: h,
      s: s,
      horizon: h * _horizonRatio,
      originX: (w - s * spread) / 2,
      width: s * spread,
    );
    // 柔光层要模糊才有"光"的样子。门槛压到 300：640×360 的预览、
    // 竖屏手机都能吃到，只有极小的缩略图尺寸才跳过。
    final softGlow = w >= 300;

    _paintSky(canvas, frame, clock, t);
    _paintSkyNebula(canvas, frame, t);
    _paintStars(canvas, frame, clock, t);
    _paintMoon(canvas, frame, clock, t, softGlow);
    _paintHalo(canvas, frame, clock, t, softGlow);
    _paintSea(canvas, frame, clock, t);
    _paintWaterShade(canvas, frame);
    _paintSeaRipples(canvas, frame, clock, t);
    _paintSeaGlints(canvas, frame, clock, t);
    _paintIslandReflection(canvas, frame, t);
    _paintMoonRibbon(canvas, frame, clock, t, softGlow);
    _paintIsland(canvas, frame, clock, t);
    _paintHorizonHaze(canvas, frame, t);
    _paintVignette(canvas, frame, t);
  }

  // ── 夜空 ──────────────────────────────────────────────────────────────

  void _paintSky(Canvas canvas, _Frame f, double clock, double t) {
    final p = _ease(t, 0.0, 0.26);
    if (p <= 0) return;
    final rect = Rect.fromLTWH(0, 0, f.w, f.horizon + 1);

    // 底：上深下亮的宝蓝。logo 的天空是 #021464 那一档蓝，
    // 全屏铺开太扎眼，这里压到 #0B2470 收尾，靠海的亮度把层次拉出来。
    // 颜色乘 p 淡入，才能从原生启动画面的底色平滑接上来，不跳色。
    // logo 的天空不是上下渐变，而是**以月牙为光心的径向**：
    // 左上 #012AA0、右上 #010F5A，差了一倍。用垂直渐变会平掉这个层次。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.30, -0.52),
          radius: 1.22,
          colors: [
            _alpha(const Color(0xFF0C31A6), p),
            _alpha(const Color(0xFF041B78), p),
            _alpha(const Color(0xFF010B46), p),
          ],
          stops: const [0, 0.52, 1],
        ).createShader(rect),
    );

    // 月牙那一侧的水汽：让左半天空比右边暖一点，月亮才有"光在散"的感觉。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.34, -0.30),
          radius: 1.15,
          colors: [
            _alpha(const Color(0xFFFFE2B4), 0.075 * p),
            _alpha(const Color(0xFFFFE2B4), 0),
          ],
          stops: const [0, 1],
        ).createShader(rect),
    );
  }

  void _paintStars(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
  ) {
    final paint = Paint();
    final unit = (f.s / 720).clamp(0.55, 2.0).toDouble();

    for (final mote in dust) {
      final reveal = _ease(
        t,
        mote.delay / _introMs,
        (mote.delay + 700) / _introMs,
      );
      if (reveal <= 0) continue;
      final twinkle = 0.82 + 0.18 * math.sin(clock * mote.speed + mote.phase);
      paint.color = _alpha(
        const Color(0xFFCFE0FF),
        mote.peak * twinkle * reveal,
      );
      canvas.drawCircle(
        Offset(mote.x * f.w, mote.y * f.h),
        mote.radius * unit * 0.75,
        paint,
      );
    }

    for (final star in stars) {
      final reveal = _ease(
        t,
        star.delay / _introMs,
        (star.delay + 460) / _introMs,
      );
      if (reveal <= 0) continue;
      final twinkle = 0.58 + 0.42 * math.sin(clock * star.speed + star.phase);
      paint.color = _alpha(Colors.white, star.peak * twinkle * reveal);
      canvas.drawCircle(
        Offset(star.x * f.w, star.y * f.h),
        star.radius * unit * 0.62,
        paint,
      );
    }

    for (final spark in sparks) {
      final reveal = _ease(
        t,
        spark.delay / _introMs,
        (spark.delay + 520) / _introMs,
      );
      if (reveal <= 0) continue;
      final twinkle = 0.70 + 0.30 * math.sin(clock * 0.8 + spark.phase);
      final r = spark.size * f.s;
      _paintSparkShape(
        canvas,
        f.at(spark.u, spark.v),
        r,
        r,
        spark.peak * twinkle * reveal,
      );
    }
  }

  // ── 月牙 ──────────────────────────────────────────────────────────────

  /// logo 里的月牙又粗又大：圆心在构图 (0.36, -0.31)，外径 0.25 个短边，
  /// 亮带最厚处约 0.13 个短边，开口朝右。这些数都是从图上量的。
  void _paintMoon(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
    bool softGlow,
  ) {
    final p = _ease(t, 0.06, 0.52);
    if (p <= 0) return;

    final r = f.s * 0.228;
    // 入场：从下方升起 2% + 淡出放大，比"直接出现"更有分量。
    final rise = (1 - p) * f.s * 0.022;
    final c = f.at(0.360, -0.310) + Offset(0, rise);
    final scale = 0.94 + 0.06 * p;
    final rr = r * scale;

    // 月晕：两层同心径向渐变，脉动 ±4%，很轻，久了才看得出在动。
    final pulse = 1 + 0.04 * math.sin(clock * 0.7);
    for (final layer in const [1.75, 3.2]) {
      final radius = rr * layer * pulse;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              _alpha(
                const Color(0xFFFFE7B0),
                0.20 * p * (layer < 2 ? 0.34 : 0.12),
              ),
              _alpha(const Color(0xFFFFE7B0), 0),
            ],
            stops: const [0.34, 1],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }

    // 月牙 = 大盘减去一个偏右上、半径相近的盘：剩余部分在左侧，开口朝右。
    final outer = Path()..addOval(Rect.fromCircle(center: c, radius: rr));
    final bite = Path()
      ..addOval(
        Rect.fromCircle(
          center: c.translate(rr * 0.520, -rr * 0.080),
          radius: rr * 0.982,
        ),
      );
    final crescent = Path.combine(PathOperation.difference, outer, bite);

    // 月面：外缘近白偏暖，往内缘过渡到淡紫——logo 的月牙内缘有一层紫，
    // 少了这层就是一块死白的弯钩。
    canvas.drawPath(
      crescent,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [
            Color(0xFFFFFCF2),
            Color(0xFFFDEBC8),
            Color(0xFFE6D8FF),
          ],
          stops: const [0, 0.52, 1],
        ).createShader(
          Rect.fromCircle(center: c, radius: rr),
        ),
    );

    // 环形山：两三个极淡的暖斑，纯白弯钩会像剪纸，有了它才有"月面"的质感。
    canvas.save();
    canvas.clipPath(crescent);

    // 内缘暗弧：月牙的凹侧背着光，靠内缘的月面要暗一档，
    // 平涂的弯钩是张纸片，有了这道暗弧才是"被照亮球体的边"。
    // 以咬掉内盘的圆心为中心画径向环——暗带贴着内缘、向外衰减。
    final biteC = c.translate(rr * 0.520, -rr * 0.080);
    final biteR = rr * 0.982;
    canvas.drawCircle(
      biteC,
      rr * 1.65,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x00000000),
            _alpha(const Color(0xFF1E1546), 0.52 * p),
            const Color(0x00000000),
          ],
          stops: const [0.56, 0.60, 0.78],
        ).createShader(Rect.fromCircle(center: biteC, radius: rr * 1.65)),
    );

    canvas.drawCircle(
      c.translate(rr * 0.30, -rr * 0.24),
      rr * 0.24,
      Paint()..color = const Color(0x14D8A15E),
    );
    canvas.drawCircle(
      c.translate(rr * 0.06, rr * 0.30),
      rr * 0.16,
      Paint()..color = const Color(0x10D8A15E),
    );
    canvas.restore();

    // 月牙外侧再罩一层暖光，让边缘不是硬边。
    if (softGlow) {
      canvas.drawPath(
        crescent,
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.055)
          ..shader = RadialGradient(
            colors: [
              _alpha(const Color(0xFFFFD79A), 0.20 * p),
              _alpha(const Color(0xFFFFD79A), 0),
            ],
            stops: const [0.6, 1],
          ).createShader(Rect.fromCircle(center: c, radius: rr)),
      );
    }
  }

  /// 图标右侧那颗主星：四尖 sparkle + 中心亮核 + 一圈光晕 + 竖向下垂的光尾。
  void _paintHalo(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
    bool softGlow,
  ) {
    final p = _ease(t, 0.20, 0.62);
    if (p <= 0) return;

    final c = f.at(0.665, -0.360);
    // 尖角长度轻度伸缩（±5%），幅度再大就变成"在抽搐"。
    final breath = 1 + 0.05 * math.sin(clock * 0.85);
    final ax = f.s * 0.082 * breath * (0.45 + 0.55 * p);
    final ay = f.s * 0.096 * breath * (0.45 + 0.55 * p);

    // 光晕：跟着呼吸，是整个画面最亮的一点。
    final glowR = f.s * 0.30;
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _alpha(const Color(0xFFDCE9FF), 0.26 * p * breath),
            _alpha(const Color(0xFF9FC4FF), 0.07 * p),
            _alpha(const Color(0xFF9FC4FF), 0),
          ],
          stops: const [0, 0.40, 1],
        ).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );

    // 竖向下垂的光尾：logo 里这颗星下方拖着一道淡淡的光，一直落到月牙内弧。
    final tail = Rect.fromLTWH(
      c.dx - f.s * 0.016,
      c.dy,
      f.s * 0.032,
      f.s * 0.355,
    );
    canvas.drawRect(
      tail,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFFEAF2FF), 0.20 * p),
            _alpha(const Color(0xFFEAF2FF), 0.05 * p),
            _alpha(const Color(0xFFEAF2FF), 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(tail),
    );

    if (softGlow) {
      canvas.drawPath(
        _sparklePath(c, ax * 1.30, ay * 1.30),
        Paint()
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, f.s * 0.012)
          ..color = _alpha(const Color(0xFFDCE9FF), 0.55 * p),
      );
    }
    _paintSparkShape(canvas, c, ax, ay, 1.0 * p);
  }

  /// 四尖星的四角星形。控制点贴得很近，四条边才会向内收成细腰。
  Path _sparklePath(Offset c, double ax, double ay) {
    const waist = 0.16;
    final wx = ax * waist;
    final wy = ay * waist;
    return Path()
      ..moveTo(c.dx, c.dy - ay)
      ..quadraticBezierTo(c.dx + wx, c.dy - wy, c.dx + ax, c.dy)
      ..quadraticBezierTo(c.dx + wx, c.dy + wy, c.dx, c.dy + ay)
      ..quadraticBezierTo(c.dx - wx, c.dy + wy, c.dx - ax, c.dy)
      ..quadraticBezierTo(c.dx - wx, c.dy - wy, c.dx, c.dy - ay)
      ..close();
  }

  void _paintSparkShape(
    Canvas canvas,
    Offset c,
    double ax,
    double ay,
    double alpha,
  ) {
    if (alpha <= 0.01 || ax <= 0.2) return;
    canvas.drawPath(
      _sparklePath(c, ax, ay),
      Paint()..color = _alpha(Colors.white, alpha),
    );
    // 中心亮核：没有它，纯白星形在亮天空里会显得"扁"。
    final core = math.max(1.0, math.min(ax, ay) * 0.34);
    canvas.drawCircle(
      c,
      core,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _alpha(Colors.white, alpha),
            _alpha(const Color(0xFFEAF2FF), 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: core)),
    );
  }

  // ── 海面 ──────────────────────────────────────────────────────────────

  void _paintSea(Canvas canvas, _Frame f, double clock, double t) {
    final p = _ease(t, 0.24, 0.66);
    if (p <= 0) return;

    final rect = Rect.fromLTWH(0, f.horizon, f.w, f.h - f.horizon);
    // 海色是照着 logo 逐行采的：海平线偏白的亮带 #9AB8ED，
    // 往下经宝蓝 #5370DF 沉到 #0A37B6。不是纯青蓝，也别往黑里压。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFF4A78F0), p),
            _alpha(const Color(0xFF3665E9), p),
            _alpha(const Color(0xFF3158DD), p),
            _alpha(const Color(0xFF021E7B), p),
          ],
          stops: const [0, 0.12, 0.44, 1],
        ).createShader(rect),
    );

  }

  /// 天空里的两团极淡星云。
  ///
  /// 纯平的渐变更容易显得"素"；两团几乎看不见的冷紫柔光就能把天空
  /// 从"一块色卡"变成"一片夜空"。透明度很低，不能抢月牙的戏。
  void _paintSkyNebula(Canvas canvas, _Frame f, double t) {
    final p = _ease(t, 0.05, 0.45);
    if (p <= 0) return;
    // [x 占比, y 占比, 半径（占短边）, ARGB]
    const blobs = <List<num>>[
      [0.22, 0.10, 0.30, 0xFF5A6BE0],
      [0.86, 0.14, 0.36, 0xFF6B54C8],
      [0.62, 0.30, 0.22, 0xFF3E7BE8],
    ];
    for (final blob in blobs) {
      final center = Offset(
        blob[0].toDouble() * f.w,
        blob[1].toDouble() * f.horizon,
      );
      final radius = blob[2].toDouble() * f.s;
      final tint = Color(blob[3].toInt());
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              _alpha(tint, 0.055 * p),
              _alpha(tint, 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  /// 海面波纹。必须画在近处压暗**之后**，否则会被那层压暗吃掉——
  /// 上一版画在压暗之前，整片海平得跟布一样。
  void _paintSeaRipples(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
  ) {
    final p = _ease(t, 0.30, 0.78);
    if (p <= 0) return;

    final span = f.h - f.horizon;
    final unit = (f.s / 720).clamp(0.55, 2.0).toDouble();
    for (var layer = 0; layer < 10; layer++) {
      final k = layer / 9;
      // 1.7 次方：越靠近观众波纹越疏，符合透视线密度。
      final baseY = f.horizon + math.pow(k, 1.7).toDouble() * span * 0.97;
      final amp = (0.7 + k * 2.2) * unit;
      final wavelength = f.w * (0.34 + k * 0.26);
      final phase = clock * (0.42 + layer * 0.08) + layer * 1.9;

      final path = Path();
      var first = true;
      for (var x = -24.0; x <= f.w + 24; x += 12) {
        final y = baseY + math.sin(x / wavelength * math.pi * 2 + phase) * amp;
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      // 亮海面上：暗纹做主体，再加一道错位的亮纹，才有起伏。
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9 + k * 1.4
          ..color = _alpha(const Color(0xFF06184A), (0.30 - k * 0.14) * p),
      );
      canvas.drawPath(
        path.shift(Offset(0, -1.6 - k * 2.0)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7 + k * 1.0
          ..color = _alpha(const Color(0xFFA8C8FF), (0.20 - k * 0.09) * p),
      );
    }
  }

  /// 水面碎光：沿地平线下方撒一层极小的横向亮点。
  ///
  /// 这块面积最大、最容易"空"，撒一层碎光之后，海面才不是一块渐变色。
  void _paintSeaGlints(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
  ) {
    final p = _ease(t, 0.36, 0.86);
    if (p <= 0) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < 90; i++) {
      final u = _hash(i * 1.31);
      final v = math.pow(_hash(i * 2.77), 1.9).toDouble(); // 越远越密
      final x = u * f.w;
      final y = f.horizon + v * (f.h - f.horizon) * 0.92;
      final flicker = 0.45 + 0.55 * math.sin(clock * 1.6 + i * 0.9).abs();
      final w = f.s * (0.004 + 0.012 * _hash(i * 5.3)) * (1 + v);
      paint
        ..strokeWidth = math.max(0.8, f.s * (0.0016 + 0.0026 * v))
        ..color = _alpha(const Color(0xFFCFE2FF), (0.30 - v * 0.16) * flicker * p);
      canvas.drawLine(Offset(x - w / 2, y), Offset(x + w / 2, y), paint);
    }
  }

  /// 近处水面渐暗。
  ///
  /// 两个作用：一是越靠近观众水面越暗（透视上远处正对光，近处背光），
  /// 二是把字标底下的水面压住，否则白字压在白光上完全看不见。
  ///
  /// 必须画在光带**之前**——放上层会把那条白光压成一条灰色的带子，
  /// 这就是之前怎么看都不像"光"的原因。
  void _paintWaterShade(Canvas canvas, _Frame f) {
    final rect = Rect.fromLTWH(0, f.horizon, f.w, f.h - f.horizon);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Color(0x00040D28),
            Color(0x33040D28),
            Color(0x8C030A1E),
          ],
          stops: const [0, 0.44, 1],
        ).createShader(rect),
    );
  }

  /// S 形月光带：从海平线蜿蜒到画面右下，logo 里最标志性的一笔。
  ///
  /// 分两层画，模仿真实的水面反光：
  /// - **底光**：一条连续的柔光带（宽、淡、模糊），负责"光柱"的形体
  /// - **碎光**：沿脊柱排一串横向拉长的亮斑，负责"水面把光打碎"的质感
  ///
  /// 早先的版本用水平直线横切光带，切出来是一把梯子、一条编织带——
  /// 水波不是尺子，亮暗从来不是等距的直线。碎光必须是**横向的椭圆斑**。
  void _paintMoonRibbon(
    Canvas canvas,
    _Frame f,
    double clock,
    double t,
    bool softGlow,
  ) {
    final reveal = _ease(t, 0.40, 0.92);
    if (reveal <= 0) return;

    final spine = _ribbonSpine(f, clock, reveal);
    if (spine.length < 4) return;

    final rect = Rect.fromLTWH(0, f.horizon, f.w, f.h - f.horizon);

    // 底光：外层极淡极宽，内层稍实。核心不实描，
    // 靠碎光把亮度顶起来——否则整条会变成一块发光的布。
    for (final layer in const [
      [2.60, 0.155, 0.048],
      [1.55, 0.420, 0.018],
    ]) {
      final paint = Paint()
        // 上白下金：远处的水正对光，近处的水把光散成暖色。
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFFFFFFFF), layer[1]),
            _alpha(const Color(0xFFF2EEFF), layer[1] * 0.90),
            _alpha(const Color(0xFFFFE0B8), layer[1] * 0.70),
            _alpha(const Color(0xFFFFB870), layer[1] * 0.35),
          ],
          stops: const [0, 0.30, 0.60, 0.88],
        ).createShader(rect);
      if (softGlow) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, f.s * layer[2]);
      }
      canvas.drawPath(_ribbonPath(f, spine, layer[0], reveal), paint);
    }

    // 碎光：沿脊柱一串横向扁椭圆。
    // 宽度跟着光带的透视走，厚度随水深入变厚；逐点都铺（步距 1），
    // 亮差收窄、椭圆互相叠压，所以是"一片被打碎的光"
    // 而不是"一串珠子"——之前步距 2 时中间露底，看着像脚印。
    final n = spine.length;
    for (var i = 0; i < n; i++) {
      final k = i / (n - 1);
      final halfW =
          _ribbonHalfWidth(f, k, 1.02) * (0.78 + 0.30 * _hash(i * 1.7));
      final halfH =
          f.s * (0.0035 + 0.0090 * k) * (0.55 + 0.90 * _hash(i * 3.1));
      final flicker = 0.74 + 0.26 * math.sin(clock * 1.8 + i * 0.55);
      final tint = k < 0.34
          ? const Color(0xFFFFFFFF)
          : (k < 0.68 ? const Color(0xFFF6F0FF) : const Color(0xFFFFD9A2));
      final paint = Paint()
        ..color = _alpha(tint, (0.62 - 0.16 * k) * flicker * reveal);
      if (softGlow) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, f.s * 0.007);
      }
      canvas.drawOval(
        Rect.fromCenter(center: spine[i], width: halfW * 2, height: halfH * 2),
        paint,
      );
    }

    // 源头：光从山脚冒出来的那一点要亮一档，
    // 否则看起来是"从海里凭空长出来的一条带子"。
    final source = f.at(0.652, 0.0);
    final sourceR = f.s * 0.075;
    canvas.drawCircle(
      source,
      sourceR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _alpha(const Color(0xFFFFF6E4), 0.40),
            _alpha(const Color(0xFFFFD89A), 0),
          ],
        ).createShader(Rect.fromCircle(center: source, radius: sourceR)),
    );
  }

  /// 光带脊柱：Catmull-Rom 样条穿过 logo 上量出来的九个点。
  List<Offset> _ribbonSpine(_Frame f, double clock, double reveal) {
    // 落在右侧那颗大四角星的正下方，和它的竖直光尾接成一条线：
    // 星 → 光柱 → 水面反光，视线是连贯的；标题也就有了干净的位置。
    const ctrl = <Offset>[
      Offset(0.652, 0.000),
      Offset(0.700, 0.056),
      Offset(0.722, 0.112),
      Offset(0.700, 0.162),
      Offset(0.664, 0.204),
      Offset(0.652, 0.244),
      Offset(0.676, 0.284),
      Offset(0.708, 0.322),
      Offset(0.716, 0.358),
    ];
    const perSegment = 10;
    final total = (ctrl.length - 1) * perSegment;
    final keep = (total * reveal).round().clamp(2, total);
    final points = <Offset>[];

    for (var i = 0; i <= keep; i++) {
      final s = i / perSegment;
      final seg = s.floor().clamp(0, ctrl.length - 2);
      final local = s - seg;
      final p0 = ctrl[(seg - 1).clamp(0, ctrl.length - 1)];
      final p1 = ctrl[seg];
      final p2 = ctrl[seg + 1];
      final p3 = ctrl[(seg + 2).clamp(0, ctrl.length - 1)];
      var point = _catmullRom(p0, p1, p2, p3, local);

      // 横向摆动：整条光带像水里的倒影一样左右漂移，越靠下幅度越大。
      final k = i / total;
      final sway =
          math.sin(clock * 1.15 + k * 5.2) * f.s * 0.008 * (0.3 + k);
      point = Offset(f.at(point.dx, point.dy).dx + sway,
          f.at(point.dx, point.dy).dy);
      points.add(point);
    }
    return points;
  }

  /// 光带在 [k]（0~1，沿脊柱）处的半宽，占短边的比例。
  ///
  /// 丝带的边界和碎光斑共用这一个公式——两处各算一份的话，
  /// 碎光会溢出光带，边缘露出来一排"脱队的亮点"。
  double _ribbonHalfWidth(_Frame f, double k, double scale) =>
      f.s * (0.022 + 0.085 * math.pow(k, 1.15)) * scale / 2;

  Path _ribbonPath(
    _Frame f,
    List<Offset> spine,
    double widthScale,
    double reveal,
  ) {
    final left = <Offset>[];
    final right = <Offset>[];
    final n = spine.length;

    for (var i = 0; i < n; i++) {
      final prev = spine[i == 0 ? 0 : i - 1];
      final next = spine[i == n - 1 ? n - 1 : i + 1];
      var tangent = next - prev;
      final len = tangent.distance;
      if (len < 0.0001) {
        tangent = const Offset(0, 1);
      } else {
        tangent = tangent / len;
      }
      final normal = Offset(-tangent.dy, tangent.dx);
      final halfWidth = _ribbonHalfWidth(f, i / (n - 1), widthScale);
      left.add(spine[i] + normal * halfWidth);
      right.add(spine[i] - normal * halfWidth);
    }

    final path = Path();
    _appendSmooth(path, left);
    _appendSmooth(path, right.reversed.toList());
    path.close();
    return path;
  }

  /// 把折线平滑地接到 [path] 上：逐点用二次贝塞尔穿过中点。
  /// 直接 `lineTo` 会在光带边缘留下肉眼可见的锯齿。
  void _appendSmooth(Path path, List<Offset> points) {
    if (points.isEmpty) return;
    path.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final mid = Offset(
        (points[i].dx + points[i + 1].dx) / 2,
        (points[i].dy + points[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
  }

  Offset _catmullRom(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    double axis(double a, double b, double c, double d) =>
        0.5 *
        (2 * b +
            (-a + c) * t +
            (2 * a - 5 * b + 4 * c - d) * t2 +
            (-a + 3 * b - 3 * c + d) * t3);
    return Offset(
      axis(p0.dx, p1.dx, p2.dx, p3.dx),
      axis(p0.dy, p1.dy, p2.dy, p3.dy),
    );
  }

  // ── 三峰山 ────────────────────────────────────────────────────────────

  /// 山在海面的倒影：以海平线为不动点垂直镜像再压扁，
  /// 一团模糊的暗影拖在海面下，画面立刻有了"深度"。
  /// 淡到只剩轮廓——太实就成了贴在玻璃上的第二座山。
  void _paintIslandReflection(Canvas canvas, _Frame f, double t) {
    final p = _ease(t, 0.30, 0.85);
    if (p <= 0) return;

    const squash = 0.55;
    canvas.save();
    canvas.translate(0, f.horizon * (1 + squash));
    canvas.scale(1, -squash);

    final path = Path()
      ..moveTo(f.at(_ridge[0].dx, _ridge[0].dy * 1.35).dx,
          f.at(_ridge[0].dx, _ridge[0].dy * 1.35).dy);
    for (var i = 1; i < _ridge.length; i++) {
      final point = f.at(_ridge[i].dx, _ridge[i].dy * 1.35);
      path.lineTo(point.dx, point.dy);
    }
    path.lineTo(f.at(_ridge.last.dx, 0.0).dx, f.horizon);
    path.lineTo(f.at(_ridge.first.dx, 0.0).dx, f.horizon);
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = _alpha(const Color(0xFF0A1850), 0.45 * p)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, f.s * 0.016),
    );
    canvas.restore();
  }

  /// 山体：一条折线剪影，受光面用 clip 后铺光，不叠三角形。
  ///
  /// 叠三角形会在山脊上留下一条笔直的斜切边，看着像塑料棚；
  /// `clipPath` + 大范围径向暖光的边界交给光自己衰减，才是山。
  void _paintIsland(Canvas canvas, _Frame f, double clock, double t) {
    final p = _ease(t, 0.26, 0.80);
    if (p <= 0) return;

    // 入场时整座岛从海面下升起 4% 屏高。
    final drop = (1 - p) * f.s * 0.040;

    // 图标里山是画面的主角；直接抄图标高度放到宽屏上会缩成
    // 海平线上的小礁石，所以纵向统一放大一档。
    const ridgeScale = 1.35;

    Offset at(int i) {
      final point = f.at(_ridge[i].dx, _ridge[i].dy * ridgeScale);
      return Offset(point.dx, point.dy + drop);
    }

    final body = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < _ridge.length; i++) {
      body.lineTo(at(i).dx, at(i).dy);
    }
    // 首尾都沉在海面以下，直接闭合：底边跟着山脚走，
    // 不会再凭空多出一条水平的深色带。
    body.close();

    final box = Rect.fromLTRB(
      f.originX - f.width * 0.14,
      f.horizon - f.s * 0.40 + drop,
      f.originX + f.width * 1.14,
      f.horizon + 6 + drop,
    );

    // 底：左暗右亮。logo 的光来自右下（月亮 + 海面反光），
    // 所以主峰左坡是深蓝紫，右坡是橙金。
    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          // 实测 logo 的山：左坡 #16378F、右坡 #2C3594、小峰 #463B92，
          // 整体是蓝紫的。之前按"橙金受光"画，怎么调都是一座土山。
          //
          // 中间那对 0.477/0.477 是个**硬分界**，正好落在主峰顶上：
          // 左边是背光坡、右边是迎光坡。全靠渐变糊过去的话，
          // 山就是一整块色斑，看不出有面。
          colors: [
            _alpha(const Color(0xFF0D2060), p),
            _alpha(const Color(0xFF142B70), p),
            _alpha(const Color(0xFF1C3380), p),
            _alpha(const Color(0xFF7A66C2), p),
            _alpha(const Color(0xFF6E5BB8), p),
            _alpha(const Color(0xFF8E6FD0), p),
          ],
          stops: const [0, 0.30, 0.477, 0.477, 0.66, 1],
        ).createShader(box),
    );

    // 山脊月光勾边：图标里主峰右脊有一道被月光照亮的细亮边，
    // 没有它，蓝紫色的山在深蓝背景上就糊成一团看不出轮廓。
    // 只描山脊线（不闭合、不含底边），宽窄随入场进度走。
    final rim = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < _ridge.length; i++) {
      rim.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.4, f.s * 0.0028)
        // 两端几乎全透明、只在主峰右脊一点亮：
        // 整条都勾的话山就成了铁丝弯出来的，立体感反而没了。
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            _alpha(const Color(0xFF8FA8FF), 0.03 * p),
            _alpha(const Color(0xFFDCE4FF), 0.20 * p),
            _alpha(const Color(0xFFFFFFFF), 0.80 * p),
            _alpha(const Color(0xFFDCE4FF), 0.42 * p),
            _alpha(const Color(0xFF9FA8FF), 0.04 * p),
          ],
          stops: const [0, 0.28, 0.477, 0.64, 0.92],
        ).createShader(box),
    );

    canvas.save();
    canvas.clipPath(body);

    // 纵向明暗：月光从上方来，山顶吃光、山脚沉进水汽——
    // 只有左右分面时山是一片平涂，叠了这层才有"体积"。
    final shadeRect = Rect.fromLTRB(
      box.left,
      f.horizon - f.s * 0.42 + drop,
      box.right,
      f.horizon + drop,
    );
    canvas.drawRect(
      shadeRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFFC4D2FF), 0.22 * p),
            _alpha(const Color(0xFFFFFFFF), 0.05 * p),
            _alpha(const Color(0xFF000A2E), 0.30 * p),
            _alpha(const Color(0xFF000A2E), 0.52 * p),
          ],
          stops: const [0, 0.28, 0.72, 1],
        ).createShader(shadeRect),
    );

    // 主峰右坡的定向受光：光来自右上（大四角星 + 月），沿坡面扫下来，
    // 比一个圆形光斑更像"整个面被照亮"。
    final litRect = Rect.fromLTRB(
      f.at(0.40, 0).dx,
      f.horizon - f.s * 0.42 + drop,
      f.at(0.68, 0).dx,
      f.horizon + drop,
    );
    canvas.drawRect(
      litRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            _alpha(const Color(0xFFFFE2BC), 0.38 * p),
            _alpha(const Color(0xFF9B8CFF), 0.10 * p),
            _alpha(const Color(0xFF9B8CFF), 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(litRect),
    );

    // 主峰右坡的橙色受光。
    // 圆心必须落在山体上：用 Alignment 相对整块 rect 定位时，
    // `-1.05` 这种值会把圆心推到画面外，光就完全照不到山上。
    final warmCenter = f.at(0.545, -0.112 * ridgeScale);
    final warmRadius = f.s * 0.40;
    canvas.drawCircle(
      warmCenter,
      warmRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _alpha(const Color(0xFFFFC078), 0.18 * p),
            _alpha(const Color(0xFFFF9E46), 0.06 * p),
            _alpha(const Color(0xFFFF9E46), 0),
          ],
          stops: const [0, 0.44, 1],
        ).createShader(
          Rect.fromCircle(center: warmCenter, radius: warmRadius),
        ),
    );

    // 右侧小峰那一块偏紫粉，是 logo 里最容易被忽略但很出味道的一笔。
    canvas.drawCircle(
      f.at(0.690, -0.090 * ridgeScale),
      f.s * 0.155,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _alpha(const Color(0xFFC58BE8), 0.30 * p),
            _alpha(const Color(0xFFC58BE8), 0),
          ],
        ).createShader(
          Rect.fromCircle(center: f.at(0.690, -0.070 * ridgeScale), radius: f.s * 0.135),
        ),
    );

    // 山脚压暗：离水面越近越暗，山才"扎"进海里而不是浮着。
    final footRect = Rect.fromLTWH(
      0,
      f.horizon - f.s * 0.055,
      f.w,
      f.s * 0.075,
    );
    canvas.drawRect(
      footRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFF05091A), 0),
            _alpha(const Color(0xFF05091A), 0.42 * p),
          ],
        ).createShader(footRect),
    );
    canvas.restore();

    // 棱线：从主峰顶沿右坡下来的一条亮边，山才不是一块色斑。
    final crest = Path()
      ..moveTo(at(13).dx, at(13).dy)
      ..lineTo(at(14).dx, at(14).dy)
      ..lineTo(at(15).dx, at(15).dy)
      ..lineTo(at(16).dx, at(16).dy);
    canvas.drawPath(
      crest,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, f.s * 0.0022)
        ..strokeJoin = StrokeJoin.round
        ..color = _alpha(const Color(0xFFFFD9A0), 0.55 * p),
    );

  }

  /// 海平线上的薄雾 + 亮带：把山脚、海面、天空粘起来，不出现硬切边。
  /// 暗角：四角压暗、中心留亮。
  ///
  /// 满屏平均亮度的插画看起来"平"，一块压了暗角的画面立刻有景深，
  /// 顺带把字标区的对比度抬上去。
  void _paintVignette(Canvas canvas, _Frame f, double t) {
    final p = _ease(t, 0.30, 0.90);
    if (p <= 0) return;
    final rect = Rect.fromLTWH(0, 0, f.w, f.h);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.05),
          radius: 0.95,
          colors: [
            _alpha(const Color(0xFF03081C), 0),
            _alpha(const Color(0xFF03081C), 0.10 * p),
            _alpha(const Color(0xFF020612), 0.22 * p),
          ],
          stops: const [0.56, 0.84, 1],
        ).createShader(rect),
    );
  }

  void _paintHorizonHaze(Canvas canvas, _Frame f, double t) {
    final p = _ease(t, 0.18, 0.62);
    if (p <= 0) return;

    final mist = Rect.fromLTWH(
      0,
      f.horizon - f.h * 0.160,
      f.w,
      f.h * 0.160,
    );
    canvas.drawRect(
      mist,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            _alpha(const Color(0xFFA6C6F5), 0.55 * p),
            _alpha(const Color(0xFFA6C6F5), 0.18 * p),
            _alpha(const Color(0xFFA6C6F5), 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(mist),
    );

    // 山脚水汽：用海色从下往上盖一层，山脚才会溶进水里。
    // 少了这层，山底就是一条笔直的深色边，像剪纸贴在海上。
    final washRect = Rect.fromLTWH(
      0,
      f.horizon - f.s * 0.050,
      f.w,
      f.s * 0.085,
    );
    canvas.drawRect(
      washRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _alpha(const Color(0xFF4C7CF0), 0),
            _alpha(const Color(0xFF4C7CF0), 0.26 * p),
            _alpha(const Color(0xFF4C7CF0), 0.72 * p),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(washRect),
    );

    // 海平线本身：一条从中心向两侧淡出的亮带。
    final half = f.w * 0.5 * p;
    if (half < 1) return;
    final lineRect = Rect.fromLTWH(
      f.w / 2 - half,
      f.horizon - 1.2,
      half * 2,
      2.4,
    );
    canvas.drawRect(
      lineRect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            _alpha(const Color(0xFFBBD6FF), 0),
            _alpha(const Color(0xFFF0F6FF), 0.42 * p),
            _alpha(const Color(0xFFBBD6FF), 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(lineRect),
    );
  }
}
