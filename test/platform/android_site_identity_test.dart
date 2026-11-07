import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:xml/xml.dart';

const _androidNamespace = 'http://schemas.android.com/apk/res/android';

String? _androidAttribute(XmlElement element, String name) =>
    element.getAttribute(name, namespace: _androidNamespace);

void main() {
  final manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );
  final activity = manifest
      .findAllElements('activity')
      .singleWhere(
        (element) => _androidAttribute(element, 'name') == '.MainActivity',
      );
  final linkFilters = activity
      .findElements('intent-filter')
      .where(
        (filter) => filter
            .findElements('action')
            .any(
              (action) =>
                  _androidAttribute(action, 'name') ==
                  'android.intent.action.VIEW',
            ),
      );

  test('Android 深链由 app_links 处理，关闭 Flutter 默认路由处理', () {
    final metadata = activity
        .findElements('meta-data')
        .singleWhere(
          (element) =>
              _androidAttribute(element, 'name') ==
              'flutter_deeplinking_enabled',
        );
    expect(_androidAttribute(metadata, 'value'), 'false');
    expect(_androidAttribute(activity, 'exported'), 'true');
    expect(_androidAttribute(activity, 'launchMode'), 'singleTask');
  });

  test('Android 网页入口完整覆盖主域、裸域、协议及三类路径', () {
    final actual = <String>[];
    for (final filter in linkFilters) {
      for (final data in filter.findElements('data')) {
        final scheme = _androidAttribute(data, 'scheme');
        if (scheme != 'https' && scheme != 'http') continue;
        final host = _androidAttribute(data, 'host');
        final path = _androidAttribute(data, 'pathPrefix');
        actual.add('$scheme://$host$path');
        if (scheme == 'https') {
          expect(_androidAttribute(filter, 'autoVerify'), 'true');
        }
      }
    }

    final expected = [
      for (final host in [AppConstants.siteHost, AppConstants.siteRootDomain])
        for (final scheme in ['https', 'http'])
          for (final path in ['/t/', '/u/', '/session/email-login/'])
            '$scheme://$host$path',
    ];
    // 比较完整列表，同时防止漏声明、重复声明以及残留旧站或通配域。
    expect(actual, unorderedEquals(expected));
  });

  test('Android 自定义协议保留话题深链和 Discourse 授权回调', () {
    final schemes = [
      for (final filter in linkFilters)
        for (final data in filter.findElements('data'))
          if (!['http', 'https'].contains(_androidAttribute(data, 'scheme')))
            _androidAttribute(data, 'scheme'),
    ];
    expect(schemes, unorderedEquals(['fluxdo', 'discourse']));
  });

  test('所有 Android 深链入口均允许浏览器与系统分发', () {
    expect(linkFilters, isNotEmpty);
    for (final filter in linkFilters) {
      final categories = filter
          .findElements('category')
          .map((element) => _androidAttribute(element, 'name'));
      expect(
        categories,
        containsAll([
          'android.intent.category.DEFAULT',
          'android.intent.category.BROWSABLE',
        ]),
      );
    }
  });
}
