import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/device_ca_rotation.dart';
import 'package:fluxdo/services/network/doh_proxy/per_device_cert_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pem = '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----';
  late Directory directory;
  late PerDeviceCertService certificates;
  late List<String> events;
  var trustWorks = true;
  var resumeWorks = true;
  var pauseWorks = true;
  var generationWorks = true;
  var generations = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fluxdo-rotation-');
    events = [];
    trustWorks = resumeWorks = pauseWorks = generationWorks = true;
    generations = 0;
    certificates = PerDeviceCertService.forTesting(
      certsDirectory: () async => directory,
      generateCa: () async {
        events.add('generate');
        generations++;
        return generationWorks ? (certPem: pem, keyPem: 'test key') : null;
      },
    );
  });

  tearDown(() async => directory.delete(recursive: true));

  DeviceCaRotation rotation() => DeviceCaRotation(
    certificates: certificates,
    pauseProxy: () async {
      events.add('pause');
      if (!pauseWorks) throw StateError('旧代理未停止');
    },
    refreshTrust: () async {
      events.add('trust');
      expect(certificates.certPem, pem);
      expect(await File('${directory.path}/ca.crt').readAsString(), pem);
      return trustWorks;
    },
    resumeProxy: () async {
      events.add('resume');
      if (!resumeWorks) throw StateError('启动失败');
    },
  );

  test('按停止、持久化、更新信任、启动顺序轮转，准备成功不等于已安装', () async {
    await rotation().prepare(regenerate: true);
    expect(events, ['pause', 'generate', 'trust', 'resume']);
    expect(await certificates.isCertInstalled(), isFalse);
  });

  test('旧代理停止失败时不重置 CA 和安装确认', () async {
    await certificates.ensureCaCert();
    await certificates.markCertInstalled();
    events.clear();
    pauseWorks = false;
    await expectLater(rotation().prepare(regenerate: true), throwsStateError);
    expect(events, ['pause']);
    expect(await certificates.isCertInstalled(), isTrue);
    expect(generations, 1);
  });

  test('生成失败不更新信任或恢复代理', () async {
    generationWorks = false;
    await expectLater(rotation().prepare(regenerate: true), throwsStateError);
    expect(events, ['pause', 'generate', 'pause']);
    expect(await certificates.isCertInstalled(), isFalse);
  });

  test('信任失败保持暂停，重试继续使用同一张 CA', () async {
    trustWorks = false;
    await expectLater(rotation().prepare(regenerate: true), throwsStateError);
    expect(events, ['pause', 'generate', 'trust', 'pause']);
    events.clear();
    trustWorks = true;
    await rotation().prepare();
    expect(events, ['pause', 'trust', 'resume']);
    expect(generations, 1);
    expect(await certificates.isCertInstalled(), isFalse);
  });

  test('恢复启动失败后再次停止代理，失败不保留旧确认', () async {
    await certificates.ensureCaCert();
    await certificates.markCertInstalled();
    events.clear();
    resumeWorks = false;
    await expectLater(rotation().prepare(regenerate: true), throwsStateError);
    expect(events, ['pause', 'generate', 'trust', 'resume', 'pause']);
    expect(await certificates.isCertInstalled(), isFalse);
  });
}
