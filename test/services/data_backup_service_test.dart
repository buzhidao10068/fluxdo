import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fluxdo/services/data_management/data_backup_service.dart';

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore(
    super.data, {
    required this.failKey,
    this.persistent = false,
    this.throwOnFailure = false,
  }) : super.withData();

  final String failKey;
  final bool persistent;
  final bool throwOnFailure;
  bool failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$failKey' && (!failed || persistent)) {
      failed = true;
      // 平台即使先落盘再报告失败，调用者也应尝试恢复失败的这一项。
      await super.setValue(valueType, key, value);
      if (throwOnFailure) throw StateError('模拟磁盘异常');
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const legacyData = <String, Map<String, dynamic>>{
    'ldc_enabled': {'type': 'bool', 'value': true},
    'cdk_enabled': {'type': 'bool', 'value': true},
    'ldc_user_info': {'type': 'String', 'value': '{"balance":100}'},
    'cdk_user_info_username': {'type': 'String', 'value': 'alice'},
    'ldc_reward_client_id': {'type': 'String', 'value': 'test-client'},
    'ldc_reward_client_secret': {'type': 'String', 'value': 'test-secret'},
  };
  final configData = <String, Map<String, dynamic>>{
    'theme_mode': {'type': 'String', 'value': 'dark'},
    'pref_hide_bar_on_scroll': {'type': 'bool', 'value': true},
    'seed_color': {'type': 'int', 'value': 0xff123456},
    'pref_font_scale': {'type': 'double', 'value': 1.25},
    'pinned_category_ids': {
      'type': 'StringList',
      'value': ['1', '2'],
    },
    'profile_stats_config': {
      'type': 'String',
      'value': jsonEncode({
        'dataSource': 'connect',
        'enabledStats': ['daysVisited', 'likesReceivedDays'],
      }),
    },
  };

  test('导出过滤旧生态开关缓存和凭证，保留普通配置及类型', () async {
    PackageInfo.setMockInitialValues(
      appName: 'FluxDO',
      packageName: 'com.example.test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({
      for (final entry in {...legacyData, ...configData}.entries)
        entry.key: entry.value['value'],
    });
    final prefs = await SharedPreferences.getInstance();

    final backup = await DataBackupService.exportData(prefs);
    final serialized = jsonDecode(jsonEncode(backup)) as Map<String, dynamic>;
    expect(serialized['version'], 2);
    expect(serialized['data'], configData);
    expect(serialized.containsKey('apiKeys'), isFalse);
    // 导出只筛选内容，不删除设备上原有的历史数据。
    expect(prefs.getString('ldc_reward_client_secret'), 'test-secret');
  });

  for (final version in [1, 2]) {
    test('导入 v$version 旧备份不写回生态数据，普通配置可恢复', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'light',
        'unrelated_setting': 'keep',
        'cdk_enabled': false,
      });
      final prefs = await SharedPreferences.getInstance();
      // 经过 JSON 往返，使用与真实备份文件一致的集合和值类型。
      final backup = jsonDecode(
        jsonEncode({
          'version': version,
          'data': {...legacyData, ...configData},
        }),
      ) as Map<String, dynamic>;

      await DataBackupService.importData(prefs, backup);

      for (final entry in configData.entries) {
        expect(prefs.get(entry.key), entry.value['value'], reason: entry.key);
      }
      for (final key in legacyData.keys.where((key) => key != 'cdk_enabled')) {
        expect(prefs.containsKey(key), isFalse, reason: '$key 不应重新写入');
      }
      expect(prefs.getBool('cdk_enabled'), isFalse);
      expect(prefs.getString('unrelated_setting'), 'keep');
      // 验证持久化结果，避免只检查 SharedPreferences 的内存缓存。
      await prefs.reload();
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.containsKey('ldc_reward_client_secret'), isFalse);
    });
  }

  final invalidBackups = <String, Map<String, dynamic>>{
    '未知版本': {'version': 3, 'data': {}},
    '缺失版本': {'data': {}},
    '错误数据结构': {'version': 2, 'data': []},
    for (final item in <Object?>[
      null,
      {'type': 'unknown', 'value': true},
      {'type': 'bool', 'value': 'true'},
      {'type': 'double', 'value': 'invalid'},
      {
        'type': 'StringList',
        'value': ['valid', 2],
      },
    ])
      '无效配置 $item': {
        'version': 2,
        'data': {
          'theme_mode': {'type': 'String', 'value': 'dark'},
          'bad_setting': item,
        },
      },
    '统计配置类型错误': {
      'version': 2,
      'data': {
        'profile_stats_config': {'type': 'int', 'value': 42},
      },
    },
    'API Key 类型错误': {
      'version': 2,
      'data': {
        'theme_mode': {'type': 'String', 'value': 'dark'},
      },
      'apiKeys': {'provider': 42},
    },
  };
  for (final entry in invalidBackups.entries) {
    test('全量预检拒绝${entry.key}，已有设置不发生部分写入', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'light'});
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        DataBackupService.importData(prefs, entry.value),
        throwsFormatException,
      );
      await prefs.reload();
      expect(prefs.getString('theme_mode'), 'light');
      expect(prefs.getKeys(), {'theme_mode'});
    });
  }

  test('被排除的旧生态字段即使损坏也直接跳过', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await DataBackupService.importData(prefs, {
      'version': 2,
      'data': {'ldc_enabled': null, 'cdk_user_info': [], ...configData},
    });
    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.containsKey('ldc_enabled'), isFalse);
  });

  for (final throwOnFailure in [false, true]) {
    test(
      '平台写入${throwOnFailure ? '抛错' : '返回 false'}后恢复已有值和新键，reload 结果一致',
      () async {
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = _FailingStore(
          {
            'flutter.theme_mode': 'light',
            'flutter.pinned_category_ids': <String>['old'],
          },
          failKey: 'pref_font_scale',
          throwOnFailure: throwOnFailure,
        );
        final prefs = await SharedPreferences.getInstance();
        await expectLater(
          DataBackupService.importData(prefs, {
            'version': 2,
            'data': {
              'theme_mode': configData['theme_mode'],
              'pinned_category_ids': configData['pinned_category_ids'],
              'new_setting': {'type': 'bool', 'value': true},
              'pref_font_scale': configData['pref_font_scale'],
            },
          }),
          throwsStateError,
        );
        await prefs.reload();
        expect(prefs.getString('theme_mode'), 'light');
        expect(prefs.getStringList('pinned_category_ids'), ['old']);
        expect(prefs.containsKey('new_setting'), isFalse);
        expect(prefs.containsKey('pref_font_scale'), isFalse);
      },
    );
  }

  test('恢复也失败时明确报告，并继续恢复其余设置', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _FailingStore(
      {'flutter.theme_mode': 'light', 'flutter.pref_font_scale': 1.0},
      failKey: 'pref_font_scale',
      persistent: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await expectLater(
      DataBackupService.importData(prefs, {
        'version': 2,
        'data': {
          'theme_mode': configData['theme_mode'],
          'pref_font_scale': configData['pref_font_scale'],
        },
      }),
      throwsA(
        isA<BackupRollbackException>().having(
          (e) => e.rollbackErrors,
          '恢复错误',
          hasLength(1),
        ),
      ),
    );
    await prefs.reload();
    expect(prefs.getString('theme_mode'), 'light');
  });

  test('读取文件时拒绝未知版本及错误顶层结构', () async {
    final directory = await Directory.systemTemp.createTemp(
      'backup_validation_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/backup.json');
    for (final content in ['[]', '{"version":99,"data":{}}']) {
      await file.writeAsString(content);
      await expectLater(
        DataBackupService.parseBackupFile(file.path),
        throwsFormatException,
      );
    }
    final backup = {'version': 1, 'data': configData};
    await file.writeAsString(jsonEncode(backup));
    expect(await DataBackupService.parseBackupFile(file.path), backup);
  });

  test('普通配置和 AI API Key 一同恢复，随后导出保留新值', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'ai_provider_key_provider': 'old-value',
    });
    PackageInfo.setMockInitialValues(
      appName: 'FluxDO',
      packageName: 'com.example.test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final prefs = await SharedPreferences.getInstance();
    await DataBackupService.importData(prefs, {
      'version': 2,
      'data': {
        'theme_mode': configData['theme_mode'],
        'ai_providers': {
          'type': 'String',
          'value': jsonEncode([
            {'id': 'provider'},
          ]),
        },
      },
      'apiKeys': {'provider': 'new-value'},
    });
    await prefs.reload();
    expect(prefs.getString('theme_mode'), 'dark');
    const secure = FlutterSecureStorage();
    expect(await secure.read(key: 'ai_provider_key_provider'), 'new-value');
    final backup = await DataBackupService.exportData(prefs);
    expect(backup['apiKeys'], {'provider': 'new-value'});
  });

  group('DataBackupService v2 反白名单', () {
    test('用户配置默认纳入(v1 白名单时代的漏备项)', () {
      const keys = [
        // v1 前缀白名单能覆盖的
        'pref_locale',
        'theme_mode',
        'seed_color',
        'read_later_items',
        // v1 漏备的重灾区(审计实锤)
        'font_family',
        'scheme_variant',
        'custom_colors',
        'web_bookmarks',
        'recent_emojis',
        'sticker_subscribed_groups',
        'sticker_recent_items',
        'upstream_proxy_protocol',
        'upstream_proxy_cipher',
        'shortcuts_custom',
        'profile_stats_config',
        'topic_new_subset',
        'auto_check_update',
        'notion_config_alice',
        'rhttp_enabled',
        // 被排除前缀误伤的真配置,精确回捞
        'sticker_market_base_url',
      ];
      for (final key in keys) {
        expect(
          DataBackupService.debugShouldBackup(key),
          isTrue,
          reason: '$key 应被备份',
        );
      }
    });

    test('缓存/会话/设备态/一次性标记被排除', () {
      const keys = [
        // 缓存/派生
        'ai_chat_session_messages_123',
        'ai_post_review_guidelines_cache',
        'current_user_cache',
        'current_user_cache_username',
        'user_summary_cache',
        'cdk_user_info',
        'ldc_user_info_username',
        'cdk_enabled',
        'ldc_enabled',
        'ldc_reward_client_id',
        'ldc_reward_client_secret',
        'update_cache',
        'update_etag',
        'sticker_market_groups_cache',
        'bookmark_last_full_sync_42',
        'blob_image_cache_last_sweep',
        // 会话/凭证
        'linux_do_csrf_token',
        'linux_do_username',
        'auth_passive_logout_history_v1',
        'bg_shared_session_key',
        'one_time_password',
        // 设备/运行态
        'cronet_has_fallen_back',
        'vpn_suppressed_doh',
        'per_device_cert_installed',
        'per_device_cert_installed_nodeloc_v1',
        'per_device_cert_installed_nodeloc_sha256_v2',
        'cert_use_per_device',
        'window_x',
        // 一次性标记
        'onboarding_completed',
        'crashlytics_notice_shown',
        'ai_chat_guide_shown',
        'profile_stats_card_guide_shown',
        'cursor_swipe_hint_move_left',
        // 迁移标记(动态派生自 MigrationService)
        'image_cache_orphan_purge_v7',
        'emoji_blob_cache_v8',
        'cookie_clean_slate_v2',
        'cookie_domain_migration_v2',
      ];
      for (final key in keys) {
        expect(
          DataBackupService.debugShouldBackup(key),
          isFalse,
          reason: '$key 不应被备份',
        );
      }
    });
  });
}
