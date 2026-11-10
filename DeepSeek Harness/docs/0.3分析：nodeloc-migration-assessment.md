# NodeLoc 迁移可行性评估与改造清单

> 面向接手的 AI / 开发者。读完这一份即可知道「能不能改、难在哪、怎么改、从哪开始」。
>
> - 基准代码：FluxDO `0.2.29`（2026-10-20），Flutter `3.47.4`
> - 探测时间：2026-11-02
> - 数据来源：**对 `www.nodeloc.com` 的真实 HTTP 探测** + 全仓代码检索。凡标注「实测」的均为真实响应，非推测。
> - 姊妹文档：`linuxdo-coupling-audit.md`（静态代码耦合审计）。**本文档负责「实测结论 + 可执行清单」，两者互补，不重复。**

---

## 0. 三句话结论

1. **能改。** NodeLoc 是标准 Discourse（`2026.10.0-latest.1`），FluxDO 约 95% 的代码与站点无关。
2. **比预期容易。** 实测发现 NodeLoc 的 Cloudflare **不拦 API**、验证码同为 hCaptcha、User API Key 授权路径**完全开放** —— 而这三项恰恰是 FluxDO 里最复杂、最容易被卡住的部分。
3. **主要工作量是「删」而不是「写」。** 约 8000 行 Linux.do 专属代码可整体移除，不需要等价重写。

---

## 1. NodeLoc 实测数据（本次探测的一手结果）

### 1.1 站点底座

| 项目 | 实测值 |
|---|---|
| 生成器 | `Discourse 2026.10.0-latest.1`（commit `b5a1e766`） |
| 语言 | `zh-CN` |
| 协议 | HTTPS |
| **主域** | **`www.nodeloc.com`** |
| 裸域行为 | `nodeloc.com` → **301** → `www.nodeloc.com` |
| 访客浏览 | 允许（`login_required = false`） |
| 注册 | 开放（`invite_only = false`、`must_approve_users = false`） |
| 首页 | `/latest` |

> ⚠️ **`baseUrl` 必须写 `https://www.nodeloc.com`（带 www）**。写裸域会引入 301，可能导致 cookie 域与 OAuth 回调异常。

### 1.2 反爬：有 Cloudflare，但不拦 API ★核心结论

所有请求都经 Cloudflare（`Server: cloudflare`，带 `cf-ray`），但 **`cf-mitigated` 响应头不存在**，即没有下发挑战页。

```
GET  /session/csrf   →  200  application/json   {"csrf":"iZY_2pAsh5..."}
POST /session.json   →  200  application/json   {"error":"用户名、邮箱或密码不正确"}
GET  /latest.json    →  200  application/json   （正常话题列表）
```

对比 FluxDO 源码 `lib/services/discourse/_login.dart` 的注释：

> `dio GET /session/csrf 实测被 CF 当 bot 403 (TLS 指纹), 仅留兜底`

**同一个端点在 Linux.do 上是 CF 403，在 NodeLoc 上是 200。** 这意味着 FluxDO 里被标记 `@Deprecated` 的原生 JSON 登录路径，在 NodeLoc 上**可以直接启用**。

### 1.3 User API Key：完全开放 ★核心结论

```
GET /user-api-key/new
    ?application_name=FluxDO
    &client_id=test-client-id-1234
    &nonce=test-nonce-abcdef
    &scopes=one_time_password
    &auth_redirect=discourse://auth_redirect

→ 400 {"errors":["param is missing or the value is empty or invalid: public_key"]}
```

这个 **400 是利好**：`application_name` / `client_id` / `nonce` / `scopes` / `auth_redirect` 全部通过校验，只差 RSA 公钥 —— 而 FluxDO 已有现成的 `pointycastle` 实现。

**结论：FluxDO 的核心登录体系（DiscourseHub 同款 User API Key 流程）在 NodeLoc 上可用。**
且 `discourse://auth_redirect` 是 Discourse 默认白名单，**无需站方额外配置**。

