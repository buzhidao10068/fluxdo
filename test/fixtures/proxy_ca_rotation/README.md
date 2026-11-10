# CA 轮转的本地 TLS 夹具

这两组 EC 证书仅用于 `network_http_adapter_ca_test.dart` 的回环地址 TLS 测试。
`ca_a.pem`、`ca_b.pem` 是不同的测试根；对应 `server_*.pem` 仅适用于
`localhost` 和 `127.0.0.1`，有效期为 2020—2050 年。

`server_*.key` 是公开测试私钥，不得用于发布、真实服务或系统信任。
测试 CA 私钥未保存，测试不会修改操作系统证书库。
