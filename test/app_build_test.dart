import 'dart:convert';

import 'package:duanju_app/core/app_build.dart';
import 'package:duanju_app/core/core_bridge.dart';
import 'package:duanju_app/core/local_profiles.dart';
import 'package:duanju_app/core/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/core/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const red = FixtureRepository.free;
  const other = FixtureRepository.vip;

  testWidgets(
    'edition branding and restored source match the compiled catalog',
    (tester) async {
      SharedPreferences.setMockInitialValues({'source': 'sorani'});
      final store = LocalStore(await SharedPreferences.getInstance());
      final repository = FixtureRepository();
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();
      // 0.7.21：首页竖滑流移除后默认进「发现」页，顶栏标题是站源菜单，
      // 应用名改从「更多 → 关于」入口校验版本烙印。
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('关于$appName'), findsOneWidget);
      await tester.tapAt(const Offset(400, 560));
      await tester.pumpAndSettle();
      expect(appName, '果屿');
      expect(appSlug, allSourcesEnabled ? 'guoyu' : 'guoyu-hongguo');
      expect(repository.requests, [allSourcesEnabled ? 'sorani' : 'hongguo']);
      expect(store.sources.length, allSourcesEnabled ? 3 : 1);
      for (final source in SourceSite.knownValues.skip(1)) {
        expect(
          find.text(source.name),
          allSourcesEnabled ? findsOneWidget : findsNothing,
        );
      }
      expect(store.preferences.getString('source'), 'sorani');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    },
  );

  test(
    'edition filtering preserves favorites and history through backup restore',
    () async {
      final history = [
        for (final drama in [red, other])
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 12,
            duration: 60,
            updatedAt: DateTime(2026, 9, 19),
          ).toJson(),
      ];
      SharedPreferences.setMockInitialValues({
        'source': 'sorani',
        'favorites': jsonEncode([red.toJson(), other.toJson()]),
        'history': jsonEncode(history),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.favorites.length, allSourcesEnabled ? 2 : 1);
      expect(store.history.length, allSourcesEnabled ? 2 : 1);
      expect(store.isFavorite(other.id), allSourcesEnabled);
      expect(store.watched(other.id) != null, allSourcesEnabled);
      await store.toggleFavorite(red);
      final backup = await store.exportBackup();
      final library =
          (jsonDecode(backup)['libraries'] as Map)['default'] as Map;
      expect((library['favorites'] as List).single['id'], other.id);
      expect(library['history'], hasLength(2));
      await store.importBackup(backup);
      // 0.7.48：本地数据已迁到 localSnapshot.v1 快照里，旧的独立键不会再更新，
      // 因此恢复结果要按内存状态断言：已移除站源的记录被丢弃，而「当前版本
      // 未启用」的站源记录仍然保留在存储里，只在视图上被过滤掉。
      expect(store.preferences.getString('source'), 'sorani');
      expect(
        store.favorites.map((drama) => drama.id).toList(),
        allSourcesEnabled ? [other.id] : <String>[],
      );
      expect(store.history, hasLength(allSourcesEnabled ? 2 : 1));
      store.dispose();
    },
  );

  test(
    'a restored foreign-source profile keeps its identity and permissions',
    () async {
      SharedPreferences.setMockInitialValues({
        'profiles': jsonEncode([
          LocalProfile(
            id: 'default',
            name: '管理员',
            admin: true,
            salt: '0' * 32,
            pinHash: '1' * 64,
          ).toJson(),
          const LocalProfile(
            id: 'viewer',
            name: '已有用户',
            sources: ['sorani'],
            download: false,
          ).toJson(),
        ]),
        'activeProfile': 'viewer',
        'profile.viewer.source': 'sorani',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.profile.id, 'viewer');
      expect(store.profile.admin, isFalse);
      expect(store.profile.sources, ['sorani']);
      expect(store.canDownload, isFalse);
      expect(store.source, allSourcesEnabled ? 'sorani' : '');
      expect(store.allowsSource('hongguo'), isFalse);
      expect(store.allowsSource('sorani'), allSourcesEnabled);
      store.dispose();
    },
  );

  test(
    'background requests reject unavailable sources before native I/O',
    () async {
      final repository = NativeRepository(background: true);
      final denied = [
        ...SourceSite.knownValues
            .where((source) => !SourceSite.isAvailable(source.id))
            .map((source) => source.id),
        'unknown',
      ];
      for (final source in denied) {
        final drama = Drama(id: '$source:123', source: source, title: '合成数据');
        final episode = Episode({'id': '1'}, 1);
        for (final request in [
          () => repository.catalog(source),
          () => repository.cached(source),
          () => repository.sourceStatus(source),
          () => repository.startSourceJob(source, 'update'),
          () => repository.cancelSourceJob(source),
          () => repository.detail(drama),
          () => repository.cover(drama),
          () => repository.resolve(drama, episode),
          () => repository.resolveOnline(drama, episode),
          () => repository.enqueueDownloads(DramaDetail(drama, [episode]), [
            episode,
          ]),
          () => repository.localPlayback(drama, episode),
        ]) {
          await expectLater(
            request(),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.message,
                'message',
                '当前版本不包含此站源',
              ),
            ),
          );
        }
      }
    },
  );
}
