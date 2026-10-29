import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/player/vertical_feed_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _a = Drama(id: 'hongguo:1', source: 'hongguo', title: '甲剧', episodes: 3);
const _b = Drama(id: 'hongguo:2', source: 'hongguo', title: '乙剧', episodes: 3);
const _c = Drama(id: 'hongguo:3', source: 'hongguo', title: '丙剧', episodes: 3);

/// 记录 preload / resolve / release 的顺序，用于判定"预加载是否被复用"。
class _Repo extends FixtureRepository {
  final preloads = <String>[];
  final resolves = <String>[];
  final releases = <String>[];

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => CatalogPage(const [_a, _b, _c]);

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
    Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    Episode({'id': '3', 'title': '第3集', 'currentEpisode': 3}, 3),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final key = '${drama.title}${episode.number}';
    resolves.add(key);
    return PlaybackPlan(
      url: 'https://example.test/r-$key.mp4',
      session: 'R-$key-${resolves.length}',
    );
  }

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    final key = '${drama.title}${episode.number}';
    preloads.add(key);
    return PlaybackPlan(
      url: 'https://example.test/p-$key.mp4',
      session: 'P-$key-${preloads.length}',
    );
  }

  @override
  Future<void> release(String session) async {
    releases.add(session);
  }
}

Future<void> _pump(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 搭一个竖滑流，返回注入的假播放器列表。
Future<List<ScriptedPlayer>> _mount(
  WidgetTester tester,
  _Repo repo,
  LocalStore store, {
  Player Function()? factory,
}) async {
  final platforms = <ScriptedPlayer>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: VerticalFeedScreen(
          key: const ValueKey('feed'),
          repository: repo,
          store: store,
          embedded: true,
          active: true,
          playerFactory:
              factory ??
              () {
                final p = ScriptedPlayer();
                platforms.add(p);
                return Player(platformPlayer: p);
              },
          videoBuilder: (controls) => controls,
        ),
      ),
    ),
  );
  return platforms;
}

void main() {
  late LocalStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    store = LocalStore(await SharedPreferences.getInstance());
  });

  tearDown(() => store.dispose());

  testWidgets('0.6.9：滑到下一部时**复用**预加载，不再重新解析', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 880);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final repo = _Repo();
    final platforms = await _mount(tester, repo, store);
    await _pump(tester, 80);

    // 当前页是哪一部？（推荐流会打乱顺序）
    String current() {
      for (final t in ['甲剧', '乙剧', '丙剧']) {
        if (find.textContaining(t).evaluate().isNotEmpty) return t;
      }
      return '?';
    }

    final first = current();
    expect(first, isNot('?'));

    // 推进到接近结束，触发"连播下一部"预加载。
    for (final p in platforms) {
      p.state = p.state.copyWith(position: const Duration(seconds: 90));
      p.positionController.add(const Duration(seconds: 90));
    }
    await _pump(tester, 80);

    expect(
      repo.preloads,
      isNotEmpty,
      reason: '推进位置后应触发"下一部"预加载',
    );
    final preloaded = repo.preloads.last;
    debugPrint('预加载目标 = $preloaded（当前页 = $first）');

    repo.resolves.clear();
    repo.releases.clear();

    // 滑到下一部。
    await tester.fling(
      find.byType(PageView),
      const Offset(0, -400),
      1200,
      initialOffset: const Offset(210, 500),
    );
    await _pump(tester, 120);

    final second = current();
    debugPrint('滑到 = $second；期间 resolve=${repo.resolves} '
        'release=${repo.releases}');

    expect(second, isNot(first), reason: '应已切换到另一部剧');

    // 核心断言：滑过去时**不应**重新解析（预加载已备好）。
    expect(
      repo.resolves,
      isEmpty,
      reason: '滑到下一部时不应重新解析播放地址（预加载应被复用）',
    );
    // 也不应把刚预载好的会话释放掉。
    expect(
      repo.releases.where((s) => s.startsWith('P-')),
      isEmpty,
      reason: '不应释放刚预载好的会话',
    );
  });

  testWidgets('0.6.9：切下一集**复用**预加载（既有行为不得回退）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 880);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final repo = _Repo();
    final platforms = <ScriptedPlayer>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: VerticalFeedScreen(
            key: const ValueKey('feed'),
            repository: repo,
            store: store,
            embedded: true,
            active: true,
            singleDrama: _a,
            playerFactory: () {
              final p = ScriptedPlayer();
              platforms.add(p);
              return Player(platformPlayer: p);
            },
            videoBuilder: (controls) => controls,
          ),
        ),
      ),
    );
    await _pump(tester, 80);

    for (final p in platforms) {
      p.state = p.state.copyWith(position: const Duration(seconds: 90));
      p.positionController.add(const Duration(seconds: 90));
    }
    await _pump(tester, 80);
    expect(repo.preloads, contains('甲剧2'), reason: '应预加载第 2 集');

    repo.resolves.clear();
    // 上滑 = 下一集。
    await tester.fling(
      find.byType(PageView).evaluate().isEmpty
          ? find.byType(VerticalFeedScreen)
          : find.byType(PageView),
      const Offset(0, -400),
      1200,
      initialOffset: const Offset(210, 500),
    );
    await _pump(tester, 120);

    expect(repo.resolves, isEmpty, reason: '切下一集不应重新解析');
  });

  testWidgets('0.6.9：预载时机提前到 25%（原为过半）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 880);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final repo = _Repo();
    final platforms = await _mount(tester, repo, store);
    await _pump(tester, 80);

    // 合成播放器时长固定 2 分钟 → 25% = 30 秒。
    // 推到 40 秒（>25%，但远未过半），旧逻辑**不会**预载。
    for (final p in platforms) {
      p.state = p.state.copyWith(position: const Duration(seconds: 40));
      p.positionController.add(const Duration(seconds: 40));
    }
    await _pump(tester, 80);

    expect(
      repo.preloads,
      isNotEmpty,
      reason: '播到 40 秒（时长的 33%）就应开始预载，不该等到过半',
    );
  });
}
