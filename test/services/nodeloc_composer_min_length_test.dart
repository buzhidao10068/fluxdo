import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/composer_min_length_resolver.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preloaded = PreloadedDataService();

  setUp(() async {
    final data = jsonEncode({
      'currentUser': {'id': 1, 'username': 'tester'},
      'siteSettings': {
        'min_post_length': 1,
        'min_first_post_length': 20,
        'min_personal_message_post_length': 3,
        'max_post_length': 99999,
      },
      'site': {'categories': []},
    });
    expect(
      await preloaded.hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">$data</script>',
      ),
      isTrue,
    );
  });
  tearDown(preloaded.reset);

  test('NodeLoc 普通回复使用 1 字下限', () async {
    expect(
      await ComposerMinLengthResolver.resolve(
        isFirstPost: false,
        isPrivateMessage: false,
      ),
      1,
    );
  });

  test('首帖和私信仍读取各自设置', () async {
    expect(
      await ComposerMinLengthResolver.resolve(
        isFirstPost: true,
        isPrivateMessage: false,
      ),
      20,
    );
    expect(
      await ComposerMinLengthResolver.resolve(
        isFirstPost: true,
        isPrivateMessage: true,
      ),
      3,
    );
  });
}
