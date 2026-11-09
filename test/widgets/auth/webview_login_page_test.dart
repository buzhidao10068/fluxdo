import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/webview_login_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/credential_store_service.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    as notifications;
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/cookie/csrf_token_service.dart';
import 'package:fluxdo/services/network/cookie/webview_cookie_priming.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/cf_test_platform.dart';

class _LoginController extends CfTestController {
  _LoginController(super.cookies);

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {}
}

class _LoginPlatform extends CfTestPlatform {
  late final _loginController = _LoginController(cookies);

  @override
  _LoginController get controller => _loginController;
}

const _token = 'webview-test-session';
const _html = '''
<meta id="data-discourse-setup">
<script id="data-preloaded" type="application/json">
{"currentUser":{"id":1,"username":"alice"},"siteSettings":{},"site":{}}
</script>
''';

/// 让真实 HTTP refresh 等待受控响应，不访问外部网络。
class _HttpReply {
  final entered = Completer<void>();
  final body = Completer<String>();
}

class _HttpClient implements io.HttpClient {
  _HttpClient(this.reply);
  final _HttpReply Function() reply;

  @override
  Future<io.HttpClientRequest> openUrl(String method, Uri url) async =>
      _HttpRequest(reply());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HttpRequest implements io.HttpClientRequest {
  _HttpRequest(this.reply);
  final _HttpReply reply;

  @override
  final headers = _HttpHeaders();

  @override
  Future<io.HttpClientResponse> close() async {
    if (!reply.entered.isCompleted) reply.entered.complete();
    return _HttpResponse(await reply.body.future);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HttpHeaders implements io.HttpHeaders {
  @override
  void forEach(void Function(String, List<String>) action) {
    action(io.HttpHeaders.contentTypeHeader, ['text/html; charset=utf-8']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HttpResponse extends Stream<List<int>> implements io.HttpClientResponse {
  _HttpResponse(this.body);
  final String body;

  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => utf8.encode(body).length;
  @override
  bool get isRedirect => false;
  @override
  List<io.RedirectInfo> get redirects => const [];
  @override
  final headers = _HttpHeaders();
  @override
  io.HttpClientResponseCompressionState get compressionState =>
      io.HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _LoginPlatform();
  final jar = CookieJarService();
  final service = DiscourseService();
  final navigator = notifications.navigatorKey;
  late SharedPreferences preferences;
  late _HttpReply httpReply;
  int broadcasts = 0;
  bool? result;
  bool routeCompleted = false;

  Widget app() => ProviderScope(
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
        home: const Scaffold(),
      ),
    ),
  );

  Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(done(), isTrue, reason: '等待受控异步阶段完成');
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(app());
    unawaited(
      navigator.currentState!
          .push<bool>(
            MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
          )
          .then((value) {
            result = value;
            routeCompleted = true;
          }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    platform.cookies.values = [
      Cookie(
        name: '_t',
        value: _token,
        domain: Uri.parse(AppConstants.baseUrl).host,
        path: '/',
        isSecure: true,
        isHttpOnly: true,
        expiresDate: DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      ),
    ];
    platform.controller.evaluateScript = (source) async {
      if (source.contains('current-username')) return 'alice';
      if (source.contains('meta[name="csrf-token"]')) return 'csrf-test';
      if (source == 'window.__rawPreloaded || null') return _html;
      return null;
    };
  }

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      io.HttpOverrides.runZoned(
        () => platform.webView!.params.onUpdateVisitedHistory!(
          platform.controller.wrapped,
          WebUri(AppConstants.baseUrl),
          false,
        ),
        createHttpClient: (_) => _HttpClient(() => httpReply),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }

  Future<void> release(WidgetTester tester, Completer<void> gate) async {
    gate.complete();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  setUpAll(platform.initialize);
  setUp(() async {
    await platform.reset();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    FlutterSecureStorage.setMockInitialValues({});
    await CredentialStoreService().load();
    WebViewCookiePriming.instance.invalidate();
    PreloadedDataService().reset();
    CsrfTokenService().clearCsrfToken();
    service.setToken('');
    broadcasts = 0;
    result = null;
    routeCompleted = false;
    httpReply = _HttpReply();
    final subscription = service.authStateStream.listen((_) => broadcasts++);
    addTearDown(subscription.cancel);
  });
  tearDown(platform.reset);

  testWidgets('完整网页登录对齐 Cookie、复用 HTML，并以 bool true 退出', (tester) async {
    await open(tester);
    final generation = AuthSession().generation;
    await start(tester);
    await drainUntil(tester, () => routeCompleted);
    expect(result, isTrue);
    expect(await jar.getTToken(), _token);
    expect(service.isAuthenticated, isTrue);
    expect(broadcasts, 1);
    expect(AuthSession().generation, generation + 1);
    expect(PreloadedDataService().currentUserSync?['username'], 'alice');
    expect(httpReply.entered.isCompleted, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  for (final scenario in ['系统返回动画中', '系统返回销毁后', '标题返回', '换代退出', '单独清理']) {
    testWidgets('CSRF 读取期间$scenario，不推进代次、不写回认证、不广播', (tester) async {
      await open(tester);
      final entered = Completer<void>();
      final gate = Completer<void>();
      final evaluate = platform.controller.evaluateScript!;
      platform.controller.evaluateScript = (source) async {
        if (source.contains('meta[name="csrf-token"]')) {
          entered.complete();
          await gate.future;
          return 'stale-csrf';
        }
        return evaluate(source);
      };
      await start(tester);
      await drainUntil(tester, () => entered.isCompleted);
      if (scenario.startsWith('系统返回')) {
        await tester.binding.handlePopRoute();
        await tester.pump();
        if (scenario.endsWith('销毁后')) {
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(WebViewLoginPage), findsNothing);
        } else {
          expect(find.byType(WebViewLoginPage), findsOneWidget);
        }
      } else if (scenario == '标题返回') {
        await tester.tap(find.byType(BackButton));
        await tester.pump();
      } else {
        if (scenario == '换代退出') AuthSession().advance();
        service.setToken('');
        await jar.clearAll();
      }
      final interrupted = AuthSession().generation;
      await release(tester, gate);
      expect(await jar.getTToken(), isNull);
      expect(service.isAuthenticated, isFalse);
      expect(broadcasts, 0);
      expect(AuthSession().generation, interrupted);
      expect(CsrfTokenService().csrfToken, isNull);
      expect(result, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final scenario in ['系统返回', '换代退出']) {
    testWidgets('最终认证 Cookie 同步期间$scenario，迟到快照不能写回', (tester) async {
      await open(tester);
      final initial = AuthSession().generation;
      final entered = Completer<void>();
      final gate = Completer<void>();
      platform.cookies.readSnapshot = () async {
        final snapshot = [...platform.cookies.values];
        if (AuthSession().generation != initial && !entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
        return snapshot;
      };
      await start(tester);
      await drainUntil(tester, () => entered.isCompleted);
      if (scenario == '系统返回') {
        await tester.binding.handlePopRoute();
        await tester.pump();
      } else {
        AuthSession().advance();
        service.setToken('');
        await jar.clearAll();
      }
      final interrupted = AuthSession().generation;
      await release(tester, gate);
      expect(await jar.getTToken(), isNull);
      expect(service.isAuthenticated, isFalse);
      expect(broadcasts, 0);
      expect(AuthSession().generation, interrupted);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final missing in [true, false]) {
    testWidgets(
      'jar 认证 Cookie ${missing ? '缺失' : '不一致'}时不能退回旧 WebView token，允许重试',
      (tester) async {
        await open(tester);
        final initial = AuthSession().generation;
        platform.cookies.readSnapshot = () async {
          if (AuthSession().generation == initial) {
            return [...platform.cookies.values];
          }
          return missing
              ? []
              : [
                  Cookie(
                    name: '_t',
                    value: 'different-session',
                    domain: Uri.parse(AppConstants.baseUrl).host,
                    path: '/',
                    expiresDate: DateTime.now()
                        .add(const Duration(days: 1))
                        .millisecondsSinceEpoch,
                  ),
                ];
        };
        await start(tester);
        await drainUntil(
          tester,
          () => platform.controller.scripts.any(
            (source) => source.contains('meta[name="csrf-token"]'),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(service.isAuthenticated, isFalse);
        expect(broadcasts, 0);
        expect(routeCompleted, isFalse);
        platform.cookies.readSnapshot = null;
        await start(tester);
        await drainUntil(tester, () => routeCompleted);
        expect(result, isTrue);
        expect(broadcasts, 1);
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  testWidgets('已设置 token 后等待 HTML 时退出，迟到结果不恢复内存认证或广播', (tester) async {
    await open(tester);
    final entered = Completer<void>();
    final gate = Completer<void>();
    final evaluate = platform.controller.evaluateScript!;
    platform.controller.evaluateScript = (source) async {
      if (source == 'window.__rawPreloaded || null') {
        entered.complete();
        await gate.future;
      }
      return evaluate(source);
    };
    await start(tester);
    await drainUntil(tester, () => entered.isCompleted);
    expect(service.isAuthenticated, isTrue);
    AuthSession().advance();
    service.setToken('');
    await jar.clearAll();
    await release(tester, gate);
    expect(await jar.getTToken(), isNull);
    expect(service.isAuthenticated, isFalse);
    expect(broadcasts, 0);
    expect(routeCompleted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in ['返回关闭', '换代退出', '超时']) {
    testWidgets('预加载 HTTP 等待期间$scenario，迟到完成不会额外广播', (tester) async {
      await open(tester);
      final evaluate = platform.controller.evaluateScript!;
      platform.controller.evaluateScript = (source) async =>
          source == 'window.__rawPreloaded || null' ? null : evaluate(source);
      await start(tester);
      await drainUntil(tester, () => httpReply.entered.isCompleted);
      if (scenario == '返回关闭') {
        await tester.binding.handlePopRoute();
        await tester.pump();
      } else if (scenario == '换代退出') {
        AuthSession().advance();
        service.setToken('');
        await jar.clearAll();
      } else {
        // 流程在 runAsync 中启动，使用真实时间等到生产代码的 8 秒超时。
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 9)),
        );
        await drainUntil(tester, () => routeCompleted);
        expect(result, isTrue);
        expect(broadcasts, 1);
      }
      httpReply.body.complete(_html);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (scenario != '换代退出') {
        // 确认真实 refresh 已成功处理迟到响应，再检查通知没有写回。
        await drainUntil(tester, () => PreloadedDataService().isLoaded);
        expect(PreloadedDataService().currentUserSync?['username'], 'alice');
      }
      expect(broadcasts, scenario == '超时' ? 1 : 0);
      if (scenario == '换代退出') {
        expect(service.isAuthenticated, isFalse);
        expect(await jar.getTToken(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
