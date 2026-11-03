# FluxDO 站点耦合审计：哪些是 linux.do 专用，哪些是通用 Discourse 代码

> 速查表，给接手"换站改造"的 AI / 开发者看。基准：`0.2.29`（2026-10-20）。
> 数据来源：全仓 grep + 关键文件人工核对，非猜测。

## 0. 一句话结论

FluxDO ≈ **通用 Discourse 客户端（约 95% 代码与站点无关）** + **一层薄的 linux.do 站点层**。

站点层只有四块：

1. 一份站点配置 `lib/config/sites/linuxdo.dart`
2. 一个地址常量 `AppConstants.baseUrl`
3. 三个 linux.do 自建外挂服务（`connect` / `credit` / `cdk`）及其 UI
4. 品牌与文案

把这三样换掉，主体功能（浏览/发帖/回复/搜索/通知/私信/聊天/图片/媒体）就能直接跑。

---

## 1. 分级图例

| 级别 | 含义 | 改造动作 |
|---|---|---|
| **L0 通用** | 任何 Discourse 站点都能用 | **不要动** |
| **L1 配置化** | 逻辑通用，只是域名/数值/文案写死 | 改配置或派生自 `baseUrl` |
| **L2 站点硬编码** | 逻辑或数据只对 linux.do 成立 | 必须改 / 删 / 重写 |
| **L3 品牌发布** | 与站点功能无关，但分发前必须替换 | 替换品牌资源 |

---

## 2. 站点抽象层（框架本体）

| 文件 | 级别 | 说明 |
|---|---|---|
| `lib/config/site_customization.dart` | **L0** | `SiteCustomization` / `LinkSecurityConfig` / `AvatarGlowRule` / `UserTitleStyleRule` 模型，纯通用 |
| `lib/config/sites/linuxdo.dart` | **L1** | 站点数据：头像光晕（`g-merchant`、`neo`）、头衔特效（`种子用户`、`Premium`）、链接安全域名表、插件清单。**照抄一份 `nodeloc.dart` 改数据即可** |
| `lib/plugins/plugin_registry.dart` | **L0 框架 + L1 硬引用** | 框架通用，但第 3/9/21 行硬引用 `linuxdoCustomization`，需改成可注入 |
| `lib/plugins/site_plugin.dart`、`plugin_context.dart`、`topic_plugin_data.dart`、`plugins.dart` | **L0** | 插件接口与上下文，仅注释提到 linux.do |

> 目录名是复数 `sites/`，**说明上游已预留多站点设计**，改造方向与架构一致。

---

## 3. 一行就能改的开关

```dart
// lib/constants.dart:14
static final SiteCustomization siteCustomization = linuxdoCustomization;

// lib/constants.dart:300-301
/// linux.do 域名
static const String baseUrl = 'https://linux.do';
```

注意：这两个是**编译期常量**（`const` / `static final`），不是运行时开关。要做多站点切换需提升为注入式。

---

## 4. linux.do 独有外挂服务（L2，NodeLoc 没有 → 整块删）

### 4.1 `connect.linux.do` —— 信任等级周期统计（HTML 爬取）

| 文件 | 说明 |
|---|---|
| `lib/models/connect_stats.dart` | 从 connect 页 HTML 解析 `.tl3-ring` 的 CSS `--val` |
| `lib/providers/directory_providers.dart` | `dio.get('https://connect.linux.do/')` |
| `lib/pages/trust_level_requirements_page.dart` | 信任等级要求页（同样爬 HTML） |
| `lib/models/profile_stats_config.dart` | `connect` 枚举值 = 该统计 |
| `lib/widgets/profile_stats_card.dart`、`lib/pages/profile_stats_edit_page.dart` | 个人页统计卡 |

> 不是 Discourse 标准 API，**没有等价替换物**，只能删或另找数据源。

### 4.2 `credit.linux.do` —— LDX 积分 / 打赏

| 文件 | 说明 |
|---|---|
| `lib/services/ldc_oauth_service.dart` | OAuth 授权（`baseUrl = https://credit.linux.do`） |
| `lib/providers/ldc_providers.dart` | 余额/用户信息 provider |
| `lib/models/ldc_user_info.dart` | 余额字段模型 |
| `lib/widgets/ldc_balance_card.dart` | 余额卡（`credit.linux.do/home`） |
| `lib/modules/ldc_reward/**`（8 个文件） | **打赏功能整套**：`ldc_reward_service`（`credit.linux.do/epay/pay/distribute`）、凭证存储、配置页、打赏面板 |

