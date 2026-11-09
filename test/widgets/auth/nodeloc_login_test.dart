import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/login_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/credential_store_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';
import 'package:fluxdo/services/network/system_proxy_service.dart';
import 'package:fluxdo/widgets/auth/login_form.dart';
import 'package:fluxdo/widgets/auth/two_factor_dialog.dart';
import 'package:fluxdo/widgets/auth/webview_login_dialog.dart';
import 'package:fluxdo/pages/webview_login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final jar = CookieJarService();
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext host;
  late SharedPreferences preferences;
  WebViewLoginDialogResult? result;

  Widget app(Widget home) => ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: home,
      ),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    Future<TwoFactorResult?> Function(WebViewLoginNeed2FA)? secondFactor,
  }) async {
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    unawaited(
      showWebViewLoginDialog(
        host,
        siteKey: AppConstants.siteCustomization.login.hcaptchaSiteKey,
        identifier: 'alice',
        password: 'test-value',
        onNeedSecondFactor: secondFactor ?? (_) async => null,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(platform.webView, isNotNull);
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
  }

  Future<void> send(Map<String, dynamic> payload) async {
    await platform.controller.handlers['login_result']!([jsonEncode(payload)]);
  }

  Future<void> drain(WidgetTester tester) async {
    // 显式推进 Cookie store 重试和路由退出动画，避免无限加载动画阻塞 settle。
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Map<String, dynamic> session(String body) => {
    'phase': 'session',
    'status': 200,
    'body': body,
  };
  Cookie cookie(String name, String value) => Cookie(
    name: name,
    value: value,
    domain: '.nodeloc.com',
    path: '/',
    isSecure: true,
    isHttpOnly: true,
    expiresDate: DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
  );

  setUpAll(platform.initialize);
  setUp(() async {
    await platform.reset();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    FlutterSecureStorage.setMockInitialValues({});
    // 在 widget 的 FakeAsync 区域之外完成共享存储初始化，避免缓存 Future
    // 绑定到前一个用例已停止推进的时钟。
    await CredentialStoreService().load();
    WebViewCookiePriming.instance.invalidate();
    CfChallengeService().resetCooldown();
    result = null;
  });
  tearDown(() async {
    CfChallengeService().resetCooldown();
    SystemProxyService.instance.resetForTest();
    await platform.reset();
  });

  for (final status in [200, 403, 429, 500]) {
    testWidgets('普通 CSRF HTTP $status 不弹 Cloudflare 验证', (tester) async {
      await open(tester);
      final original = platform.webView;
      await send({
        'phase': 'csrf',
        'status': status,
        'body': status == 200 ? '<html>NodeLoc</html>' : '{"error":"拒绝"}',
        'contentType': status == 200 ? 'text/html' : 'application/json',
      });
      await drain(tester);
      expect(result?.status, WebViewLoginStatus.failure);
      expect(identical(platform.webView, original), isTrue);
      expect(await jar.getCfClearance(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('真实 CSRF challenge 才打开兜底验证页，取消后失败', (tester) async {
    await open(tester);
    final original = platform.webView;
    final pending = send({
      'phase': 'csrf',
      'status': 403,
      'body': '<html>challenge</html>',
      'contentType': 'text/html',
      'cfMitigated': 'challenge',
    });
    for (var i = 0; i < 10 && identical(platform.webView, original); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(identical(platform.webView, original), isFalse);
    expect(result, isNull);
    await tester.tap(find.byTooltip(host.l10n.common_exit));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, host.l10n.common_exit));
    await drain(tester);
    await pending;
    expect(result?.status, WebViewLoginStatus.failure);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只有匿名 Cookie 或旧 jar 令牌，不能把成功响应当已登录', (tester) async {
    await jar.cookieJar.saveFromResponse(Uri.parse(AppConstants.baseUrl), [
      io.Cookie('_t', 'old-native-token')..path = '/',
    ]);
    await open(tester);
    platform.cookies.values = [cookie('_forum_session', 'anonymous')];
    final pending = send(session('{"user":{"id":1,"username":"alice"}}'));
    await drain(tester);
    await pending;
    expect(result?.status, WebViewLoginStatus.failure);
    expect(await jar.getTToken(), 'old-native-token');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('本次 WebView 的 HttpOnly _t 同步后才能成功，允许短暂存储延迟', (tester) async {
    await open(tester);
    final pending = send(session('{"user":{"id":1,"username":"alice"}}'));
    await tester.pump(const Duration(milliseconds: 200));
    platform.cookies.values = [
      cookie('_t', 'new-session'),
      cookie('_forum_session', 'authenticated'),
    ];
    await drain(tester);
    await pending;
    expect(result?.status, WebViewLoginStatus.success);
    expect(await jar.getTToken(), 'new-session');
    expect(await jar.getCfClearance(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cookie 读取期间换会话，旧登录不会写入 jar', (tester) async {
    await open(tester);
    final pending = send(session('{"user":{"id":1,"username":"alice"}}'));
    await tester.pump(const Duration(milliseconds: 200));
    AuthSession().advance();
    platform.cookies.values = [cookie('_t', 'stale-session')];
    await drain(tester);
    await pending;
    expect(result?.status, WebViewLoginStatus.canceled);
    expect(await jar.getTToken(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('2FA 在同一控制器重试，等待输入时忽略重复验证码回调', (tester) async {
    final code = Completer<TwoFactorResult?>();
    var prompts = 0;
    await open(
      tester,
      secondFactor: (_) {
        prompts++;
        return code.future;
      },
    );
    await platform.controller.handlers['hcaptcha_pass']!(['captcha-first']);
    final pending = send(
      session('{"reason":"invalid_second_factor_method","totp_enabled":true}'),
    );
    await tester.pump();
    await platform.controller.handlers['hcaptcha_pass']!(['captcha-duplicate']);
    expect(prompts, 1);
    expect(
      platform.controller.scripts.where(
        (s) => s.startsWith('window.__fluxdoLogin('),
      ),
      hasLength(1),
    );
    code.complete(const TwoFactorResult.code('123456'));
    await pending;
    final calls = platform.controller.scripts
        .where((s) => s.startsWith('window.__fluxdoLogin('))
        .toList();
    expect(calls, hasLength(2));
    expect(calls.last, contains('null, "123456"'));
    platform.cookies.values = [cookie('_t', 'second-factor-session')];
    await send(session('{"user":{"id":1,"username":"alice"}}'));
    await drain(tester);
    expect(result?.status, WebViewLoginStatus.success);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无 cf_clearance 直接进入本站 hCaptcha，不先弹过盾页', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(const LoginPage()));
      await CredentialStoreService().load();
    });
    for (var i = 0; i < 20 && find.byType(LoginForm).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final form = tester.widget<LoginForm>(find.byType(LoginForm));
    final pending = form.onSubmit(
      identifier: 'alice',
      password: 'test-value',
      rememberCredentials: false,
    );
    for (var i = 0; i < 10 && platform.webView == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(platform.webView, isNotNull);
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    // Windows 由同源 bootstrap 后注入 HTML，移动平台直接使用 initialData。
    String html;
    if (io.Platform.isWindows) {
      platform.controller.evaluateScript = (source) async {
        if (source.contains('window.location.origin')) {
          return {'origin': AppConstants.baseUrl};
        }
        return '';
      };
      platform.webView!.params.onLoadStop!(
        platform.controller.wrapped,
        WebUri('${AppConstants.baseUrl}/robots.txt'),
      );
      await tester.pump();
      html = platform.controller.scripts.last;
    } else {
      html = platform.webView!.params.initialData!.data;
    }
    expect(html, contains('d2a8ddf6-4c2a-4054-ac7c-2e288c2477aa'));
    expect(await jar.getCfClearance(), isNull);
    await tester.tap(find.byTooltip('取消'));
    await drain(tester);
    expect(await pending, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final duringSync in [false, true]) {
    for (final closeButton in [false, true]) {
      testWidgets(
        '${closeButton ? '标题关闭' : '系统返回'}在${duringSync ? '最终同步' : '首次读取'}期间取消，不写回 Cookie',
        (tester) async {
          await open(tester);
          final generation = AuthSession().generation;
          final snapshot = Completer<List<Cookie>>();
          var reads = 0;
          platform.cookies.readSnapshot = () {
            reads++;
            if (duringSync && reads == 1) {
              return Future.value([cookie('_t', 'canceled-login-session')]);
            }
            return snapshot.future;
          };
          final pending = send(session('{"user":{"id":1,"username":"alice"}}'));
          await tester.pump();
          expect(reads, duringSync ? 2 : 1);
          if (closeButton) {
            await tester.tap(find.byTooltip('取消'));
          } else {
            await tester.binding.handlePopRoute();
          }
          // 在退出动画尚未 dispose 时释放读取，验证 pop 当时就已失效。
          snapshot.complete([cookie('_t', 'canceled-login-session')]);
          await tester.pump();
          await pending;
          await drain(tester);
          expect(
            result?.status,
            closeButton ? WebViewLoginStatus.canceled : isNull,
          );
          expect(AuthSession().generation, generation);
          expect(await jar.getTToken(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('mini 销毁后，已发出的读取返回也不写入 Cookie', (tester) async {
    await open(tester);
    final snapshot = Completer<List<Cookie>>();
    platform.cookies.readSnapshot = () => snapshot.future;
    final pending = send(session('{"user":{"id":1,"username":"alice"}}'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    snapshot.complete([cookie('_t', 'disposed-session')]);
    await tester.pump();
    await pending;
    expect(await jar.getTToken(), isNull);
  });

  testWidgets('真实备用码按钮先结束 mini，再由登录页打开 bool 网页路由', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app(const LoginPage()));
      await CredentialStoreService().load();
    });
    for (var i = 0; i < 20 && find.byType(LoginForm).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final pending = tester
        .widget<LoginForm>(find.byType(LoginForm))
        .onSubmit(
          identifier: 'alice',
          password: 'test-value',
          rememberCredentials: false,
        );
    for (var i = 0; i < 10 && platform.webView == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
    final secondFactor = send(
      session('{"reason":"invalid_second_factor_method","totp_enabled":true}'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('改用备用码 / 安全密钥'));
    await tester.pump();
    await secondFactor;
    await drain(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(WebViewLoginPage), findsOneWidget);
    expect(find.text('改用备用码 / 安全密钥'), findsNothing);
    expect(find.text('完成人机验证'), findsNothing);
    // 返回网页后仍留在登录表单，不会遗留 mini 或误弹出登录页。
    navigator.currentState!.pop<bool>(false);
    await drain(tester);
    expect(await pending, isFalse);
    expect(find.byType(LoginForm), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
