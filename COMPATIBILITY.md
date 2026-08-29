# Compatibility contract

## Preview profile

本项目不是按“OPPO Pad 5”这个营销名称做宽松匹配，而是按 `config/compatibility.json` 中的完整 identity、slot 方向、分区大小和 cryptographic hash 做严格匹配。

当前唯一 profile 是 `opd2506-cn-16.0.9.400-b-to-a`：

- `ro.product.model = OPD2506`
- `ro.product.device = OP6542L1`
- `ro.build.display.id = OPD2506_16.0.9.400(CN01)`
- `ro.build.version.ota = OPD2506_11.A.33_0330_202607091921`
- `uname -r = 6.6.118-android15-8-ge58033dc8ea6-abogki498046332-4k`
- source slot `_b`，target slot `_a`
- unlock 前必须为 `ro.boot.flash.locked=1` 与 `ro.boot.verifiedbootstate=green`
- 电量至少 60%

## 分区约束

| 对象 | 大小 | SHA-256 |
|---|---:|---|
| `lk_a` partition | 16,777,216 bytes | 整分区不用于兼容判断 |
| stock LK prefix | 9,416,704 bytes | `0da00158fbed097d8ced1fb61bb2c3c5048fc3a9086996e65715e31ccbbbaede` |
| modified LK image | 9,416,784 bytes | `eef2ed953a97e4f895b54cb8f06ac8d33e37e6376cedf263f4824e25aa4cb654` |
| stock `init_boot_a` | 8,388,608 bytes | `745e8f8f9804d90d362286b9078b90850e0f5c0877ae641d71924729b77a6e28` |
| KernelSU 3.2.5 patched `init_boot_a` | 8,388,608 bytes | `dbe1aae03b81804e7293ca0a9dd86e2808613bd3eda7e33d49e8f9920aface29` |

大小相同但 hash 不同仍然拒绝。工作流 state 只是本地记录，不能代替每次运行时的重新核验。

## 不兼容即停止

以下情况都没有“尽量继续”的 fallback：

- active slot 是 `_a`；
- system、OTA 或 kernel 任一字符不同；
- GhostLock 显示 unsupported、unknown offsets 或 kernel mismatch；
- 分区大小或 stock hash 不同；
- 多台 ADB 设备且未显式提供 serial；
- 电量不足；
- 临时 root、两个本地分区备份或固定资产缺失；
- bootloader 回读未同时给出 `unlocked=yes` 与 `secure=no`；
- 普通重启后没有同时观察到 `_a`、unlocked/orange、KernelSU 3.2.5 和 `uid=0(root)`。

## 增加 profile 的标准

提交新 profile 不能只修改 JSON。需要提供可公开的设备 identity、两槽分区大小与 stock hash、资产来源和 hash、B/A 方向、失败恢复信息，以及至少一轮独立真机执行记录。缺少 destructive 真机记录时，只能标记为 read-only 或 experimental，不能标记 supported。
