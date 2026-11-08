import 'dart:convert';

/// 统计项类型
enum ProfileStatType {
  // Summary API 字段
  daysVisited,
  postsReadCount,
  likesReceived,
  likesGiven,
  topicCount,
  postCount,
  timeRead,
  recentTimeRead,
  bookmarkCount,
  topicsEntered,
}

/// 布局模式
enum StatsLayoutMode { grid, scroll }

/// 数据源
enum StatsDataSource {
  summary, // 全量（Summary API）
}

/// 各数据源支持的统计项
const Map<StatsDataSource, Set<ProfileStatType>> supportedStatsPerSource = {
  StatsDataSource.summary: {
    ProfileStatType.daysVisited,
    ProfileStatType.postsReadCount,
    ProfileStatType.likesReceived,
    ProfileStatType.likesGiven,
    ProfileStatType.topicCount,
    ProfileStatType.postCount,
    ProfileStatType.timeRead,
    ProfileStatType.recentTimeRead,
    ProfileStatType.bookmarkCount,
    ProfileStatType.topicsEntered,
  },
};

/// 判断某统计项是否兼容指定数据源
bool isStatCompatible(ProfileStatType stat, StatsDataSource source) {
  return supportedStatsPerSource[source]?.contains(stat) ?? false;
}

/// 统计卡片配置
class ProfileStatsConfig {
  final List<ProfileStatType> enabledStats;
  final StatsLayoutMode layoutMode;
  final int columnsPerRow; // 网格模式 2/3/4
  final StatsDataSource dataSource;

  const ProfileStatsConfig({
    this.enabledStats = const [
      ProfileStatType.daysVisited,
      ProfileStatType.postsReadCount,
      ProfileStatType.likesReceived,
      ProfileStatType.postCount,
    ],
    this.layoutMode = StatsLayoutMode.grid,
    this.columnsPerRow = 4,
    this.dataSource = StatsDataSource.summary,
  });

  ProfileStatsConfig copyWith({
    List<ProfileStatType>? enabledStats,
    StatsLayoutMode? layoutMode,
    int? columnsPerRow,
    StatsDataSource? dataSource,
  }) {
    return ProfileStatsConfig(
      enabledStats: enabledStats ?? this.enabledStats,
      layoutMode: layoutMode ?? this.layoutMode,
      columnsPerRow: columnsPerRow ?? this.columnsPerRow,
      dataSource: dataSource ?? this.dataSource,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabledStats': enabledStats.map((e) => e.name).toList(),
    'layoutMode': layoutMode.name,
    'columnsPerRow': columnsPerRow,
    'dataSource': dataSource.name,
  };

  factory ProfileStatsConfig.fromJson(Map<String, dynamic> json) {
    final savedStats = json['enabledStats'];
    final statsByName = {
      for (final stat in ProfileStatType.values) stat.name: stat,
    };
    final enabledStats = savedStats is List
        ? savedStats
              .map((name) => statsByName[name])
              .whereType<ProfileStatType>()
              .toSet()
              .toList()
        : const ProfileStatsConfig().enabledStats;
    // 旧 Connect 配置只保留 Summary 支持的项目；不能把每个未知项都替换成
    // daysVisited，否则会出现重复卡片。全部项目失效时恢复默认，主动清空则保留。
    final restoreDefaults =
        savedStats is List && savedStats.isNotEmpty && enabledStats.isEmpty;
    final savedColumns = json['columnsPerRow'];
    return ProfileStatsConfig(
      enabledStats: restoreDefaults
          ? const ProfileStatsConfig().enabledStats
          : enabledStats,
      layoutMode: StatsLayoutMode.values.firstWhere(
        (v) => v.name == json['layoutMode'],
        orElse: () => StatsLayoutMode.grid,
      ),
      columnsPerRow:
          savedColumns is int && savedColumns >= 2 && savedColumns <= 4
          ? savedColumns
          : 4,
      dataSource: StatsDataSource.summary,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory ProfileStatsConfig.fromJsonString(String jsonStr) {
    return ProfileStatsConfig.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  }
}
