import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 提取单张 CA 的 DER；指纹不受 PEM 换行方式影响。
Uint8List proxyCaDer(String pem) {
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (match == null) throw const FormatException('缺少 CA 证书');
  final der = base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  if (der.isEmpty) throw const FormatException('CA 证书为空');
  return der;
}

/// iOS 的 SecurityContext 要求单张 DER，其他平台接受 PEM。
Uint8List proxyCaTrustBytes(String pem) =>
    Platform.isIOS ? proxyCaDer(pem) : Uint8List.fromList(utf8.encode(pem));
