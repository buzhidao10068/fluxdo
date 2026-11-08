import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';
import 'bookmark_name_suggestions_provider.dart';
import 'bookmark_sync_controller.dart';
import 'notification_list_provider.dart';
import 'topic_list/topic_list_provider.dart';
import 'topic_list/filter_provider.dart';
import 'topic_list/sort_provider.dart';
import 'topic_list/tab_state_provider.dart';
import 'pinned_categories_provider.dart';
import 'user_content_providers.dart';
import 'category_provider.dart';
import 'message_bus/notification_providers.dart';
import 'message_bus/pm_tracking_providers.dart';
import 'message_bus/session_channel_providers.dart';
import 'message_bus/topic_tracking_providers.dart';

// 容器销毁时取消待执行的刷新，不依赖 Riverpod 的内部 disposed 字段。
final _refreshLifetimeProvider = Provider<_RefreshLifetime>((ref) {
  final lifetime = _RefreshLifetime();
  ref.onDispose(() => lifetime.active = false);
  return lifetime;
});

class _RefreshLifetime {
  bool active = true;
}

class AppStateRefresher {
  AppStateRefresher._();

  static final _lastRefreshTimes = Expando<DateTime>();
  static final _refreshGenerations = Expando<int>();

  /// 调用方用 [ProviderScope.containerOf] 取 container 后传入，
  /// 避免 [Future.delayed] 闭包持有的 [WidgetRef] 在延迟期间随 widget unmount 失效，
  /// 进而抛 StateError 中断后续 invalidate（曾导致登录后 ProfilePage 卡 loading）。
  static void refreshAll(ProviderContainer container) {
    // 会话重绑不能被普通页面刷新去抖跳过。
    _resetAccountState(container);
    // 去抖：2 秒内重复调用直接跳过（如 authStateProvider listener + _goToLogin 同时触发）
    final now = DateTime.now();
    final lastRefresh = _lastRefreshTimes[container];
    if (lastRefresh != null &&
        now.difference(lastRefresh) < const Duration(seconds: 2)) {
      return;
    }
    _lastRefreshTimes[container] = now;
    final lifetime = container.read(_refreshLifetimeProvider);
    final generation = (_refreshGenerations[container] ?? 0) + 1;
    _refreshGenerations[container] = generation;

    // 第一批：主页渲染必需（用户信息 + 分类 + 话题列表）
    for (final refresh in _coreRefreshers) {
      refresh(container);
    }
    _refreshTopicTabs(container);
    // 第二批：延迟 1 秒执行，避免并发请求过多触发风控
    Future.delayed(const Duration(seconds: 1), () {
      if (!lifetime.active || _refreshGenerations[container] != generation) {
        return;
      }
      for (final refresh in _deferredRefreshers) {
        refresh(container);
      }
    });
  }

  static Future<void> resetForLogout(ProviderContainer container) async {
    _refreshGenerations[container] = (_refreshGenerations[container] ?? 0) + 1;
    _lastRefreshTimes[container] = null;
    _resetAccountState(container);
    // 同时启动两项清理；一个失败仍等待另一项完成，再向调用者报告错误。
    final clearing = Future.wait([
      container.read(currentUserProvider.notifier).clearCache(),
      container.read(userSummaryProvider.notifier).clearCache(),
    ]);
    // 立即挂接错误处理，状态重置期间也不会产生未处理的异步错误。
    final completed = clearing.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    // 登出时 invalidate 所有（不会发请求，因为数据被清空了）
    for (final refresh in _coreRefreshers) {
      refresh(container);
    }
    for (final refresh in _deferredRefreshers) {
      refresh(container);
    }
    // 重置筛选/排序/标签（会通过 signal listener 触发话题列表刷新，
    // 无需再手动 invalidate 话题列表）
    container
        .read(topicFilterProvider.notifier)
        .setFilter(TopicListFilter.latest);
    container
        .read(topicSortOrderProvider.notifier)
        .setOrder(TopicSortOrder.defaultOrder);
    container.read(topicSortAscendingProvider.notifier).setAscending(false);
    final pinnedIds = container.read(pinnedCategoriesProvider);
    container.read(tabTagsProvider(null).notifier).state = [];
    for (final id in pinnedIds) {
      container.read(tabTagsProvider(id).notifier).state = [];
    }
    container.read(activeCategorySlugsProvider.notifier).reset();
    final error = await completed;
    if (error != null) throw error;
  }

  static void _resetAccountState(ProviderContainer container) {
    // 未初始化的 provider 没有旧状态；提前创建再清理会使首次加载失效。
    if (container.exists(bookmarkNameSuggestionsProvider)) {
      container.read(bookmarkNameSuggestionsProvider.notifier).clearCache();
    }
    if (container.exists(bookmarkSyncControllerProvider)) {
      container.read(bookmarkSyncControllerProvider.notifier).reset();
    }
    container.invalidate(currentUsernameProvider);
    container.invalidate(bookmarksProvider);
  }

  /// 刷新话题列表各 tab
  /// 只刷新当前 tab，非活跃 tab 标记 stale，切换到时才刷新
  static void _refreshTopicTabs(ProviderContainer container) {
    final currentCategoryId = container.read(currentTabCategoryIdProvider);
    container.invalidate(topicListProvider(currentCategoryId));

    // 非当前 tab 标记 stale，不发请求
    final pinnedIds = container.read(pinnedCategoriesProvider);
    final staleTabs = <int?>{};
    for (final categoryId in [null, ...pinnedIds]) {
      if (categoryId == currentCategoryId) continue;
      staleTabs.add(categoryId);
    }
    container.read(staleTabsProvider.notifier).state = staleTabs;
  }

  /// 第一批：主页渲染必需的 provider
  /// 用户信息、分类列表（tab 栏依赖）
  static final List<void Function(ProviderContainer container)>
  _coreRefreshers = [
    (c) => c.invalidate(currentUserProvider),
    (c) => c.invalidate(categoriesProvider),
    (c) => c.invalidate(topicTrackingStateMetaProvider),
    (c) => c.invalidate(topicTrackingStateProvider),
  ];

  /// 第二批：非首屏必需，延迟执行以降低并发请求量
  static final List<void Function(ProviderContainer container)>
  _deferredRefreshers = [
    (c) => c.invalidate(userSummaryProvider),
    (c) => c.invalidate(notificationListProvider),
    (c) => c.invalidate(tagsProvider),
    (c) => c.invalidate(canTagTopicsProvider),
    (c) {
      final activeSlugs = c.read(activeCategorySlugsProvider);
      for (final slug in activeSlugs) {
        c.invalidate(categoryTopicsProvider(slug));
      }
    },
    (c) => c.invalidate(browsingHistoryProvider),
    (c) => c.invalidate(bookmarksProvider),
    (c) => c.invalidate(myTopicsProvider),
    (c) => c.invalidate(notificationCountStateProvider),
    (c) => c.invalidate(notificationChannelProvider),
    (c) => c.invalidate(notificationAlertChannelProvider),
    (c) => c.invalidate(logoutChannelProvider),
    (c) => c.invalidate(pmTrackingProvider),
    (c) => c.invalidate(doNotDisturbProvider),
    (c) => c.invalidate(userStatusProvider),
    (c) => c.invalidate(userDraftCountProvider),
    (c) => c.invalidate(reviewableCountsProvider),
    (c) => c.invalidate(messageBusInitProvider),
  ];
}
