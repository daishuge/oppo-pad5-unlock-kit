# Security policy

## Supported versions

当前只有最新 Preview branch 接收安全修复。仓库没有声明 production-ready 版本。

## Report a vulnerability

请使用 GitHub Security Advisory 的 private reporting；不要在公开 issue 中上传设备 serial、完整日志、OTA 私有链接、APK、partition dump 或个人数据。

报告至少包含：受影响 commit、Windows/PowerShell 版本、预期 gate、实际 gate、最小合成 fixture，以及问题是否可能导致命令注入、错误设备选择、错误 slot 写入、hash 绕过或敏感信息泄露。

## Supply-chain policy

- 仓库不分发 Platform-Tools、APK、OTA 或 `lk.img`。
- 可自动下载的资产必须使用 HTTPS、固定 release/commit URL、精确 byte length 与 SHA-256。
- user-supplied 资产也必须通过相同校验。
- 新 URL 不得只因为文件名相同就替换现有 pin。
- CI fixture 不得包含真实 serial、备份、密钥或个人路径。

## Scope limitation

GhostLock 与原教程属于第三方项目。其漏洞利用代码、二进制构建和设备兼容性不由本仓库审计或担保；本项目只记录固定来源、hash 与调用边界。
