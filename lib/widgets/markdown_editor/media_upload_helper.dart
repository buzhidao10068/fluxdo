/// 音视频上传公共链路：先检查站点附件大小，优先使用原始扩展名上传，
/// 仅在站点只允许 `.xz` 而不允许原扩展名时保留历史改名兼容路径。
/// 上传后生成 `<audio>/<video>` HTML 标签文本插入 raw。
///
/// 播放兼容:标签 `type` 写原文件真实 MIME(网页端浏览器/本 app
/// AVFoundation 按它选解码器);`src` 使用保留服务端扩展名的站内短链路径，
/// 由 Rails 动态路由跳转到真实存储，避免 CDN 域名下的 404。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../services/uploads/upload_progress.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart' show lookupMimeType;

import '../../utils/app_directories.dart';

import 'package:m3e_ui/m3e_ui.dart';

import '../../services/app_error_handler.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/media_transcoder/media_compressor.dart';
import '../../services/media_transcoder/media_transcoder.dart';
import '../../services/preloaded_data_service.dart';
import '../../services/uploads/media_upload_limits.dart';
import '../../l10n/s.dart';

/// 站点允许上传的扩展名 —— 从 preloaded siteSettings 的
/// `authorized_extensions`(staff 追加 `authorized_extensions_for_staff`)
/// 动态派生,与网页端 `lib/uploads.js` 的 authorizedExtensions 同口径:
/// 小写、剥空白与点、按 `|` 拆、滤掉带 `*` 的通配项。
///
/// 返回 null = 不设限(任一名单含 `*`,官方 authorizesAllExtensions
/// 同款判定;或 siteSettings 未加载 —— 此时让服务端裁决,好过拿一份
/// 写死的列表两头错:站点允许的选不了、列表里有的选完照样 422)。
List<String>? attachmentAllowedExtensions() {
  final preloaded = PreloadedDataService();
  final base = preloaded.siteSettingsSync?['authorized_extensions'] as String?;
  if (base == null) return null;
  final user = preloaded.currentUserSync;
  final isStaff = user?['admin'] == true || user?['moderator'] == true;
  final staffExtra = isStaff
      ? (preloaded.siteSettingsSync?['authorized_extensions_for_staff']
            as String?)
      : null;

  if (base.contains('*') || (staffExtra?.contains('*') ?? false)) {
    return null;
  }
  final exts = {
    ..._extensionsToList(base),
    if (staffExtra != null) ..._extensionsToList(staffExtra),
  }.toList();
  return exts;
}

List<String> _extensionsToList(String raw) => raw
    .toLowerCase()
    .replaceAll(RegExp(r'[\s.]+'), '')
    .split('|')
    .where((ext) => ext.isNotEmpty && !ext.contains('*'))
    .toList();

/// 保留服务端返回的扩展名，兼容普通媒体和历史 `.xz` 短链。
String mediaShortUrlToPath(String shortUrl) {
  if (shortUrl.startsWith('upload://')) {
    final token = shortUrl.substring('upload://'.length);
    return '/uploads/short-url/$token';
  }
  return shortUrl;
}

/// 未加载设置、通配符、原扩展名已获准时均原名上传。
/// NodeLoc 不允许 `.xz`，因此不再为未授权扩展名强制改名。
bool shouldUploadMediaAsXz(String filename) {
  final allowed = attachmentAllowedExtensions();
  if (allowed == null || !allowed.contains('xz')) return false;
  final name = filename.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return !allowed.contains(ext);
}

/// 生成插入 raw 的媒体 HTML 标签。[voice] = 语音消息(包 `[wrap=voice]`
/// 壳,本 app 渲染语音条,网页端无样式影响)。
String buildMediaTag({
  required bool isAudio,
  required String srcPath,
  required String mime,
  bool voice = false,
}) {
  if (isAudio) {
    final tag =
        '<audio controls>\n  <source src="$srcPath" type="$mime">\n</audio>';
    return voice ? '[wrap=voice]\n$tag\n[/wrap]' : tag;
  }
  return '<video width="640" height="360" controls>\n'
      '  <source src="$srcPath" type="$mime">\n'
      '</video>';
}

/// 准备与上传分离，失败重试只重传处理后的文件，不重新压缩。
class PreparedMediaUpload {
  const PreparedMediaUpload({
    required this.path,
    required this.name,
    required this.isAudio,
    required this.voice,
  });
  final String path;
  final String name;
  final bool isAudio;
  final bool voice;

