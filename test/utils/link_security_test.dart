import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/site_customization.dart';
import 'package:fluxdo/config/sites/nodeloc.dart';
import 'package:fluxdo/utils/link_security.dart';

void main() {
  final config = nodelocCustomization.linkSecurityConfig!;

  void expectUrls(List<String> urls, LinkRiskLevel level) {
    for (final url in urls) {
      expect(LinkSecurity.checkUrl(url, config), level, reason: url);
    }
  }

  test('NodeLoc 裸域、www 和多级子域均为内部链接', () {
    expectUrls([
      'https://nodeloc.com',
      'https://www.nodeloc.com/t/1',
      'https://a.b.nodeloc.com:8443/t/1?q=2#reply',
      'https://WWW.NODELOC.COM/t/1',
    ], LinkRiskLevel.internal);
  });

  test('伪装站点和旧站域名保持外链确认', () {
    expectUrls([
      'https://evilnodeloc.com',
      'https://nodeloc.com.evil.test',
      'https://www.nodeloc.com@evil.test/',
      'https://example.com/nodeloc.com',
      'https://linux.do/',
      'https://cdn.ldstatic.com/',
      'https://idcflare.com/',
      'https://chiddns.com/',
      'https://github.com/linux-do/fluxdo',
    ], LinkRiskLevel.normal);
    expect(config.trustedDomains, isEmpty);
    expect(config.blockedDomains, isEmpty);
  });

  test('通用本机与私网地址按主机匹配，支持端口和协议相对地址', () {
    expectUrls([
      'http://localhost:8080/',
      'https://printer.local/',
      'https://a.b.local/',
      'http://127.0.0.1/',
      'http://127.255.255.255:3000',
      'HTTP://10.0.0.1:8080/path',
      'http://10.255.255.255?test=1',
      'https://169.254.0.1#local',
      'https://169.254.255.255',
      'http://192.168.0.1/',
      'http://192.168.255.255/',
      'http://172.16.0.0/',
      'http://172.31.255.255/',
      'http://user@127.0.0.1/',
      '//10.1.2.3/path',
    ], LinkRiskLevel.internal);
  });

  test('公网地址、非法 IP 和在 URL 非主机处出现的私网地址不能绕过确认', () {
    expectUrls([
      for (final octets in [
        [172, 15, 255, 255],
        [172, 32, 0, 0],
        [192, 169, 0, 1],
        [169, 255, 0, 1],
      ])
        'https://${octets.join('.')}/',
      'https://10.256.0.1/',
      'https://127.0.0.1.evil.test/',
      'https://10.0.0.1.evil.test/',
      'https://example.com/path/127.0.0.1',
      'https://example.com/?next=http://10.0.0.1/',
      'https://127.0.0.1@evil.test/',
      'https://localhost.evil.test/',
      'https://printer.local.evil.test/',
      'https://8.8.8.8/',
    ], LinkRiskLevel.normal);
  });

  test('通用短链接显示风险提示，不按域名子串误判', () {
    expectUrls([
      'https://bit.ly/abc',
      'https://tinyurl.com/abc',
      'https://t.co/abc',
      'https://a.short.link/abc',
      'https://link.zip/abc',
    ], LinkRiskLevel.risky);
    expectUrls([
      'https://bit.ly.evil.test/abc',
      'https://example.com/bit.ly/abc',
    ], LinkRiskLevel.normal);
  });

  test('推广关键词忽略大小写，并优先于短链和内部域名', () {
    expectUrls([
      'https://example.com/?aff=123',
      'https://bit.ly/abc?AFF=123',
      'https://www.nodeloc.com/t/1?aff=123',
      'http://127.0.0.1/?aff=123',
    ], LinkRiskLevel.dangerous);
  });

  test('配置优先级为阻止、危险、风险、信任、内部', () {
    const rules = ['example.com'];
    const url = 'https://example.com/';
    for (final (overlap, expected) in [
      (
        const LinkSecurityConfig(
          blockedDomains: rules,
          dangerousDomains: rules,
          riskyDomains: rules,
          trustedDomains: rules,
          internalDomains: rules,
        ),
        LinkRiskLevel.blocked,
      ),
      (
        const LinkSecurityConfig(
          dangerousDomains: rules,
          riskyDomains: rules,
          trustedDomains: rules,
          internalDomains: rules,
        ),
        LinkRiskLevel.dangerous,
      ),
      (
        const LinkSecurityConfig(
          riskyDomains: rules,
          trustedDomains: rules,
          internalDomains: rules,
        ),
        LinkRiskLevel.risky,
      ),
      (
        const LinkSecurityConfig(trustedDomains: rules, internalDomains: rules),
        LinkRiskLevel.trusted,
      ),
    ]) {
      expect(LinkSecurity.checkUrl(url, overlap), expected);
    }
  });

  test('既有正则仍匹配完整 URL，路径规则保持原有语义', () {
    const custom = LinkSecurityConfig(
      blockedDomains: [r'^/blocked(?:\?|$)'],
      trustedDomains: ['example.com/docs/*', 'example.com/about'],
    );
    expect(
      LinkSecurity.checkUrl('https://example.com/blocked?a=1', custom),
      LinkRiskLevel.blocked,
    );
    for (final path in ['/docs/a', '/about', '/about?q=1']) {
      expect(
        LinkSecurity.checkUrl('https://example.com$path', custom),
        LinkRiskLevel.trusted,
      );
    }
    expect(
      LinkSecurity.checkUrl('https://example.com/about-us', custom),
      LinkRiskLevel.normal,
    );
  });
}
