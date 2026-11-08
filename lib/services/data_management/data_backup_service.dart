import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../migration_service.dart';
import '../storage/resilient_secure_storage.dart';
import '../../utils/share_utils.dart';

/// 数据备份导出/导入服务
///
/// ## v2:反白名单(排除清单)
///
/// v1 是前缀白名单(pref_/ai_/theme_/…),问题是**持续腐烂**:每加一个
/// 不在白名单前缀下的配置就静默漏备(实际审计发现主题字体/自定义配色、
/// 网页收藏、贴纸订阅、代理另一半 upstream_proxy_* 等十余项全漏,主题
/// 恢复"一半对一半错")。
///
/// v2 反转:**默认全备,只排除稳定类别**——缓存/派生、会话/凭证、
/// 设备绑定/运行态、一次性 UI 标记、迁移标记。新配置项自动纳入,
/// 失败模式从"用户丢配置"变成"备份文件多几个无害 key"。
/// 排除规则在导出与导入两侧都生效(防旧备份/手改文件把会话态灌回来)。
class DataBackupService {
  static final ResilientSecureStorage _secureStorage = ResilientSecureStorage();
  static const _apiKeyPrefix = 'ai_provider_key_';

  /// 排除前缀:命中即不备份。按类别分组,新增排除项时对号入座。
  static const _excludeKeyPrefixes = [
    // ── 缓存 / 派生数据(可重建,体积大或随会话变)──
    'ai_chat_session_messages_',
    'ai_chat_topic_sessions_',
    'ai_chat_all_sessions_index',
    'ai_post_review_guidelines_cache',
    'current_user_cache',
    'user_summary_cache',
    // 已移除的旧站生态配置、缓存与旧版凭证：旧备份也不能重新导入。
    'cdk_',
    'ldc_',
    'update_', // update_cache / update_cache_time / update_etag
    'sticker_market_', // 贴纸市场缓存(真配置 base_url 在下面精确回捞)
    'bookmark_last_full_sync_',
    'blob_image_cache_last_sweep',
    // ── 会话 / 凭证(跨设备无效或有害)──
    'linux_do_', // csrf_token / username
    'cookie_',
    'auth_passive_logout_history',
    'bg_shared_session_key',
    'one_time_password',
    // ── 设备绑定 / 运行态 ──
    'cronet_', // 降级状态
    'vpn_suppressed_',
    'per_device_cert_installed',
    'cert_use_per_device',
    'window_', // 桌面端窗口几何(legacy keys)
    // ── 一次性 UI 标记(新设备应重新引导)──
    'onboarding_completed',
    'crashlytics_notice_shown',
    'cursor_swipe_hint_',
  ];

  /// 排除后缀:一次性引导标记的通用形态(xxx_guide_shown)。
  static const _excludeKeySuffixes = ['_guide_shown'];

  /// 被排除前缀误伤的真配置,精确回捞。
  static const _includeExactKeys = ['sticker_market_base_url'];

  /// 判断 key 是否应该被备份(导出与导入同一套规则)。
  static bool _shouldBackup(String key) {
    if (_includeExactKeys.contains(key)) return true;
    // 迁移完成标记:动态从 MigrationService 派生,不抄常量
    if (MigrationService.migrationKeys.contains(key)) return false;
    for (final prefix in _excludeKeyPrefixes) {
      if (key.startsWith(prefix)) return false;
    }
    for (final suffix in _excludeKeySuffixes) {
      if (key.endsWith(suffix)) return false;
    }
    return true;
  }

  /// 导出数据为 Map
  static Future<Map<String, dynamic>> exportData(
    SharedPreferences prefs,
  ) async {
    final pkg = await PackageInfo.fromPlatform();
    final data = <String, Map<String, dynamic>>{};

    for (final key in prefs.getKeys()) {
      if (!_shouldBackup(key)) continue;

      final value = prefs.get(key);
      if (value == null) continue;

      String type;
      dynamic serializedValue;

      if (value is bool) {
        type = 'bool';
        serializedValue = value;
      } else if (value is int) {
        type = 'int';
        serializedValue = value;
      } else if (value is double) {
        type = 'double';
        serializedValue = value;
      } else if (value is String) {
        type = 'String';
        serializedValue = value;
      } else if (value is List<String>) {
        type = 'StringList';
        serializedValue = value;
      } else {
        continue;
      }

      data[key] = {'type': type, 'value': serializedValue};
    }

    // 导出 AI 供应商 API Key（存储在 FlutterSecureStorage 中）。
    // 其余 SecureStorage 项(登录账密 / User-Api-Key 凭证)是设备绑定,
    // 刻意不导出。
    final apiKeys = await _exportApiKeys(prefs);

    return {
      'version': 2,
      'appVersion': pkg.version,
      'exportTime': DateTime.now().toIso8601String(),
      'data': data,
      if (apiKeys.isNotEmpty) 'apiKeys': apiKeys,
    };
  }

  /// 从 SecureStorage 中导出所有 AI 供应商的 API Key
  static Future<Map<String, String>> _exportApiKeys(
    SharedPreferences prefs,
  ) async {
    final apiKeys = <String, String>{};
    final providersJson = prefs.getString('ai_providers');
    if (providersJson == null) return apiKeys;

    try {
      final list = jsonDecode(providersJson) as List<dynamic>;
      for (final item in list) {
        final id = (item as Map<String, dynamic>)['id'] as String?;
        if (id == null) continue;
        final key = await _secureStorage.read(key: '$_apiKeyPrefix$id');
        if (key != null && key.isNotEmpty) {
          apiKeys[id] = key;
        }
      }
    } catch (_) {
      // 解析失败时跳过
    }
    return apiKeys;
  }

