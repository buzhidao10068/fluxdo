import 'dart:async';
import 'dart:isolate';

/// 有限等待的 FFI 通信；超时只结束等待，不取消正在执行的原生调用。
class FfiWorker {
  FfiWorker(this.entryPoint, {this.timeout = const Duration(seconds: 10)});

  final void Function(SendPort) entryPoint;
  final Duration timeout;
  Future<SendPort>? _ready;
  Isolate? _isolate;
  Object? _failure;
  final Set<Completer<dynamic>> _pending = {};

  Future<SendPort> _connect() => _ready ??= _spawn();

  Future<SendPort> _spawn() async {
    final ready = ReceivePort();
    final lifecycle = ReceivePort();
    final connected = Completer<SendPort>();
    _failure = null;
    void fail(Object error) {
      _failure = error;
      if (!connected.isCompleted) connected.completeError(error);
      for (final pending in _pending.toList()) {
        if (!pending.isCompleted) pending.completeError(error);
      }
    }

    final subscription = lifecycle.listen((message) {
      fail(StateError('FFI 工作 isolate 已退出或异常：$message'));
      if (message == null) {
        // 退出通知之后才允许建立新 worker，避免并行执行原生启停。
        _isolate = null;
        _ready = null;
        lifecycle.close();
      }
    });
    final readySubscription = ready.listen((message) {
      if (message is SendPort && !connected.isCompleted) {
        connected.complete(message);
      }
    });
    // 先安装错误处理，防止 spawn 返回前收到退出通知造成未处理异常。
    final handshake = connected.future.timeout(timeout);
    unawaited(handshake.then<void>((_) {}, onError: (Object _) {}));
    var abandoned = false;
    try {
      // 从创建时监听退出和未捕获错误，覆盖握手前退出的情况。
      final spawned = Isolate.spawn(
        entryPoint,
        ready.sendPort,
        onExit: lifecycle.sendPort,
        onError: lifecycle.sendPort,
        errorsAreFatal: true,
      );
      // spawn 本身也可能失败或延迟；超时后清理迟到的 isolate，此时尚未发送业务命令。
      unawaited(
        spawned.then<void>((isolate) {
          if (abandoned) isolate.kill(priority: Isolate.immediate);
        }, onError: (Object _) {}),
      );
      _isolate = await spawned.timeout(timeout);
      return await handshake;
    } catch (error) {
      abandoned = true;
      _failure = error;
      if (_isolate == null) {
        await subscription.cancel();
        lifecycle.close();
        // 同步 spawn 失败时，下次调用允许重试。
        scheduleMicrotask(() => _ready = null);
      } else {
        // 尚未发出业务命令，握手超时可以安全终止这个 worker。
        _isolate!.kill(priority: Isolate.immediate);
      }
      rethrow;
    } finally {
      await readySubscription.cancel();
      ready.close();
    }
  }

  Future<dynamic> request(Map<String, dynamic> arguments) async {
    final sendPort = await _connect();
    if (_failure != null) throw _failure!;
    final response = ReceivePort();
    final result = Completer<dynamic>();
    _pending.add(result);
    final subscription = response.listen((message) {
      if (!result.isCompleted) result.complete(message);
    });
    try {
      sendPort.send({...arguments, 'replyTo': response.sendPort});
      return await result.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'FFI ${arguments['cmd']} 等待超时，原生状态尚未确认',
          timeout,
        ),
      );
    } finally {
      _pending.remove(result);
      await subscription.cancel();
      response.close();
    }
  }

  /// 只用于测试清理；业务超时不能通过杀死 worker 假定原生已停止。
  void dispose() => _isolate?.kill(priority: Isolate.immediate);
}
