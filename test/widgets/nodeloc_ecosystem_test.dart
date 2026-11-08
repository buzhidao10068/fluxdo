import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/pages/profile_page.dart';
import 'package:fluxdo/pages/profile_stats_edit_page.dart';
import 'package:fluxdo/providers/app_state_refresher.dart';
import 'package:fluxdo/providers/bookmark_name_suggestions_provider.dart';
import 'package:fluxdo/providers/bookmark_sync_controller.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/providers/topic_list/sort_provider.dart';
import 'package:fluxdo/providers/topic_list/tab_state_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/layout/master_detail_layout.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_footer_section/post_footer_section.dart';
import 'package:fluxdo/widgets/profile_stats_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoggedInUser extends CurrentUserNotifier {
  @override
  User? build() => User(id: 1, username: 'alice', trustLevel: 2);
}

class _Summary extends UserSummaryNotifier {
  @override
  Future<UserSummary?> build() async => UserSummary(
    daysVisited: 12,
    postsReadCount: 84,
    likesReceived: 21,
    likesGiven: 8,
    topicCount: 2,
    postCount: 7,
    timeRead: 3600,
    bookmarkCount: 3,
  );
}

/// 只替换远端边界，保留真实的刷新、缓存清理和退出状态重置逻辑。
class _ProfileService extends Fake implements DiscourseService {
  User? user = User(id: 1, username: 'alice', trustLevel: 3);
  int userReads = 0;
  int summaryReads = 0;
  int logoutCalls = 0;
  int daysVisited = 12;
  final forcedSummaryReads = <bool>[];
  final summaryUsernames = <String>[];
  final logoutApiCalls = <bool>[];

  @override
  Future<User?> getPreloadedCurrentUser() async => user;

  @override
  Future<User?> getCurrentUser() async {
    userReads++;
    return user;
  }

  @override
  Future<UserSummary> getUserSummary(
    String username, {
    bool forceRefresh = false,
  }) async {
    summaryUsernames.add(username);
    summaryReads++;
    forcedSummaryReads.add(forceRefresh);
    return UserSummary(
      daysVisited: daysVisited,
      postsReadCount: 84,
      likesReceived: 21,
      likesGiven: 8,
      topicCount: 2,
      postCount: 7,
      timeRead: 3600,
      bookmarkCount: 3,
    );
  }

