import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/services/storage/system_secret_store.dart';
import 'package:fluxdo/utils/app_directories.dart';

class _NamespacedStorage extends FlutterSecureStoragePlatform {
  final services = <String, Map<String, String>>{};
  final calls = <Map<String, String>>[];

  Map<String, String> _values(Map<String, String> options) {
    calls.add(Map.of(options));
    return services.putIfAbsent(options['accountName']!, () => {});
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _values(options)[key];

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _values(options)[key] = value;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _values(options).remove(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(_values(options));

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _values(options).containsKey(key);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _values(options).clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterSecureStoragePlatform originalPlatform;

  setUp(() {
    originalPlatform = FlutterSecureStoragePlatform.instance;
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    FlutterSecureStoragePlatform.instance = originalPlatform;
    debugDefaultTargetPlatformOverride = null;
  });

  test('macOS 读写、迁移及作用域清理均限定在 fork Keychain service', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = _NamespacedStorage();
    FlutterSecureStoragePlatform.instance = platform;
    const key = SecretKey(
      namespace: 'auth',
      name: 'token',
      legacyKeys: ['legacy_token'],
    );
    const oldService = AppleOptions.defaultAccountName;
    platform.services[oldService] = {
      key.storageKey: '原版令牌',
      'legacy_token': '原版旧令牌',
    };
    final store = SystemSecretStore();

    expect(await store.read(key), isNull);
    platform.services[appStorageNamespace]!['legacy_token'] = 'fork 旧令牌';
    expect(await store.read(key), 'fork 旧令牌');
    expect(platform.services[appStorageNamespace], {
      key.storageKey: 'fork 旧令牌',
    });
    await store.write(key, 'fork 新令牌');
    expect(await store.read(key), 'fork 新令牌');
    await store.deleteScope(const SecretScope(namespace: 'auth'));
    expect(await store.read(key), isNull);
    expect(platform.services[oldService], {
      key.storageKey: '原版令牌',
      'legacy_token': '原版旧令牌',
    });
    expect(platform.calls, isNotEmpty);
    for (final options in platform.calls) {
      expect(options['accountName'], appStorageNamespace);
      expect(options['usesDataProtectionKeychain'], 'false');
    }
  });

  test('iOS 保留现有 Keychain service', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final platform = _NamespacedStorage();
    FlutterSecureStoragePlatform.instance = platform;
    const key = SecretKey(namespace: 'auth', name: 'token');

    await SystemSecretStore().write(key, 'value');

    expect(
      platform.calls.single['accountName'],
      AppleOptions.defaultAccountName,
    );
  });

  test('系统安全存储支持读写和删除', () async {
    final store = SystemSecretStore();
    const key = SecretKey(namespace: 'test', name: 'secret');

    await store.write(key, 'value');
    expect(await store.read(key), 'value');

    await store.delete(key);
    expect(await store.read(key), isNull);
  });

  test('读取时自动迁移旧 SecureStorage Key', () async {
    FlutterSecureStorage.setMockInitialValues({'legacy_key': 'legacy-value'});
    final store = SystemSecretStore();
    const key = SecretKey(
      namespace: 'test',
      name: 'secret',
      legacyKeys: ['legacy_key'],
    );

    expect(await store.read(key), 'legacy-value');

    const storage = FlutterSecureStorage();
    expect(await storage.read(key: key.storageKey), 'legacy-value');
    expect(await storage.read(key: 'legacy_key'), isNull);
  });

  test('作用域清理不会影响其它账号', () async {
    final store = SystemSecretStore();
    const alice = SecretKey(
      namespace: 'auth',
      name: 'token',
      accountId: 'alice',
    );
    const bob = SecretKey(namespace: 'auth', name: 'token', accountId: 'bob');
    await store.write(alice, 'a');
    await store.write(bob, 'b');

    await store.deleteScope(
      const SecretScope(namespace: 'auth', accountId: 'alice'),
    );

    expect(await store.read(alice), isNull);
    expect(await store.read(bob), 'b');
  });
}
