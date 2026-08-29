# OPPO Pad 5 Unlock Kit

[![test](https://github.com/daishuge/oppo-pad5-unlock-kit/actions/workflows/test.yml/badge.svg)](https://github.com/daishuge/oppo-pad5-unlock-kit/actions/workflows/test.yml)

面向 OPPO Pad 5 `OPD2506` 的安全优先解锁与持久化 root 工具集。

> [!CAUTION]
> 这是 **Preview**，不是“已验证的一键解锁器”。原始 B→A 手工流程曾在一台真机上完成；本仓库的新脚本只经过 mock、静态分析和双版本 PowerShell 测试，**没有再次在真机上执行破坏性步骤**。解锁 bootloader 会清除用户数据，错误写入 LK 或 `init_boot` 可能导致设备无法启动。

## 当前能做什么

- `Start-ReadOnlyCheck.cmd`：推荐入口。只读取设备身份、完整 kernel、slot、电量和锁状态，不安装、不推送、不重启、不获取 root。
- `Get-OPPOPad5Assets.ps1`：下载或检查固定版本资产，要求文件大小和 SHA-256 同时匹配；下载先落到 `.partial`，验证后才原子提升。
- `device/verify-stage.sh`：在已有临时 root 的前提下，只读检查 inactive slot 的 LK 与 `init_boot`。
- `Start-UnlockWizard.cmd`：高级 **计划器**。每次重新核对证据，只有所有门禁通过才生成固定 B→A 逻辑计划；Preview 不会自动执行 `adb`、`fastboot` 或分区写入。
- `device/write-lk.sh`：单一 LK 写边界。它固定只允许目标 `lk_a`，写前和写后核对 hash，并用 trap 恢复 block device 的只读状态。该脚本尚无新自动化真机验证。

## 唯一兼容配置

| 项目 | 精确值 |
|---|---|
| 型号 | `OPD2506` |
| device | `OP6542L1` |
| build | `OPD2506_16.0.9.400(CN01)` |
| OTA | `OPD2506_11.A.33_0330_202607091921` |
| kernel | `6.6.118-android15-8-ge58033dc8ea6-abogki498046332-4k` |
| 已记录方向 | active `_b` → target `_a` |
| 最低电量 | 60% |

任何字符不同都会 fail-closed。`_a` → `_b`、其他地区版本、其他 kernel 或系统更新后的设备都不在当前兼容范围内。完整边界见 [COMPATIBILITY.md](COMPATIBILITY.md)。

## 从只读检查开始

1. 从 [Android Developers](https://developer.android.com/tools/releases/platform-tools) 下载官方 Platform-Tools。
2. 在平板打开 Developer options 与 USB debugging，不要先运行高级流程。
3. 在仓库目录执行：

```powershell
.\Start-ReadOnlyCheck.cmd -PlatformToolsDir "C:\platform-tools" -OutputJson ".\reports\audit.json"
```

退出码 `0` 只代表只读身份与当前 Preview profile 完全一致，不代表解锁一定成功，也不授权任何写入。

继续研究或手工操作前，完整阅读 [详细教程](docs/DETAILED_GUIDE.zh-CN.md) 与 [安全边界](SAFETY.md)。

## 证据边界

| 结论 | 证据 |
|---|---|
| 原始手工 B→A 路径可完成 | 单台 OPD2506、上述精确版本的历史真机观察 |
| 只读检查器与状态机按设计 fail-closed | mock fixtures；PowerShell 7 与 Windows PowerShell 5.1 |
| Unicode/空格路径可用 | 两种 PowerShell 的本地 mock 回归测试 |
| shell 脚本语法可解析 | Git for Windows Bash `-n` 与 CI ShellCheck |
| 新高级流程能安全解锁任意设备 | **没有这种证据** |
| 存在免费、无需授权的 OPD2506 硬砖恢复方案 | **尚未证实** |

## 资产与许可

仓库不包含 APK、`lk.img`、OTA、Platform-Tools、设备备份或序列号。KernelSU、GhostLock 与教程 LK 的来源、固定 commit、hash 和再分发边界见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本项目自身代码采用 [MIT License](LICENSE)。

## 测试

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

测试只使用公开的合成 fixture，不连接真实设备。