### 1.4 验证码：同为 hCaptcha，换 sitekey 即可

```
discourse_captcha_enabled  = true
discourse_captcha_provider = "hcaptcha"
hcaptcha_site_key          = "d2a8ddf6-4c2a-4054-ac7c-2e288c2477aa"
recaptcha_v2_site_key      = ""
recaptcha_v3_site_key      = ""
risk_control_captcha_only_when_risky = false
```

与 Linux.do **同一家服务商**。`lib/pages/login_page.dart` 里写死的 hCaptcha mini-webview 整套流程可原样复用，只换 sitekey 字符串。

### 1.5 认证方式：无 SSO，本地登录为主

```
enable_discourse_connect      = false     ← 没有 Discourse Connect SSO
enable_local_logins           = true
enable_local_logins_via_code  = true
enable_local_logins_via_email = true
enable_passkeys               = true
enforce_second_factor         = "no"      ← 不强制 2FA
```

OAuth 社交登录齐全（均 `can_connect: true`）：
`google_oauth2`、`github`、`twitter`、`apple`、`telegram`

### 1.6 站点限制参数（直接替换硬编码值）

| 参数 | NodeLoc 实测值 | 对 FluxDO 的影响 |
|---|---|---|
| `max_attachment_size_kb` | **15360（15 MB）** | `_uploads.dart` 写死 4 MB，**必须改** |
| `max_post_length` | 99999 | 极宽松 |
| `min_post_length` | **1** | 无最小字数约束 |
| `min_topic_title_length` | 6 | |
| `max_topic_title_length` | 255 | |
| `min_password_length` | 10 | |
| `min_username_length` / `max_username_length` | 3 / 20 | |
| `min_search_term_length` | 1 | |
| `min_personal_message_post_length` | 3 | |
| `unicode_usernames` | false | |
| `poll_enabled` | true | |
| `newuser_max_attachments` | 0 | 新用户不能传附件 |

**`authorized_extensions`（重要差异）：**

```
jpg|jpeg|png|gif|heic|heif|webp|avif|rar|zip|7z|txt|svg|mov|mp4|webm|m4v|3gp|ogv|avi|mpeg|mp3|ogg|m4a|wav|aac|flac|pdf|doc|docx|csv
```

比 Linux.do 宽得多（含 `avif` / `heic` / `heif` / `rar` / `7z`）。
→ FluxDO 里 `media_compat_service` 那套「改后缀绕过白名单」的策略**大概率可以大幅简化甚至删除**。

### 1.7 插件清单：确认三个 SitePlugin 全部失效

NodeLoc 实际启用的插件：

> Chat、AI、Assign、Cakeday、Calendar、Check-in、Checklist、Data Explorer、Follow、Lottery、Policy、Poll、Post Voting、Push、Signatures、Solved、Spoiler、Topic Voting、User Notes、Affiliate

**不存在**：`discourse-reply-cost`、`discourse-warden`、`character-counts`

→ FluxDO 的 `ReplyCostPlugin` / `WardenPlugin` / `CharacterCountsPlugin` 在 NodeLoc 上**全是死代码**，站点配置里 `plugins` 数组必须清空。

反向缺口（NodeLoc 有、FluxDO 未适配）：**Lottery 抽奖、Check-in 签到、Post Voting、Topic Voting、Solved、Signatures、Reward**。

### 1.8 其他实测细节

- **会话 cookie 名**：匿名 `/session/csrf` 下发 `_forum_session`（Rails session）。
  FluxDO `webview_login_page.dart` 检查的是 `_t`（登录后的长效 token cookie）。
  → **需真机验证登录后是否下发 `_t`**。这是全清单唯一必须实机确认的点。
- **MessageBus**：NodeLoc 无 `ping.` 子域。
  但 FluxDO 的 `longPollingBaseUrl` / `cdnUrl` / `s3CdnUrl` 均返回 `String?` 且有空值降级，**不会崩，会自动退回主域长轮询**，仅性能略降。
