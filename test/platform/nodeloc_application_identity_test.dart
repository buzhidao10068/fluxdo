import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  const appId = 'com.buzhidao10068.fluxdo';
  const oldId = 'com.github.lingyan000.fluxdo';

  test('应用标识、包目录及分发模板使用 fork 身份', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('namespace = "$appId"'));
    expect(gradle, contains('applicationId = "$appId"'));
    final kotlin = Directory('android/app/src/main/kotlin');
    final sources = kotlin
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.kt'));
    expect(sources, isNotEmpty);
    for (final source in sources) {
      expect(
        source.path.replaceAll('\\', '/'),
        contains('/com/buzhidao10068/fluxdo/'),
      );
      expect(source.readAsStringSync(), startsWith('package $appId'));
    }

    for (final path in [
      'ios/Runner.xcodeproj/project.pbxproj',
      'macos/Runner.xcodeproj/project.pbxproj',
      'macos/Runner/Configs/AppInfo.xcconfig',
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
      'linux/CMakeLists.txt',
      'flatpak/$appId.yml',
      'flatpak/$appId.metainfo.xml',
    ]) {
      final content = File(path).readAsStringSync();
      expect(content, contains(appId), reason: path);
      expect(content, isNot(contains(oldId)), reason: path);
    }
    final source =
        jsonDecode(File('altstore/source.json').readAsStringSync()) as Map;
    expect(source['identifier'], '$appId.AltStore');
    expect((source['apps'] as List).single['bundleIdentifier'], appId);
  });

  test('原生通道与 Dart 调用端同步迁移', () {
    final android = File(
      'android/app/src/main/kotlin/com/buzhidao10068/fluxdo/MainActivity.kt',
    ).readAsStringSync();
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    const callers = {
      'browser': [
        'lib/utils/link_launcher.dart',
        'lib/services/app_link_service.dart',
        'lib/widgets/auth/qr_login_sheet.dart',
        'lib/pages/network_settings_page/widgets/ios_cert_install_dialog.dart',
      ],
      'app_icon': ['lib/providers/app_icon_provider.dart'],
      'crashlytics': [
        'lib/main.dart',
        'lib/providers/preferences_provider.dart',
        'lib/services/crash_context_reporter.dart',
      ],
      'render_backend': ['lib/services/render_backend_service.dart'],
    };
    for (final entry in callers.entries) {
      final channel = '$appId/${entry.key}';
      expect(android, contains('"$channel"'));
      if (entry.key == 'browser' || entry.key == 'app_icon') {
        expect(ios, contains('"$channel"'));
      }
      for (final path in entry.value) {
        final content = File(path).readAsStringSync();
        expect(content, contains("'$channel'"), reason: path);
        expect(content, isNot(contains(oldId)), reason: path);
      }
    }
  });

  test('Windows 安装、存储和窗口实例均使用独立身份', () {
    final setup = File('windows/setup.iss').readAsStringSync();
    expect(setup, contains('AppId={{F9CB3564-FA04-4AF3-88E7-35D2B77A09B2}'));
    expect(setup, contains('#define MyAppExeName "fluxdo-nodeloc.exe"'));
    expect(setup, contains('#define MyAppInstallName "FluxDO NodeLoc"'));
    expect(setup, contains(r'DefaultDirName={autopf}\{#MyAppInstallName}'));
    expect(setup, contains('DefaultGroupName={#MyAppInstallName}'));
    expect(setup, contains('/f /im {#MyAppExeName}'));
    expect(setup, isNot(contains('/im fluxdo.exe')));
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('set(BINARY_NAME "fluxdo-nodeloc")'));
    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    expect(rc, contains('"CompanyName", "com.buzhidao10068"'));
    expect(rc, contains('"ProductName", "FluxDO"'));
    expect(rc, contains('"OriginalFilename", "fluxdo-nodeloc.exe"'));
    final identity = File('windows/runner/app_identity.h').readAsStringSync();
    expect(identity, contains('L"$appId.RunnerWindow"'));
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final window = File('windows/runner/win32_window.cpp').readAsStringSync();
    for (final content in [main, window]) {
      expect(content, contains('#include "app_identity.h"'));
      expect(content, isNot(contains('FLUTTER_RUNNER_WIN32_WINDOW')));
    }
    expect(main, contains('FindWindow(kWindowClassName, L"FluxDO")'));
    expect(window, contains('window_class.lpszClassName = kWindowClassName'));
    final reg = File('windows/fluxdo_url_scheme.reg').readAsStringSync();
    expect(RegExp('fluxdo-nodeloc.exe').allMatches(reg).length, 2);
    final notifications = File('lib/services/local_notification_service.dart')
        .readAsStringSync();
    expect(notifications, contains("appName: 'FluxDO NodeLoc'"));
    expect(notifications, contains("appUserModelId: '$appId'"));
    expect(
      notifications,
      contains("guid: '6e6bd52e-3237-4e62-90d6-39e06a9a58b7'"),
    );
    expect(notifications, isNot(contains('Com.FluxDO.FluxDO')));
    expect(
      notifications,
      isNot(contains('e965ef8c-b676-47c1-b6e7-297d63942974')),
    );
  });

  test('Linux 在插件启动前创建专属目录，避免 path_provider 旧路径回退', () {
    final runner = File('linux/runner/my_application.cc').readAsStringSync();
    final bootstrap = runner.substring(
      runner.indexOf('MyApplication* my_application_new()'),
    );
    expect(bootstrap, contains('g_get_user_data_dir()'));
    expect(bootstrap, contains('g_get_user_cache_dir()'));
    expect(
      bootstrap,
      contains('g_build_filename(base, APPLICATION_ID, nullptr)'),
    );
    expect(
      bootstrap.indexOf('g_mkdir_with_parents'),
      lessThan(bootstrap.indexOf('g_object_new')),
    );
  });

  test('macOS 产品、测试宿主和分发路径指向同一个独立 app', () {
    const product = 'fluxdo-nodeloc';
    final config = File('macos/Runner/Configs/AppInfo.xcconfig')
        .readAsStringSync();
    expect(config, contains('PRODUCT_NAME = $product'));
    final project = File('macos/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    expect(project, contains('path = "$product.app";'));
    final hosts = RegExp(r'TEST_HOST = "([^"]+)";')
        .allMatches(project)
        .map((match) => match.group(1));
    expect(hosts, hasLength(3));
    for (final host in hosts) {
      expect(
        host,
        '\$(BUILT_PRODUCTS_DIR)/$product.app/\$(BUNDLE_EXECUTABLE_FOLDER_PATH)/$product',
      );
    }
    final scheme = XmlDocument.parse(
      File('macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme')
          .readAsStringSync(),
    );
    final apps = scheme
        .findAllElements('BuildableReference')
        .where((element) => element.getAttribute('BlueprintName') == 'Runner');
    expect(apps, hasLength(5));
    for (final app in apps) {
      expect(app.getAttribute('BuildableName'), '$product.app');
    }
    // Apple 源码保留身份检查；当前 Android CI 不再构建 macOS 产品。
    for (final content in [project, scheme.toXmlString()]) {
      expect(content, isNot(contains('/fluxdo.app')));
    }
  });

  test('macOS CA 重试不按共享标签删除钥匙串证书', () {
    final source = File('macos/Runner/DohProxyCertHandler.swift')
        .readAsStringSync();
    expect(source, contains('"FluxDO NodeLoc DOH Proxy CA"'));
    expect(source, contains('errSecDuplicateItem'));
    expect(source, contains('SecTrustSettingsSetTrustSettings(cert,'));
    expect(source, isNot(contains('SecItemDelete(')));
  });

  test('Linux 二进制、桌面身份与 Flatpak wrapper 构建链一致', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final binary = RegExp(r'set\(BINARY_NAME "([^"]+)"\)')
        .firstMatch(cmake)!
        .group(1)!;
    expect(binary, 'fluxdo-nodeloc');
    final desktop = File('linux/runner/$appId.desktop').readAsStringSync();
    expect(desktop, contains('Exec=$binary %u'));
    for (final path in [
      'linux/runner/$appId.desktop',
      'flatpak/$appId.desktop',
    ]) {
      final content = File(path).readAsStringSync();
      expect(content, contains('Name=FluxDO NodeLoc'));
      expect(content, contains('Icon=$appId'));
      expect(content, contains('StartupWMClass=$appId'));
    }
    expect(cmake, contains(r'runner/${APPLICATION_ID}.desktop'));
    expect(cmake, contains(r'flatpak/icons/${APPLICATION_ID}.png'));
    expect(File('flatpak/icons/$appId.png').existsSync(), isTrue);
    final runner = File('linux/runner/my_application.cc').readAsStringSync();
    expect(runner, contains('g_set_prgname(APPLICATION_ID)'));
    final wrapper = File('flatpak/fluxdo-wrapper.sh').readAsStringSync();
    expect(wrapper, contains('exec "/app/fluxdo/$binary" "\$@"'));
    final manifest = File('flatpak/$appId.yml').readAsStringSync();
    expect(manifest, contains('command: fluxdo'));
    expect(
      manifest,
      contains('source-tree/flatpak/fluxdo-wrapper.sh /app/bin/fluxdo'),
    );
    final flatpakDesktop = File('flatpak/$appId.desktop').readAsStringSync();
    expect(flatpakDesktop, contains('Exec=fluxdo %u'));
    expect(
      File('scripts/ci/flatpak/stage_bundle.sh').readAsStringSync(),
      contains('\${STAGE_ROOT}/bundle/$binary'),
    );
  });
}