### 4.3 `cdk.linux.do` —— CDK 兑换

| 文件 | 说明 |
|---|---|
| `lib/services/cdk_oauth_service.dart` | OAuth 授权（`baseUrl = https://cdk.linux.do`） |
| `lib/providers/cdk_providers.dart` | provider |
| `lib/widgets/cdk_balance_card.dart` | 余额卡（`cdk.linux.do/dashboard`） |

### 4.4 聚合入口

| 文件 | 说明 |
|---|---|
| `lib/pages/metaverse_page.dart` | "多元宇宙"页 = LDX 余额 + CDK 余额 + 打赏入口。由 `lib/pages/profile_page.dart:878` 进入 |

### 4.5 OAuth 通用辅助（可留可删）

| 文件 | 说明 |
|---|---|
| `lib/services/oauth_flow_helper.dart` | 给 OAuth 相邻请求插随机延迟，避免被反爬识别（注释记录了踩坑历史） |
| `lib/services/oauth_session_client.dart` | OAuth 会话 Dio |

> 这两个是"linux.do 系 OAuth 链路"的产物；如果新站没有自建 OAuth 服务，**整套一起删**最省事。

---

## 5. 登录与反爬（L2，最容易卡住的区域）

| 文件 | 级别 | 关键点 |
|---|---|---|
| `lib/pages/login_page.dart:39` | **L2 必改** | `_kLinuxDoHcaptchaSiteKey = 'a776b4ac-...'` —— **linux.do 的 hCaptcha sitekey 写死在代码里** |
| `lib/pages/login_page.dart:431` | L1 | 找回密码走 `https://linux.do/password-reset` |
| `lib/services/discourse/_login.dart` | **L0** | 原生用户名/密码登录流程，Discourse 通用 |
| `lib/widgets/auth/webview_login_dialog.dart` | **L1/L2** | 内嵌登录页的 document origin 必须是站点域（多处 `baseUrl=linux.do` 逻辑），换站要跟着换 |
| `lib/services/user_api_key_login_flow.dart`、`user_api_key_service.dart` | **L2** | scopes 按 linux.do 收窄成 `one_time_password`，注释明确"linux.do 现配置" |
| `lib/services/cf_challenge_service.dart`、`cf_clearance_refresh_service.dart`、`cf_clearance_authority.dart`、`cf_challenge_logger.dart` | **L2 需重调** | Cloudflare 挑战/clearance 维护。逻辑通用，但阈值与流程按 linux.do 现配置调过 |
| `lib/services/browser_trust_coordinator.dart` | L2 | 浏览器信任/会话协调 |
| `lib/services/webview_session_cookie_refresh_service.dart:61` | **L2** | 会话 bootstrap 脚本来自 linux.do 的 fingerprint 插件 |
| `lib/services/eruda_settings_service.dart` | L0 | 调试面板开关，通用 |

---

## 6. 网络层里的域名硬编码（L1 为主，改起来最碎）

| 文件 | 行 | 内容 | 级别 |
|---|---|---|---|
| `lib/services/network/doh/ech_dns_policy.dart` | 6 | `builtinDomains = ['linux.do', 'ldstatic.com']` | L1 |
| `lib/services/network/doh/network_settings_service.dart` | 1376-1380 | 预置域名 `connect/ping/cdn/credit/cdk.linux.do` | L1 |
| `lib/services/network/cookie/app_cookie_manager.dart` | 455 | `if (host == 'connect.linux.do')` 注入认证 cookie 特判 | **L2** |
| `lib/services/network/cookie/cookie_jar_service.dart` | 53/119/129 | 注释与逻辑围绕 `linux.do` / 子域 cookie 归置 | L1 |
| `lib/services/network/cookie/session_cookie_sentinel.dart` | 565 | 公共后缀处理，注释说明"实际场景为 linux.do" | L1 |
| `lib/services/network/cookie/cookie_devtools_extension.dart` | 305 | 默认 URL `https://linux.do` | L1 |
| `lib/services/network/cookie/raw_cookie_writer.dart`、`webview_cookie_priming.dart`、`boundary_sync_*` | — | cookie 写入/预热/边界同步，逻辑通用 | L0/L1 |
| `lib/services/network/adapters/platform_adapter.dart` | 428 | WebView fetch 运行在 `linux.do` origin | L2 |
| `lib/services/network/recovery/*` | — | `retry_after` 按 Discourse 行为补齐 | L0 |
| `lib/services/dio_http_client.dart` | 17/101-109 | **主域/子域判定已从 `baseUrl` 派生** | **L1 半自动** |
| `lib/services/preloaded_data_service.dart` | 45-46/377-389 | MessageBus / CDN / S3 域名从 preload 拿 | **L0 通用** |

