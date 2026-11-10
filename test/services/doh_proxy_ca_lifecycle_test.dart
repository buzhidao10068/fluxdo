import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_service.dart';
import 'package:fluxdo/services/network/doh_proxy/ffi_worker.dart';

// 模拟同步原生 start 阻塞，后续 stop/status 只能在同一 isolate 中排队执行。
void _slowNativeWorker(SendPort ready) {
  final requests = ReceivePort();
  var running = false;
  final history = <String>[];
  ready.send(requests.sendPort);
  requests.listen((dynamic message) {
    final reply = message['replyTo'] as SendPort;
    switch (message['cmd']) {
      case 'start':
        final cert = message['caCertPem'];
        history.add('start:$cert');
        if (cert == 'CA A') sleep(const Duration(milliseconds: 800));
        running = true;
        reply.send({'ok': true, 'port': 23456});
      case 'stop':
        history.add('stop');
        running = false;
        reply.send({'ok': true});
      case 'status':
        reply.send({
          'ok': true,
          'running': running,
          'port': running ? 23456 : 0,
        });
      case 'history':
        reply.send(history);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DohProxyService service;
  late List<Map<String, dynamic>> starts;
  var running = false;
  var stopWorks = true;
  var statusWorks = true;
  var startWorks = true;
  var stops = 0;

  setUp(() {
    starts = [];
    running = false;
    stopWorks = statusWorks = startWorks = true;
    stops = 0;
    service = DohProxyService.forTesting(
      startFfi: (config) async {
        starts.add(config);
        running = startWorks;
        return startWorks ? 23456 : -1;
      },
      stopFfi: () async {
        stops++;
        if (!stopWorks) throw StateError('停止失败');
        running = false;
      },
      statusFfi: () async => statusWorks
          ? {'ok': true, 'running': running, 'port': running ? 23456 : 0}
          : {'ok': false},
    );
  });

  Future<bool> start({String cert = 'CA A', String key = 'key A'}) =>
      service.start(caCertPem: cert, caKeyPem: key);

  test('同一 CA 和配置复用正在运行的代理', () async {
    expect(await start(), isTrue);
    expect(await start(), isTrue);
    expect(starts, hasLength(1));
    expect(stops, 0);
    expect(service.port, 23456);
  });

  for (final changeKey in [false, true]) {
    test('${changeKey ? '私钥' : 'CA'} 变更时先停止并传入新材料启动', () async {
      expect(await start(), isTrue);
      expect(
        await start(cert: changeKey ? 'CA A' : 'CA B', key: 'key B'),
        isTrue,
      );
      expect(starts, hasLength(2));
      expect(stops, 1);
      expect(starts.last['caCertPem'], changeKey ? 'CA A' : 'CA B');
      expect(starts.last['caKeyPem'], 'key B');
    });
  }

  test('新 CA 启动失败不被记录为已运行，重试真正再次启动', () async {
    expect(await start(), isTrue);
    startWorks = false;
    expect(await start(cert: 'CA B'), isFalse);
    expect(service.isRunning, isFalse);
    expect(service.lastError, isNotNull);
    startWorks = true;
    expect(await start(cert: 'CA B'), isTrue);
    expect(starts, hasLength(3));
    expect(service.lastError, isNull);
  });

  test('旧代理停止失败时不启动新 CA，并保留真实运行状态供重试', () async {
    expect(await start(), isTrue);
    stopWorks = false;
    expect(await start(cert: 'CA B'), isFalse);
    expect(starts, hasLength(1));
    expect(service.isRunning, isTrue);
    await expectLater(service.stop(verifyStopped: true), throwsStateError);
    stopWorks = true;
    expect(await start(cert: 'CA B'), isTrue);
    expect(starts, hasLength(2));
  });

  test('状态查询失败不能被当作代理已停止', () async {
    expect(await start(), isTrue);
    statusWorks = false;
    await expectLater(service.stop(verifyStopped: true), throwsStateError);
    expect(starts, hasLength(1));
    statusWorks = true;
    await service.stop(verifyStopped: true);
    expect(service.isRunning, isFalse);
  });

  test('启动永久不回包时有界失败，状态未确认前禁止下一次启动', () async {
    var attempts = 0;
    var statusCalls = 0;
    service = DohProxyService.forTesting(
      ffiTimeout: const Duration(milliseconds: 100),
      startFfi: (_) {
        attempts++;
        return Completer<int>().future;
      },
      stopFfi: () => Completer<void>().future,
      statusFfi: () async {
        statusCalls++;
        return {'ok': true, 'running': false};
      },
    );
    expect(await service.start(), isFalse);
    expect(service.lastError, contains('TimeoutException'));
    expect(await start(cert: 'CA B'), isFalse);
    expect(attempts, 1);
    expect(statusCalls, 1);
  });

  test('停止永久不回包时保留旧状态，恢复后可以重新停止', () async {
    var blocked = false;
    service = DohProxyService.forTesting(
      ffiTimeout: const Duration(milliseconds: 100),
      startFfi: (_) async {
        running = true;
        return 23456;
      },
      stopFfi: () async {
        if (blocked) await Completer<void>().future;
        running = false;
      },
      statusFfi: () async => {'ok': true, 'running': running},
    );
    expect(await start(), isTrue);
    blocked = true;
    await expectLater(service.stop(), throwsA(isA<TimeoutException>()));
    expect(service.isRunning, isTrue);
    expect(service.port, 23456);
    blocked = false;
    await service.stop();
    expect(service.isRunning, isFalse);
  });

  test('状态查询永久不回包时不启动新 CA，恢复后可以重试', () async {
    var blocked = false;
    service = DohProxyService.forTesting(
      ffiTimeout: const Duration(milliseconds: 100),
      startFfi: (config) async {
        starts.add(config);
        running = true;
        return 23456;
      },
      stopFfi: () async {
        running = false;
      },
      statusFfi: () async {
        if (blocked) return Completer<Map<String, dynamic>>().future;
        return {'ok': true, 'running': running};
      },
    );
    expect(await start(), isTrue);
    blocked = true;
    expect(await start(cert: 'CA B'), isFalse);
    expect(starts, hasLength(1));
    expect(service.isRunning, isTrue);
    blocked = false;
    expect(await start(cert: 'CA B'), isTrue);
    expect(starts, hasLength(2));
  });

  test('健康检查状态失败不清空本地状态，同配置重试也先停止确认', () async {
    expect(await start(), isTrue);
    statusWorks = false;
    expect(await service.checkAlive(), isFalse);
    expect(service.isRunning, isTrue);
    expect(await start(), isFalse);
    expect(starts, hasLength(1));
    statusWorks = true;
    expect(await start(), isTrue);
    expect(starts, hasLength(2));
  });

  test('真实 isolate 中迟到的旧启动必须经停止确认，才能启动新 CA', () async {
    final worker = FfiWorker(
      _slowNativeWorker,
      timeout: const Duration(milliseconds: 300),
    );
    addTearDown(worker.dispose);
    service = DohProxyService.withWorkerForTesting(worker);
    expect(await start(), isFalse);
    expect(await start(cert: 'CA B'), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(service.isRunning, isFalse);
    expect(await start(cert: 'CA B'), isTrue);
    expect(await worker.request({'cmd': 'history'}), [
      'start:CA A',
      'stop',
      'stop',
      'start:CA B',
    ]);
    await service.stop();
  });
}
