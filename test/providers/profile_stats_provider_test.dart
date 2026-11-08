import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/profile_stats_config.dart';
import 'package:fluxdo/providers/profile_stats_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取旧配置后持久化 Summary 迁移结果，重新创建容器仍可读取', () async {
    SharedPreferences.setMockInitialValues({
      'profile_stats_config': jsonEncode({
        'dataSource': 'connect',
        'enabledStats': ['likesReceivedDays', 'postCount', 'postCount'],
        'layoutMode': 'scroll',
        'columnsPerRow': 2,
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer.test(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    final config = container.read(profileStatsConfigProvider);
    expect(config.enabledStats, [ProfileStatType.postCount]);
    await Future<void>.delayed(Duration.zero);
    expect(
      jsonDecode(prefs.getString('profile_stats_config')!),
      config.toJson(),
    );
    final fresh = ProviderContainer.test(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    expect(fresh.read(profileStatsConfigProvider).toJson(), config.toJson());
  });

  test('损坏配置回退默认值', () async {
    SharedPreferences.setMockInitialValues({'profile_stats_config': '{broken'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer.test(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    expect(
      container.read(profileStatsConfigProvider).toJson(),
      const ProfileStatsConfig().toJson(),
    );
  });

  for (final damaged in <Object>[
    42,
    true,
    <String>['summary'],
  ]) {
    test('底层类型为 ${damaged.runtimeType} 时回退并修复持久化配置', () async {
      SharedPreferences.setMockInitialValues({'profile_stats_config': damaged});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer.test(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      expect(
        container.read(profileStatsConfigProvider).toJson(),
        const ProfileStatsConfig().toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      await prefs.reload();
      expect(
        prefs.getString('profile_stats_config'),
        const ProfileStatsConfig().toJsonString(),
      );
    });
  }

  testWidgets('快速编辑保存最终结果，销毁后取消待写入定时器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    final notifier = container.read(profileStatsConfigProvider.notifier);
    notifier.setEnabledStats([ProfileStatType.postCount]);
    notifier.setLayoutMode(StatsLayoutMode.scroll);
    await tester.pump(const Duration(milliseconds: 350));
    final saved = ProfileStatsConfig.fromJsonString(
      prefs.getString('profile_stats_config')!,
    );
    expect(saved.enabledStats, [ProfileStatType.postCount]);
    expect(saved.layoutMode, StatsLayoutMode.scroll);
    notifier.setColumnsPerRow(2);
    container.dispose();
    await tester.pump(const Duration(milliseconds: 350));
    expect(prefs.getString('profile_stats_config'), saved.toJsonString());
    expect(tester.takeException(), isNull);
  });
}