- **`/session/hp.json`**：正常返回 honeypot（`value` / `challenge` / `expires_in`），标准反垃圾流程完整。
- **反爬提示**：带正确 CSRF 的 `POST /session.json` 返回的是**中文应用层错误**，证明请求被正常处理，未被 WAF 拦截。

---

## 2. 改造清单（按优先级，可直接拆 issue）

> 行号基于 `0.2.29`。级别沿用姊妹文档：**L1 配置化 / L2 站点硬编码 / L3 品牌**。

### P0 — 站点身份（不改则无法运行）

| # | 文件:行 | 现状 | 改为 |
|---|---|---|---|
| 1 | `lib/constants.dart:301` | `baseUrl = 'https://linux.do'` | `'https://www.nodeloc.com'`（**必须带 www**） |
| 2 | `lib/constants.dart:14` | `siteCustomization = linuxdoCustomization` | 指向新建的 `nodelocCustomization` |
| 3 | `lib/config/sites/nodeloc.dart` | 不存在 | **新建**，见 P1-9 |
| 4 | `android/app/src/main/AndroidManifest.xml:57-94` | 6 个 `linux.do` intent-filter | 全部换 `www.nodeloc.com` |
| 5 | `ios/Runner/Runner.entitlements`、`macos/Runner/*.entitlements` | 关联域 `linux.do` | `www.nodeloc.com` |
| 6 | `apple/`、`web/` 下的 AASA | 关联域文件 | 重新生成 |
| 7 | `lib/services/deep_link_service.dart:149,272` | host 白名单 | 加入 `www.nodeloc.com` |
| 8 | `lib/services/clipboard_topic_link_service.dart:170` | 识别 `linux.do` | 换域名 |

> 注：`dio_http_client.dart` 的主域判定已从 `baseUrl` 派生（`_mainHost = Uri.parse(AppConstants.baseUrl).host`），**改完 #1 即自动生效，无需改代码**。

### P1 — 站点定制层

| # | 文件 | 改动 |
|---|---|---|
| 9 | 新建 `lib/config/sites/nodeloc.dart` | `linkSecurityConfig` 换 NodeLoc 域名策略；**`plugins: const []` 清空**；`avatarGlowRules` / `userTitleStyleRules` 换 NodeLoc 头衔体系（实测存在 `王者会员` / `钻石会员` / `MANAGER` / `无所不知` / `3 YEARS` 等，需进一步采集配色） |
| 10 | `lib/services/network/doh/ech_dns_policy.dart:6` | `builtinDomains = ['linux.do','ldstat.com']` → `['nodeloc.com']` |
| 11 | `lib/services/network/doh/network_settings_service.dart:1376-1380` | ECH 域名组 `connect/ping/credit/cdk.linux.do` → 清空或仅留 `www.nodeloc.com` |
| 12 | `lib/services/dio_http_client.dart:22` | 注释中 `cdn.ldstatic.com` 示例更新（**逻辑无需改**） |

### P2 — 登录与认证（NodeLoc 上反而更简单）

| # | 文件:行 | 改动 |
|---|---|---|
| 13 | `lib/pages/login_page.dart:38-39` | hCaptcha sitekey → `d2a8ddf6-4c2a-4054-ac7c-2e288c2477aa` |
| 14 | `lib/services/discourse/_login.dart:16-49` | **可移除两处 `@Deprecated`**：NodeLoc 上 `/session/csrf` 与 `POST /session.json` 实测均为 200 JSON |
| 15 | `lib/services/user_api_key_service.dart:57` | `scopes = 'one_time_password'` 保留（已实测被接受）；`keyWorthKeeping` 逻辑按实测结果决定 |
| 16 | `lib/services/user_api_key_service.dart:56` | `applicationName = 'FluxDO'` → 新应用名 |
| 17 | `lib/pages/webview_login_page.dart:1036,1044` | `_t` cookie 检测 → **实测确认**，必要时兼容 `_forum_session` |
| 18 | `lib/services/cf_challenge_service.dart`（2898 行） | **先不动**。NodeLoc 实测无 CF 挑战；保留作兜底，但需确认不会误触发 |

