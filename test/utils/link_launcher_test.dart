import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/pages/webview_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/link_launcher.dart';
import 'package:fluxdo/utils/url_helper.dart';
import 'package:fluxdo/widgets/layout/home_workspace_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PushObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  Iterable<PageRoute<dynamic>> get pages =>
      pushed.whereType<PageRoute<dynamic>>();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

/// 保留真实确认弹窗和点击入口，仅在构建前检查并移除原生页面路由。
class _LinkHost {
  final observer = _PushObserver();
  final topics = <(int, String?, int?)>[];
  final downloads = <String>[];
  final tags = <String>[];
  late BuildContext context;
  Future<void>? pending;

  Future<void> mount(
    WidgetTester tester,
    String url, {
    bool external = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'pref_open_external_links_in_app_browser': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            navigatorObservers: [observer],
            home: HomeWorkspaceScope(
              onShowFeed: () {},
              onShowCategory: (_) {},
              onShowTag: tags.add,
              child: Scaffold(
                body: Builder(
                  builder: (value) {
                    context = value;
                    return TextButton(
                      onPressed: () {
                        pending = external
                            ? launchExternalLink(context, url)
                            : launchContentLink(
                                context,
                                url,
                                onInternalLinkTap: (id, slug, post) =>
                                    topics.add((id, slug, post)),
                                onDownloadAttachment: downloads.add,
                              );
                      },
                      child: const Text('打开链接'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    observer.pushed.clear();
    await tester.tap(find.text('打开链接'));
  }

  Future<void> expectWarning(WidgetTester tester, String title) async {
    expect(topics, isEmpty);
    expect(downloads, isEmpty);
    expect(tags, isEmpty);
    expect(observer.pages, isEmpty);
    expect(observer.pushed, hasLength(1));
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(find.text(S.current.common_continueVisit), findsOneWidget);
  }

  Future<void> cancel(WidgetTester tester) async {
    await tester.tap(
      find.widgetWithText(OutlinedButton, S.current.common_cancel),
    );
    await pending;
    await tester.pumpAndSettle();
    expect(topics, isEmpty);
    expect(downloads, isEmpty);
    expect(tags, isEmpty);
    expect(observer.pages, isEmpty);
  }

  Future<void> continueVisit(WidgetTester tester) async {
    await tester.tap(
      find.widgetWithText(FilledButton, S.current.common_continueVisit),
    );
    await pending;
  }

  void expectWebView(String url) {
    expect(observer.pages, hasLength(1));
    final route = observer.pages.single as MaterialPageRoute<dynamic>;
    final page = route.builder(context);
    expect(page, isA<WebViewPage>());
    expect((page as WebViewPage).url, url);
    Navigator.of(context).removeRoute(route);
  }
}

void main() {
  setUp(() {
    UrlHelper.debugSetOverrides(baseUri: '');
  });
  tearDown(UrlHelper.debugClearOverrides);

  test('站内判断区分路径、协议相对本站和协议相对外站', () {
    for (final url in [
      '/t/123',
      '//nodeloc.com/t/123',
      '//www.nodeloc.com/t/123',
      '//cdn.nodeloc.com/t/123',
    ]) {
      expect(isInternalUrlString(url), isTrue, reason: url);
    }
    for (final url in [
      '//bit.ly/t/123',
      '//evilnodeloc.com/t/123',
      '//nodeloc.com.evil.test/t/123',
      '//www.nodeloc.com@evil.test/t/123',
    ]) {
      expect(isInternalUrlString(url), isFalse, reason: url);
    }
  });

  for (final (url, dangerous) in [
    ('//bit.ly/t/123', false),
    ('//bit.ly/abc?aff=123', true),
    ('//evil.test/t/123', false),
  ]) {
    testWidgets('协议相对外链先确认，取消不跳转：$url', (tester) async {
      final host = _LinkHost();
      await host.mount(tester, url);
      await host.expectWarning(
        tester,
        dangerous
            ? S.current.externalLink_securityWarningTitle
            : url.contains('bit.ly')
            ? S.current.externalLink_shortLinkTitle
            : S.current.externalLink_leavingTitle,
      );
      await host.cancel(tester);
    });
  }

  for (final url in [
    'https://www.nodeloc.com/t/123?aff=456',
    '/t/123?aff=456',
    '//nodeloc.com/t/123?aff=456',
    'https://www.nodeloc.com/?aff=123',
    '/u/alice?aff=123',
    '/chat/c/general/1?aff=123',
    '/tag/news?aff=123',
    '/uploads/default/test.pdf?aff=123',
    '/uploads/default/test.png?aff=123',
  ]) {
    testWidgets('站内推广链接先提示，取消不执行快捷跳转：$url', (tester) async {
      final host = _LinkHost();
      await host.mount(tester, url);
      await host.expectWarning(
        tester,
        S.current.externalLink_securityWarningTitle,
      );
      await host.cancel(tester);
    });
  }

  testWidgets('确认推广话题后保留原生话题 ID、slug 与楼层', (tester) async {
    final host = _LinkHost();
    await host.mount(tester, '/t/example/123/4?aff=456');
    await host.expectWarning(
      tester,
      S.current.externalLink_securityWarningTitle,
    );
    await host.continueVisit(tester);
    expect(host.topics, [(123, 'example', 4)]);
    expect(host.observer.pushed, hasLength(1));
    await tester.pumpAndSettle();
    expect(
      find.text(S.current.externalLink_securityWarningTitle),
      findsNothing,
    );
  });

  testWidgets('确认推广附件后保留下载回调和完整 URL', (tester) async {
    final host = _LinkHost();
    await host.mount(tester, '/uploads/default/test.pdf?aff=123');
    await host.expectWarning(
      tester,
      S.current.externalLink_securityWarningTitle,
    );
    await host.continueVisit(tester);
    expect(host.downloads, [
      'https://www.nodeloc.com/uploads/default/test.pdf?aff=123',
    ]);
    expect(host.observer.pushed, hasLength(1));
    await tester.pumpAndSettle();
  });

  for (final url in [
    '//bit.ly/t/123',
    '//bit.ly/abc?aff=123#end',
    '//evil.test/t/123',
  ]) {
    testWidgets('协议相对外链确认一次后打开实际外站：$url', (tester) async {
      final host = _LinkHost();
      await host.mount(tester, url);
      expect(host.observer.pages, isEmpty);
      await tester.pumpAndSettle();
      await host.continueVisit(tester);
      expect(host.topics, isEmpty);
      expect(host.observer.pushed, hasLength(2));
      host.expectWebView('https:$url');
      await tester.pumpAndSettle();
      expect(find.byType(FilledButton), findsNothing);
    });
  }

  testWidgets('普通站内推广页确认后打开 WebView', (tester) async {
    final host = _LinkHost();
    const url = 'https://www.nodeloc.com/?aff=123';
    await host.mount(tester, url);
    await host.expectWarning(
      tester,
      S.current.externalLink_securityWarningTitle,
    );
    await host.continueVisit(tester);
    host.expectWebView(url);
    expect(host.observer.pushed, hasLength(2));
    await tester.pumpAndSettle();
  });

  for (final url in ['/t/123', '//nodeloc.com/t/123']) {
    testWidgets('普通站内话题无需确认：$url', (tester) async {
      final host = _LinkHost();
      await host.mount(tester, url);
      await host.pending;
      expect(host.topics, [(123, null, null)]);
      expect(host.observer.pushed, isEmpty);
    });
  }

  testWidgets('配置的 CDN 图片仍直接进入图库并保留 S3 重写', (tester) async {
    UrlHelper.debugSetOverrides(
      baseUri: '',
      s3BaseUrl: '//uploads.example.com',
      s3CdnUrl: 'https://cdn.example.com',
    );
    final host = _LinkHost();
    await host.mount(tester, '//uploads.example.com/original/test.png');
    expect(host.observer.pushed, hasLength(1));
    final route = host.observer.pages.single as PageRouteBuilder<dynamic>;
    final page = route.pageBuilder(
      host.context,
      const AlwaysStoppedAnimation(1.0),
      const AlwaysStoppedAnimation(0.0),
    );
    expect(page, isA<ImageViewerPage>());
    expect(
      (page as ImageViewerPage).imageUrl,
      'https://cdn.example.com/original/test.png',
    );
    Navigator.of(host.context).removeRoute(route);
    await host.pending;
    await tester.pumpAndSettle();
  });

  testWidgets('直接外链入口补全协议且只确认一次', (tester) async {
    final host = _LinkHost();
    await host.mount(tester, '//bit.ly/abc', external: true);
    await host.expectWarning(tester, S.current.externalLink_shortLinkTitle);
    await host.continueVisit(tester);
    host.expectWebView('https://bit.ly/abc');
    expect(host.observer.pushed, hasLength(2));
    await tester.pumpAndSettle();
  });

  testWidgets('等待确认期间原入口销毁后不继续导航', (tester) async {
    final host = _LinkHost();
    await host.mount(tester, '/t/123?aff=456');
    await host.expectWarning(
      tester,
      S.current.externalLink_securityWarningTitle,
    );
    final route = ModalRoute.of(host.context)!;
    Navigator.of(host.context).removeRoute(route);
    await tester.pumpAndSettle();
    expect(host.context.mounted, isFalse);
    await host.continueVisit(tester);
    expect(host.topics, isEmpty);
    expect(host.observer.pages, isEmpty);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
