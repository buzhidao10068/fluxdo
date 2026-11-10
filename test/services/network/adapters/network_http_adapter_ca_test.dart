import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/network_http_adapter.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = NetworkSettingsService.instance;
  late NetworkSettings original;
  late ServerSocket proxy;
  late HttpServer serverA;
  late HttpServer serverB;
  late NetworkHttpAdapter adapter;
  late List<Socket> sockets;
  late String currentCa;
  var caReadFails = false;
  var connections = 0;

  Future<HttpServer> tlsServer(String version) async {
    final context = SecurityContext()
      ..useCertificateChain(
        'test/fixtures/proxy_ca_rotation/server_$version.pem',
      )
      ..usePrivateKey('test/fixtures/proxy_ca_rotation/server_$version.key');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) {
      request.response.write(version);
      unawaited(request.response.close());
    }, onError: (Object _) {});
    return server;
  }

  setUp(() async {
    // 只访问本机测试服务，需要真实的 TLS 握手。
    HttpOverrides.global = null;
    original = settings.current;
    sockets = [];
    connections = 0;
    caReadFails = false;
    currentCa = await File('test/fixtures/proxy_ca_rotation/ca_a.pem')
        .readAsString();
    serverA = await tlsServer('a');
    serverB = await tlsServer('b');
    proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((downstream) async {
      sockets.add(downstream);
      final incoming = StreamIterator(downstream.cast<List<int>>());
      final header = <int>[];
      while (!ascii.decode(header).contains('\r\n\r\n')) {
        if (!await incoming.moveNext()) return;
        header.addAll(incoming.current);
      }
      final request = ascii.decode(header).split('\r\n').first.split(' ');
      expect(request.first, 'CONNECT');
      connections++;
      final port = int.parse(request[1].split(':').last);
      final upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
      sockets.add(upstream);
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await downstream.flush();
      unawaited(
        upstream
            .cast<List<int>>()
            .pipe(downstream)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      unawaited(() async {
        try {
          while (await incoming.moveNext()) {
            upstream.add(incoming.current);
          }
        } catch (_) {
          // 证书拒绝和清理时客户端会断开测试隧道。
        } finally {
          await incoming.cancel();
          upstream.destroy();
        }
      }());
    });
    settings.notifier.value = original.copyWith(
      dohEnabled: true,
      proxyPort: proxy.port,
    );
    adapter = NetworkHttpAdapter.forTesting(
      settings,
      ProxySettingsService.instance,
      certificatePem: () async {
        if (caReadFails) throw StateError('读取失败');
        return currentCa;
      },
    );
  });

  tearDown(() async {
    adapter.close(force: true);
    for (final socket in sockets) {
      socket.destroy();
    }
    await Future.wait([
      proxy.close(),
      serverA.close(force: true),
      serverB.close(force: true),
    ]);
    settings.notifier.value = original;
  });

  Future<String> fetch(HttpServer server) async {
    final response = await adapter.fetch(
      RequestOptions(
        path: 'https://127.0.0.1:${server.port}/',
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ),
      null,
      null,
    );
    return utf8.decode(await response.stream.expand((bytes) => bytes).toList());
  }

  test('请求信任当前设备 CA，CA 变化后接受新链并拒绝旧链', () async {
    expect(await fetch(serverA), 'a');
    await expectLater(fetch(serverB), throwsA(isA<HandshakeException>()));
    currentCa = await File('test/fixtures/proxy_ca_rotation/ca_b.pem')
        .readAsString();
    expect(await fetch(serverB), 'b');
    await expectLater(fetch(serverA), throwsA(isA<HandshakeException>()));
    expect(connections, 4);
  });

  test('CA 读取失败不能复用已缓存的信任，恢复后可重试', () async {
    expect(await fetch(serverA), 'a');
    caReadFails = true;
    await expectLater(fetch(serverA), throwsStateError);
    expect(connections, 1);
    caReadFails = false;
    currentCa = await File('test/fixtures/proxy_ca_rotation/ca_b.pem')
        .readAsString();
    expect(await fetch(serverB), 'b');
  });
}