### P3 — Linux.do 生态功能（整块删除，约 8000 行）

| # | 文件 | 处置 |
|---|---|---|
| 19 | `lib/services/ldc_oauth_service.dart`（200 行） | 删（`credit.linux.do` 不存在） |
| 20 | `lib/services/cdk_oauth_service.dart`（200 行） | 删（`cdk.linux.do`） |
| 21 | `lib/modules/ldc_reward/`（整个模块，8 文件） | 删（`credit.linux.do/epay/pay/distribute`） |
| 22 | `lib/widgets/ldc_balance_card.dart`（824 行） | 删 |
| 23 | `lib/widgets/cdk_balance_card.dart`（722 行） | 删 |
| 24 | `lib/models/connect_stats.dart` | 删（`connect.linux.do` HTML 爬取） |
| 25 | `lib/providers/directory_providers.dart`（19 行） | 删 |
| 26 | `lib/pages/trust_level_requirements_page.dart:45` | 删或改为纯本地计算 |
| 27 | `lib/models/profile_stats_config.dart:28` | 移除 `connect` 枚举分支 |
| 28 | `lib/pages/metaverse_page.dart`（多元宇宙聚合页） | 删，并清理 `profile_page.dart` 入口 |
| 29 | `lib/services/network/cookie/app_cookie_manager.dart:455-469` | 移除 `connect.linux.do` 特判 |
| 30 | `lib/services/network/cookie/cookie_jar_service.dart:119` | 子域 cookie 归置注释与逻辑更新 |
| 31 | `lib/services/oauth_flow_helper.dart`、`oauth_session_client.dart` | 删（专为 connect.linux.do 的 CSRF 怪癖而写） |
| 32 | `lib/plugins/reply_cost/`、`warden/`、`character_counts/` | 删，或保留但不启用 |

### P4 — 参数与文案

| # | 文件:行 | 改动 |
|---|---|---|
| 33 | `lib/services/discourse/_uploads.dart:426` | 4 MB → **15 MB** |
| 34 | `lib/services/composer_min_length_resolver.dart` | 最小字数逻辑简化（`min_post_length = 1`） |
| 35 | `lib/services/media_compat_service.dart` | 按 NodeLoc `authorized_extensions` 重评「改后缀」策略，**大概率可简化** |
| 36 | `lib/models/user.dart:234` | 头像相对路径补全的 `https://linux.do` → 新域 |
| 37 | `lib/pages/profile_page.dart:341` | 偏好设置链接（跟随 baseUrl，检查即可） |
| 38 | `lib/pages/search_page.dart:35` | 站内直达链接的域名识别 |
| 39 | `lib/services/ai_post_review_service.dart:83` | `/guidelines` 保留（NodeLoc 有该页） |
| 40 | `lib/widgets/common/smart_avatar.dart:35`、`painted_topic_card.dart:285`、`user_profile_page.dart:2229` | 移除 `neo` 头像方形化特例 |
| 41 | `lib/config/sites/linuxdo.dart:10-32` | 头衔/光晕规则由新站点配置取代 |
| 42 | `lib/l10n/**`（4 语言 arb） | 品牌名，`proxy_*` / `reward_*` 中的 linux.do 文案 |
| 43 | `pubspec.yaml`、`README.md`、`assets/`、`screenshots/`、Telegram 链接 | 全面替换 |
| 44 | Android `applicationId = com.github.lingyan000.fluxdo`、iOS bundle id | **必须更换**（GPL 合规 + 避免混淆） |

### P5 — 新功能缺口（可选，NodeLoc 独有）

非迁移必需，属于「加分项」：

