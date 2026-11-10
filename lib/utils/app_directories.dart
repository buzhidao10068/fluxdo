import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const appStorageNamespace = 'com.buzhidao10068.fluxdo';

bool get _needsNamespace => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

/// 桌面的 Documents/Temporary 不保证按应用隔离，统一增加 fork 子目录。
/// 移动端已有系统沙盒，保留既有路径；用户主动下载仍使用公共下载目录。
Future<Directory> _scope(Directory base) async {
  if (!_needsNamespace) return base;
  return Directory(p.join(base.path, appStorageNamespace))
      .create(recursive: true);
}

/// 内部持久数据根目录。旧公共目录归属不明，不自动读取、迁移或清理。
Future<Directory> getAppDataDirectory() async =>
    _scope(await getApplicationDocumentsDirectory());

/// 缓存、中转文件及迁移待删区必须共用此入口，限制清理范围。
Future<Directory> getAppTemporaryDirectory() async =>
    _scope(await getTemporaryDirectory());
