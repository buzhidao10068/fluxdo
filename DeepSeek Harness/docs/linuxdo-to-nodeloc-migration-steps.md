# 将 linux.do 换成 www.nodeloc.com 的步骤与注意事项

> 依据：本目录两份文档
> - `linuxdo-coupling-audit.md`（静态代码耦合审计，基线 `0.2.29`）
> - `nodeloc-migration-assessment.md`（NodeLoc 实测迁移评估，探测时间 2026-11-02）
>
> 本文是两者的执行版汇总，行号基于 FluxDO `0.2.29`（2026-10-20），Flutter `3.47.4`。

---

## 一、总体判断（先看结论）

- **能改**。NodeLoc 是标准 Discourse（`2026.10.0-latest.1`），FluxDO 约 95% 代码与站点无关。
- **工作量主要是「删」而非「写」**：约 8000 行 Linux.do 专属代码可整体移除，无需等价重写。
- **比预期容易**：实测 NodeLoc 的 Cloudflare **不拦 API**、验证码同为 hCaptcha（换 sitekey 即可）、User API Key 授权路径完全开放 —— 这三项恰是 FluxDO 最复杂、最易卡住的部分。
- **架构上不要「fork 后硬改」**：应把站点差异提升为 `SiteProfile`（`lib/config/sites/linuxdo.dart` 保留 + 新增 `nodeloc.dart`），否则上游高速发版会导致同步灾难。

---

## 二、改造步骤（按优先级）

### 第 1 步：P0 站点身份（不改则无法运行）

| # | 位置 | 改动 |
|---|---|---|
| 1 | `lib/constants.dart:301` | `baseUrl = 'https://linux.do'` → `'https://www.nodeloc.com'`（**必须带 www**） |
| 2 | `lib/constants.dart:14` | `siteCustomization = linuxdoCustomization` → `nodelocCustomization` |
| 3 | `lib/config/sites/nodeloc.dart` | 新建（见第 3 步） |
| 4 | `android/app/src/main/AndroidManifest.xml:57-94` | 6 个 `linux.do` intent-filter 全换 |
| 5 | `ios/Runner/Runner.entitlements`、`macos/Runner/*.entitlements` | 关联域换 `www.nodeloc.com` |
| 6 | `apple/`、`web/` 下 AASA | 重新生成关联域文件 |
| 7 | `lib/services/deep_link_service.dart:149,272` | host 白名单加 `www.nodeloc.com` |
| 8 | `lib/services/clipboard_topic_link_service.dart:170` | 域名识别替换 |

> 注：`dio_http_client.dart` 的主域判定已从 `baseUrl` 派生（`_mainHost = Uri.parse(AppConstants.baseUrl).host`），改完 #1 即自动生效，无需改代码。

### 第 2 步：P3 删除 Linux.do 外挂生态（约 8000 行，消除崩溃点）

| # | 位置 | 处置 |
|---|---|---|
| 19 | `lib/services/ldc_oauth_service.dart` | 删（`credit.linux.do` 不存在） |
| 20 | `lib/services/cdk_oauth_service.dart` | 删（`cdk.linux.do` 不存在） |
| 21 | `lib/modules/ldc_reward/`（整个模块，8 文件） | 删（`credit.linux.do/epay/pay/distribute`） |
| 22 | `lib/widgets/ldc_balance_card.dart`（824 行） | 删 |
| 23 | `lib/widgets/cdk_balance_card.dart`（722 行） | 删 |
| 24 | `lib/models/connect_stats.dart` | 删（HTML 爬 `connect.linux.do`） |
| 25 | `lib/providers/directory_providers.dart`（19 行） | 删 |
| 26 | `lib/pages/trust_level_requirements_page.dart:45` | 删或改为纯本地计算 |
| 27 | `lib/models/profile_stats_config.dart:28` | 移除 `connect` 枚举分支 |
| 28 | `lib/pages/metaverse_page.dart` | 删「多元宇宙」页，并清理 `profile_page.dart:878` 入口 |
| 29 | `lib/services/network/cookie/app_cookie_manager.dart:455-469` | 移除 `connect.linux.do` 特判 |
| 30 | `lib/services/network/cookie/cookie_jar_service.dart:119` | 子域 cookie 归置注释与逻辑更新 |
| 31 | `lib/services/oauth_flow_helper.dart`、`oauth_session_client.dart` | 删（专为 connect.linux.do 的 CSRF 怪癖而写） |
| 32 | `lib/plugins/reply_cost/`、`warden/`、`character_counts/` | 删，或保留但不启用（NodeLoc 无对应服务端插件） |