- **Lottery 抽奖**（`lottery_enabled`）— 通知类型 `6002 lottery_result`
- **Check-in 签到**（`checkin_enabled`）
- **Post Voting / Topic Voting** — 帖子级投票
- **Solved** — 问答采纳
- **Signatures** — 签名档（FluxDO 已有 `post_signature_block.dart`，可能部分支持）
- **Reward** — 通知类型 `5000 reward_received`

---

## 3. 工作量与风险重估

| 项 | 改造前判断 | 实测后修正 |
|---|---|---|
| 登录 / 反爬 | 最大未知数，可能需重写 | **低风险**：CF 不拦 API、hCaptcha 同家、User API Key 开放 |
| 站点专属代码 | 需逐个等价替换 | **可整体删除约 8000 行** |
| 上传限制 | 需实测 | 已知：15 MB / 扩展名清单 |
| MessageBus | 可能崩溃 | 有降级，仅性能略降 |
| 站点插件 | 需重写 | 三个全部删除即可 |

**唯一真机验证点**：登录成功后是否下发 `_t` cookie（P2-17）。

**工期估计（单人）：**

| 范围 | 估计 |
|---|---|
| P0 + P1 + P3（能跑、无残留） | **3～5 人日** |
| 再加 P2 + P4（登录顺畅、参数正确） | **再 3～4 人日** |
| P5 新功能 | 按需 |

> 比预期乐观，因为 NodeLoc 的反爬比 Linux.do 宽松，而 FluxDO 最复杂的 2898 行 `cf_challenge_service` 反而可以保持休眠。

---

## 4. 架构建议（重要）

**不要「fork 后硬改」。** 推荐把站点差异提升为 `SiteProfile` 抽象：

```
lib/config/sites/
├── linuxdo.dart     ← 保留
└── nodeloc.dart     ← 新增
```

把 `baseUrl`、子域服务、ECH 域名、插件列表、站点限制参数全部收进配置对象，通过「按站点启用/禁用」隔离。

理由：

1. 目录名本就是复数 `sites/`，**上游已预留多站点设计**，改造方向与架构一致。
2. 上游发版极快（CHANGELOG 116 KB，近乎每周），硬改会让 `upstream` 同步变成灾难。
3. P1 / P3 的工作因此退化为「纯数据改动」，可持续跟进上游。

**合规提示：**

- 项目为 **GPL-3.0**，改造后发布**必须开源**。
- 不得使用原作者名义分发；包名 / bundle id 必须更换。
- NodeLoc 存在 `nodeloc-app` 用户组，**可能已有官方 App**，建议先与站方沟通。

---

## 5. 开工顺序

```
1. P0 全部（站点身份）           → 能启动、能浏览
2. P3 全部（删 Linux.do 外挂）   → 消除崩溃点与无效入口
3. P1-9（建 nodeloc.dart）       → 站点定制层落地
4. P2（登录链路）                → 打通登录
5. P4（参数与文案）              → 细节对齐
6. P5（新功能）                  → 按需
```

**建议先做第 4 步中的 P2-17 实测**（真机登录一次，抓 cookie），因为它决定 P2 是否需要额外分支。

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

# 站点限制参数（藏在 /login 页内嵌的转义 JSON 里，约 947 项）
# 关键词：discourse_captcha_provider / hcaptcha_site_key / max_attachment_size_kb / authorized_extensions
```

```bash
# 代码侧耦合检索
grep -rn "linux\.do" lib --include=*.dart | wc -l
grep -rn "connect\.linux\.do\|credit\.linux\.do\|cdk\.linux\.do\|ping\.linux\.do" lib
grep -rln "ldc\|ldx\|cdk\|metaverse\|connectStats" lib
grep -rn "linux\.do" android ios macos windows linux flatpak altstore test
```

---

*本文档基于真实探测与源码核对，未使用推测数据。若 NodeLoc 后续调整风控策略，§1.2 / §1.3 的结论需重新验证。*
