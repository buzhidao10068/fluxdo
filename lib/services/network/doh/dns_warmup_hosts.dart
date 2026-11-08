/// 从站点和服务端下发的资源 URL 收集 DNS 预热主机。
/// 不预设任何站点专属子域，空资源配置自然降级到站点主机。
List<String> collectDnsWarmupHosts({
  required String baseUrl,
  Iterable<String?> resourceUrls = const [],
}) {
  final hosts = <String>{};
  for (final raw in [baseUrl, ...resourceUrls]) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) continue;
    final normalized = value.startsWith('//') ? 'https:$value' : value;
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      continue;
    }
    hosts.add(uri.host.toLowerCase());
  }
  return hosts.toList()..sort();
}