### 第 3 步：P1 站点定制层

新建 `lib/config/sites/nodeloc.dart`：

- `linkSecurityConfig` 换 NodeLoc 域名策略
- **`plugins: const []` 必须清空** —— NodeLoc 未启用 `discourse-reply-cost` / `discourse-warden` / `character-counts`，注册会导致回复前校验误判
- `avatarGlowRules` / `userTitleStyleRules` 换 NodeLoc 头衔体系（实测有「王者会员」「钻石会员」「MANAGER」「无所不知」「3 YEARS」等，配色需进一步采集）

另需处理：

| 位置 | 改动 |
|---|---|
| `lib/services/network/doh/ech_dns_policy.dart:6` | `builtinDomains = ['linux.do','ldstatic.com']` → `['nodeloc.com']` |
| `lib/services/network/doh/network_settings_service.dart:1376-1380` | ECH 域名组 `connect/ping/cdn/credit/cdk.linux.do` → 清空或仅留 `www.nodeloc.com` |
| `lib/services/dio_http_client.dart:22` | 仅注释里的 `cdn.ldstatic.com` 示例，**逻辑无需改** |

### 第 4 步：P2 登录链路（NodeLoc 上反而更简单）

| # | 位置 | 改动 |
|---|---|---|
| 13 | `lib/pages/login_page.dart:38-39` | hCaptcha sitekey → `d2a8ddf6-4c2a-4054-ac7c-2e288c2477aa`（同一家服务商，mini-webview 整套流程原样复用） |
| 14 | `lib/services/discourse/_login.dart:16-49` | **可移除两处 `@Deprecated`**（NodeLoc 上 `/session/csrf` 与 `POST /session.json` 实测均 200 JSON） |
| 15 | `lib/services/user_api_key_service.dart:57` | `scopes = 'one_time_password'` 保留（实测被接受）；`keyWorthKeeping` 逻辑按实测决定 |
| 16 | `lib/services/user_api_key_service.dart:56` | `applicationName = 'FluxDO'` → 新应用名 |
| 17 | `lib/pages/webview_login_page.dart:1036,1044` | `_t` cookie 检测 → **实测确认**，必要时兼容 `_forum_session` |
| 18 | `lib/services/cf_challenge_service.dart`（2898 行） | **先不动**。NodeLoc 实测无 CF 挑战；保留作兜底，确认不会误触发即可 |

### 第 5 步：P4 参数与文案对齐

| # | 位置 | 改动 |
|---|---|---|
| 33 | `lib/services/discourse/_uploads.dart:426` | 上传上限 4 MB → **15 MB**（NodeLoc `max_attachment_size_kb = 15360`） |
| 34 | `lib/services/composer_min_length_resolver.dart` | 最小字数逻辑简化（NodeLoc `min_post_length = 1`） |
| 35 | `lib/services/media_compat_service.dart` | 按 NodeLoc `authorized_extensions` 重评「改后缀」策略，**大概率可简化甚至删除**（含 avif/heic/heif/rar/7z） |
| 36 | `lib/models/user.dart:234` | 头像相对路径补全的 `https://linux.do` → 新域 |
| 37 | `lib/pages/profile_page.dart:341` | 偏好设置链接（跟随 baseUrl，检查即可） |
| 38 | `lib/pages/search_page.dart:35` | 站内直达链接的域名识别 |
| 39 | `lib/services/ai_post_review_service.dart:83` | `/guidelines` 保留（NodeLoc 有该页），但 prompt 中「你是 Linux.do 社区发帖前的本地 AI 审核助手」需改写 |
| 40 | `lib/widgets/common/smart_avatar.dart:35`、`painted_topic_card.dart:285`、`user_profile_page.dart:2229` | 移除 `neo` 头像方形化特例 |
| 41 | `lib/config/sites/linuxdo.dart:10-32` | 头衔/光晕规则由新站点配置取代 |
| 42 | `lib/l10n/**`（en / zh / zh_HK / zh_TW 共 4 语言 × 6 模块） | 品牌名，`proxy_*` / `reward_*` / `about_legalese` / `auth_cdk\|ldcConfirmMessage` / `invite_shareSubject` / `profile_loginLinuxDo` 中的 linux.do 文案 |
| 43 | `pubspec.yaml`、`README.md`、`assets/`、`screenshots/`、Telegram 链接 | 全面替换 |
| 44 | Android `applicationId = com.github.lingyan000.fluxdo`、iOS bundle id | **必须更换**（GPL 合规 + 避免混淆） |

