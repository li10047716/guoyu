import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/core/models.dart';
import 'package:duanju_app/core/app_build.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('catalog, VIP filter and fresh details at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FixtureRepository();
      final local = await store();
      await tester.pumpWidget(DuanjuApp(repository: repository, store: local));
      await tester.pumpAndSettle();
      // 0.7.48：VIP 标记原本只由黄豆站源产生，黄豆移除后没有任何站源会给出
      // VIP 标记，VIP 过滤入口随之收起（本地旧开关保留，只是不再渲染）。
      expect(find.textContaining('VIP：'), findsNothing);
      expect(find.text('测试短剧'), findsOneWidget);
      if (allSourcesEnabled) {
        await tester.tap(find.byKey(const ValueKey('source-switch')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('青空次元'));
        await tester.pumpAndSettle();
        expect(find.text('会员测试剧'), findsOneWidget);
        expect(find.textContaining('VIP：'), findsNothing);
      } else {
        expect(find.text('青空次元'), findsNothing);
        expect(find.text('会员测试剧'), findsNothing);
      }
      await tester.tap(find.text('测试短剧'));
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 1);
      expect(find.byKey(const ValueKey('episode-2')), findsOneWidget);
      await tester.tap(find.byTooltip('加入追剧'));
      await tester.pumpAndSettle();
      expect(local.isFavorite(FixtureRepository.free.id), isTrue);
      for (final episode in [1, 2]) {
        await local.saveWatch(
          WatchEntry(
            drama: FixtureRepository.free,
            episode: episode,
            position: 18.5,
            duration: 90,
            updatedAt: DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('继续第 $episode 集'), findsOneWidget);
        for (final number in [1, 2]) {
          final button = tester.widget<OutlinedButton>(
            find.byKey(ValueKey('episode-$number')),
          );
          expect(
            button.style?.backgroundColor?.resolve({}),
            number == episode ? isNotNull : isNull,
          );
        }
      }
      await local.clearHistory();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed catalog can be retried', (tester) async {
    final repository = FixtureRepository()..fail = true;
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsOneWidget);
  });

  testWidgets('fresh disk catalog skips the network and resumes pagination', (
    tester,
  ) async {
    final repository = FixtureRepository();
    repository.cachedPages['hongguo'] = CatalogPage(
      [FixtureRepository.free],
      fresh: true,
      page: 3,
      hasMore: true,
    );
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsOneWidget);
    expect(repository.requests, isEmpty);
    await tester.scrollUntilVisible(
      find.text('加载更多'),
      200,
      scrollable: find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(repository.pages, [4]);
    await tester.tap(find.byTooltip('更新当前站源'));
    await tester.pumpAndSettle();
    expect(repository.pages, [4, 1]);
    expect(repository.forced, [false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale disk catalog remains usable when refresh fails', (
    tester,
  ) async {
    final repository = FixtureRepository()..fail = true;
    repository.cachedPages['hongguo'] = CatalogPage([FixtureRepository.free]);
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsOneWidget);
    expect(find.text('合成网络错误'), findsOneWidget);
    expect(find.text('暂时无法加载'), findsNothing);
    expect(repository.requests, ['hongguo']);
    expect(tester.takeException(), isNull);
  });

  test('watch progress and favorites survive a new store', () async {
    final local = await store();
    await local.saveWatch(
      WatchEntry(
        drama: FixtureRepository.free,
        episode: 2,
        position: 18.5,
        duration: 90,
        updatedAt: DateTime.now(),
      ),
    );
    await local.toggleFavorite(FixtureRepository.free);
    final restored = LocalStore(local.preferences);
    expect(restored.watched(FixtureRepository.free.id)?.position, 18.5);
    expect(restored.watched(FixtureRepository.free.id)?.episode, 2);
    expect(restored.isFavorite(FixtureRepository.free.id), isTrue);
  });
}
