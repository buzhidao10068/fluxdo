import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cert_preference_service.dart';
import 'per_device_cert_service.dart';
import 'proxy_ca_material.dart';

/// Proxy CA certificate management
///
/// Configures the app to trust the MITM proxy's CA certificate
/// on all platforms.
class ProxyCertificate {
  ProxyCertificate._();

  static bool _initialized = false;
  static Future<bool>? _initializing;

  /// macOS: CA 是否已在钥匙串中被信任
  static bool _macOsKeychainTrusted = false;

  /// Initialize the security context to trust the proxy CA
  ///
  /// Call this early in app startup (e.g., in main.dart)
  static Future<bool> initialize() async {
    if (_initialized) return true;
    final pending = _initializing;
    if (pending != null) return pending;
    final operation = _initialize();
    _initializing = operation;
    try {
      return await operation;
    } finally {
      _initializing = null;
    }
  }

  static Future<bool> _initialize() async {
    final usePerDevice = await CertPreferenceService.usePerDevice();

    if (usePerDevice) {
      // per-device CA 证书（iOS/macOS 强制，其他平台可选）
      _initialized = await _initializePerDevice();
    } else if (!Platform.isAndroid) {
      // Android: CA 通过 network_security_config.xml 信任
      // 其他平台: 从 assets 加载编译时 CA
      _initialized = await _configureSecurityContext();
    } else {
      _initialized = true;
    }

    return _initialized;
  }

  /// 重新初始化（切换 per-device 开关后调用）
  static Future<bool> reinitialize() async {
    await _initializing;
    _initialized = false;
    _macOsKeychainTrusted = false;
    return initialize();
  }

  /// macOS: 检查 CA 是否在钥匙串中被信任
  ///
  /// 用于 DOH 启用前的检查。如果未信任，尝试重新添加。
  /// 返回 true 表示已信任或不需要钥匙串信任（非 macOS 平台）。
  static Future<bool> ensureKeychainTrust() async {
    if (!Platform.isMacOS) return true;

    // 始终传入当前 CA，原生层对精确证书检查，避免复用旧 CA 的信任结果。
    final certService = PerDeviceCertService.instance;
    if (!certService.isLoaded) {
      await certService.ensureCaCert();
    }
    if (certService.certPem != null) {
      _macOsKeychainTrusted = await _sendCaCertToNative(certService.certPem!);
      return _macOsKeychainTrusted;
    }
    return false;
  }

  /// macOS: CA 钥匙串信任状态（内存缓存，避免频繁调用原生）
  static bool get isMacOsKeychainTrusted =>
      !Platform.isMacOS || _macOsKeychainTrusted;

  /// 初始化 per-device CA 证书（全平台通用）
  static Future<bool> _initializePerDevice() async {
    final certService = PerDeviceCertService.instance;
    final ok = await certService.ensureCaCert();
    if (ok && certService.certPem != null) {
      try {
        final certBytes = proxyCaTrustBytes(certService.certPem!);
        final context = SecurityContext.defaultContext;
        context.setTrustedCertificatesBytes(certBytes);
        debugPrint('ProxyCertificate: per-device CA loaded');
      } catch (e) {
        debugPrint('ProxyCertificate: Could not load per-device CA: $e');
        return false;
      }

      // iOS: 将 CA 发送到原生层（swizzle 需要在 WebView 创建前设置）
      if (Platform.isIOS) {
        if (!await _sendCaCertToNative(certService.certPem!)) return false;
      }
      // macOS: 不在启动时添加钥匙串，等 DOH 开启时由 ensureKeychainTrust() 处理
      return true;
    }
    debugPrint('ProxyCertificate: per-device CA not ready');
    return false;
  }

  /// Configure the global security context to trust the proxy CA
  static Future<bool> _configureSecurityContext() async {
    try {
      final certData = await rootBundle.load('assets/certs/proxy_ca.pem');
      final certBytes = certData.buffer.asUint8List();
      final context = SecurityContext.defaultContext;
      context.setTrustedCertificatesBytes(certBytes);
      debugPrint('ProxyCertificate: CA certificate loaded successfully');
      return true;
    } catch (e) {
      debugPrint('ProxyCertificate: Could not load CA certificate: $e');
      return false;
    }
  }

  static const _proxyCertChannel = MethodChannel('com.fluxdo/proxy_cert');

  /// 将 CA 证书发送到原生层，返回是否信任成功
  static Future<bool> _sendCaCertToNative(String pem) async {
    try {
      final result = await _proxyCertChannel.invokeMethod<bool>(
        'setCaCertPem',
        pem,
      );
      debugPrint('ProxyCertificate: CA cert sent to native, trusted=$result');
      return result ?? false;
    } catch (e) {
      debugPrint('ProxyCertificate: Failed to send CA cert to native: $e');
      return false;
    }
  }

  /// Get the CA certificate PEM content for display or export
  static Future<String?> getCertificatePem() async {
    final usePerDevice = await CertPreferenceService.usePerDevice();
    if (usePerDevice) {
      final certService = PerDeviceCertService.instance;
      if (certService.isLoaded) return certService.certPem;
      await certService.ensureCaCert();
      return certService.certPem;
    }
    try {
      return await rootBundle.loadString('assets/certs/proxy_ca.pem');
    } catch (e) {
      return null;
    }
  }
}
