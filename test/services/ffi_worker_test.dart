import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/ffi_worker.dart';

void _worker(SendPort ready) {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((dynamic message) {
    final reply = message['replyTo'] as SendPort;
    switch (message['cmd']) {
      case 'silent':
        break;
      case 'late':
        Timer(const Duration(milliseconds: 300), () => reply.send('迟到'));
      case 'exit':
        Isolate.exit();
      case 'error':
        Timer.run(() => throw StateError('工作线程失败'));
      default:
        reply.send('成功');
    }
  });
}

void _exitBeforeReady(SendPort _) => Isolate.exit();
void _neverReady(SendPort _) => ReceivePort().listen((_) {});

void main() {
  late FfiWorker worker;
  setUp(
    () =>
        worker = FfiWorker(_worker, timeout: const Duration(milliseconds: 150)),
  );
  tearDown(() => worker.dispose());

  test('不回包时有界失败，下一次请求仍使用同一 worker', () async {
    expect(await worker.request({'cmd': 'ok'}), '成功');
    await expectLater(
      worker.request({'cmd': 'silent'}),
      throwsA(isA<TimeoutException>()),
    );
    expect(await worker.request({'cmd': 'ok'}), '成功');
  });

  test('迟到回包不会污染下一次请求', () async {
    await expectLater(
      worker.request({'cmd': 'late'}),
      throwsA(isA<TimeoutException>()),
    );
    expect(await worker.request({'cmd': 'ok'}), '成功');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(await worker.request({'cmd': 'ok'}), '成功');
  });

  for (final command in ['exit', 'error']) {
    test('$command 唤醒等待者，退出确认后允许重试', () async {
      await expectLater(worker.request({'cmd': command}), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await worker.request({'cmd': 'ok'}), '成功');
    });
  }

  test('握手前退出也会失败，不悬挂等待', () async {
    worker.dispose();
    worker = FfiWorker(_exitBeforeReady);
    await expectLater(worker.request({'cmd': 'ok'}), throwsStateError);
  });

  test('握手不回包时超时并清理未接收业务命令的 worker', () async {
    worker.dispose();
    worker = FfiWorker(_neverReady, timeout: const Duration(milliseconds: 100));
    await expectLater(
      worker.request({'cmd': 'ok'}),
      throwsA(isA<TimeoutException>()),
    );
  });
}
