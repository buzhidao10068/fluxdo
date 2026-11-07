import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/deep_link_service.dart';

class _RecordingNavigatorObserver extends NavigatorObserver {
  final pushedRoutes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRoutes.add(route);
    super.didPush(route, previousRoute);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DeepLinkService.instance.dispose();
  });

  test('canHandleUri 只接受受支持的 scheme 和 host', () {
    final service = DeepLinkService.instance;

    expect(
      service.canHandleUri(Uri.parse('https://www.nodeloc.com/t/123')),
      isTrue,
    );
    // 回归点：这两条断言曾经重复（都是 www），裸域覆盖丢失。
    // 站点裸域 301 到 www，用户分享裸域链接很常见，必须显式覆盖。
    expect(
      service.canHandleUri(Uri.parse('https://nodeloc.com/t/123')),
      isTrue,
    );
    expect(
      service.canHandleUri(Uri.parse('https://nodeloc.com/u/alice')),
      isTrue,
    );
    expect(
      service.canHandleUri(Uri.parse('https://meta.nodeloc.com/latest')),
      isTrue,
    );
    expect(service.canHandleUri(Uri.parse('fluxdo://topic/123')), isTrue);
    expect(
      service.canHandleUri(Uri.parse('discourse://auth_redirect?payload=x')),
      isTrue,
    );
    expect(
      service.canHandleUri(Uri.parse('https://example.com/t/123')),
      isFalse,
    );
    expect(
      service.canHandleUri(Uri.parse('ftp://www.nodeloc.com/t/123')),
      isFalse,
    );
  });

  test('Android HTTP(S) 入口识别本站路径，拒绝旧站与伪装域', () {
    final service = DeepLinkService.instance;
    for (final host in ['www.nodeloc.com', 'nodeloc.com']) {
      for (final scheme in ['http', 'https']) {
        for (final path in [
          '/t/123',
          '/u/alice',
          '/session/email-login/token',
        ]) {
          final uri = Uri.parse('$scheme://$host$path');
          expect(service.canHandleUri(uri), isTrue, reason: '$uri');
        }
      }
    }
    for (final url in [
      'https://linux.do/t/123',
      'https://www.linux.do/u/alice',
      'https://nodeloc.com.evil.example/t/123',
      'https://notnodeloc.com/t/123',
      'https://www.nodeloc.com@evil.example/t/123',
      'discourse://other_callback?payload=x',
    ]) {
      expect(service.canHandleUri(Uri.parse(url)), isFalse, reason: url);
    }
  });

  testWidgets('handleUri 不接管非 www.nodeloc.com 的话题路径', (tester) async {
    BuildContext? capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final context = capturedContext!;
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(Uri.parse('https://example.com/t/123'));
    await tester.pump();

    expect(Navigator.of(context).canPop(), isFalse);
  });

  testWidgets('handleUri 支持 fluxdo 话题链接', (tester) async {
    BuildContext? capturedContext;
    final observer = _RecordingNavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final context = capturedContext!;
    observer.pushedRoutes.clear();
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(Uri.parse('fluxdo://topic/123/5'));

    expect(observer.pushedRoutes, hasLength(1));
    expect(Navigator.of(context).canPop(), isTrue);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('handleUri 支持 fluxdo 用户链接', (tester) async {
    BuildContext? capturedContext;
    final observer = _RecordingNavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final context = capturedContext!;
    observer.pushedRoutes.clear();
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(Uri.parse('fluxdo://user/alice'));

    expect(observer.pushedRoutes, hasLength(1));
    expect(Navigator.of(context).canPop(), isTrue);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('handleUri 对 fluxdo scheme 大小写不敏感', (tester) async {
    BuildContext? capturedContext;
    final observer = _RecordingNavigatorObserver();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final context = capturedContext!;
    observer.pushedRoutes.clear();
    DeepLinkService.instance.updateContext(context);
    DeepLinkService.instance.handleUri(Uri.parse('fluxdo://Topic/123'));

    expect(observer.pushedRoutes, hasLength(1));
    expect(Navigator.of(context).canPop(), isTrue);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  });
}
