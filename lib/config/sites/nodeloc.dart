import 'package:flutter/material.dart';

import '../../widgets/common/badge_title_text.dart';
import '../site_customization.dart';

/// nodeloc.com 站点自定义配置
///
/// NodeLoc（www.nodeloc.com）为标准 Discourse 站点，与 linux.do 的差异点：
/// - 未启用 discourse-reply-cost / discourse-warden / character-counts，
///   因此 [plugins] 必须保持为空，否则回复提交前校验会误判。
/// - 光晕及头衔基色、效果类型依据公开主题 CSS 和用户徽章 custom_style。
///   未采集到样式的头衔沿用默认显示，来源见 P1 实施记录。
final nodelocCustomization = SiteCustomization(
  avatarGlowRules: const [
    AvatarGlowRule(primaryGroupName: 'Rich', glowColor: Color(0xFFF5BF03)),
  ],
  userTitleStyleRules: [
    UserTitleStyleRule(
      title: '王者会员',
      builder: (title, fontSize) => BadgeTitleText(
        text: title,
        fontSize: fontSize,
        color: const Color(0xFFF7E58D),
        effect: BadgeTitleEffect.goldFlow,
      ),
    ),
    UserTitleStyleRule(
      title: '钻石会员',
      builder: (title, fontSize) => BadgeTitleText(
        text: title,
        fontSize: fontSize,
        color: const Color(0xFF888672),
        effect: BadgeTitleEffect.shimmer,
      ),
    ),
    UserTitleStyleRule(
      title: 'MANAGER',
      builder: (title, fontSize) => BadgeTitleText(
        text: title,
        fontSize: fontSize,
        color: const Color(0xFFE4C862),
        effect: BadgeTitleEffect.holographicFlow,
      ),
    ),
  ],
  linkSecurityConfig: _nodelocLinkSecurityConfig,
  plugins: const [],
);

/// nodeloc.com 链接安全配置
///
/// 未确认的站点专属信任/屏蔽名单保持为空，外链默认需要确认。
/// 短链与推广关键词沿用通用风险规则，不继承 Linux.do 的专属域名。
const _nodelocLinkSecurityConfig = LinkSecurityConfig(
  enableExitConfirmation: true,
  internalDomains: [
    // 站点自身域名（*.nodeloc.com 同时匹配 www.nodeloc.com 与 nodeloc.com）
    '*.nodeloc.com',
    'localhost',
    '*.local',
    // ^ 是规则语法前缀，紧随其后的 ^ 才是正则锚点。
    // 限定 URL 的主机边界，避免路径、查询参数或伪装域命中内网规则。
    '${_ipv4UrlPrefix}127$_ipv4Octet{3}$_ipv4UrlSuffix',
    '${_ipv4UrlPrefix}10$_ipv4Octet{3}$_ipv4UrlSuffix',
    '${_ipv4UrlPrefix}169\\.254$_ipv4Octet{2}$_ipv4UrlSuffix',
    '${_ipv4UrlPrefix}192\\.168$_ipv4Octet{2}$_ipv4UrlSuffix',
    '${_ipv4UrlPrefix}172\\.(?:1[6-9]|2\\d|3[0-1])$_ipv4Octet{2}$_ipv4UrlSuffix',
  ],
  trustedDomains: [],
  riskyDomains: [
    'bit.ly',
    'tinyurl.com',
    't.co',
    'goo.gl',
    'ow.ly',
    'buff.ly',
    'adf.ly',
    'short.link',
    '*.short.link',
    'tiny.cc',
    'is.gd',
    'cli.gs',
    'pic.gd',
    'dwarfurl.com',
    'yfrog.com',
    'migre.me',
    'ff.im',
    'tiny.pl',
    'url4.eu',
    'tr.im',
    'twit.ac',
    'su.pr',
    'twurl.nl',
    'snipurl.com',
    'budurl.com',
    'short.to',
    'ping.fm',
    'digg.com',
    'post.ly',
    'just.as',
    'bkite.com',
    'snipr.com',
    'fic.kr',
    'loopt.us',
    'doiop.com',
    'twitthis.com',
    'htxt.it',
    'alturl.com',
    'redirx.com',
    'digbig.com',
    'short.ie',
    'u.mavrev.com',
    'kl.am',
    'wp.me',
    'rubyurl.com',
    'om.ly',
    'to.ly',
    'bit.do',
    'lnkd.in',
    'db.tt',
    'qr.ae',
    'bitly.com',
    'cur.lv',
    'ity.im',
    'q.gs',
    'po.st',
    'bc.vc',
    'u.to',
    'j.mp',
    'buzurl.com',
    'cutt.us',
    'u.bb',
    'yourls.org',
    'x.co',
    'prettylinkpro.com',
    'scrnch.me',
    'filoops.info',
    'vzturl.com',
    'qr.net',
    '1url.com',
    'tweez.me',
    'v.gd',
    'link.zip',
  ],
  dangerousDomains: ['**aff='],
  blockedDomains: [],
);

const _ipv4UrlPrefix = r'^^(?:[hH][tT][tT][pP][sS]?:)?//(?:[^/?#@]*@)?';
const _ipv4Octet = r'(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))';
const _ipv4UrlSuffix = r'(?::\d+)?(?:[/?#]|$)';
