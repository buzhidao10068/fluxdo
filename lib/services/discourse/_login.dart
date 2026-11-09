part of 'discourse_service.dart';

/// 原生用户名/密码登录，与当前站点的 Discourse 网页流程对齐:
/// 1. (UI 层) 弹 hcaptcha mini webview, 让用户人机验证拿 hcaptcha token
/// 2. GET /session/csrf (由 RequestHeaderInterceptor 在 POST 前自动触发)
/// 3. POST /hcaptcha/create.json {token: hcaptchaToken}
///    → server 写一个 2 分钟 TTL 的 encrypted cookie `h_captcha_temp_id`
/// 4. POST /session.json {login, password, second_factor_token?}
///    → server 见 h_captcha_temp_id cookie + verify hcaptcha → 真正登录
///
/// 主要解决 iOS 15.7 用户卡 splash 的 Discourse `static {}` (ES2022) 兼容问题:
/// 不再加载 Discourse Ember bundle, 直接走 native JSON API。
mixin _LoginMixin on _DiscourseServiceBase, _AuthMixin {
  /// 用 hcaptcha token 换 h_captcha_temp_id cookie。
  /// caller 必须先通过 hcaptcha mini webview 让用户人机交互拿到 token。
  Future<bool> verifyHcaptchaToken(String hcaptchaToken) async {
    final endpoints = {
      ?AppConstants.siteCustomization.login.hcaptchaCreateEndpoint,
      '/captcha/hcaptcha/create.json',
      '/hcaptcha/create.json',
    };
    for (final endpoint in endpoints) {
      try {
        final response = await _dio.post<dynamic>(
          endpoint,
          data: {'token': hcaptchaToken},
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
        if (response.statusCode == 404) continue;
        final contentType = response.headers.value(Headers.contentTypeHeader);
        return response.statusCode == 200 &&
            contentType?.contains('text/html') != true &&
            !response.data.toString().trimLeft().startsWith('<');
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) continue;
        debugPrint(
          '[DiscourseLogin] hcaptcha verify 失败: ${e.type} ${e.response?.statusCode}',
        );
        return false;
      }
    }
    return false;
  }

  /// 用户名/邮箱 + 密码登录。
  ///
  /// 调用约定:
  /// - 调用前必须先 [verifyHcaptchaToken] 让 server 写 h_captcha_temp_id cookie
  /// - 首次返 [LoginErrorKind.secondFactorRequired] 时由 caller 弹 TOTP 对话框
  ///   拿 6 位 code, 再次调本方法带 [secondFactorToken]
  Future<LoginResult> loginWithPassword({
    required String identifier,
    required String password,
    String? secondFactorToken,
  }) async {
    final requestGeneration = AuthSession().generation;
    final data = <String, String>{'login': identifier, 'password': password};
    if (secondFactorToken != null && secondFactorToken.isNotEmpty) {
      data['second_factor_token'] = secondFactorToken;
      // 1=TOTP, 2=backup code, 3=security key. 第一版只支持 TOTP, backup/key
      // 引导用户跳 webview 登录兜底。
      data['second_factor_method'] = '1';
    }

    final Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        '/session.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      debugPrint(
        '[DiscourseLogin] session POST 失败: ${e.type} ${e.response?.statusCode}',
      );
      if (e.response != null) {
        final failure = _parseSessionResponse(
          e.response!.statusCode ?? 0,
          e.response!.data,
        );
        if (failure is LoginFailure) return failure;
      }
      // 取消、拦截器拒绝等异常即使附带 2xx 响应也不能绕过正常收口。
      return LoginResult.error(
        LoginErrorKind.network,
        message: e.message ?? '网络异常',
      );
    }

    final result = _parseSessionResponse(resp.statusCode ?? 0, resp.data);
    if (result is LoginFailure) return result;
    try {
      await finalizeNativeLoginSuccess(
        identifier,
        requestGeneration: requestGeneration,
      );
    } on StateError catch (e) {
      return LoginResult.error(LoginErrorKind.unknown, message: e.message);
    }
    return const LoginResult.success();
  }

  LoginResult _parseLoginError(String reason, Map<String, dynamic> body) {
    switch (reason) {
      case 'invalid_second_factor':
      // Discourse 3.1 重构二步验证后移除了旧挑战契约:已启用 2FA 的账号
      // 在登录请求未带 second_factor_method 时不再返回挑战包
      // (reason=second_factor),而是直接拒绝并返回该 reason。
      // 语义等同"需要二步验证"——由 caller 弹验证码框后带全参数重发
      // (second_factor_token + second_factor_method=1)。
      case 'invalid_second_factor_method':
      case 'second_factor':
        return LoginResult.error(
          LoginErrorKind.secondFactorRequired,
          message: body['error']?.toString(),
          totpEnabled: body['totp_enabled'] == true,
          securityKeyEnabled: body['security_key_enabled'] == true,
          backupEnabled: body['backup_enabled'] == true,
        );
      case 'invalid_credentials':
        return LoginResult.error(
          LoginErrorKind.invalidCredentials,
          message: body['error']?.toString(),
        );
      case 'not_activated':
        return LoginResult.error(
          LoginErrorKind.notActivated,
          message: body['error']?.toString(),
          sentToEmail: body['sent_to_email']?.toString(),
          currentEmail: body['current_email']?.toString(),
        );
      case 'not_approved':
        return LoginResult.error(
          LoginErrorKind.notApproved,
          message: body['error']?.toString(),
        );
      case 'expired':
        return LoginResult.error(
          LoginErrorKind.passwordExpired,
          message: body['error']?.toString(),
        );
      default:
        return LoginResult.error(
          LoginErrorKind.unknown,
          message: body['error']?.toString() ?? 'reason=$reason',
        );
    }
  }

  /// 解析 WebView 内 JS 全流程登录 POST /session.json 的响应体 (字符串)。
  ///
  /// 与 [loginWithPassword] 的响应解析逻辑一致, 但**不发 dio、不做收尾** ——
  /// 收尾由调用方在 cookie 同步落 jar 后显式调 [finalizeNativeLoginSuccess]。
  /// 同时校验 HTTP 状态与 user，避免空 JSON 或错误页被视为登录成功。
  LoginResult parseSessionJsonBody(int status, String body) =>
      _parseSessionResponse(status, body);

  LoginResult _parseSessionResponse(int status, dynamic body) {
    Map<String, dynamic>? map;
    try {
      final decoded = body is String ? jsonDecode(body) : body;
      if (decoded is Map) map = Map<String, dynamic>.from(decoded);
    } catch (_) {
      map = null;
    }
    if (map == null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: 'Discourse 返回非 JSON: HTTP $status',
      );
    }

    // 错误状态可以携带 Discourse 的业务错误，但绝不能收口为成功。
    if (status < 200 || status >= 300) {
      if (status == 400 || status == 401 || status == 403) {
        final reason = map['reason']?.toString();
        if (reason != null) return _parseLoginError(reason, map);
      }
      return LoginResult.error(
        LoginErrorKind.network,
        message: '登录请求失败: HTTP $status',
      );
    }
    final reason = map['reason']?.toString();
    if (reason != null) return _parseLoginError(reason, map);
    if (map['error'] != null || map['errors'] != null) {
      return LoginResult.error(
        LoginErrorKind.unknown,
        message: (map['error'] ?? map['errors']).toString(),
      );
    }
    final user = map['user'];
    if (user is! Map ||
        user['id'] is! num ||
        (user['id'] as num) <= 0 ||
        user['username'] is! String ||
        (user['username'] as String).trim().isEmpty) {
      return const LoginResult.error(
        LoginErrorKind.unknown,
        message: '登录响应缺少有效用户信息',
      );
    }
    return const LoginResult.success();
  }

  /// 收口对齐 webview_login_page 的 _finalizeLoginBeforeExit + _finalizeLoginBootstrap:
  /// 校验会话代次与 jar 中的 _t → AuthSession.advance → saveUsername/setToken
  /// → LoginReadyCoordinator。
  ///
  /// WebView JS 全流程登录成功后, 由 login_page 在 dialog 已把会话 cookie
  /// syncFromWebView 落 jar 之后显式调用 (public)。dio 版 [loginWithPassword]
  /// 成功路径也复用它。
  @override
  Future<void> finalizeNativeLoginSuccess(
    String identifier, {
    int? requestGeneration,
  }) async {
    final generation = requestGeneration ?? AuthSession().generation;
    final token = await _cookieJar.getTToken() ?? '';
    if (!AuthSession().isValid(generation)) {
      throw StateError('登录流程已过期，请重新登录');
    }
    if (token.isEmpty) {
      throw StateError('未读取到登录 Cookie，请使用网页登录重试');
    }
    final loginGeneration = AuthSession().advance();
    await saveUsername(identifier);
    if (!AuthSession().isValid(loginGeneration)) {
      throw StateError('登录流程已过期，请重新登录');
    }
    setToken(token);
    final forceBrowserSessionSync = !WebViewSessionCookieRefreshService.instance
        .hasFreshSyncForToken(token);

    var loginReadyNotified = false;
    try {
      await LoginReadyCoordinator(
            hydrateFromHtml: PreloadedDataService().hydrateFromHtml,
            refreshPreloadedData: PreloadedDataService().refresh,
            notifyLoginReady: (t) {
              if (!AuthSession().isValid(loginGeneration)) return;
              loginReadyNotified = true;
              onLoginSuccess(
                t,
                forceBrowserSessionSync: forceBrowserSessionSync,
              );
            },
          )
          .finalize(token: token, pageHtml: null)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[DiscourseLogin] PreloadedData 收尾失败/超时: $e');
    } finally {
      // 兜底广播, 避免 UI 卡在"同步登录中"
      if (!loginReadyNotified && AuthSession().isValid(loginGeneration)) {
        onLoginSuccess(token, forceBrowserSessionSync: forceBrowserSessionSync);
      }
    }
    if (!AuthSession().isValid(loginGeneration)) {
      throw StateError('登录流程已过期，请重新登录');
    }
  }
}

enum LoginErrorKind {
  invalidCredentials,
  secondFactorRequired,
  notActivated,
  notApproved,
  passwordExpired,
  network,
  unknown,
}

/// sealed 风格的登录结果
sealed class LoginResult {
  const LoginResult();

  const factory LoginResult.success() = LoginSuccess;

  const factory LoginResult.error(
    LoginErrorKind kind, {
    String? message,
    bool totpEnabled,
    bool securityKeyEnabled,
    bool backupEnabled,
    String? sentToEmail,
    String? currentEmail,
  }) = LoginFailure;
}

class LoginSuccess extends LoginResult {
  const LoginSuccess();
}

class LoginFailure extends LoginResult {
  const LoginFailure(
    this.kind, {
    this.message,
    this.totpEnabled = false,
    this.securityKeyEnabled = false,
    this.backupEnabled = false,
    this.sentToEmail,
    this.currentEmail,
  });

  final LoginErrorKind kind;
  final String? message;
  final bool totpEnabled;
  final bool securityKeyEnabled;
  final bool backupEnabled;
  final String? sentToEmail;
  final String? currentEmail;
}