  Future<UploadResult> execute(
    CancelToken cancelToken,
    UploadProgressCallback onProgress,
  ) => _uploadMedia(
    path,
    name: name,
    isAudio: isAudio,
    cancelToken: cancelToken,
    onProgress: onProgress,
  );

  String markdown(UploadResult result) => buildMediaTag(
    isAudio: isAudio,
    voice: voice,
    srcPath: mediaShortUrlToPath(result.shortUrl),
    mime: lookupMimeType(name) ?? (isAudio ? 'audio/mpeg' : 'video/mp4'),
  );
}

Future<UploadResult> _uploadMedia(
  String path, {
  required String name,
  required bool isAudio,
  CancelToken? cancelToken,
  UploadProgressCallback? onProgress,
}) async {
  // 必须先读取设置，不能在冷启动时因同步缓存尚未加载而误判上传策略。
  await waitForUpload(PreloadedDataService().getSiteSettings(), cancelToken);
  if (shouldUploadMediaAsXz(name)) {
    return DiscourseService().uploadMediaAsXz(
      path,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }
  final mime = lookupMimeType(name) ?? (isAudio ? 'audio/mpeg' : 'video/mp4');
  return DiscourseService().uploadMedia(
    path,
    filename: name,
    contentType: DioMediaType.parse(mime),
    cancelToken: cancelToken,
    onProgress: onProgress,
  );
}

Future<PreparedMediaUpload?> prepareMediaUpload(
  BuildContext context, {
  required String path,
  required String name,
  required bool isAudio,
  bool voice = false,
}) async {
  final size = await File(path).length();
  final maxBytes = await MediaUploadLimits.load();
  if (!context.mounted) return null;
  var preparedPath = path;
  var preparedName = name;
  if (maxBytes != null && size >= maxBytes) {
    final compressed = await compressMediaWithDialog(
      context,
      path: path,
      isAudio: isAudio,
      voice: voice,
      maxBytes: maxBytes,
    );
    if (compressed == null || !context.mounted) return null;
    preparedPath = compressed;
    preparedName = compressed.split(RegExp(r'[/\\]')).last;
  }
  return PreparedMediaUpload(
    path: preparedPath,
    name: preparedName,
    isAudio: isAudio,
    voice: voice,
  );
}

/// 已有本地媒体文件 → 上传 → 标签文本。失败弹 SnackBar 并返回 null
/// (站点大小超限时先提示压缩，服务端仍执行最终校验)。
Future<String?> uploadMediaFileAsTag(
  BuildContext context, {
  required String path,
  required String name,
  required bool isAudio,
  bool voice = false,
}) async {
  try {
    var uploadPath = path;
    var uploadName = name;
    // 超站点上限先压缩(原生转码,进度对话框可取消);压缩产物换用
    // 新文件名算 MIME(m4a/mp4)。取消/失败返回 null(已提示)。
    final size = await File(path).length();
    final maxBytes = await MediaUploadLimits.load();
    if (maxBytes != null && size >= maxBytes) {
      if (!context.mounted) return null;
      final compressed = await compressMediaWithDialog(
        context,
        path: path,
        isAudio: isAudio,
        maxBytes: maxBytes,
        voice: voice,
      );
      if (compressed == null) return null;
      uploadPath = compressed;
      uploadName = compressed.split(Platform.pathSeparator).last;
    }
    final mime =
        lookupMimeType(uploadName) ?? (isAudio ? 'audio/mpeg' : 'video/mp4');
    final result = await _uploadMedia(
      uploadPath,
      name: uploadName,
      isAudio: isAudio,
    );
    return buildMediaTag(
      isAudio: isAudio,
      srcPath: mediaShortUrlToPath(result.shortUrl),
      mime: mime,
      voice: voice,
    );
  } catch (e, s) {
    if (context.mounted) {
      final msg = e is Exception
          ? e.toString().replaceFirst('Exception: ', '')
          : '媒体上传失败';
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(msg)));
    } else {
      AppErrorHandler.handleUnexpected(e, s);
    }
    return null;
  }
}