---

## 7. 散落在 UI 层的站点行为定制（L2）

| 文件 | 位置 | 内容 |
|---|---|---|
| `lib/widgets/common/smart_avatar.dart` | 35 | 账号 `neo` 头像方形化（复刻 linux.do 主题 CSS `border-radius:10%`） |
| `lib/widgets/topic/painted_topic_card.dart` | 285 | 同上，但走画布直绘分支 |
| `lib/pages/user_profile_page.dart` | 2229 | 同上，个人页 |
| `lib/config/sites/linuxdo.dart` | 10-32 | 头像光晕（`g-merchant`/`neo`）、`种子用户`/`Premium` 全息文字 |
| `lib/services/ai_post_review_service.dart` | 83/161/209 | `guidelinesUrl = 'https://linux.do/guidelines'`，prompt 里写死"你是 Linux.do 社区发帖前的本地 AI 审核助手" |
| `lib/services/clipboard_topic_link_service.dart` | 170 | host 判定 `linux.do` / `www.linux.do` |
| `lib/services/deep_link_service.dart` | 149-274 | `_isLinuxDoHost()`：`linux.do` / `www.linux.do` / `*.linux.do` |
| `lib/pages/profile_page.dart` | 341 | 跳 `linux.do/u/{username}/preferences/account` |
| `lib/services/discourse/_uploads.dart` | 426 | 上传体积上限按 linux.do 的 4MB |
| `lib/pages/create_topic_page.dart` | 540 | 未分类话题放行策略，注释说明"linux.do 属于后者" |
| `lib/pages/search_page.dart` | 35 | 站内直达链接标准化（`linux.do/...` → 完整 URL） |
| `lib/services/media_compat_service.dart` | 17 | 扩展名白名单导致用户改后缀（通用现象，逻辑通用） |
| `lib/utils/webm_opus_to_caf.dart` | 6-10 | `.xz` 装音频的实测结论（逻辑通用） |

---

## 8. 插件系统：框架通用，插件本身是 linux.do 的

| 文件 | 级别 | 对应 Discourse 插件 |
|---|---|---|
| `lib/plugins/reply_cost/reply_cost_plugin.dart` | **L2** | `discourse-reply-cost`（回复扣积分） |
| `lib/plugins/warden/warden_plugin.dart` | **L2** | `discourse-warden`（按分类改写最小字数） |
| `lib/plugins/character_counts/character_counts_plugin.dart` | **L2** | `character-counts` 主题组件（字数不足提示） |

> 三个插件只在 `linuxdo.dart` 的 `plugins:` 列表里注册。新站没装对应服务端插件就**不要注册**，否则回复前校验会误判。
> 相关字段：`reply_cost`（话题级）、`premium_min_post_length`（分类级），见 `lib/plugins/plugin_context.dart:14/70`、`lib/services/composer_min_length_resolver.dart:12/49`。

---

## 9. 文案（L3，共 4 套语言 × 6 个模块）

`lib/l10n/modules/*/*.arb`（en / zh / zh_HK / zh_TW）：

| 模块 | 文案键 | 内容 |
|---|---|---|
| `aboutUpdate` | `about_legalese` | "非官方 Linux.do 客户端" |
| `auth` | `auth_cdkConfirmMessage`、`auth_ldcConfirmMessage` | "Linux.do CDK / Credit 将获取你的基本信息" |
| `invite` | `invite_shareSubject` | "Linux.do 邀请链接" |
| `proxy` | `httpProxy_testingProxy` | "正在验证是否能通过当前代理访问 linux.do" |
| `reward` | `reward_configHint` | "请输入在 credit.linux.do 申请的凭证" |
| `settings` | `preferences_clipboardTopicLinkDetectionDesc`、`preferences_blockedUsernamesDesc` | 剪贴板检测 Linux.do 链接；名单不同步到 Linux.do |
| `user` | `profile_loginLinuxDo` | "登录 LINUX.DO" |
| `metaverse` | 整模块 | LDX/CDK 余额与打赏文案 |

---

## 10. 平台与打包（L3，纯品牌）

