import '../site_customization.dart';

/// nodeloc.com 站点自定义配置
///
/// NodeLoc（www.nodeloc.com）为标准 Discourse 站点，与 linux.do 的差异点：
/// - 未启用 discourse-reply-cost / discourse-warden / character-counts，
///   因此 [plugins] 必须保持为空，否则回复提交前校验会误判。
/// - 头衔体系实测含「王者会员」「钻石会员」「MANAGER」「无所不知」
///   「3 YEARS」等，配色尚未采集；[avatarGlowRules] / [userTitleStyleRules]
///   待配色与规则确认后再补全。
final nodelocCustomization = SiteCustomization(
  avatarGlowRules: const [],
  userTitleStyleRules: const [],
  linkSecurityConfig: _nodelocLinkSecurityConfig,
  plugins: const [],
);

/// nodeloc.com 链接安全配置
///
/// NodeLoc 暂未公开对应主题组件设置，先以站点自身域名 + 通用内网段兜底；
/// trusted / risky / dangerous / blocked 列表待站方主题配置采集后补全。
const _nodelocLinkSecurityConfig = LinkSecurityConfig(
  enableExitConfirmation: true,
  internalDomains: [
    // 站点自身域名（*.nodeloc.com 同时匹配 www.nodeloc.com 与 nodeloc.com）
    '*.nodeloc.com',
    'localhost',
    // 通用内网地址（与 linux.do 配置保持一致）
    '^127(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}',
    '^10(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}',
    '^169\\.254(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
    '^192\\.168(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
    '^172\\.(?:1[6-9]|2\\d|3[0-1])(?:\\.(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){2}',
  ],
  trustedDomains: const [],
  riskyDomains: const [],
  dangerousDomains: const [],
  blockedDomains: const [],
);
