/// NodeLoc 原扩展名上传及历史媒体兼容策略。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/markdown_editor/media_upload_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final preloaded = PreloadedDataService();
  tearDown(() => preloaded.debugSeed());

  test('服务端短链保留实际扩展名，直链和查询参数保持完整', () {
    expect(
      mediaShortUrlToPath('upload://lwDn83PDeB3xOUoEeZI9v77qGJa.mp4'),
      '/uploads/short-url/lwDn83PDeB3xOUoEeZI9v77qGJa.mp4',
    );
    expect(mediaShortUrlToPath('upload://abc'), '/uploads/short-url/abc');
    expect(mediaShortUrlToPath('upload://old.xz'), '/uploads/short-url/old.xz');
    const direct = 'https://cdn.example.com/a.mp3?token=123';
    expect(mediaShortUrlToPath(direct), direct);
    expect(
      mediaShortUrlToPath('/uploads/original/a.mp3'),
      '/uploads/original/a.mp3',
    );
  });

  test('NodeLoc 授权的媒体直接上传，不为未知格式强改 xz', () {
    preloaded.debugSeed(
      siteSettings: {
        'authorized_extensions':
            'jpg|heic|heif|avif|rar|7z|mp4|webm|m4a|mp3|flac',
      },
    );
    for (final name in [
      'clip.mp4',
      'clip.WEBM',
      r'C:\voice\audio.m4a',
      'unknown.xyz',
    ]) {
      expect(shouldUploadMediaAsXz(name), isFalse, reason: name);
    }
    expect(
      attachmentAllowedExtensions(),
      containsAll(['heic', 'heif', 'avif', 'rar', '7z']),
    );
  });

  test('旧站仅在 xz 获准且原格式未获准时改名', () {
    preloaded.debugSeed(siteSettings: {'authorized_extensions': 'jpg|mp4|xz'});
    expect(shouldUploadMediaAsXz('clip.mp4'), isFalse);
    expect(shouldUploadMediaAsXz('audio.m4a'), isTrue);
    expect(shouldUploadMediaAsXz('old.xz'), isFalse);
  });

  test('管理员扩展名单叠加，普通用户不可借用', () {
    const settings = {
      'authorized_extensions': ' .JPG | mp4 ',
      'authorized_extensions_for_staff': '.M4A|xz',
    };
    preloaded.debugSeed(
      currentUser: {'moderator': true},
      siteSettings: settings,
    );
    expect(attachmentAllowedExtensions(), ['jpg', 'mp4', 'm4a', 'xz']);
    expect(shouldUploadMediaAsXz('audio.m4a'), isFalse);
    expect(shouldUploadMediaAsXz('audio.wav'), isTrue);
    preloaded.debugSeed(currentUser: {}, siteSettings: settings);
    expect(attachmentAllowedExtensions(), ['jpg', 'mp4']);
    expect(shouldUploadMediaAsXz('audio.wav'), isFalse);
  });

  test('通配符、未加载和空名单均不强制改名', () {
    for (final settings in <Map<String, dynamic>?>[
      null,
      {'authorized_extensions': '*'},
      {'authorized_extensions': ''},
    ]) {
      preloaded.debugSeed(siteSettings: settings);
      expect(shouldUploadMediaAsXz('clip.mp4'), isFalse);
    }
    expect(attachmentAllowedExtensions(), isEmpty);
    preloaded.debugSeed(
      currentUser: {'admin': true},
      siteSettings: {
        'authorized_extensions': 'jpg',
        'authorized_extensions_for_staff': '*',
      },
    );
    expect(attachmentAllowedExtensions(), isNull);
  });

  test('准备后的文件名决定 MIME，服务端扩展名用于播放地址', () {
    const prepared = PreparedMediaUpload(
      path: '/tmp/compressed.m4a',
      name: 'compressed.m4a',
      isAudio: true,
      voice: true,
    );
    final markup = prepared.markdown(
      UploadResult(
        shortUrl: 'upload://abc.m4a',
        originalFilename: 'compressed.m4a',
      ),
    );
    expect(markup, contains('src="/uploads/short-url/abc.m4a"'));
    expect(markup, contains('type="audio/mp4"'));
    expect(markup, startsWith('[wrap=voice]'));
  });

  test('audio 标签形态(脚本 makeTag 同款)', () {
    expect(
      buildMediaTag(
        isAudio: true,
        srcPath: '/uploads/short-url/abc.xz',
        mime: 'audio/mpeg',
      ),
      '<audio controls>\n'
      '  <source src="/uploads/short-url/abc.xz" type="audio/mpeg">\n'
      '</audio>',
    );
  });

  test('语音消息包 [wrap=voice] 壳', () {
    final tag = buildMediaTag(
      isAudio: true,
      srcPath: '/uploads/short-url/abc.xz',
      mime: 'audio/mp4',
      voice: true,
    );
    expect(tag, startsWith('[wrap=voice]\n<audio controls>'));
    expect(tag, endsWith('[/wrap]'));
  });

  test('video 标签带默认宽高', () {
    final tag = buildMediaTag(
      isAudio: false,
      srcPath: '/uploads/short-url/xyz.xz',
      mime: 'video/mp4',
    );
    expect(tag, contains('<video width="640" height="360" controls>'));
    expect(
      tag,
      contains('<source src="/uploads/short-url/xyz.xz" type="video/mp4">'),
    );
  });
}
