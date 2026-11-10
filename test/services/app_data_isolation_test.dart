import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/models/draft.dart';
import 'package:fluxdo/services/data_management/cache_size_service.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/migration_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/storage/app_database.dart';
import 'package:fluxdo/utils/app_directories.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  String path(String name) => p.join(root.path, name);

  @override
  Future<String?> getApplicationDocumentsPath() async => path('Documents');

  @override
  Future<String?> getTemporaryPath() async => path('Temporary');

  // 实际平台的 Support 已由原生应用身份隔离，在这里模拟它的结果。
  @override
  Future<String?> getApplicationSupportPath() async => path('Support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late PathProviderPlatform originalPaths;
  late _Paths paths;
  final platform = CfTestPlatform();

  Future<File> write(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<File> legacy(String relative) =>
      write(p.join(paths.path('Documents'), relative), '原版数据');

  setUpAll(() async {
    sandbox = await Directory.systemTemp.createTemp('fluxdo-isolation-');
    originalPaths = PathProviderPlatform.instance;
    paths = _Paths(sandbox);
    PathProviderPlatform.instance = paths;
    for (final name in ['Documents', 'Temporary', 'Support']) {
      await Directory(paths.path(name)).create(recursive: true);
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await platform.initialize();
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    await platform.reset();
    await Hive.close();
    await AppDatabase.debugReset();
  });

  tearDown(() async {
    await Hive.close();
    await AppDatabase.debugReset();
    await LogWriter.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    await CookieJarService().cookieJar.deleteAll();
    PathProviderPlatform.instance = originalPaths;
    // sandbox 由 createTemp 返回，所有测试读写与递归清理均限制在此目录。
    await sandbox.delete(recursive: true);
  });

  for (final target in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    test('$target 内部路径符合平台隔离策略', () async {
      debugDefaultTargetPlatformOverride = target;
      final desktop = [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ].contains(target);
      final data = await getAppDataDirectory();
      final temp = await getAppTemporaryDirectory();
      expect(
        data.path,
        desktop
            ? p.join(paths.path('Documents'), appStorageNamespace)
            : paths.path('Documents'),
      );
      expect(
        temp.path,
        desktop
            ? p.join(paths.path('Temporary'), appStorageNamespace)
            : paths.path('Temporary'),
      );
      expect(await data.exists(), isTrue);
      expect(await temp.exists(), isTrue);
    });
  }

  test('持久 Cookie 读写和退出清理不改动旧共享目录', () async {
    final old = await legacy(p.join('.cookies', 'sentinel'));
    final jar = CookieJarService();
    final uri = Uri.parse(AppConstants.baseUrl);
    await jar.cookieJar.saveFromResponse(uri, [
      Cookie('isolation_probe', 'fork')
        ..path = '/'
        ..maxAge = 3600,
    ]);
    expect(await jar.getCookieValue('isolation_probe'), 'fork');
    final root = await getAppDataDirectory();
    final cookies = Directory(p.join(root.path, '.cookies'));
    expect(
      await cookies.list(recursive: true).where((e) => e is File).isEmpty,
      isFalse,
    );
    expect(await CacheSizeService.getCookieCacheSize(), greaterThan(0));

    await jar.clearAll();
    expect(await jar.getCookieValue('isolation_probe'), isNull);
    expect(await old.readAsString(), '原版数据');
  });

  test('真实 Hive 草稿不读取或覆盖旧目录同账号数据', () async {
    final oldHive = Directory(p.join(paths.path('Documents'), 'hive'));
    await oldHive.create(recursive: true);
    final oldBox = await Hive.openBox<Map>('local_drafts', path: oldHive.path);
    final original = LocalDraftStore(boxFactory: () async => oldBox);
    await original.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: const DraftData(reply: '原版草稿'),
      sequence: 1,
    );
    final oldFile = File(oldBox.path!);
    await oldBox.close();
    final before = await oldFile.readAsBytes();

    final fork = LocalDraftStore();
    expect(await fork.read('alice', 'topic_1'), isNull);
    await fork.write(
      accountId: 'alice',
      draftKey: 'topic_1',
      data: const DraftData(reply: 'NodeLoc 草稿'),
      sequence: 2,
    );
    final box = await AppDatabase.namedBox('local_drafts');
    expect(p.isWithin((await getAppDataDirectory()).path, box.path!), isTrue);
    await Hive.close();
    await AppDatabase.debugReset();
    expect((await fork.read('alice', 'topic_1'))!.data.reply, 'NodeLoc 草稿');
    expect(await oldFile.readAsBytes(), before);
  });

  test('日志迁移只处理应用专属目录中的文件', () async {
    final old = await legacy(p.join('logs', 'app_error.jsonl'));
    final root = await getAppDataDirectory();
    final own = await write(
      p.join(root.path, 'logs', 'app_error.jsonl'),
      '{"message":"fork"}\n',
    );
    final log = await LogWriter.getLogFile();
    expect(p.isWithin(root.path, log.path), isTrue);
    expect(await log.readAsString(), '{"message":"fork"}\n');
    expect(await own.exists(), isFalse);
    expect(await old.readAsString(), '原版数据');
  });

  test('v5–v9 迁移及后台清理不触碰旧共享数据', () async {
    final oldQueue = await write(
      p.join(paths.path('Documents'), '.cookies', 'pending_set_cookies.json'),
      jsonEncode([
        {'url': AppConstants.baseUrl, 'raw': 'original_only=keep; Path=/'},
      ]),
    );
    final oldIndex = await legacy(p.join('hive', 'image_cache_meta_old.hive'));
    final oldCache = await write(
      p.join(paths.path('Temporary'), kLegacyImageCacheKeys.first, 'old'),
      '原版缓存',
    );
    final oldTrash = await write(
      p.join(paths.path('Temporary'), 'unrelated.trash', 'old'),
      '其他应用待删文件',
    );
    final data = await getAppDataDirectory();
    final temp = await getAppTemporaryDirectory();
    final ownQueue = await write(
      p.join(data.path, '.cookies', 'pending_set_cookies.json'),
      jsonEncode([
        {'url': AppConstants.baseUrl, 'raw': 'fork_only=migrated; Path=/'},
      ]),
    );
    final ownIndex = await write(
      p.join(data.path, 'hive', 'image_cache_meta_old.hive'),
      '旧索引',
    );
    for (final key in kLegacyImageCacheKeys) {
      await write(p.join(temp.path, key, 'own'), 'fork 缓存');
      await write(p.join(paths.path('Support'), '$key.db'), 'fork 索引');
    }
    final ownTrash = await write(p.join(temp.path, 'own.trash', 'own'), '待删');

    // v2–v4 是旧版本登录态重置，当前测试仅重放文件迁移 v5–v9。
    final prefs = await SharedPreferences.getInstance();
    for (final key in MigrationService.migrationKeys.take(3)) {
      await prefs.setBool(key, true);
    }
    await MigrationService.runAll(prefs);
    await MigrationService.purgeTrash();
    final jar = CookieJarService();
    expect(await jar.getCookieValue('fork_only'), 'migrated');
    expect(await jar.getCookieValue('original_only'), isNull);
    expect(await ownQueue.exists(), isFalse);
    expect(await ownIndex.exists(), isFalse);
    expect(await ownTrash.exists(), isFalse);
    for (final key in kLegacyImageCacheKeys) {
      expect(await Directory(p.join(temp.path, key)).exists(), isFalse);
      expect(
        await File(p.join(paths.path('Support'), '$key.db')).exists(),
        isFalse,
      );
    }
    expect(
      await temp.list().where((e) => e.path.endsWith('.trash')).isEmpty,
      isTrue,
    );
    expect(await oldQueue.exists(), isTrue);
    expect(await oldIndex.readAsString(), '原版数据');
    expect(await oldCache.readAsString(), '原版缓存');
    expect(await oldTrash.readAsString(), '其他应用待删文件');
  });

  test('图片缓存统计与分类、全量清理都限制在应用目录', () async {
    final oldBlob = await write(
      p.join(paths.path('Temporary'), BlobImageCache.dirName, 'old'),
      '原版图片',
    );
    final oldCache = await write(
      p.join(paths.path('Temporary'), kLegacyImageCacheKeys.first, 'old'),
      '原版缓存',
    );
    final temp = await getAppTemporaryDirectory();
    await BlobImageCache.write(
      BlobImageCache.contentBucket,
      'https://www.nodeloc.com/test.jpg',
      Uint8List.fromList([1, 2, 3, 4]),
    );
    final ownLegacy = await write(
      p.join(temp.path, kLegacyImageCacheKeys.first, 'own'),
      '12345',
    );
    final ownTrash = await write(p.join(temp.path, 'test.trash', 'own'), '123');
    expect(await CacheSizeService.getImageCacheSize(), 12);
    final sizes = await CacheSizeService.getImageCacheBreakdown();
    expect(sizes[ImageCacheCategory.content], 4);
    expect(sizes[ImageCacheCategory.other], 8);
    await CacheSizeService.clearImageCacheCategory(ImageCacheCategory.content);
    expect(await CacheSizeService.getImageCacheSize(), 8);
    await CacheSizeService.deleteImageCacheDirs();
    expect(await CacheSizeService.getImageCacheSize(), 0);
    expect(await ownLegacy.exists(), isFalse);
    expect(await ownTrash.exists(), isFalse);
    expect(await oldBlob.readAsString(), '原版图片');
    expect(await oldCache.readAsString(), '原版缓存');
  });
}
