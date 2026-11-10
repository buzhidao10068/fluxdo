import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/markdown_editor/media_upload_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = DiscourseService();
  final preloaded = PreloadedDataService();
  late Directory temp;
  late List<Interceptor> originalInterceptors;
  final uploaded = <MultipartFile>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('nodeloc_upload_');
    originalInterceptors = service.dio.interceptors.toList();
    final data = jsonEncode({
      'currentUser': {'id': 1, 'username': 'tester'},
      'site': {'categories': []},
      'siteSettings': {
        'max_attachment_size_kb': 15360,
        'authorized_extensions': 'mp4|m4a|webm|mp3',
        'enable_direct_s3_uploads': false,
      },
    });
    expect(
      await preloaded.hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">$data</script>',
      ),
      isTrue,
    );
    uploaded.clear();
    service.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/uploads.json');
            final file = (options.data as FormData).files.single.value;
            uploaded.add(file);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'short_url': 'upload://abc.${file.filename!.split('.').last}',
                },
              ),
            );
          },
        ),
      );
  });

  tearDown(() async {
    service.dio.interceptors
      ..clear()
      ..addAll(originalInterceptors);
    preloaded.reset();
    await temp.delete(recursive: true);
  });

  Future<File> media(int bytes) async {
    final file = File('${temp.path}/recording.webm');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(bytes);
    await handle.close();
    return file;
  }

  test('大于旧 4 MiB 的媒体以原文件名及真实 MIME 上传', () async {
    final file = await media(5 * 1024 * 1024);
    final prepared = PreparedMediaUpload(
      path: file.path,
      name: 'recording.webm',
      isAudio: false,
      voice: false,
    );
    final result = await prepared.execute(CancelToken(), (_) {});
    expect(uploaded.single.filename, 'recording.webm');
    expect(uploaded.single.contentType.toString(), 'video/webm');
    expect(result.originalFilename, 'recording.webm');
    expect(prepared.markdown(result), contains('/uploads/short-url/abc.webm'));
  });

  testWidgets('超过 NodeLoc 15 MiB 上限时在发送前拒绝', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.runAsync(() async {
      final file = await media(15 * 1024 * 1024 + 1);
      await expectLater(
        service.uploadMedia(file.path),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('媒体文件须小于'),
          ),
        ),
      );
    });
    expect(uploaded, isEmpty);
  });

  test('保留旧站显式 xz 上传入口', () async {
    final file = await media(32);
    final result = await service.uploadMediaAsXz(file.path);
    expect(uploaded.single.filename, 'recording.xz');
    expect(uploaded.single.contentType.toString(), 'application/x-xz');
    expect(result.shortUrl, 'upload://abc.xz');
  });
}
