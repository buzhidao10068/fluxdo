import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

UserSummary _summary(int days) => UserSummary(
  daysVisited: days,
  postsReadCount: 1,
  likesReceived: 1,
  likesGiven: 1,
  topicCount: 1,
  postCount: 1,
  timeRead: 1,
  bookmarkCount: 1,
);

class _Service extends Fake implements DiscourseService {
  final requests = <Completer<UserSummary>>[];
  final userRequest = Completer<User?>();

  @override
  Future<UserSummary> getUserSummary(
    String username, {
    bool forceRefresh = false,
  }) {
    final result = Completer<UserSummary>();
    requests.add(result);
    return result.future;
  }

  @override
  Future<User?> getPreloadedCurrentUser() async => null;

  @override
  Future<User?> getCurrentUser() => userRequest.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final action in ['dispose', 'clear', 'switch']) {
    test('Summary 刷新迟到：$action 后不写旧状态或缓存，也不抛生命周期异常', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _Service();
      var username = 'alice';
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          discourseServiceProvider.overrideWithValue(service),
          currentUserProvider.overrideWithBuild(
            (ref, notifier) => User(id: 1, username: username, trustLevel: 2),
          ),
        ],
      );
      if (action != 'dispose') addTearDown(container.dispose);
      final initial = container.read(userSummaryProvider.future);
      await Future<void>.delayed(Duration.zero);
      service.requests.single.complete(_summary(12));
      await initial;
      final notifier = container.read(userSummaryProvider.notifier);
      final refresh = notifier.refresh();
      if (action == 'dispose') {
        container.dispose();
      } else if (action == 'clear') {
        await notifier.clearCache();
      } else {
        username = 'bob';
        container.invalidate(currentUserProvider);
        final fresh = container.read(userSummaryProvider.future);
        await Future<void>.delayed(Duration.zero);
        service.requests.last.complete(_summary(30));
        await fresh;
      }
      service.requests[1].complete(_summary(99));
      await refresh;
      await prefs.reload();
      if (action == 'clear') {
        expect(prefs.containsKey('user_summary_cache'), isFalse);
      } else {
        expect(
          jsonDecode(prefs.getString('user_summary_cache')!)['days_visited'],
          action == 'switch' ? 30 : 12,
        );
        expect(
          prefs.getString('user_summary_cache_username'),
          action == 'switch' ? 'bob' : 'alice',
        );
      }
    });
  }

  test('首次 Summary 加载期间销毁容器，不再写入缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _Service();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWithBuild(
          (ref, notifier) => User(id: 1, username: 'alice', trustLevel: 2),
        ),
      ],
    );
    container.read(userSummaryProvider);
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    service.requests.single.complete(_summary(99));
    await Future<void>.delayed(Duration.zero);
    expect(prefs.containsKey('user_summary_cache'), isFalse);
  });

  test('用户静默刷新在 clearCache 后完成，不再恢复已退出的用户缓存', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = _Service();
    final container = ProviderContainer.test(
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWithBuild(
          (ref, notifier) => User(id: 1, username: 'alice', trustLevel: 2),
        ),
      ],
    );
    final notifier = container.read(currentUserProvider.notifier);
    final refreshing = notifier.refreshSilently(force: true);
    await Future<void>.delayed(Duration.zero);
    await notifier.clearCache();
    service.userRequest.complete(User(id: 1, username: 'alice', trustLevel: 2));
    await refreshing;
    expect(prefs.containsKey('current_user_cache'), isFalse);
  });
}