/// 选择音/视频文件并上传,返回标签文本;取消/失败返回 null。
Future<String?> pickAndUploadMediaTag(
  BuildContext context, {
  required bool isAudio,
}) async {
  final picked = await FilePicker.platform.pickFiles(
    type: isAudio ? FileType.audio : FileType.video,
  );
  final file = picked?.files.single;
  final path = file?.path;
  if (file == null || path == null || !context.mounted) return null;
  return uploadMediaFileAsTag(
    context,
    path: path,
    name: file.name,
    isAudio: isAudio,
  );
}

/// 超限媒体压缩(模态进度对话框,可取消)。返回压缩后文件路径;
/// null = 取消 / 失败 / 平台不支持(失败已 SnackBar 提示)。
Future<String?> compressMediaWithDialog(
  BuildContext context, {
  required String path,
  required bool isAudio,
  required int maxBytes,
  bool voice = false,
}) async {
  final transcoder = MediaTranscoder.forCurrentPlatform();
  if (transcoder == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '当前平台不支持压缩，请压到 ${(maxBytes / 1048576).toStringAsFixed(1)} MiB 内再上传',
        ),
      ),
    );
    return null;
  }
  var mode = MediaCompressionMode.compatible;
  if (!isAudio) {
    final selected = await showDialog<MediaCompressionMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(dialogContext.l10n.mediaPlayer_compressionMode),
        children: [
          for (final option in MediaCompressionMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, option),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (option) {
                      MediaCompressionMode.compatible =>
                        dialogContext.l10n.mediaPlayer_compressionCompatible,
                      MediaCompressionMode.screen =>
                        dialogContext.l10n.mediaPlayer_compressionScreen,
                      MediaCompressionMode.efficient =>
                        dialogContext.l10n.mediaPlayer_compressionEfficient,
                    }),
                    Text(switch (option) {
                      MediaCompressionMode.compatible =>
                        dialogContext
                            .l10n
                            .mediaPlayer_compressionCompatibleHint,
                      MediaCompressionMode.screen =>
                        dialogContext.l10n.mediaPlayer_compressionScreenHint,
                      MediaCompressionMode.efficient =>
                        dialogContext.l10n.mediaPlayer_compressionEfficientHint,
                    }, style: Theme.of(dialogContext).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return null;
    mode = selected;
  }
  final tempDir = await getAppTemporaryDirectory();
  if (!context.mounted) return null;

  final cancellation = MediaCompressionCancellation();
  final status = ValueNotifier<String>('准备压缩…');
  final resultFuture = compressMediaToFit(
    transcoder,
    path,
    isAudio: isAudio,
    outputDir: tempDir.path,
    maxBytes: maxBytes,
    voice: voice,
    mode: mode,
    cancellation: cancellation,
    onStatus: (s) => status.value = s,
  );

  final result = await showDialog<CompressResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => _CompressProgressDialog(
      transcoder: transcoder,
      cancellation: cancellation,
      status: status,
      resultFuture: resultFuture,
    ),
  );
  // 意外关闭时等待任务结束后再释放状态，避免迟到进度写入已销毁 notifier。
  final r = result ?? await resultFuture;
  status.dispose();
  if (r.isOk) return r.path;
  if (!r.cancelled && r.error != null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(r.error!)));
  }
  return null;
}

class _CompressProgressDialog extends StatefulWidget {
  const _CompressProgressDialog({
    required this.transcoder,
    required this.cancellation,
    required this.status,
    required this.resultFuture,
  });

  final MediaTranscoder transcoder;
  final MediaCompressionCancellation cancellation;
  final ValueNotifier<String> status;
  final Future<CompressResult> resultFuture;

  @override
  State<_CompressProgressDialog> createState() =>
      _CompressProgressDialogState();
}

class _CompressProgressDialogState extends State<_CompressProgressDialog> {
  Timer? _timer;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        final p = await widget.transcoder.progress();
        if (mounted) setState(() => _progress = p);
      } catch (_) {
        // 进度查询失败不应中断实际转码任务。
      }
    });
    widget.resultFuture.then((r) {
      if (mounted) Navigator.of(context).pop(r);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('压缩媒体'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: widget.status,
            builder: (_, s, _) => Align(
              alignment: Alignment.centerLeft,
              child: Text(s, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          const SizedBox(height: 12),
          M3eLinearProgress(
            value: _progress <= 0 ? null : _progress.clamp(0.0, 1.0),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            widget.cancellation.cancel();
            try {
              await widget.transcoder.cancel();
            } catch (_) {}
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}