| 位置 | 内容 |
|---|---|
| `android/app/src/main/AndroidManifest.xml:56-93` | App Links：`https://linux.do/t/`、`/u/`、`/session/email-login/` |
| `android/app/build.gradle.kts` | `applicationId = com.github.lingyan000.fluxdo`、`namespace` 同 |
| `android/.../kotlin/com/github/lingyan000/fluxdo/*.kt` | 包名目录 |
| `ios/Runner.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER = com.github.lingyan000.fluxdo` |
| `ios/Runner/Info.plist` | `fluxdo` URL scheme、`com.fluxdo.app`、`com.fluxdo.notificationPoll` |
| `macos/Runner/Configs/AppInfo.xcconfig` | `PRODUCT_NAME = fluxdo`、bundle id |
| `windows/CMakeLists.txt`、`windows/runner/main.cpp` | `BINARY_NAME = fluxdo`、`fluxdo://` 深链转发 |
| `linux/runner/fluxdo.desktop` | `Comment=Linux.do 客户端` |
| `flatpak/com.github.lingyan000.fluxdo.*` | `.desktop` / `.metainfo.xml` 写"Linux.do client" |
| `altstore/source.json` | AltStore 源 |
| `release_telegram.py`、`cliff.toml` | 发版脚本 / changelog 生成 |
| `screenshots/`、`README.md`、`CHANGELOG.md` | 展示与文档 |

> 深链双 scheme：`discourse://auth_redirect`（Discourse 标准 OAuth 回调）+ `fluxdo://`（自有）。换站时 `fluxdo` 前缀建议一并改，避免与官方客户端抢 scheme。

---

## 11. 完全通用、可以放心的部分（L0）

这些是项目的主体，**换站不用碰**：

- `lib/services/discourse/**` —— Discourse REST API 封装（`discourse_service.dart` 注释写"Linux.do API 服务"但实现是标准 API）
- `lib/services/cook/**` —— Discourse 官方 markdown-it cook bundle
- `lib/services/discourse_cook_service.dart`、`html_parse_service.dart`
- `packages/fluxdo_render/**` —— 自研 HTML/编辑器渲染引擎
- `lib/providers/message_bus/**` —— Discourse MessageBus 长轮询
- `lib/pages/chat/**` —— **Discourse Chat 插件**（NodeLoc 已启用该插件）
- `lib/models/**` —— 除 `connect_stats` / `ldc_user_info` / `profile_stats_config` 外全部通用
- `lib/pages/**`、`lib/widgets/**`、`lib/providers/**` —— 绝大多数通用（上表点名者除外）
- `lib/services/network/doh/**` + `core/doh_proxy/**`（Rust）—— DNS over HTTPS + ECH，与站点无关
- `lib/utils/time_utils.dart` 等工具层
- `packages/` 下 9 个本地包（`common_ui`、`m3e_ui`、`app_icons`、`pangutext`、`paper_shaders`、`ai_model_manager`、`enhanced_cookie_jar`、`extended_image_lite`）

---

## 12. 改造顺序建议

1. **先验证登录**（最大不确定性）：摸清目标站是否有 Turnstile / Bot-sentry / CF 拦截，决定走密码登录、WebView 登录还是 User API Key
2. `lib/constants.dart` 换 `baseUrl`，新建 `lib/config/sites/nodeloc.dart`（插件列表先留空）
3. 摘掉 §4 全部外挂服务（connect / credit / cdk / metaverse / ldc_reward），清理 `profile_page` 与导航入口
4. 换 §5 的 hCaptcha sitekey、`user_api_key` scopes、CF 相关阈值
5. 处理 §6 域名硬编码（`ech_dns_policy`、`network_settings_service`、`app_cookie_manager` 特判）
6. 处理 §7 的 UI 定制（`neo` 头像、`种子用户` 特效、AI 审核 prompt）
7. 最后做 §9/§10 品牌与文案替换

**风险提示**：直接把 linux.do 代码删掉会让上游同步（`upstream` 节流极快）变成灾难。更稳的做法是把 linux.do 保留为 `sites/linuxdo.dart` 的一个 profile，新站新增 profile，通过"按站点启用/禁用"来隔离。

---

## 附录：检索命令

```bash
# lib 内 linux.do 字面量：166 处，92 个文件（含注释）
grep -rn "linux\.do\|Linux\.do\|linuxdo" lib --include=*.dart | wc -l

# 外挂服务
grep -rn "connect\.linux\.do\|credit\.linux\.do\|cdk\.linux\.do" lib

# 站点标识符
grep -rln "ldc\|ldx\|cdk\|metaverse\|connectStats" lib

# 平台/打包层
grep -rn "linux\.do" android ios macos windows linux flatpak altstore test
```
