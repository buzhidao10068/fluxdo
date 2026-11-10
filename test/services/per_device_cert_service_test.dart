import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/per_device_cert_service.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

XmlElement _value(XmlElement dict, String key) {
  final elements = dict.childElements.toList();
  final index = elements.indexWhere(
    (element) => element.name.local == 'key' && element.innerText == key,
  );
  expect(index, greaterThanOrEqualTo(0), reason: '缺少 plist 字段 $key');
  return elements[index + 1];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/profile_install');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = PerDeviceCertService.instance;
  late PathProviderPlatform originalPaths;
  late Directory sandbox;
  final profiles = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('fluxdo-cert-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(sandbox);
    await service.reset();
    final certs = await Directory('${sandbox.path}/certs').create();
    await File('${certs.path}/ca.crt').writeAsString(
      '-----BEGIN CERTIFICATE-----\nAQID\nBAUG\n-----END CERTIFICATE-----\n',
    );
    await File('${certs.path}/ca.key').writeAsString('test device private key');
    profiles.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installProfile');
      profiles.add(call.arguments as String);
      return true;
    });
  });

  tearDown(() async {
    await service.reset();
    messenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = originalPaths;
    // 仅清理由 createTemp 创建的本测试目录。
    await sandbox.delete(recursive: true);
  });

  test('原生安装收到独立且稳定的 profile 身份和当前设备的 CA', () async {
    expect(await service.installProfile(), isTrue);
    expect(await service.installProfile(), isTrue);
    expect(profiles, hasLength(2));
    expect(profiles[1], profiles[0], reason: '同一设备重新安装应替换自己的描述文件');

    final plist = XmlDocument.parse(profiles.first);
    final outer = plist.rootElement.getElement('dict')!;
    final inner = _value(outer, 'PayloadContent').getElement('dict')!;
    expect(
      _value(outer, 'PayloadIdentifier').innerText,
      'com.buzhidao10068.fluxdo.doh-proxy-ca',
    );
    expect(
      _value(inner, 'PayloadIdentifier').innerText,
      'com.buzhidao10068.fluxdo.doh-proxy-ca.cert',
    );
    expect(_value(outer, 'PayloadType').innerText, 'Configuration');
    expect(_value(inner, 'PayloadType').innerText, 'com.apple.security.root');
    final uuids = [
      _value(outer, 'PayloadUUID').innerText,
      _value(inner, 'PayloadUUID').innerText,
    ];
    expect(uuids.toSet(), hasLength(2));
    for (final uuid in uuids) {
      expect(
        uuid,
        matches(
          RegExp(
            r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$',
          ),
        ),
      );
    }
    expect(profiles.first, isNot(contains('com.fluxdo.doh-proxy-ca')));
    for (final dict in [outer, inner]) {
      expect(_value(dict, 'PayloadDisplayName').innerText, contains('NodeLoc'));
    }
    expect(base64Decode(_value(inner, 'PayloadContent').innerText), [
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(
      await service.isCertInstalled(),
      isFalse,
      reason: '原生下载成功不等于用户已完成系统安装和信任',
    );
  });

  test('旧 profile 完成标记不能跳过 fork 新描述文件的安装确认', () async {
    SharedPreferences.setMockInitialValues({'per_device_cert_installed': true});
    expect(await service.isCertInstalled(), isFalse);
    await service.markCertInstalled();
    expect(await service.isCertInstalled(), isTrue);
    await service.clearCertInstalled();
    expect(await service.isCertInstalled(), isFalse);
  });

  test('重置 CA 同时清除确认状态，保留其他文件', () async {
    final unrelated = File('${sandbox.path}/unrelated.txt');
    await unrelated.writeAsString('keep');
    expect(await service.ensureCaCert(), isTrue);
    await service.markCertInstalled();
    await service.reset();
    expect(await service.isCertInstalled(), isFalse);
    expect(service.isLoaded, isFalse);
    expect(service.certPem, isNull);
    expect(service.keyPem, isNull);
    expect(File('${sandbox.path}/certs/ca.crt').existsSync(), isFalse);
    expect(File('${sandbox.path}/certs/ca.key').existsSync(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
  });

  test('原生安装失败不记为用户已安装', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'open_failed');
    });
    expect(await service.installProfile(), isFalse);
    expect(await service.isCertInstalled(), isFalse);
  });

  const fingerprintKey = 'per_device_cert_installed_nodeloc_sha256_v2';
  const secondCa =
      '-----BEGIN CERTIFICATE-----\nBwgJ\n-----END CERTIFICATE-----\n';

  PerDeviceCertService freshService({Future<DeviceCa?> Function()? generate}) =>
      PerDeviceCertService.forTesting(
        certsDirectory: () async => Directory('${sandbox.path}/certs'),
        generateCa:
            generate ?? () async => (certPem: secondCa, keyPem: 'new key'),
      );

  test('4.3 布尔确认不迁移为当前 CA 已安装', () async {
    SharedPreferences.setMockInitialValues({
      'per_device_cert_installed_nodeloc_v1': true,
    });
    expect(await freshService().isCertInstalled(), isFalse);
  });

  test('确认随当前 CA 指纹持久化，PEM 换行不影响确认', () async {
    await freshService().markCertInstalled();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(fingerprintKey), matches(RegExp(r'^[0-9a-f]{64}$')));
    final cert = File('${sandbox.path}/certs/ca.crt');
    await cert.writeAsString(
      (await cert.readAsString()).replaceAll('\n', '\r\n'),
    );
    expect(await freshService().isCertInstalled(), isTrue);
  });

  test('重启后读取到另一张 CA 时旧确认失效', () async {
    await freshService().markCertInstalled();
    await File('${sandbox.path}/certs/ca.crt').writeAsString(secondCa);
    expect(await freshService().isCertInstalled(), isFalse);
  });

  for (final missing in ['ca.crt', 'ca.key']) {
    test('$missing 缺失后自动生成新 CA，并在生成前清除旧确认', () async {
      await freshService().markCertInstalled();
      await File('${sandbox.path}/certs/$missing').delete();
      final regenerated = freshService(
        generate: () async {
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.containsKey(fingerprintKey), isFalse);
          return (certPem: secondCa, keyPem: 'new key');
        },
      );
      expect(await regenerated.ensureCaCert(), isTrue);
      expect(regenerated.certPem, secondCa);
      expect(await regenerated.isCertInstalled(), isFalse);
      await regenerated.markCertInstalled();
      expect(await freshService().isCertInstalled(), isTrue);
    });
  }

  test('自动生成失败仍清除旧确认，后续可重试', () async {
    await freshService().markCertInstalled();
    await File('${sandbox.path}/certs/ca.key').delete();
    var attempts = 0;
    final regenerated = freshService(
      generate: () async {
        attempts++;
        return attempts == 1 ? null : (certPem: secondCa, keyPem: 'new key');
      },
    );
    expect(await regenerated.ensureCaCert(), isFalse);
    expect(await regenerated.isCertInstalled(), isFalse);
    expect(regenerated.isLoaded, isFalse);
    expect(await regenerated.ensureCaCert(), isTrue);
    expect(attempts, 2);
    expect(await regenerated.isCertInstalled(), isFalse);
  });

  test('并发加载只生成一次，确认与重置依次执行', () async {
    await service.reset();
    var generations = 0;
    final generated = Completer<DeviceCa?>();
    final local = freshService(
      generate: () {
        generations++;
        return generated.future;
      },
    );
    final loads = List.generate(3, (_) => local.ensureCaCert());
    generated.complete((certPem: secondCa, keyPem: 'new key'));
    expect(await Future.wait(loads), everyElement(isTrue));
    expect(generations, 1);
    await Future.wait([local.markCertInstalled(), local.reset()]);
    expect(await local.isCertInstalled(), isFalse);
    expect(local.isLoaded, isFalse);
  });

  test('重置遇到文件系统错误必须传播失败，且确认已失效', () async {
    await freshService().markCertInstalled();
    final broken = PerDeviceCertService.forTesting(
      certsDirectory: () async => throw const FileSystemException('不可访问'),
      generateCa: () async => null,
    );
    await expectLater(broken.reset(), throwsA(isA<FileSystemException>()));
    expect(await broken.isCertInstalled(), isFalse);
  });
}
