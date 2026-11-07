import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/sites/nodeloc.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/plugins/plugin_registry.dart';
import 'package:fluxdo/services/dio_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppConstants 站点身份派生', () {
    test('站点定制与插件注册均使用 NodeLoc 配置', () {
      PluginRegistry.resetOverride();
      addTearDown(PluginRegistry.resetOverride);
      expect(AppConstants.siteCustomization, same(nodelocCustomization));
      expect(
        PluginRegistry.plugins,
        same(AppConstants.siteCustomization.plugins),
      );
      expect(PluginRegistry.plugins, isEmpty);
    });

    test('baseUrl 带 www，siteHost 保留 www，siteRootDomain 去掉 www', () {
      expect(AppConstants.baseUrl, 'https://www.nodeloc.com');
      expect(AppConstants.siteHost, 'www.nodeloc.com');
      expect(AppConstants.siteRootDomain, 'nodeloc.com');
    });

    test('isSiteHost 接受主域、裸域与任意子域，拒绝外域与相似域', () {
      expect(AppConstants.isSiteHost('www.nodeloc.com'), isTrue);
      expect(AppConstants.isSiteHost('nodeloc.com'), isTrue);
      expect(AppConstants.isSiteHost('cdn.nodeloc.com'), isTrue);
      expect(AppConstants.isSiteHost('meta.nodeloc.com'), isTrue);
      expect(AppConstants.isSiteHost('WWW.NODELOC.COM'), isTrue);

      expect(AppConstants.isSiteHost('example.com'), isFalse);
      // 相似域不能被子串匹配误判
      expect(AppConstants.isSiteHost('notnodeloc.com'), isFalse);
      expect(AppConstants.isSiteHost('nodeloc.com.evil.com'), isFalse);
      expect(AppConstants.isSiteHost('evil-nodeloc.com'), isFalse);
      expect(AppConstants.isSiteHost(''), isFalse);
    });
  });

  group('DioHttpClient 主域通道选择', () {
    test('主域 / 裸域 / 子域都走带 cookie 的主域通道', () {
      expect(
        DioHttpClient.isSiteRequest(Uri.parse('https://www.nodeloc.com/t/1')),
        isTrue,
      );
      // 回归点：裸域过去会被 endsWith('.www.nodeloc.com') 漏判成 CDN
      expect(
        DioHttpClient.isSiteRequest(Uri.parse('https://nodeloc.com/t/1')),
        isTrue,
      );
      // 回归点：兄弟子域同样必须命中主域通道（secure-uploads 鉴权依赖）
      expect(
        DioHttpClient.isSiteRequest(
          Uri.parse('https://cdn.nodeloc.com/uploads/secure-uploads/a.png'),
        ),
        isTrue,
      );
      expect(
        DioHttpClient.isSiteRequest(Uri.parse('https://meta.nodeloc.com/')),
        isTrue,
      );
    });

    test('外域与空 host 走无 cookie 的 CDN 通道', () {
      expect(
        DioHttpClient.isSiteRequest(Uri.parse('https://example.com/a.png')),
        isFalse,
      );
      expect(
        DioHttpClient.isSiteRequest(Uri.parse('https://notnodeloc.com/a.png')),
        isFalse,
      );
      // 相对路径没有 host，按 CDN 通道处理
      expect(DioHttpClient.isSiteRequest(Uri.parse('/uploads/a.png')), isFalse);
    });
  });
}
