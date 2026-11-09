import 'dart:async';
import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/boundary_sync_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';

import '../../../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  final sync = BoundarySyncService.instance;

  late io.Directory cookieDirectory;
  setUpAll(() async {
    cookieDirectory = await io.Directory.systemTemp.createTemp(
      'cf-boundary-test-',
    );
    await platform.initialize(cookieDirectory: cookieDirectory.path);
  });
  setUp(platform.reset);
  tearDown(platform.reset);
  tearDownAll(() => cookieDirectory.delete(recursive: true));

  Future<void> seed(String value) =>
      jar.cookieJar.saveFromResponse(Uri.parse('https://www.nodeloc.com'), [
        io.Cookie('cf_clearance', value)
          ..domain = '.nodeloc.com'
          ..path = '/',
      ]);

  test('验证前快照包含 WebView 中并存的所有旧值', () async {
    platform.cookies.values = [cfTestCookie('old-a'), cfTestCookie('old-b')];

    expect(await sync.readCookieValuesFromWebView(name: 'cf_clearance'), {
      'old-a',
      'old-b',
    });
    expect(await jar.getCfClearance(), isNull);
  });

  test('trusted 普通同步仍不能替换健康值', () async {
    await seed('verified');
    platform.cookies.values = [cfTestCookie('residue')];

    await sync.syncFromWebView(cookieNames: {'cf_clearance'}, trusted: true);

    expect(await jar.getCfClearance(), 'verified');
  });

  test('验证确认值可替换抢先写入的副本，后续普通同步不能覆盖', () async {
    await seed('bootstrap-residue');
    platform.cookies.values = [cfTestCookie('residue'), cfTestCookie('fresh')];

    await sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );
    expect(await jar.getCfClearance(), 'fresh');

    platform.cookies.values = [cfTestCookie('residue')];
    await sync.syncFromWebView(cookieNames: {'cf_clearance'}, trusted: true);
    expect(await jar.getCfClearance(), 'fresh');
  });

  test('在位判定与写入串行，较慢的旧同步不能覆盖新验证值', () async {
    final readStarted = Completer<void>();
    final oldRead = Completer<CanonicalCookie?>();
    var reads = 0;
    CfClearanceAuthority.instance.debugCookieReader = () {
      if (++reads == 1) {
        readStarted.complete();
        return oldRead.future;
      }
      return jar.getCanonicalCookie('cf_clearance');
    };

    platform.cookies.values = [cfTestCookie('slow-residue')];
    final ordinary = sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
    );
    await readStarted.future;

    platform.cookies.values = [cfTestCookie('fresh')];
    final verified = sync.syncFromWebView(
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );
    await Future<void>.delayed(Duration.zero);
    final readsBeforeRelease = reads;
    oldRead.complete(null);
    await Future.wait([ordinary, verified]);

    expect(readsBeforeRelease, 1, reason: '后续同步必须等前一轮判定与写入完成');
    expect(await jar.getCfClearance(), 'fresh');
  });

  for (final viaCdp in [false, true]) {
    test(
      '${viaCdp ? 'CDP' : 'CookieManager'} 确认值淘汰 expires 更晚的旧分区副本',
      () async {
        final enhanced = jar.cookieJar as EnhancedPersistCookieJar;
        await enhanced.saveCanonicalCookies(
          Uri.parse('https://www.nodeloc.com'),
          [
            CanonicalCookie(
              name: 'cf_clearance',
              value: 'long-lived-residue',
              domain: '.nodeloc.com',
              hostOnly: false,
              expiresAt: DateTime.now().add(const Duration(days: 30)),
              partitionKey: 'old-partition',
              partitioned: true,
            ),
          ],
        );
        platform.cookies.values = [cfTestCookie('fresh')];
        if (viaCdp) platform.controller.partitionKey = 'new-partition';

        await sync.syncFromWebView(
          controller: viaCdp ? platform.controller.wrapped : null,
          cookieNames: {'cf_clearance'},
          trusted: true,
          acceptValues: {'cf_clearance': 'fresh'},
        );

        expect(await jar.getCfClearance(), 'fresh');
        final remaining = (await enhanced.readAllCookies()).where(
          (cookie) => cookie.name == 'cf_clearance',
        );
        expect(remaining.map((cookie) => cookie.value), ['fresh']);
      },
      skip: viaCdp && !io.Platform.isWindows,
    );
  }

  test('Windows CDP 快路径也保护已验证值', () async {
    await seed('verified');
    platform.cookies.values = [cfTestCookie('cdp-residue')];

    await sync.syncFromWebView(
      controller: platform.controller.wrapped,
      cookieNames: {'cf_clearance'},
      trusted: true,
    );

    expect(await jar.getCfClearance(), 'verified');
  }, skip: !io.Platform.isWindows);

  test('Windows CDP 只接受本轮确认值', () async {
    await seed('bootstrap-residue');
    platform.cookies.values = [cfTestCookie('residue'), cfTestCookie('fresh')];

    await sync.syncFromWebView(
      controller: platform.controller.wrapped,
      cookieNames: {'cf_clearance'},
      trusted: true,
      acceptValues: {'cf_clearance': 'fresh'},
    );

    expect(await jar.getCfClearance(), 'fresh');
  }, skip: !io.Platform.isWindows);

  test('清理等待已开始的 WebView 写入结束，最终内存与磁盘均为空', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final epoch = jar.webViewSyncEpoch;
    final writing = jar.writeFromWebView(() async {
      entered.complete();
      await release.future;
      // 模拟已通过有效性检查、正在完成中的异步写入。
      await jar.cookieJar.saveFromResponse(Uri.parse(AppConstants.baseUrl), [
        io.Cookie('_t', 'in-flight-session')
          ..path = '/'
          ..expires = DateTime.now().add(const Duration(days: 1)),
      ]);
    }, isCurrent: () => epoch == jar.webViewSyncEpoch);
    await entered.future;
    var cleared = false;
    final clearing = jar.clearAll().then((_) => cleared = true);
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isFalse, reason: '清理不能越过已经开始的持久化');
    release.complete();
    expect(await writing, isFalse);
    await clearing;
    expect(await jar.getTToken(), isNull);
    final reloaded = EnhancedPersistCookieJar(
      store: FileCookieStore('${cookieDirectory.path}/.cookies'),
    );
    expect(await reloaded.readAllCookies(), isEmpty);
  });

  for (final viaCdp in [false, true]) {
    for (final invalidation in ['换代退出', '局部取消', '单独清理']) {
      test(
        '${viaCdp ? 'CDP' : 'CookieManager'} 等待读取时$invalidation，持久化 jar 不恢复旧认证',
        () async {
          final entered = Completer<void>();
          final snapshot = Completer<List<Cookie>>();
          var reads = 0;
          var cancelled = false;
          platform.cookies.readSnapshot = () {
            reads++;
            if (!entered.isCompleted) entered.complete();
            return snapshot.future;
          };
          final generation = AuthSession().generation;
          final pending = sync.syncFromWebView(
            controller: viaCdp ? platform.controller.wrapped : null,
            cookieNames: {'_t'},
            requestGeneration: generation,
            trusted: true,
            isCancelled: () => cancelled,
          );
          await entered.future;
          if (invalidation == '局部取消') {
            cancelled = true;
          } else {
            if (invalidation == '换代退出') AuthSession().advance();
            // 清理不能等待读取释放；验证锁只包住实际写入。
            await jar.clearAll().timeout(const Duration(seconds: 5));
          }
          expect(await jar.getTToken(), isNull);
          snapshot.complete([
            Cookie(
              name: '_t',
              value: 'old-session',
              domain: Uri.parse(AppConstants.baseUrl).host,
              path: '/',
              isSecure: true,
              isHttpOnly: true,
              expiresDate: DateTime.now()
                  .add(const Duration(days: 1))
                  .millisecondsSinceEpoch,
            ),
          ]);
          await pending;
          expect(await jar.getTToken(), isNull);
          final reloaded = EnhancedPersistCookieJar(
            store: FileCookieStore('${cookieDirectory.path}/.cookies'),
          );
          expect(
            (await reloaded.readAllCookies()).where(
              (cookie) => cookie.name == '_t',
            ),
            isEmpty,
          );
          expect(reads, 1, reason: '失效后不能再进入 CookieManager fallback');
        },
        skip: viaCdp && !io.Platform.isWindows,
      );
    }
  }
}