### 第 6 步：P5 新功能缺口（可选，NodeLoc 独有）

非迁移必需，属于「加分项」：

- **Lottery 抽奖**（`lottery_enabled`）— 通知类型 `6002 lottery_result`
- **Check-in 签到**（`checkin_enabled`）
- **Post Voting / Topic Voting** — 帖子级 / 话题级投票
- **Solved** — 问答采纳
- **Signatures** — 签名档（FluxDO 已有 `post_signature_block.dart`，可能部分支持）
- **Reward** — 通知类型 `5000 reward_received`

---

## 三、注意事项 / 风险

1. **`baseUrl` 必须写 `https://www.nodeloc.com`（带 www）**。裸域 `nodeloc.com` 会 301 到 www，可能导致 cookie 域与 OAuth 回调异常。
2. **唯一真机验证点**：登录成功后是否下发 `_t` cookie（NodeLoc 匿名 `/session/csrf` 只下发 `_forum_session`）。这一条决定 P2 是否需要额外分支，**建议开工第一件事就是真机登录一次抓 cookie**。
3. **hCaptcha sitekey 必须替换**，但 mini-webview 流程可整块复用（与 Linux.do 同一服务商，`discourse_captcha_provider = hcaptcha`）。
4. **三个 SitePlugin 在 NodeLoc 上全是死代码**，`plugins` 数组必须清空，否则回复前校验会误判。相关字段：`reply_cost`（话题级）、`premium_min_post_length`（分类级），见 `lib/plugins/plugin_context.dart:14/70`、`lib/services/composer_min_length_resolver.dart:12/49`。
5. **Cloudflare 逻辑不要急着删**。NodeLoc 实测无 `cf-mitigated` 头、API 不拦（`/session/csrf` 在 Linux.do 是 403，在 NodeLoc 是 200），但 `cf_challenge_service.dart` 2898 行可作为兜底休眠保留。
6. **MessageBus 降级安全**：NodeLoc 无 `ping.` 子域，但 `longPollingBaseUrl` / `cdnUrl` / `s3CdnUrl` 均返回 `String?` 且有空值降级，不会崩，只是性能略降。
7. **`min_post_length = 1`**：Warden / CharacterCounts 类校验失去意义，删插件后要确认没有残留引用。
8. **上传 4 MB → 15 MB** 是硬限制，不改会导致上传被服务端拒绝。
9. **`upstream` 同步风险**：上游 CHANGELOG 116 KB、近乎每周发版。**直接删 linux.do 代码会让同步变成灾难**，务必走 `sites/` profile 隔离路线（目录名本就是复数，上游已预留多站点设计）。
10. **合规（GPL-3.0）**：改造后发布必须开源；不得使用原作者名义分发；包名 / bundle id 必须更换。NodeLoc 存在 `nodeloc-app` 用户组，**可能已有官方 App**，建议先与站方沟通。
11. **反爬结论有时效性**：「CF 不拦 API」「User API Key 路径开放」均基于 2026-11-02 探测，若站方后续调整风控策略需重新验证。
12. **登录方式**：NodeLoc 无 Discourse Connect SSO（`enable_discourse_connect = false`），本地登录为主（`enable_local_logins = true`，含 passkeys，不强制 2FA），社交 OAuth 齐全（google/github/twitter/apple/telegram）。

