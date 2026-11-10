import 'per_device_cert_service.dart';

/// 暂停期间生成并加载同一张 CA；任一步失败都维持暂停，供用户重试。
class DeviceCaRotation {
  DeviceCaRotation({
    required this.certificates,
    required this.pauseProxy,
    required this.refreshTrust,
    required this.resumeProxy,
  });

  final PerDeviceCertService certificates;
  final Future<void> Function() pauseProxy;
  final Future<bool> Function() refreshTrust;
  final Future<void> Function() resumeProxy;

  Future<void> prepare({bool regenerate = false}) async {
    await pauseProxy();
    try {
      if (regenerate) await certificates.reset();
      if (!await certificates.ensureCaCert()) throw StateError('无法生成设备 CA');
      if (!await refreshTrust()) throw StateError('无法更新代理 CA 信任');
      await resumeProxy();
    } catch (_) {
      await pauseProxy();
      rethrow;
    }
  }
}
