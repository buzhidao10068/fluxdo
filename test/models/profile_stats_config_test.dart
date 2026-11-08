import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/profile_stats_config.dart';

void main() {
  test('旧 Connect 配置保留有效项目与顺序，过滤专属项并去重', () {
    final config = ProfileStatsConfig.fromJson({
      'dataSource': 'connect',
      'enabledStats': [
        'likesReceived',
        'topicsRepliedTo',
        'likesReceivedDays',
        'daysVisited',
        'likesReceivedUsers',
        'likesReceived',
      ],
      'layoutMode': 'scroll',
      'columnsPerRow': 3,
    });
    expect(config.dataSource, StatsDataSource.summary);
    expect(config.enabledStats, [
      ProfileStatType.likesReceived,
      ProfileStatType.daysVisited,
    ]);
    expect(config.layoutMode, StatsLayoutMode.scroll);
    expect(config.columnsPerRow, 3);
    expect(config.toJson()['dataSource'], 'summary');
  });

  test('全部为废弃项时恢复默认，但用户主动清空仍保持为空', () {
    final retired = ProfileStatsConfig.fromJson({
      'dataSource': 'connect',
      'enabledStats': [
        'topicsRepliedTo',
        'likesReceivedDays',
        'likesReceivedUsers',
      ],
    });
    expect(retired.enabledStats, const ProfileStatsConfig().enabledStats);
    expect(
      ProfileStatsConfig.fromJson({'enabledStats': []}).enabledStats,
      isEmpty,
    );
  });

  test('未知或非字符串项目不生成重复卡片，非法列数回退', () {
    for (final columns in [0, -1, 8, '3', null]) {
      final config = ProfileStatsConfig.fromJson({
        'enabledStats': ['postCount', 'unknown', null, 12, 'postCount'],
        'columnsPerRow': columns,
        'layoutMode': 'unknown',
      });
      expect(config.enabledStats, [ProfileStatType.postCount]);
      expect(config.columnsPerRow, 4);
      expect(config.layoutMode, StatsLayoutMode.grid);
    }
  });

  test('标准 Summary 配置往返保留设置', () {
    const config = ProfileStatsConfig(
      enabledStats: [ProfileStatType.timeRead, ProfileStatType.bookmarkCount],
      layoutMode: StatsLayoutMode.scroll,
      columnsPerRow: 2,
    );
    expect(
      ProfileStatsConfig.fromJsonString(config.toJsonString()).toJson(),
      config.toJson(),
    );
  });
}
