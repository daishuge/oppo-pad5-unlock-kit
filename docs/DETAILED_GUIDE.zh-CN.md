# OPPO Pad 5 OPD2506 详细研究与操作指南

## 1. 先确认这份指南是什么

这份指南服务于研究、复核和有意识的手工操作。它不是“点一下就安全解锁”的承诺。

历史证据只覆盖一台设备、active `_b` → target `_a`、ColorOS `16.0.9.400(CN01)` 和完整 kernel `6.6.118-android15-8-ge58033dc8ea6-abogki498046332-4k`。仓库的新状态机没有重新在真机上执行 destructive path；当前 Preview 故意把高级入口停在“生成经门禁核验的计划”。

## 2. 调研结论

原始教程仓库 [ZincGluxx/OPPO-Pad-5-Unlock](https://github.com/ZincGluxx/OPPO-Pad-5-Unlock/tree/e13b657dfaa925df38fbe73802e7e928aa00aa7e) 描述了通过 GhostLock 获得临时 root，把修改 LK 写到 opposite slot，再进入 fastboot 解锁的流程。该仓库在固定 commit 中包含 APK 与 `lk.img`，但没有明确开源许可，所以本项目不重新分发这些二进制。

[GhostLock 源码](https://github.com/YuKongA/ghostlock-app/tree/e9e10f276c1d41596ec559e9359a930ef3e72302) 使用完整 `uname -r` 匹配 offsets，并以 Apache-2.0 发布。当前固定 APK 没有官方 release，因此必须由使用者自行构建或提供，然后按 manifest 中的 byte length 与 SHA-256 校验。

[KernelSU v3.2.5](https://github.com/tiann/KernelSU/releases/tag/v3.2.5) 有官方 release。持久化 root 的目标不是“GhostLock exploit 每次重跑”，而是在 bootloader 已独立确认 unlocked 后，让设备从 KernelSU 3.2.5 修补过的 `init_boot_a` 普通启动。

[AOSP bootloader 文档](https://source.android.com/docs/core/architecture/bootloader/locking_unlocking) 说明 `fastboot flashing unlock` 应要求物理确认并执行 factory data reset；解锁状态随后跨重启保持。官方 [Platform-Tools 页面](https://developer.android.com/tools/releases/platform-tools) 提供独立下载，包含 `adb` 与 `fastboot`，无需安装 Android Studio。

## 3. 准备与停止条件

准备一台 Windows 电脑、可靠 USB 数据线、官方 Platform-Tools、至少 60% 电量，以及足以容纳 OTA 和分区备份的磁盘空间。关闭系统自动更新与夜间安装，保持精确 build。

出现以下任一情况立即停止：identity/kernel 不一致、GhostLock unsupported、active `_a`、未知 offsets、kernel panic、反复重启、分区大小/hash 不一致、没有本地备份、fastboot readback 不完整，或普通重启后 KernelSU root 不成立。

## 4. 第一阶段：只读主机检查

下载仓库后，在 PowerShell 运行：

```powershell
.\Start-ReadOnlyCheck.cmd `
  -PlatformToolsDir "C:\platform-tools" `
  -OutputJson ".\reports\audit.json"
```

这一步不会安装 APK、push 文件、请求 root、reboot 或调用 fastboot。报告中的 serial 已遮罩。只有 exit code `0` 才说明 identity 与 profile 精确匹配。

## 5. 第二阶段：固定资产

自动获取官方 KernelSU APK 与固定 commit 的 LK：

```powershell
.\Get-OPPOPad5Assets.ps1 -DestinationDirectory ".\assets"
```

GhostLock 必须自行提供：

```powershell
.\Get-OPPOPad5Assets.ps1 `
  -DestinationDirectory ".\assets" `
  -GhostLockPath "C:\downloads\GhostLock-e9e10f2-release.apk"
```

不要从网盘搜索“破解版”替代。脚本要求 byte length 与 SHA-256 同时匹配，错误文件不会被提升为正式资产。

## 6. 第三阶段：临时 root 与只读 inactive-slot 复核

本仓库不自动点击 GhostLock，也不把 exploit 伪装成可重复的稳定 API。手工安装固定 KernelSU Manager 与经 hash 核对的 GhostLock；KernelSU Manager 此时只能打开，不能让它直接修补或刷写 partition。

GhostLock 只有明确显示 exact kernel supported 才能执行一次。成功后在 KernelSU 给 `com.android.shell` 授权，然后验证 `su` 下的 `id` 含 `uid=0(root)`。任何失败都停止，不连续点击 exploit。

把只读 stage verifier 放到临时目录并运行：

```powershell
$adb = "C:\platform-tools\adb.exe"
& $adb shell mkdir -p "/data/local/tmp/oppo-pad5"
& $adb push ".\device\verify-stage.sh" "/data/local/tmp/oppo-pad5/verify-stage.sh"
& $adb shell su -c "sh /data/local/tmp/oppo-pad5/verify-stage.sh" |
  Set-Content -LiteralPath ".\reports\stage.json" -Encoding utf8
```

`verify-stage.sh` 只读 `lk_a` 与 `init_boot_a`，不含 `setrw` 或 `dd of=`。如果 root shell 的 quoting 在特定 Windows 环境被改写，请不要随手拼接新的 nested command；先在交互式 `adb shell` 中逐项读取并与 `config/compatibility.json` 比较。

## 7. 第四阶段：本地备份

在 root shell 中把四个 stock partitions 复制到普通文件，再 pull 到电脑。方向必须是 block device → file：

```sh
mkdir -p /data/local/tmp/oppo-pad5/backups
dd if=/dev/block/by-name/lk_a of=/data/local/tmp/oppo-pad5/backups/lk_a.img bs=1048576
dd if=/dev/block/by-name/lk_b of=/data/local/tmp/oppo-pad5/backups/lk_b.img bs=1048576
dd if=/dev/block/by-name/init_boot_a of=/data/local/tmp/oppo-pad5/backups/init_boot_a.img bs=1048576
dd if=/dev/block/by-name/init_boot_b of=/data/local/tmp/oppo-pad5/backups/init_boot_b.img bs=1048576
sha256sum /data/local/tmp/oppo-pad5/backups/*.img
sync
```

Pull 到电脑后再次计算 `Get-FileHash -Algorithm SHA256`，device 与 host hash 必须一致。备份不能抵消 hard brick 风险；它只是必要条件之一。

## 8. 第五阶段：生成经门禁核对的逻辑计划

先把实际备份 hash 填入命令。确认口令必须完整、区分大小写：

```powershell
.\Start-UnlockWizard.cmd `
  -Mode Plan `
  -AuditReportPath ".\reports\audit.json" `
  -StageReportPath ".\reports\stage.json" `
  -AssetDirectory ".\assets" `
  -Serial "YOUR_ADB_SERIAL" `
  -TemporaryRootAvailable `
  -LocalBackupsPresent `
  -LkBackupSha256 "64_HEX_CHARACTERS" `
  -InitBootBackupSha256 "64_HEX_CHARACTERS" `
  -EnableDestructive `
  -ConfirmationPhrase "I UNDERSTAND OPD2506 DATA WILL BE ERASED"
```

即使全部通过，Preview 也只输出四个逻辑阶段：`write-lk-a`、`set-active-a`、`unlock-and-revalidate`、`flash-init-boot-a`。它不会自动执行这些阶段。

## 9. LK 写边界：仅供已完成独立复核者

先 push 固定 LK 和脚本，再在 root shell 中运行：

```powershell
$adb = "C:\platform-tools\adb.exe"
& $adb push ".\assets\lk.img" "/data/local/tmp/oppo-pad5/lk.img"
& $adb push ".\device\write-lk.sh" "/data/local/tmp/oppo-pad5/write-lk.sh"
& $adb shell su -c 'sh /data/local/tmp/oppo-pad5/write-lk.sh /data/local/tmp/oppo-pad5/lk.img "I UNDERSTAND OPD2506 DATA WILL BE ERASED"'
```

这一步会真实写 `lk_a`，有变砖风险。脚本绝不切 slot；只有它输出的 post-write SHA-256 和 read-only 状态都正确，才有资格研究下一阶段。中断、错误或没有 JSON 成功结果都按失败处理。

### 关于系统“本地安装”

历史路径依赖与当前 build 完全匹配的官方 full OTA 在 inactive slot 完成 staging，再通过系统 update UI 重启。只从系统更新页面的本地安装入口选择精确 full OTA；先核对文件的 9,489,857,569 bytes、MD5 `d91129ab34b195ac12f70baac3525e01` 与 SHA-256 `c3030e151abc6dc59e1dd06ddef7d62fa05298413f0361d7c54d8bc16a59bdea`。

如果本地安装按钮是灰色、file picker 不接受 package、系统准备写入 active slot，或 UI 行为与已记录路径不一致，立即停止。当前 Preview 不包含绕过灰色按钮、伪造 update metadata 或强制 slot 切换的逻辑。

## 10. Slot、解锁与持久化 root

当前 Preview 不自动执行这三步，因为新的自动化没有真机证据，而且设备侧的本地安装/slot 切换仍包含 UI 与 build-specific 行为。不要用未经本 profile 验证的 `bootctl` 或 generic A/B 命令替代。

历史路径是在完成匹配版本的本地系统安装后，通过系统 UI 重启到 target `_a`，再进入 fastboot。执行 `fastboot flashing unlock` 后，host 输出 `OKAY` 不是完成证据；必须重新读取 bootloader variables，并且同时得到：

```text
unlocked: yes
secure: no
```

只有这两个 readback 成立，才允许把精确 hash 的 KernelSU 3.2.5 patched image 刷到 `init_boot_a`。已记录 patch 参数为：

```text
ksud boot-patch -b STOCK_INIT_BOOT -o OUTPUT_DIR --out-name NAME --kmi android15-6.6 --partition init_boot
```

修补结果必须恰好是 8,388,608 bytes，SHA-256 必须与 compatibility manifest 中 `kernelSu325PatchedSha256` 相同。然后才可研究 `fastboot flash init_boot_a PATCHED_IMAGE`。本指南不把该命令包装为“一键”，因为它的前提还没有由新自动化在真机复验。

Bootloader unlock 的 factory reset 会移除 app data。设备完成初次设置后，需要重新安装同一份已校验 KernelSU Manager APK，让 Manager 与已经刷入的 patched `init_boot_a` 建立管理界面；不要在此时再次 patch 或覆盖其他 slot。

## 11. 最终验收

解锁和刷入完成后必须做一次普通 reboot，不接受临时 boot、exploit 尚在内存中或 host-side success 作为持久化证据。验收需要同时满足：

- active slot `_a`；
- `ro.boot.flash.locked=0`；
- `ro.boot.verifiedbootstate=orange`；
- `ksud` 版本 `3.2.5`；
- Shell 经 KernelSU 授权后 `id` 包含 `uid=0(root)`。

可以把这些字段写成 JSON，然后用计划器的 `VerifyPostUnlock` mode 做纯判断。缺少任一字段返回 exit code `40`。

## 12. 恢复边界

如果设备仍能进入已独立确认 unlocked 的 fastboot，才可以研究用本机保存且 hash 已验证的 stock partition image 恢复对应 partition。不要使用来自另一台设备或另一个 build 的 stock image，也不要在 locked/unknown 状态下猜测 flash 权限。

本项目没有证实 OPD2506 在 hard brick 后存在免费、无需 OPPO service authorization 的通用恢复链。能 pull 回来的 partition backups 不等于设备在 BootROM/Preloader 状态下一定能被写回。因此最重要的恢复策略仍是：不匹配就不写、只支持一个方向、写前保存 stock、写后立即 readback，并把任何未知状态当成停止。