---

## 四、工期与顺序建议

```
1. P0 站点身份                → 能启动、能浏览
2. P3 删 Linux.do 外挂        → 消除崩溃点与无效入口
3. P1 建 nodeloc.dart         → 站点定制层落地
4. P2 登录链路（先做 P2-17 实机验证）→ 打通登录
5. P4 参数与文案              → 细节对齐
6. P5 新功能                  → 按需
```

| 范围 | 单人工期 |
|---|---|
| P0 + P1 + P3（能跑、无残留） | **3～5 人日** |
| 再加 P2 + P4（登录顺畅、参数正确） | 再 3～4 人日 |
| P5 新功能 | 按需 |

> 比预期乐观：NodeLoc 的反爬比 Linux.do 宽松，FluxDO 最复杂的 2898 行 `cf_challenge_service` 反而可以保持休眠。

---

## 五、NodeLoc 实测参数速查（直接用于替换硬编码值）

| 参数 | 实测值 | 备注 |
|---|---|---|
| 生成器 | `Discourse 2026.10.0-latest.1` | commit `b5a1e766` |
| 主域 | `www.nodeloc.com` | 裸域 301 到 www |
| 语言 / 协议 | `zh-CN` / HTTPS | |
| 访客浏览 / 注册 | 允许 / 开放 | `login_required=false`、`invite_only=false` |
| 首页 | `/latest` | |
| `discourse_captcha_provider` | `hcaptcha` | |
| `hcaptcha_site_key` | `d2a8ddf6-4c2a-4054-ac7c-2e288c2477aa` | |
| `max_attachment_size_kb` | **15360（15 MB）** | FluxDO 写死 4 MB |
| `min_post_length` | **1** | 无最小字数约束 |
| `max_post_length` | 99999 | |
| `min_topic_title_length` / `max` | 6 / 255 | |
| `min_password_length` | 10 | |
| `min_username_length` / `max` | 3 / 20 | |
| `min_search_term_length` | 1 | |
| `min_personal_message_post_length` | 3 | |
| `unicode_usernames` | false | |
| `poll_enabled` | true | |
| `newuser_max_attachments` | 0 | 新用户不能传附件 |
| `authorized_extensions` | `jpg\|jpeg\|png\|gif\|heic\|heif\|webp\|avif\|rar\|zip\|7z\|txt\|svg\|mov\|mp4\|webm\|m4v\|3gp\|ogv\|avi\|mpeg\|mp3\|ogg\|m4a\|wav\|aac\|flac\|pdf\|doc\|docx\|csv` | 比 Linux.do 宽得多 |
| 会话 cookie（匿名） | `_forum_session` | 登录后 `_t` 待真机确认 |

---

## 附录：复现探测的命令

```bash
# 站点底座
curl -s https://www.nodeloc.com/about.json | head -c 300
curl -s https://www.nodeloc.com/site.json  | head -c 300

# 反爬判定（关键：Linux.do 上此处为 403）
curl -s -i https://www.nodeloc.com/session/csrf

# User API Key 授权路径（关键：400 且报 public_key 缺失 = 路径开放）
curl -s -i "https://www.nodeloc.com/user-api-key/new?application_name=FluxDO&client_id=t&nonce=n&scopes=one_time_password&auth_redirect=discourse://auth_redirect"
```

```bash
# 代码侧耦合检索
grep -rn "linux\\.do" lib --include=*.dart | wc -l
grep -rn "connect\\.linux\\.do\\|credit\\.linux\\.do\\|cdk\\.linux\\.do\\|ping\\.linux\\.do" lib
grep -rln "ldc\\|ldx\\|cdk\\|metaverse\\|connectStats" lib
grep -rn "linux\\.do" android ios macos windows linux flatpak altstore test
```
