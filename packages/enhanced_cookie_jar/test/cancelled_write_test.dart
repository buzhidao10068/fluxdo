import 'dart:async';
import 'dart:io';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:test/test.dart';

/// 精确控制磁盘读取和队列占用，重放 WebView 快照通过入口检查后才取消。
class _PausedStore extends FileCookieStore {
  _PausedStore(super.directoryPath, {required this.pauseRead});

  final bool pauseRead;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<CanonicalCookie>> readAll() async {
    final cookies = await super.readAll();
    if (pauseRead) {
      entered.complete();
      await release.future;
    }
    return cookies;
  }

  @override
  Future<void> writeAll(List<CanonicalCookie> cookies) async {
    if (!pauseRead && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.writeAll(cookies);
  }
}

void main() {
  final uri = Uri.parse('https://www.nodeloc.com');
  for (final operation in ['CookieManager', 'CDP', '原子替换']) {
    for (final pauseRead in [false, true]) {
      test('$operation 在${pauseRead ? '冷读' : '写入排队'}期间取消，保留原认证值', () async {
        final directory =
            await Directory.systemTemp.createTemp('cookie-cancel-');
        addTearDown(() => directory.delete(recursive: true));
        final seed = EnhancedPersistCookieJar(
          store: FileCookieStore(directory.path),
        );
        await seed.saveFromSetCookieHeaders(
            uri,
            [
              '_t=incumbent; Path=/; Secure; HttpOnly; Max-Age=86400',
            ],
            trusted: true);
        final store = _PausedStore(directory.path, pauseRead: pauseRead);
        final jar = EnhancedPersistCookieJar(store: store);
        Future<void>? occupyingWrite;
        if (!pauseRead) {
          await jar.readAllCookies();
          occupyingWrite = jar.saveFromSetCookieHeaders(uri, [
            'preference=unrelated; Path=/; Max-Age=86400',
          ]);
          await store.entered.future;
        }
        var current = true;
        final expiry = DateTime.now().add(const Duration(days: 1));
        Future<void> save() async {
          switch (operation) {
            case 'CookieManager':
              await jar.saveFromResponseTrusted(
                  uri,
                  [
                    Cookie('_t', 'stale')
                      ..path = '/'
                      ..expires = expiry,
                  ],
                  trusted: true,
                  shouldWrite: () => current);
            case 'CDP':
              await jar.saveFromCdpCookies(
                  uri,
                  [
                    {
                      'name': '_t',
                      'value': 'stale',
                      'domain': uri.host,
                      'path': '/',
                      'expires': expiry.millisecondsSinceEpoch / 1000,
                    },
                  ],
                  trusted: true,
                  shouldWrite: () => current);
            case '原子替换':
              await jar.replaceByNameForSite(
                  uri,
                  '_t',
                  [
                    CanonicalCookie(
                      name: '_t',
                      value: 'stale',
                      domain: uri.host,
                      hostOnly: true,
                      expiresAt: expiry,
                    ),
                  ],
                  shouldWrite: () => current);
          }
        }

        final pending = save();
        if (pauseRead) await store.entered.future;
        current = false;
        store.release.complete();
        await pending;
        if (occupyingWrite != null) await occupyingWrite;
        expect(
          (await jar.loadForRequest(uri))
              .singleWhere((c) => c.name == '_t')
              .value,
          'incumbent',
        );
        final reloaded = EnhancedPersistCookieJar(
          store: FileCookieStore(directory.path),
        );
        expect(
          (await reloaded.loadForRequest(uri))
              .singleWhere((c) => c.name == '_t')
              .value,
          'incumbent',
        );
      });
    }
  }
}
