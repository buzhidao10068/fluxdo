import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/app_state_refresher.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/bookmark_sync_controller.dart';
import 'package:fluxdo/providers/bookmarks_reconciler.dart';
import 'package:fluxdo/providers/bookmarks_repository.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/storage/bookmark_cache_dao.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/bookmark_hive_test_support.dart';

class _Service extends Fake implements DiscourseService {
  String? username = 'alice';
  final changes = StreamController<void>.broadcast();

  @override
  Stream<void> get authStateStream => changes.stream;

  @override
  Future<String?> getUsername() async => username;
}

class _DelayedCurrent extends CurrentUserNotifier {
  final gate = Completer<void>();
  bool fail = false;

  @override
  User? build() => null;

  @override
  Future<void> clearCache() async {
    await gate.future;
    if (fail) throw StateError('模拟用户缓存清理失败');
    await super.clearCache();
  }
}

class _DelayedSummary extends UserSummaryNotifier {
  final gate = Completer<void>();

  @override
  Future<UserSummary?> build() async => null;

  @override
  Future<void> clearCache() async {
    await gate.future;
    await super.clearCache();
  }
}

BookmarkCacheEntry _entry(int id, String name) => BookmarkCacheEntry(
  bookmarkId: id,
  topicId: id,
  nameNormalized: name,
  updatedAt: DateTime.utc(2026),
  cachedAt: DateTime.utc(2026),
  payload: {'id': id, '_bookmark_id': id, 'title': name},
);

class _DelayedRepository extends BookmarksRepository {
  _DelayedRepository(super.dao);

  Completer<void>? namesGate;
  Completer<void>? recordsGate;

  @override
  Future<Map<String, int>> nameCounts(String accountId) async {
    final result = await super.nameCounts(accountId);
    if (accountId == 'alice') await namesGate?.future;
    return result;
  }