  /// 将导出数据写入临时文件，返回文件路径
  static Future<String> exportToFile(SharedPreferences prefs) async {
    final exportData = await DataBackupService.exportData(prefs);
    final jsonStr = const JsonEncoder.withIndent('  ').convert(exportData);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = await ShareUtils.createOutboxFile(
      'fluxdo_backup_$timestamp.json',
    );
    await file.writeAsString(jsonStr);

    return file.path;
  }

  /// 从 Map 导入数据。
  ///
  /// 导入侧同样过 [_shouldBackup]:v1 旧备份(白名单时代)与手改文件
  /// 里可能混着会话态/缓存 key,一律过滤。
  static Future<void> importData(
    SharedPreferences prefs,
    Map<String, dynamic> backup,
  ) async {
    // 完整预检发生在任何写入之前，包括后半段的 API Key。
    final plan = _validateBackup(backup);
    final previousValues = <String, Object?>{
      for (final key in plan.values.keys) key: prefs.get(key),
    };
    final previousApiKeys = <String, String?>{};
    for (final id in plan.apiKeys.keys) {
      previousApiKeys[id] = await _secureStorage.read(key: '$_apiKeyPrefix$id');
    }
    final attemptedValues = <String>[];
    final attemptedApiKeys = <String>[];
    try {
      for (final entry in plan.values.entries) {
        // setter 即使抛错/返回 false，也可能已改内存或落盘，必须包含在恢复中。
        attemptedValues.add(entry.key);
        await _writePreference(prefs, entry.key, entry.value);
      }
      for (final entry in plan.apiKeys.entries) {
        attemptedApiKeys.add(entry.key);
        await _secureStorage.write(
          key: '$_apiKeyPrefix${entry.key}',
          value: entry.value,
        );
      }
    } catch (error) {
      final rollbackErrors = <Object>[];
      for (final id in attemptedApiKeys.reversed) {
        try {
          final oldValue = previousApiKeys[id];
          if (oldValue == null) {
            await _secureStorage.delete(key: '$_apiKeyPrefix$id');
          } else {
            await _secureStorage.write(
              key: '$_apiKeyPrefix$id',
              value: oldValue,
            );
          }
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      for (final key in attemptedValues.reversed) {
        try {
          await _writePreference(prefs, key, previousValues[key]);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (rollbackErrors.isNotEmpty) {
        throw BackupRollbackException(error, rollbackErrors);
      }
      rethrow;
    }
  }

  static ({Map<String, Object> values, Map<String, String> apiKeys})
  _validateBackup(Map<String, dynamic> backup) {
    if (backup['version'] != 1 && backup['version'] != 2) {
      throw const FormatException('不支持的备份版本');
    }
    final data = backup['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('备份缺少有效的 data 字段');
    }
    final values = <String, Object>{};
    for (final entry in data.entries) {
      if (!_shouldBackup(entry.key)) continue;
      final item = entry.value;
      if (item is! Map<String, dynamic>) {
        throw FormatException('备份配置格式无效：${entry.key}');
      }
      final value = item['value'];
      final Object normalized;
      switch (item['type']) {
        case 'bool' when value is bool:
          normalized = value;
        case 'int' when value is int:
          normalized = value;
        case 'double' when value is num && value.toDouble().isFinite:
          normalized = value.toDouble();
        case 'String' when value is String:
          normalized = value;
        case 'StringList' when value is List && value.every((v) => v is String):
          normalized = List<String>.from(value);
        default:
          throw FormatException('备份配置类型或值无效：${entry.key}');
      }
      if (entry.key == 'profile_stats_config' && normalized is! String) {
        throw const FormatException('统计卡片配置必须是字符串');
      }
      values[entry.key] = normalized;
    }
    final rawApiKeys = backup['apiKeys'];
    final apiKeys = <String, String>{};
    if (rawApiKeys != null) {
      if (rawApiKeys is! Map<String, dynamic>) {
        throw const FormatException('备份 API Key 格式无效');
      }
      for (final entry in rawApiKeys.entries) {
        if (entry.key.isEmpty || entry.value is! String) {
          throw const FormatException('备份 API Key 格式无效');
        }
        apiKeys[entry.key] = entry.value as String;
      }
    }
    return (values: values, apiKeys: apiKeys);
  }

  static Future<void> _writePreference(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    final success = switch (value) {
      null => await prefs.remove(key),
      bool v => await prefs.setBool(key, v),
      int v => await prefs.setInt(key, v),
      double v => await prefs.setDouble(key, v),
      String v => await prefs.setString(key, v),
      List<String> v => await prefs.setStringList(key, v),
      _ => throw FormatException('不支持的配置类型：$key'),
    };
    if (!success) throw StateError('配置写入失败：$key');
  }

  /// 从文件路径读取并解析备份数据
  static Future<Map<String, dynamic>> parseBackupFile(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString();
    final json = jsonDecode(content);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('备份格式无效');
    }
    _validateBackup(json);
    return json;
  }

  /// 测试钩子:暴露备份判定(仅测试用)。
  static bool debugShouldBackup(String key) => _shouldBackup(key);
}

/// 底层存储持续失败时无法保证跨存储恢复，明确报告并保留原错误供诊断。
class BackupRollbackException implements Exception {
  BackupRollbackException(this.cause, this.rollbackErrors);

  final Object cause;
  final List<Object> rollbackErrors;

  @override
  String toString() => '备份导入失败，${rollbackErrors.length} 项数据恢复失败，请重试恢复备份';
}
