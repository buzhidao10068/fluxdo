# Android 构建与候选交付

本阶段只交付 Android 9 / API 28 及以上的 arm64-v8a APK。其他平台源码保留，退出本阶段 CI、验收和发布。项目源自 [Lingyan000/FluxDO](https://github.com/Lingyan000/fluxdo)，遵循 GPL-3.0 许可。

## 从源码构建

默认分支为 `NodeLoc`，本轮交付分支为 `fifth`。使用递归检出，构建目录不得复制旧的原生库或 CA 材料：

```bash
git clone --recursive --branch fifth https://github.com/buzhidao10068/fluxdo.git
cd fluxdo
flutter pub get
dart tool/flutterw.dart build apk --debug --target-platform android-arm64 --dart-define=cronetHttpNoPlay=true
```

工具链固定为 Flutter 3.47.4 / Dart 3.13.3、JDK 21、Gradle 8.14、AGP 8.11.1、Kotlin 2.2.20、SDK 36、NDK 28.2.13676358、Rust 1.99.1 和 cargo-ndk 4.1.2。还需 CMake、OpenSSL 和 `aarch64-linux-android` Rust target。Windows 宿主需配置 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_NDK_HOME`，使用项目 SDK 的 `dart.bat` 执行入口。

包装入口会生成本地化与 CA，调用 cargo-ndk，以 API 28、ECH 特性和 `--locked` 编译，再暂存原生库和证书资源，最后构建 APK。Rust 子模块位于 `buzhidao10068/fluxdo_doh`，当前交付提交为 `d2e7f9033177a656bec812b6414aa8619a9f1aa7`。

在含非 ASCII 字符的路径中直接运行 Gradle 时，PowerShell 参数必须整体引用：`'-Pandroid.overridePathCheck=true'`。未经引用的参数会被 PowerShell 拆开，将 Gradle 的 `android` 扩展覆盖为字符串。也可以设置同名 Gradle project property 的环境变量。

## Android CI 与产物核验

Android Delivery 在 push / PR 时生成验证用 debug APK，先执行 Quality Gate 的静态分析、五组 Flutter 定向检查、Node 检查和 Rust 默认/ECH 测试。全量 Flutter 测试保存当前失败日志，继续作为非阻塞项；涉及 Android 核心链路和本次回归的失败仍须解决。流程不创建 Release 或发版标签。

GitHub 要求手动工作流存在于默认分支。本轮 `fifth` 可通过 push 构建；在工作流尚未进入 `NodeLoc` 时，不能宣称手动候选入口已可用。工作流进入默认分支后，手动选择 `candidate=true` 构建正式签名候选包。

产物包括 APK、release 符号、工具链与构建日志、子模块记录和 `apk-evidence.json`，在对应 Actions 运行的 artifacts 中保留 14 天。

```bash
python3 scripts/ci/android/verify_apk.py --apk build/app/outputs/flutter-apk/app-debug.apk --mode debug --sdk "$ANDROID_HOME" --output build/delivery/apk-evidence.json
```

核验脚本检查包名 `com.buzhidao10068.fluxdo`、pubspec 版本、min 28 / target 36、arm64 ELF、实际签名证书、Rust gitlink、ECH 编译指纹，以及 Rust 构建输出与 APK 中原生库的可装载内容。还检查嵌入式 CA、Flutter PEM 和 Android DER 资源一致性，并记录 APK SHA-256。AGP 会剥离调试节，因此原生库的文件哈希可能不同。

## 正式签名与可选配置

候选构建使用维护者自己的签名。CI 需要 secrets `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_PROPERTIES`（包含 `keyAlias`、`keyPassword`、`storePassword`），以及变量 `ANDROID_SIGNING_CERT_SHA256`。CI 使用临时 `storeFile`，构建结束后清理签名材料。

本机构建时准备被忽略的 `android/key.properties`，并设置 `ORG_GRADLE_PROJECT_requireReleaseSigning=true`：

```bash
dart tool/flutterw.dart build apk --release --target-platform android-arm64 --dart-define=cronetHttpNoPlay=true --split-debug-info=build/symbols
python3 scripts/ci/android/verify_apk.py --apk build/app/outputs/flutter-apk/app-release.apk --mode release --sdk "$ANDROID_HOME" --expected-cert "维护者证书SHA256" --output build/delivery/apk-evidence.json
```

普通 release 仍可能回退到 debug 签名，不能据此认定正式签名完成。候选 CI 强制要求正式签名配置，并在构建后核验预期证书摘要。

Firebase 默认关闭。启用时提供本 fork 自有的 `android/app/google-services.json`，设置 `ORG_GRADLE_PROJECT_enableFirebase=true`，并重新验证相关功能。当前 CI 验证的是关闭 Firebase 的构建。

HTTPS App Links 尚未启用，需要站方部署实际包名与证书对应的 `assetlinks.json` 后再验收。保留的 `fluxdo` / `discourse` scheme 需要验证两版共存时的回调归属。

## 设备验收与发布边界

debug 构建不能代替真实账号和真机验收。需覆盖登录、浏览、回复、上传、重启恢复、退出重登，以及安装升级、原版共存、回调、通知、权限、文件保存、分享、录音转码、DOH/ECH 与网络切换。Rust 停止确认只保证监听器已释放，已接受连接可能继续处理。

最终候选包需要维护者正式签名、目标设备验收记录和同一提交的产物证据。NodeLoc 真机截图待补，见 [截图说明](../screenshots/README.md)。本轮实际执行结果记录在 `DeepSeek Harness/docs/5.2复盘(5.1)：Android交付与实机验收.md`；未完成设备验收前不作公开发布结论。
