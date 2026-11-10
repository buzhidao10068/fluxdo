import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 平台深链 scheme 注册的静态断言。
///
/// 背景：User API Key 授权登录依赖 Discourse 的 `discourse://auth_redirect`
/// 回调。应用侧（Android Manifest / iOS-macOS Info.plist / Linux desktop /
/// Flatpak desktop）都注册了 `discourse://`，但 **Windows 侧曾只注册
/// `fluxdo://`** —— App 的 `windows/runner/main.cpp` 会解析命令行里的
/// `discourse://`，系统却从不把它路由过来，授权登录因此断在最后一步。
///
/// 本文件校验跨平台注册配置；实际 handler 选择和卸载行为须在原生环境验证。
void main() {
  // Windows 侧两个注册入口：便携/手动用的 .reg 文件 + 安装器 setup.iss。
  const regFile = 'windows/fluxdo_url_scheme.reg';
  const issFile = 'windows/setup.iss';

  // 各平台必须注册的 scheme 全集。
  const requiredSchemes = <String>['fluxdo', 'discourse'];

  group('Windows URL scheme 注册', () {
    test('$regFile 存在且为每个必需 scheme 注册了协议键', () {
      final file = File(regFile);
      expect(file.existsSync(), isTrue, reason: '$regFile 不存在');

      final content = file.readAsStringSync();

      for (final scheme in requiredSchemes) {
        final key = 'HKEY_CURRENT_USER\\Software\\Classes\\$scheme';
        expect(
          content,
          contains(key),
          reason: '$regFile 缺少 $scheme 的注册表键（$key）',
        );
        // .reg 里的子键路径不带引号，形如
        // [HKEY_CURRENT_USER\Software\Classes\fluxdo\shell\open\command]
        expect(
          content,
          contains('Classes\\$scheme\\shell\\open\\command]'),
          reason: '$regFile 缺少 $scheme 的 open\\command 子键',
        );
      }

      // 每个协议键都必须带 "URL Protocol"，否则系统不会把它当协议处理。
      final protocolKeyCount = RegExp(r'"URL Protocol"\s*=\s*""')
          .allMatches(content)
          .length;
      expect(
        protocolKeyCount,
        greaterThanOrEqualTo(requiredSchemes.length),
        reason: '"URL Protocol" 标记数量少于必需 scheme 数',
      );
    });

    test('$issFile 的 [Registry] 段为每个必需 scheme 注册了协议键', () {
      final file = File(issFile);
      expect(file.existsSync(), isTrue, reason: '$issFile 不存在');

      final content = file.readAsStringSync();

      // 安装器必须真的写注册表，否则 scheme 只能靠用户手动导入 .reg。
      expect(
        content,
        contains('[Registry]'),
        reason: '$issFile 缺少 [Registry] 段，安装后不会自动注册 URL scheme',
      );

      for (final scheme in requiredSchemes) {
        expect(
          content,
          contains('Software\\Classes\\$scheme'),
          reason: '$issFile 缺少 $scheme 的注册表写入项',
        );
      }

      // HKA 在默认免管理员模式写 HKCU，选择管理员安装时写 HKLM。
      expect(
        content,
        contains('Root: HKA; Subkey: "Software\\Classes\\'),
        reason: '$issFile 的 [Registry] 段应随安装模式选择注册表范围',
      );
      expect(
        content,
        isNot(contains('Root: HKLM')),
        reason: '$issFile 不应写 HKLM，免管理员安装模式下会失败',
      );
    });

    test('两个注册入口覆盖的 scheme 集合一致', () {
      final regContent = File(regFile).readAsStringSync();
      final issContent = File(issFile).readAsStringSync();

      final regSchemes = RegExp(
        r'HKEY_CURRENT_USER\\Software\\Classes\\([A-Za-z0-9_]+)',
      ).allMatches(regContent).map((m) => m.group(1)).toSet();
      final issSchemes = RegExp(r'Subkey: "Software\\Classes\\([A-Za-z0-9_]+)')
          .allMatches(issContent)
          .map((m) => m.group(1))
          .toSet();

      expect(regSchemes, issSchemes, reason: '.reg 与 setup.iss 注册的 scheme 不一致');
      expect(regSchemes, containsAll(requiredSchemes));
    });

    test('共用 scheme 只允许按当前安装路径核对归属后清理', () {
      final content = File(issFile).readAsStringSync();
      final registry = content.split('[Registry]').last.split('[Run]').first;
      expect(
        registry,
        isNot(contains('uninsdelete')),
        reason: '共用协议不能交给卸载日志无条件删除',
      );
      final cleanup = content
          .split('procedure RemoveOwnedProtocol')
          .last
          .split('procedure CurUninstallStepChanged')
          .first;
      expect(
        cleanup,
        contains(r'''ExpandConstant('"{app}\{#MyAppExeName}" "%1"')'''),
      );
      expect(cleanup, contains('RegQueryStringValue'));
      final guard = cleanup.indexOf(
        'CompareText(Trim(Command), ExpectedCommand) = 0',
      );
      final deletion = cleanup.indexOf('RegDeleteKeyIncludingSubkeys');
      expect(guard, greaterThanOrEqualTo(0));
      expect(deletion, greaterThan(guard));
      for (final scheme in requiredSchemes) {
        expect(content, contains("RemoveOwnedProtocol(HKCU, '$scheme')"));
        expect(content, contains("RemoveOwnedProtocol(HKLM, '$scheme')"));
      }
      expect(content, contains('if IsAdminInstallMode then'));
      expect(
        content,
        contains('UninstallLogMode=overwrite'),
        reason: '覆盖安装不能保留旧日志中的无条件删键动作',
      );
      expect(content, contains('if CurUninstallStep = usUninstall then'));
    });
  });

  group('各平台 scheme 注册一致性', () {
    test('Android Manifest 注册 fluxdo 与 discourse', () {
      final content = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      for (final scheme in requiredSchemes) {
        expect(
          content,
          contains('android:scheme="$scheme"'),
          reason: 'AndroidManifest.xml 缺少 $scheme scheme',
        );
      }
    });

    test('iOS / macOS Info.plist 注册 fluxdo 与 discourse', () {
      for (final plist in [
        'ios/Runner/Info.plist',
        'macos/Runner/Info.plist',
      ]) {
        final content = File(plist).readAsStringSync();
        for (final scheme in requiredSchemes) {
          expect(
            content,
            contains('<string>$scheme</string>'),
            reason: '$plist 缺少 $scheme scheme',
          );
        }
      }
    });

    test('Linux / Flatpak desktop 文件注册 fluxdo 与 discourse', () {
      for (final desktop in [
        'linux/runner/com.buzhidao10068.fluxdo.desktop',
        'flatpak/com.buzhidao10068.fluxdo.desktop',
      ]) {
        final content = File(desktop).readAsStringSync();
        for (final scheme in requiredSchemes) {
          expect(
            content,
            contains('x-scheme-handler/$scheme'),
            reason: '$desktop 缺少 x-scheme-handler/$scheme',
          );
        }
      }
    });
  });
}