  @override
  Future<List<BookmarkRecord>> readByIds(
    String accountId,
    List<int> ids,
  ) async {
    final result = await super.readByIds(accountId, ids);
    if (accountId == 'alice') await recordsGate?.future;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late _Service service;
  late BookmarkHiveTestSupport storage;
  late _DelayedRepository repo;
  late ProviderContainer container;
  late BookmarkRawPageLoader pageLoader;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final name in ['alice', 'bob'])
        'bookmark_last_full_sync_$name': DateTime.now()
            .toUtc()
            .toIso8601String(),
    });
    prefs = await SharedPreferences.getInstance();
    service = _Service();
    storage = await BookmarkHiveTestSupport.create();
    repo = _DelayedRepository(BookmarkCacheDao(boxFactory: storage.openBox));
    pageLoader = (_) async =>
        BookmarkPageParseResult(topics: [], entries: [], moreUrl: null);
    await repo.upsertOne('alice', _entry(1, 'alice-only'));
    await repo.upsertOne('bob', _entry(2, 'bob-only'));
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWithBuild((ref, notifier) => null),
        bookmarksRepositoryProvider.overrideWithValue(repo),
        bookmarkRawPageLoaderProvider.overrideWithValue(
          (page) => pageLoader(page),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await service.changes.close();
    await repo.dispose();
    await storage.dispose();
  });

  test('真实退出后 ensureLoaded 和仓库通知均不会恢复旧账号候选', () async {
    expect(await container.read(currentUsernameProvider.future), 'alice');
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);
    expect(await notifier.ensureLoaded(), ['alice-only']);
    service.username = null;
    await AppStateRefresher.resetForLogout(container);
    expect(await container.read(currentUsernameProvider.future), isNull);
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      isEmpty,
    );
    await repo.upsertOne('alice', _entry(3, 'late-alice'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(bookmarkNameSuggestionsProvider), isEmpty);

    service.username = 'bob';
    AppStateRefresher.refreshAll(container);
    expect(await container.read(currentUsernameProvider.future), 'bob');
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      ['bob-only'],
    );
  });

  test('两秒内再次刷新也重绑账号，去抖不会保留旧候选', () async {
    AppStateRefresher.refreshAll(container);
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      ['alice-only'],
    );
    service.username = 'bob';
    AppStateRefresher.refreshAll(container);
    expect(await container.read(currentUsernameProvider.future), 'bob');
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      ['bob-only'],
    );
  });

  testWidgets('容器销毁后取消尚未执行的延迟刷新', (tester) async {
    final disposable = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    AppStateRefresher.refreshAll(disposable);
    disposable.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  test('认证广播后自动重建候选和书签列表，迟到的旧读取不能覆盖新账号', () async {
    final sub = container.listen<AsyncValue<List<Topic>>>(
      bookmarksProvider,
      (_, _) {},
    );
    addTearDown(sub.close);
    expect(
      (await container.read(bookmarksProvider.future)).single.bookmarkId,
      1,
    );
    final notifier = container.read(bookmarkNameSuggestionsProvider.notifier);
    expect(await notifier.ensureLoaded(), ['alice-only']);
    repo.namesGate = Completer<void>();
    repo.recordsGate = Completer<void>();
    await repo.upsertOne('alice', _entry(3, 'late-alice'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    service.username = 'bob';
    service.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(currentUsernameProvider.future), 'bob');
    expect(
      (await container.read(bookmarksProvider.future)).single.bookmarkId,
      2,
    );
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      ['bob-only'],
    );
    repo.namesGate!.complete();
    repo.recordsGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(bookmarkNameSuggestionsProvider), ['bob-only']);
    expect(container.read(bookmarksProvider).value!.single.bookmarkId, 2);

    // 连续 void 广播的值均为 null，也必须让下一次认证切换重新读取账号。
    service.username = null;
    service.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(currentUsernameProvider.future), isNull);
    expect(await container.read(bookmarksProvider.future), isEmpty);
    expect(
      await container
          .read(bookmarkNameSuggestionsProvider.notifier)
          .ensureLoaded(),
      isEmpty,
    );
  });

  for (final fail in [false, true]) {
    test('退出等待两项清理完成${fail ? '，失败也继续清理另一项' : ''}', () async {
      container.dispose();
      final current = _DelayedCurrent()..fail = fail;
      final summary = _DelayedSummary();
      container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          discourseServiceProvider.overrideWithValue(service),
          currentUserProvider.overrideWith(() => current),
          userSummaryProvider.overrideWith(() => summary),
          bookmarksRepositoryProvider.overrideWithValue(repo),
        ],
      );
      await prefs.setString('current_user_cache', '{}');
      await prefs.setString('user_summary_cache', '{}');
      service.username = null;
      var finished = false;
      Object? error;
      final resetting = AppStateRefresher.resetForLogout(container).then(
        (_) {
          finished = true;
        },
        onError: (Object e) {
          error = e;
          finished = true;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      current.gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      summary.gate.complete();
      await resetting;
      expect(prefs.containsKey('user_summary_cache'), isFalse);
      expect(prefs.containsKey('current_user_cache'), fail);
      expect(error, fail ? isA<StateError>() : isNull);
    });
  }

  test('reset 释放旧同步任务，旧响应不写仓库也不覆盖新同步状态', () async {
    final pages = <Completer<BookmarkPageParseResult>>[];
    pageLoader = (_) {
      final page = Completer<BookmarkPageParseResult>();
      pages.add(page);
      return page.future;
    };
    final controller = container.read(bookmarkSyncControllerProvider.notifier);
    final old = controller.manualFullSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pages, hasLength(1));
    service.username = 'bob';
    controller.reset();
    container.invalidate(currentUsernameProvider);
    await container.read(currentUsernameProvider.future);
    final current = container.read(bookmarkSyncControllerProvider.notifier);
    final fresh = current.manualFullSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pages, hasLength(2));
    pages[0].complete(
      BookmarkPageParseResult(
        topics: [],
        entries: [_entry(99, 'late')],
        moreUrl: '/next',
      ),
    );
    expect(await old, isNull);
    expect(await repo.findOne('alice', 99), isNull);
    expect(container.read(bookmarkSyncControllerProvider).isSyncing, isTrue);
    pages[1].complete(
      BookmarkPageParseResult(topics: [], entries: [], moreUrl: null),
    );
    expect(await fresh, isNotNull);
    expect(
      container.read(bookmarkSyncControllerProvider).phase,
      BookmarkSyncPhase.idle,
    );
  });
}
