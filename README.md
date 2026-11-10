# FluxDO NodeLoc

基于 [Lingyan000/FluxDO](https://github.com/Lingyan000/fluxdo) 的 [NodeLoc](https://www.nodeloc.com/) 非官方客户端。与 NodeLoc 官方及上游作者无分发隶属关系。

本阶段唯一交付目标为 **Android 9（API 28）及以上、arm64-v8a**。其他平台源码保留，退出本阶段构建、验收与发布。当前仍需完成真实账号、真机系统集成及正式签名候选验收；迁移分支与 Actions debug APK 不代表正式发行版。

## 构建与下载

默认分支为 NodeLoc，本轮交付分支为 fifth。使用 Flutter 3.47.4 / Dart 3.13.3、JDK 21、SDK 36、NDK 28.2.13676358、Rust 1.99.1、cargo-ndk 4.1.2。宿主还需 CMake、OpenSSL，并安装 aarch64-linux-android Rust target。

```bash
git clone --recursive --branch fifth https://github.com/buzhidao10068/fluxdo.git
cd fluxdo
flutter pub get
dart tool/flutterw.dart build apk --debug --target-platform android-arm64 --dart-define=cronetHttpNoPlay=true
```

包装入口统一生成本地化、CA 资源和启用 ECH 的 Rust 库。APK 位于 build/app/outputs/flutter-apk/。CI 验证产物见 [Android Delivery](https://github.com/buzhidao10068/fluxdo/actions/workflows/build.yaml)，选取对应提交下载 artifacts。工作流不会自动创建 Release。

正式签名与核验步骤见 [Android 构建与候选验收](docs/release.md)。HTTPS App Links 暂未启用，浏览器授权及两版共存回调仍需真机验收。NodeLoc 实机截图待补，见 [截图说明](screenshots/README.md)。

## 功能与技术

- 浏览、搜索、回复、Markdown 编辑、书签、历史与通知。
- 图片及媒体上传按 NodeLoc 动态站点限额和权限处理。
- Material Design 3、深色模式、图片缓存及 HTML 分块渲染。
- Flutter、Riverpod、Dio、Rust DOH/ECH 代理。

保留的登录入口及原生交互必须取得实际设备结果后才可宣称通过。P5 扩展功能另行排期。

## 文档与反馈

- [开发环境与日常命令](docs/development.md)（含保留的历史平台命令，当前支持范围以本页为准）
- [Android 构建与候选验收](docs/release.md)
- [Android 交付推进计划](DeepSeek%20Harness/docs/5.1步骤：Android交付与实机验收.md)
- [问题反馈](https://github.com/buzhidao10068/fluxdo/issues)

## 来源与许可

感谢 Lingyan000/FluxDO 及其贡献者提供上游实现，感谢 NodeLoc 社区。本项目保留原作者版权，遵循 [GPL-3.0](LICENSE)。不使用 NodeLoc 官方应用标识或官方图标。
