import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'doh_proxy_service.dart';
import 'proxy_ca_material.dart';

typedef DeviceCa = ({String certPem, String keyPem});

/// Per-device CA 证书管理服务
///
/// 每台设备生成唯一的 CA 证书，避免所有用户共享同一私钥。
/// 全平台可用：iOS 强制启用，其他平台通过 CertPreferenceService 可选启用。
/// installProfile() / _buildMobileConfig() 仅 iOS 调用。
class PerDeviceCertService {
  PerDeviceCertService._();
  static final PerDeviceCertService instance = PerDeviceCertService._();

  @visibleForTesting
  PerDeviceCertService.forTesting({
    required Future<Directory> Function() certsDirectory,
    required Future<DeviceCa?> Function() generateCa,
  }) : _directoryOverride = certsDirectory,
       _generateOverride = generateCa;

  Future<Directory> Function()? _directoryOverride;
  Future<DeviceCa?> Function()? _generateOverride;
  Future<void> _operations = Future.value();

  // 新描述文件必须重新由用户安装；不沿用旧共用 profile 的完成标记。
  // 保留此前缀，使 DataBackupService 继续排除此设备绑定状态。
  static const _certInstalledKey = 'per_device_cert_installed_nodeloc_v1';
  static const _installedFingerprintKey =
      'per_device_cert_installed_nodeloc_sha256_v2';

  String? _certPem;
  String? _keyPem;
  bool _loaded = false;

  /// 获取 CA 证书 PEM
  String? get certPem => _certPem;

  /// 获取 CA 私钥 PEM
  String? get keyPem => _keyPem;

  /// 证书是否已加载
  bool get isLoaded => _loaded && _certPem != null && _keyPem != null;

  /// 确保 CA 证书存在（有则读取，无则生成并存储）
  Future<bool> ensureCaCert() => _serialize(_ensureCaCert);

  Future<bool> _ensureCaCert() async {
    if (isLoaded) return true;

    final dir = await _certsDir();
    final certFile = File('${dir.path}/ca.crt');
    final keyFile = File('${dir.path}/ca.key');

    if (certFile.existsSync() && keyFile.existsSync()) {
      _certPem = await certFile.readAsString();
      _keyPem = await keyFile.readAsString();
      _loaded = true;
      debugPrint('[PerDeviceCert] 已加载本地 CA 证书');
      return true;
    }

    // 文件不完整时先作废确认，即使随后生成失败也不能沿用旧状态。
    await _clearCertInstalled();
    final result =
        await (_generateOverride?.call() ??
            DohProxyService.instance.generateCa());
    if (result == null) {
      debugPrint('[PerDeviceCert] CA 生成失败');
      return false;
    }

    await dir.create(recursive: true);
    await certFile.writeAsString(result.certPem);
    await keyFile.writeAsString(result.keyPem);

    _certPem = result.certPem;
    _keyPem = result.keyPem;
    _loaded = true;
    debugPrint('[PerDeviceCert] 新 CA 证书已生成并保存');
    return true;
  }

  static const _profileChannel = MethodChannel('com.fluxdo/profile_install');

  /// 通过原生层安装描述文件
  ///
  /// 原生层启动 HTTP server + 后台保活 + 打开 Safari 下载 .mobileconfig
  Future<bool> installProfile() async {
    if (!isLoaded) {
      final ok = await ensureCaCert();
      if (!ok) return false;
    }

    try {
      final mobileconfig = _buildMobileConfig(_certPem!);
      final success = await _profileChannel.invokeMethod<bool>(
        'installProfile',
        mobileconfig,
      );
      debugPrint('[PerDeviceCert] 原生安装结果: $success');
      return success ?? false;
    } catch (e) {
      debugPrint('[PerDeviceCert] 描述文件安装失败: $e');
      return false;
    }
  }

  /// 检查用户是否已标记证书为已安装
  Future<bool> isCertInstalled() => _serialize(() async {
    final prefs = await SharedPreferences.getInstance();
    final fingerprint = prefs.getString(_installedFingerprintKey);
    if (fingerprint == null || !await _ensureCaCert()) return false;
    return fingerprint == sha256.convert(proxyCaDer(_certPem!)).toString();
  });

  /// 标记证书为已安装
  Future<void> markCertInstalled() => _serialize(() async {
    if (!await _ensureCaCert()) throw StateError('CA 尚未就绪');
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _installedFingerprintKey,
      sha256.convert(proxyCaDer(_certPem!)).toString(),
    );
    if (!saved) throw StateError('无法保存证书安装确认');
  });

  /// 清除已安装标记（用于重新安装）
  Future<void> clearCertInstalled() => _serialize(_clearCertInstalled);

  Future<void> _clearCertInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_certInstalledKey, _installedFingerprintKey]) {
      if (!await prefs.remove(key)) throw StateError('无法清除证书安装确认');
    }
  }

  /// 重置内存状态并删除已有证书文件，下次 ensureCaCert 会重新生成
  Future<void> reset() => _serialize(() async {
    await _clearCertInstalled();
    _certPem = null;
    _keyPem = null;
    _loaded = false;
    final dir = await _certsDir();
    final certFile = File('${dir.path}/ca.crt');
    final keyFile = File('${dir.path}/ca.key');
    if (certFile.existsSync()) await certFile.delete();
    if (keyFile.existsSync()) await keyFile.delete();
  });

  Future<Directory> _certsDir() async {
    if (_directoryOverride != null) return _directoryOverride!();
    final appSupport = await getApplicationSupportDirectory();
    return Directory('${appSupport.path}/certs');
  }

  /// 加载、生成、重置和确认串行执行，避免并发生成覆盖正在安装的 CA。
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// 生成 .mobileconfig XML
  String _buildMobileConfig(String certPem) {
    // 从 PEM 中提取 base64 编码的证书数据
    final lines = certPem
        .split('\n')
        .where((line) => !line.startsWith('-----') && line.trim().isNotEmpty)
        .join('');

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>FluxDO_NodeLoc_DOH_Proxy_CA.cer</string>
            <key>PayloadContent</key>
            <data>$lines</data>
            <key>PayloadDescription</key>
            <string>FluxDO NodeLoc DOH Proxy CA Certificate</string>
            <key>PayloadDisplayName</key>
            <string>FluxDO NodeLoc DOH Proxy CA</string>
            <key>PayloadIdentifier</key>
            <string>com.buzhidao10068.fluxdo.doh-proxy-ca.cert</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>DB16E462-6C07-4C05-A0A6-151A8D405753</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>安装此证书以启用 FluxDO NodeLoc DOH Proxy 的 HTTPS 拦截功能</string>
    <key>PayloadDisplayName</key>
    <string>FluxDO NodeLoc DOH Proxy CA</string>
    <key>PayloadIdentifier</key>
    <string>com.buzhidao10068.fluxdo.doh-proxy-ca</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>2A51D8CE-AE54-4EF6-8ED0-E96A9C69507C</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>''';
  }
}
