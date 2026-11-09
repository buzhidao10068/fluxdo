import 'dart:convert';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/site_customization.dart';
import 'package:fluxdo/config/sites/linuxdo.dart';
import 'package:fluxdo/config/sites/nodeloc.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/user_api_key_service.dart';
import 'package:fluxdo/services/webview_session_cookie_refresh_service.dart';

import '../support/cf_test_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = CfTestPlatform();
  final service = DiscourseService();
  final jar = CookieJarService();

  setUpAll(platform.initialize);
  setUp(platform.reset);
  tearDown(platform.reset);

  test('NodeLoc 使用本站验证码和非官方授权名，不探测旧站 fingerprint', () {
    final login = AppConstants.siteCustomization.login;
    expect(login, same(nodelocCustomization.login));
    expect(login.hcaptchaSiteKey, 'd2a8ddf6-4c2a-4054-ac7c-2e288c2477aa');
    expect(login.hcaptchaCreateEndpoint, '/captcha/hcaptcha/create.json');
    expect(login.requiresFingerprint, isFalse);
    expect(UserApiKeyService.applicationName, 'NodeLoc Unofficial Client');
    expect(
      UserApiKeyService.qrApplicationName,
      'NodeLoc Unofficial Client QR Login',
    );
    expect(UserApiKeyService.scopes, 'one_time_password');
    expect(UserApiKeyService.keyWorthKeeping, isFalse);
    expect(const SiteLoginConfig().requiresFingerprint, isFalse);
    expect(linuxdoCustomization.login.requiresFingerprint, isTrue);
    expect(
      linuxdoCustomization.login.hcaptchaSiteKey,
      'a776b4ac-8c4c-441e-986a-c6ee9ed8cf08',
    );
  });

  test('NodeLoc 的后台和现有控制器收口均不执行 fingerprint 脚本', () async {
    final refresh = WebViewSessionCookieRefreshService.instance;
    expect((await refresh.ensureSynced(force: true)).ok, isTrue);
    expect(
      (await refresh.runOnController(
        platform.controller.wrapped,
        reason: 'test',
      )).ok,
      isTrue,
    );
    expect(platform.webView, isNull);
    expect(platform.controller.scripts, isEmpty);
  });

  test('只接受 HTTP 成功且包含有效 user 的响应', () {
    expect(
      service.parseSessionJsonBody(200, '{"user":{"id":1,"username":"alice"}}'),
      isA<LoginSuccess>(),
    );
    for (final body in [
      '{}',
      '[]',
      '<html>NodeLoc</html>',
      '{"success":true}',
      '{"user":{"id":0,"username":"alice"}}',
      '{"user":{"id":1,"username":" "}}',
      '{"error":"denied","user":{"id":1,"username":"alice"}}',
    ]) {
      expect(
        service.parseSessionJsonBody(200, body),
        isA<LoginFailure>(),
        reason: body,
      );
    }
    for (final status in [302, 400, 401, 403, 429, 500]) {
      expect(
        service.parseSessionJsonBody(
          status,
          '{"user":{"id":1,"username":"alice"}}',
        ),
        isA<LoginFailure>(),
      );
    }
  });

  for (final (reason, kind) in [
    ('invalid_credentials', LoginErrorKind.invalidCredentials),
    ('invalid_second_factor', LoginErrorKind.secondFactorRequired),
    ('invalid_second_factor_method', LoginErrorKind.secondFactorRequired),
    ('second_factor', LoginErrorKind.secondFactorRequired),
    ('not_activated', LoginErrorKind.notActivated),
    ('not_approved', LoginErrorKind.notApproved),
    ('expired', LoginErrorKind.passwordExpired),
  ]) {
    test('保留 Discourse 业务错误 $reason', () {
      for (final status in [200, 400, 401, 403]) {
        final result = service.parseSessionJsonBody(
          status,
          jsonEncode({
            'reason': reason,
            'error': '提示',
            'totp_enabled': true,
            'sent_to_email': 'a***@example.com',
          }),
        ) as LoginFailure;
        expect(result.kind, kind);
        expect(result.message, '提示');
        if (kind == LoginErrorKind.secondFactorRequired) {
          expect(result.totpEnabled, isTrue);
        }
        if (kind == LoginErrorKind.notActivated) {
          expect(result.sentToEmail, 'a***@example.com');
        }
      }
    });
  }

  test('只有匿名 _forum_session 时不推进会话、不广播登录', () async {
    await jar.cookieJar.saveFromResponse(Uri.parse(AppConstants.baseUrl), [
      io.Cookie('_forum_session', 'anonymous')..path = '/',
    ]);
    service.setToken('');
    final generation = AuthSession().generation;
    var notifications = 0;
    final subscription = service.authStateStream.listen((_) => notifications++);
    addTearDown(subscription.cancel);
    await expectLater(
      service.finalizeNativeLoginSuccess(
        'alice',
        requestGeneration: generation,
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(AuthSession().generation, generation);
    expect(service.isAuthenticated, isFalse);
    expect(notifications, 0);
  });

  test('旧流程即使 jar 有 _t 也不能收口', () async {
    await jar.cookieJar.saveFromResponse(Uri.parse(AppConstants.baseUrl), [
      io.Cookie('_t', 'current-session')..path = '/',
    ]);
    final generation = AuthSession().generation;
    AuthSession().advance();
    await expectLater(
      service.finalizeNativeLoginSuccess(
        'alice',
        requestGeneration: generation,
      ),
      throwsStateError,
    );
    expect(AuthSession().generation, generation + 1);
  });

  group('原生 Dio 登录入口', () {
    late List<Interceptor> originalInterceptors;

    setUp(() {
      originalInterceptors = service.dio.interceptors.toList();
      service.dio.interceptors.clear();
    });
    tearDown(() {
      service.dio.interceptors
        ..clear()
        ..addAll(originalInterceptors);
    });

    test('验证码路径仅在 404 时回退到插件原生路径', () async {
      final paths = <String>[];
      service.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            paths.add(request.path);
            if (paths.length == 1) {
              handler.reject(
                DioException.badResponse(
                  statusCode: 404,
                  requestOptions: request,
                  response: Response(requestOptions: request, statusCode: 404),
                ),
              );
            } else {
              handler.resolve(
                Response(requestOptions: request, statusCode: 200, data: {}),
              );
            }
          },
        ),
      );
      expect(await service.verifyHcaptchaToken('captcha'), isTrue);
      expect(paths, ['/captcha/hcaptcha/create.json', '/hcaptcha/create.json']);
    });

    for (final status in [200, 403]) {
      test('验证码 HTTP $status 错误页不算成功，也不继续探测路径', () async {
        var requests = 0;
        service.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests++;
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: status,
                  data: '<html>NodeLoc</html>',
                  headers: Headers.fromMap({
                    Headers.contentTypeHeader: ['text/html'],
                  }),
                ),
              );
            },
          ),
        );
        expect(await service.verifyHcaptchaToken('captcha'), isFalse);
        expect(requests, 1);
      });
    }

    test('DioException 保留二步验证提示，携带 2xx user 也不能成功', () async {
      var status = 401;
      service.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: request,
                statusCode: status,
                data: status == 401
                    ? {'reason': 'invalid_second_factor', 'totp_enabled': true}
                    : {
                        'user': {'id': 1, 'username': 'alice'},
                      },
              ),
            ),
          ),
        ),
      );
      final generation = AuthSession().generation;
      final secondFactor = await service.loginWithPassword(
        identifier: 'alice',
        password: 'test-value',
      ) as LoginFailure;
      expect(secondFactor.kind, LoginErrorKind.secondFactorRequired);
      expect(secondFactor.totpEnabled, isTrue);
      status = 200;
      final rejected = await service.loginWithPassword(
        identifier: 'alice',
        password: 'test-value',
      );
      expect(rejected, isA<LoginFailure>());
      expect(AuthSession().generation, generation);
    });

    test('原生请求期间会话已切换，不用 jar 中的新令牌完成旧登录', () async {
      service.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            AuthSession().advance();
            await jar.cookieJar.saveFromResponse(
              Uri.parse(AppConstants.baseUrl),
              [io.Cookie('_t', 'other-session')..path = '/'],
            );
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'user': {'id': 1, 'username': 'alice'},
                },
              ),
            );
          },
        ),
      );
      final generation = AuthSession().generation;
      expect(
        await service.loginWithPassword(
          identifier: 'alice',
          password: 'test-value',
        ),
        isA<LoginFailure>(),
      );
      expect(AuthSession().generation, generation + 1);
    });
  });
}
