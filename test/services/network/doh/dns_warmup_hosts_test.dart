import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/network/doh/dns_warmup_hosts.dart';

void main() {
  test('无独立资源域时仅预热当前站点，不合成旧站生态主机', () {
    expect(collectDnsWarmupHosts(baseUrl: AppConstants.baseUrl), [
      'www.nodeloc.com',
    ]);
  });

  test('采纳服务端资源域，协议相对 URL、大小写、端口和重复地址统一处理', () {
    expect(
      collectDnsWarmupHosts(
        baseUrl: AppConstants.baseUrl,
        resourceUrls: [
          'https://www.nodeloc.com/message-bus/',
          '//CDN.example.com/assets',
          ' https://cdn.example.com:443/uploads ',
          'https://storage.example.com/bucket',
          'https://s3.example.com:8443/uploads',
        ],
      ),
      [
        'cdn.example.com',
        's3.example.com',
        'storage.example.com',
        'www.nodeloc.com',
      ],
    );
  });

  test('缺失、相对路径、非 HTTP 和非法资源地址不触发 DNS 预热', () {
    expect(
      collectDnsWarmupHosts(
        baseUrl: AppConstants.baseUrl,
        resourceUrls: [
          null,
          '',
          '   ',
          '/uploads/asset.png',
          'not a url',
          'https://',
          'https://[invalid',
          'file://local/path',
          'ftp://ftp.example.com/path',
        ],
      ),
      ['www.nodeloc.com'],
    );
  });
}
