import 'dart:async';
import 'dart:io';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:test/test.dart';

/// 只暂停首次读取，让清理、保存和其他冷读可以先完成。
class _PausedReadStore extends FileCookieStore {
  _PausedReadStore(super.directoryPath);

  final entered = Completer<void>();
  final release = Completer<void>();
  var _reads = 0;

  @override
  Future<List<CanonicalCookie>> readAll() async {
    final pause = _reads++ == 0;
    final snapshot = await super.readAll();
    if (pause) {
      entered.complete();
      await release.future;
    }
    return snapshot;
  }
}

void main() {
  final uri = Uri.parse('https://www.nodeloc.com');
  for (final reader in [
    'loadForRequest',
    'loadCanonicalForRequest',
    'readAllCookies'
  ]) {
    for (final action in ['清理', '保存', '另一次冷读']) {
      test('$reader 的旧磁盘读取不能覆盖期间完成的$action', () async {
        final directory = await Directory.systemTemp.createTemp('cookie-cold-');
        addTearDown(() => directory.delete(recursive: true));
        final disk = FileCookieStore(directory.path);
        final seed = EnhancedPersistCookieJar(store: disk);
        await seed.saveFromSetCookieHeaders(
            uri,
            [
              '_t=old-session; Path=/; Secure; HttpOnly; Max-Age=86400',
            ],
            trusted: true);
        final store = _PausedReadStore(directory.path);
        final jar = EnhancedPersistCookieJar(store: store);
        Future<List<String>> read() async {
          switch (reader) {
            case 'loadForRequest':
              return (await jar.loadForRequest(uri))
                  .map((c) => c.value)
                  .toList();
            case 'loadCanonicalForRequest':
              return (await jar.loadCanonicalForRequest(uri))
                  .map((c) => c.value)
                  .toList();
            default:
              return (await jar.readAllCookies()).map((c) => c.value).toList();
          }
        }

        final pending = read();
        await store.entered.future;
        switch (action) {
          case '清理':
            await jar.deleteAll();
          case '保存':
            await jar.saveFromSetCookieHeaders(
                uri,
                [
                  '_t=new-session; Path=/; Secure; HttpOnly; Max-Age=86400',
                ],
                trusted: true);
          case '另一次冷读':
            // 模拟另一写入方更新磁盘，再由第二次冷读发布最新缓存。
            await seed.saveFromSetCookieHeaders(
                uri,
                [
                  '_t=new-session; Path=/; Secure; HttpOnly; Max-Age=86400',
                ],
                trusted: true);
            expect(await read(), ['new-session']);
        }
        final expected = action == '清理' ? <String>[] : ['new-session'];
        store.release.complete();
        expect(await pending, expected);
        expect(await read(), expected);

        // 无关保存会把缓存重新落盘，因此同时核对重建 jar 后的认证值。
        await jar.saveFromSetCookieHeaders(uri, [
          'preference=unrelated; Path=/; Max-Age=86400',
        ]);
        final reloaded = EnhancedPersistCookieJar(
          store: FileCookieStore(directory.path),
        );
        expect(
          (await reloaded.loadForRequest(uri))
              .where((c) => c.name == '_t')
              .map((c) => c.value),
          expected,
        );
      });
    }
  }
}
