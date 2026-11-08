import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/profile_stats_config.dart';
import '../models/user.dart';
import '../providers/core_providers.dart';
import '../providers/profile_stats_provider.dart';
import '../widgets/profile_stats_card.dart';

import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';

/// 统计卡片编辑页
class ProfileStatsEditPage extends ConsumerStatefulWidget {
  const ProfileStatsEditPage({super.key});

  @override
  ConsumerState<ProfileStatsEditPage> createState() =>
      _ProfileStatsEditPageState();
}

class _ProfileStatsEditPageState extends ConsumerState<ProfileStatsEditPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(profileStatsConfigProvider);
    final notifier = ref.read(profileStatsConfigProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(S.current.profileStats_editTitle),
        actions: [
          TextButton(
            onPressed: () => notifier.update(const ProfileStatsConfig()),
            child: Text(S.current.common_reset),
          ),
        ],
      ),
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
        children: [
          // 预览（可拖拽排序）
          _PreviewSection(
            config: config,
            onReorder: notifier.reorderStats,
            scrollController: _scrollController,
          ),
          const SizedBox(height: 24),

          // 统计项选择
          _SectionHeader(
            title: S.current.profileStats_selectItems,
            trailing: Text(
              '${config.enabledStats.length}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _StatChipGrid(config: config),
          const SizedBox(height: 24),

          // 布局设置
          _SectionHeader(title: S.current.profileStats_layoutSettings),
          const SizedBox(height: 8),
          _LayoutSettings(config: config),
        ],
      ),
    );
  }
}

/// 区块标题
class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 使用标准 Summary 数据的预览区域，支持拖拽排序。
class _PreviewSection extends ConsumerWidget {
  final ProfileStatsConfig config;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final ScrollController? scrollController;
  const _PreviewSection({
    required this.config,
    this.onReorder,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerState = ref.watch(userSummaryProvider);
    final isLoading = providerState.isLoading && !providerState.hasValue;
    final hasError = providerState.hasError && !providerState.hasValue;

    return Stack(
      children: [
        ProfileStatsCardPreview(
          config: config,
          values: _fromSummary(providerState.value),
          onReorder: onReorder,
          scrollController: scrollController,
        ),
        if (isLoading)
          const Positioned(
            right: 12,
            bottom: 8,
            child: LoadingSpinner(size: 16),
          ),
        if (hasError)
          Positioned(
            right: 8,
            bottom: 6,
            child: Tooltip(
              message: S.current.profileStats_loadError,
              child: Icon(
                Symbols.error_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error
                    .withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }

  Map<ProfileStatType, int> _fromSummary(UserSummary? s) {
    if (s == null) return {};
    return {
      ProfileStatType.daysVisited: s.daysVisited,
      ProfileStatType.postsReadCount: s.postsReadCount,
      ProfileStatType.likesReceived: s.likesReceived,
      ProfileStatType.likesGiven: s.likesGiven,
      ProfileStatType.topicCount: s.topicCount,
      ProfileStatType.postCount: s.postCount,
      ProfileStatType.timeRead: s.timeRead,
      ProfileStatType.recentTimeRead: s.recentTimeRead,
      ProfileStatType.bookmarkCount: s.bookmarkCount,
      ProfileStatType.topicsEntered: s.topicsEntered,
    };
  }
}

/// 统计项 Chip 网格（点击切换选中/取消，排序通过预览卡片拖拽）
class _StatChipGrid extends ConsumerWidget {
  final ProfileStatsConfig config;
  const _StatChipGrid({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(profileStatsConfigProvider.notifier);
    final selected = config.enabledStats;
    final unselected = ProfileStatType.values
        .where((s) => !selected.contains(s))
        .toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final stat in selected)
          FilterChip(
            label: Text(getStatLabel(stat)),
            selected: true,
            onSelected: (_) => notifier.removeStat(stat),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        for (final stat in unselected)
          FilterChip(
            label: Text(getStatLabel(stat)),
            selected: false,
            onSelected: !isStatCompatible(stat, config.dataSource)
                ? null
                : (_) => notifier.addStat(stat),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            tooltip: !isStatCompatible(stat, config.dataSource)
                ? S.current.profileStats_incompatibleSource
                : null,
          ),
      ],
    );
  }
}

/// 布局设置
class _LayoutSettings extends ConsumerWidget {
  final ProfileStatsConfig config;
  const _LayoutSettings({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(profileStatsConfigProvider.notifier);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SettingRow(
              label: S.current.profileStats_layoutMode,
              child: M3eButtonGroup<StatsLayoutMode>(
                items: [
                  M3eButtonGroupItem(
                    value: StatsLayoutMode.grid,
                    icon: const Icon(Symbols.grid_view_rounded),
                    label: Text(S.current.profileStats_layoutGrid),
                  ),
                  M3eButtonGroupItem(
                    value: StatsLayoutMode.scroll,
                    icon: const Icon(Symbols.view_column_rounded),
                    label: Text(S.current.profileStats_layoutScroll),
                  ),
                ],
                selected: config.layoutMode,
                onSelected: (mode) => notifier.setLayoutMode(mode),
              ),
            ),
            if (config.layoutMode == StatsLayoutMode.grid) ...[
              Divider(
                height: 24,
                thickness: 0.5,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
              _SettingRow(
                label: S.current.profileStats_columnsPerRow,
                child: M3eButtonGroup<int>(
                  items: const [
                    M3eButtonGroupItem(value: 2, label: Text('2')),
                    M3eButtonGroupItem(value: 3, label: Text('3')),
                    M3eButtonGroupItem(value: 4, label: Text('4')),
                  ],
                  selected: config.columnsPerRow,
                  onSelected: (n) => notifier.setColumnsPerRow(n),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _SettingRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 16),
        // M3eButtonGroup 内部 Expanded 布局需要有界宽度,child 占满剩余
        Expanded(child: child),
      ],
    );
  }
}
