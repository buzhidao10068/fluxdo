import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Notion 同步范围。
enum NotionSyncScope {
  firstPostOnly('first_post_only'),
  allPosts('all_posts');

  const NotionSyncScope(this.code);
  final String code;

  static NotionSyncScope fromCode(String? code) {
    return values.firstWhere(
      (s) => s.code == code,
      orElse: () => NotionSyncScope.allPosts,
    );
  }
}

/// Notion 同步配置。按账号隔离存储。
///
/// [integrationToken] 用户从 notion.so/my-integrations 拿到的 secret_xxx。
/// [databaseId] 目标 database 的 id（创建/查询页面都在它里面）。
/// [autoSyncOnBookmark] 收藏一帖时是否自动同步。默认 false，避免意外消耗 API。
/// [syncScope] 默认同步全部帖子（不受 MD 导出的 10 条上限影响）。
class NotionConfig {
  const NotionConfig({
    this.integrationToken,
    this.databaseId,
    this.autoSyncOnBookmark = false,
    this.syncScope = NotionSyncScope.allPosts,
  });

  final String? integrationToken;
  final String? databaseId;
  final bool autoSyncOnBookmark;
  final NotionSyncScope syncScope;

  bool get isComplete =>
      integrationToken != null &&
      integrationToken!.isNotEmpty &&
      databaseId != null &&
      databaseId!.isNotEmpty;

  NotionConfig copyWith({
    String? integrationToken,
    String? databaseId,
    bool? autoSyncOnBookmark,
    NotionSyncScope? syncScope,
    bool clearToken = false,
    bool clearDatabaseId = false,
  }) {
    return NotionConfig(
      integrationToken: clearToken
          ? null
          : (integrationToken ?? this.integrationToken),
      databaseId: clearDatabaseId ? null : (databaseId ?? this.databaseId),
      autoSyncOnBookmark: autoSyncOnBookmark ?? this.autoSyncOnBookmark,
      syncScope: syncScope ?? this.syncScope,
    );
  }

  Map<String, dynamic> toJson() => {
    if (integrationToken != null) 'token': integrationToken,
    if (databaseId != null) 'database_id': databaseId,
    'auto_sync_bookmark': autoSyncOnBookmark,
    'sync_scope': syncScope.code,
  };

  static NotionConfig fromJson(Map<String, dynamic> json) {
    return NotionConfig(
      integrationToken: json['token'] as String?,
      databaseId: json['database_id'] as String?,
      autoSyncOnBookmark: json['auto_sync_bookmark'] as bool? ?? false,
      syncScope: NotionSyncScope.fromCode(json['sync_scope'] as String?),
    );
  }
}

/// 配置仓库：按账号 username 隔离 key 存到 SharedPreferences。
///
/// Token 是明文存储；后续迁移应使用统一的 SecretStore。
/// 如果以后要加密，可以替换为 flutter_secure_storage。
class NotionConfigRepository {
  NotionConfigRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _keyPrefix = 'notion_config_';

  String _key(String accountId) {
    final sanitized = accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$_keyPrefix$sanitized';
  }

  NotionConfig read(String accountId) {
    final raw = _prefs.getString(_key(accountId));
    if (raw == null || raw.isEmpty) return const NotionConfig();
    try {
      return NotionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const NotionConfig();
    }
  }

  Future<void> write(String accountId, NotionConfig config) async {
    await _prefs.setString(_key(accountId), jsonEncode(config.toJson()));
  }

  Future<void> clear(String accountId) async {
    await _prefs.remove(_key(accountId));
  }
}