  @override
  Future<void> logout({bool callApi = true, bool refreshPreload = true}) async {
    logoutApiCalls.add(callApi);
    logoutCalls++;
    user = null;
  }
}

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // 旧备份中的开关不应重新启用已移除的 UI 或服务。
      'ldc_enabled': true,
      'cdk_enabled': true,
      'profile_stats_card_guide_shown': true,
      'profile_stats_config': jsonEncode({
        'dataSource': 'connect',
        'enabledStats': ['daysVisited', 'likesReceivedDays'],
      }),
    });
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  Widget app(Widget child, {ProviderContainer? container}) {
    final localized = TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: child),
      ),
    );
    if (container != null) {
      return UncontrolledProviderScope(container: container, child: localized);
    }
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_LoggedInUser.new),
        userSummaryProvider.overrideWith(_Summary.new),
      ],
      child: localized,
    );
  }

  ProviderContainer profileContainer(
    _ProfileService service,
  ) => ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discourseServiceProvider.overrideWithValue(service),
      currentUserProvider.overrideWithBuild((ref, notifier) => service.user),
      // 书签仓库依赖原生存储；仅替换初始化，仍执行真实 clearCache。
      bookmarkNameSuggestionsProvider.overrideWithBuild(
        (ref, notifier) => ['旧账号书签'],
      ),
    ],
  );

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final wide = size.width >= 900;
    testWidgets('${wide ? '宽屏' : '窄屏'}个人页保留标准入口，旧开关不影响刷新和退出', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      PlatformUtils.debugDesktopOverride = wide;
      final service = _ProfileService();
      final container = profileContainer(service);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        PlatformUtils.debugDesktopOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        app(const ProfilePage(isActive: true), container: container),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(MasterDetailLayout),
        wide ? findsOneWidget : findsNothing,
      );
      expect(find.text('12'), findsOneWidget);
      // 不只查首屏：滚动到各个标准入口，覆盖完整菜单。
      for (final label in [
        S.current.profile_myBookmarks,
        S.current.profile_privateMessages,
        S.current.chat_title,
        S.current.profile_myBadges,
        S.current.profile_inviteLinks,
      ]) {
        final entry = find.text(label);
        await tester.ensureVisible(entry);
        await tester.pumpAndSettle();
        expect(entry.hitTestable(), findsOneWidget);
      }
      for (final retiredLabel in ['LDC', 'CDK', '多元宇宙', '信任要求']) {
        expect(
          find.textContaining(retiredLabel, skipOffstage: false),
          findsNothing,
        );
      }

      service.daysVisited = 19;
      final previousReads = service.summaryReads;
      container
          .read(navActionBusProvider.notifier)
          .state = const NavActionEvent(
        targetId: NavEntryIds.profile,
        action: NavAction.refresh,
        nonce: 1,
      );
      await tester.pumpAndSettle();
      expect(service.userReads, 1);
      expect(service.summaryReads, previousReads + 1);
      expect(service.forcedSummaryReads.last, isTrue);
      expect(service.summaryUsernames, everyElement('alice'));
      expect(container.read(userSummaryProvider).hasError, isFalse);
      expect(find.text('19'), findsOneWidget);

      // 准备真实的账号缓存与筛选，确保退出确实完成 resetForLogout。
      expect(prefs.containsKey('current_user_cache'), isTrue);
      expect(prefs.containsKey('user_summary_cache'), isTrue);
      container
          .read(topicFilterProvider.notifier)
          .setFilter(TopicListFilter.unread);
      container
          .read(topicSortOrderProvider.notifier)
          .setOrder(TopicSortOrder.likes);
      container.read(topicSortAscendingProvider.notifier).setAscending(true);
      container.read(tabTagsProvider(null).notifier).state = ['old-tag'];
      container.read(activeCategorySlugsProvider.notifier).add('old-category');
      final suggestions = container.read(
        bookmarkNameSuggestionsProvider.notifier,
      );
      expect(container.read(bookmarkNameSuggestionsProvider), isNotEmpty);

      final logoutButton = find.text(S.current.profile_logoutCurrentAccount);
      if (wide) {
        await tester.ensureVisible(logoutButton);
      } else {
        await tester.scrollUntilVisible(
          logoutButton,
          400,
          scrollable: find
              .descendant(
                of: find.byType(ProfilePage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(logoutButton);
      await tester.pumpAndSettle();
      expect(find.text(S.current.profile_confirmLogout), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, S.current.common_exit),
      );
      await tester.pumpAndSettle();

      expect(service.logoutCalls, 1);
      expect(service.logoutApiCalls, [true]);
      expect(container.read(currentUserProvider).value, isNull);
      expect(container.read(userSummaryProvider).value, isNull);
      for (final key in [
        'current_user_cache',
        'current_user_cache_username',
        'user_summary_cache',
        'user_summary_cache_username',
      ]) {
        expect(prefs.containsKey(key), isFalse, reason: key);
      }
      expect(
        container.read(bookmarkNameSuggestionsProvider.notifier),
        same(suggestions),
      );
      expect(container.read(bookmarkNameSuggestionsProvider), isEmpty);
      expect(container.read(bookmarkSyncControllerProvider).isSyncing, isFalse);
      expect(container.read(topicFilterProvider), TopicListFilter.latest);
      expect(
        container.read(topicSortOrderProvider),
        TopicSortOrder.defaultOrder,
      );
      expect(container.read(topicSortAscendingProvider), isFalse);
      expect(container.read(tabTagsProvider(null)), isEmpty);
      expect(container.read(activeCategorySlugsProvider), isEmpty);
      expect(find.byType(ProfileStatsCard), findsNothing);
      expect(find.text(S.current.profile_loggingOut), findsNothing);
      expect(find.text(S.current.profile_loginLinuxDo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('全局刷新重建 Summary，旧生态开关不影响延迟刷新', (tester) async {
    final service = _ProfileService();
    final container = profileContainer(service);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    await tester.pumpWidget(
      app(const ProfileStatsCard(), container: container),
    );
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    service.daysVisited = 23;
    final previousReads = service.summaryReads;
    AppStateRefresher.refreshAll(container);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(service.summaryReads, greaterThan(previousReads));
    expect(container.read(userSummaryProvider).hasError, isFalse);
    expect(find.text('23'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧 Connect 配置通过 Summary 显示数据，编辑页不提供旧数据源', (tester) async {
    await tester.pumpWidget(app(const ProfileStatsCard()));
    await tester.pumpAndSettle();
    expect(find.text('12'), findsOneWidget);
    expect(find.text('访问天数'), findsOneWidget);
    expect(find.text('获赞天数'), findsNothing);
    await tester.pumpWidget(app(const ProfileStatsEditPage()));
    await tester.pumpAndSettle();
    expect(find.text('统计卡片自定义'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('信任等级周期'), findsNothing);
    expect(find.text('获赞人数'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('他人帖子更多菜单移除 LDC 打赏，保留回复分享书签', (tester) async {
    final post = Post.fromJson({
      'id': 2,
      'user_id': 2,
      'username': 'bob',
      'post_number': 2,
      'cooked': '<p>hello</p>',
    });
    await tester.pumpWidget(
      app(
        PostFooterSection(
          post: post,
          topicId: 42,
          topicHasAcceptedAnswer: false,
          padding: EdgeInsets.zero,
          onReply: ({String? initialContent}) {},
          onEdit: null,
          onShareAsImage: null,
          onRefreshPost: null,
          onJumpToPost: null,
          onSolutionChanged: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Symbols.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.text('打赏 LDC'), findsNothing);
    expect(find.byIcon(Symbols.volunteer_activism_rounded), findsNothing);
    expect(find.text(S.current.common_reply), findsWidgets);
    expect(find.text(S.current.common_shareLink), findsOneWidget);
    expect(find.text(S.current.common_addBookmark), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
