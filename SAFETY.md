# Safety model

## 先说结论

本仓库不能消除解锁 bootloader、写 LK 和刷 `init_boot` 的固有风险。它的目标是缩小允许操作的状态空间，并让“不确定”自动变成停止，而不是继续猜测。

[AOSP bootloader 文档](https://source.android.com/docs/core/architecture/bootloader/locking_unlocking) 明确说明，用户确认 `fastboot flashing unlock` 后设备应执行 factory data reset；因此任何“无损解锁、保留全部数据”的承诺都不可信。

## 三类入口

### 物理只读

`Start-ReadOnlyCheck.cmd` 只允许白名单中的命令：`adb devices -l`、单项 `getprop`、`uname -r`、`dumpsys battery` 与读取 mobile-data/roaming 设置。源代码测试拒绝 `install`、`push`、`reboot`、`su`、`fastboot` 和分区写入 token。

`device/verify-stage.sh` 需要已有 root 才能读取 inactive slot，但脚本本身不包含 `setrw`、`dd of=`、slot 切换或 reboot。

### 计划器

`Start-UnlockWizard.cmd` 即使得到 `-EnableDestructive` 和完整确认口令，也只生成逻辑计划和本地 state。它不自动运行 device tools。State 会记录设备 fingerprint、source/target slot、stock/modified hash 与本地备份 hash；恢复时还必须重新收集 live evidence。

### 单一写边界

`device/write-lk.sh` 是唯一包含 LK 写入的文件。它硬编码目标为 `lk_a`，只接受绝对路径的普通文件；写前核对 exact identity、电量、锁状态、partition size、stock prefix 和 image hash；写后重新读取写入区计算 SHA-256。EXIT/INT/TERM/HUP trap 会尝试恢复 read-only，恢复失败返回非零状态。

## 必须由操作者承担的边界

- 保留两份可离线读取的 `lk_a`、`lk_b`、`init_boot_a`、`init_boot_b` 备份与 SHA-256。
- 了解 bootloader unlock 会清除 data；应用内部私有数据不能靠普通 `adb pull` 完整备份。
- 在设备上亲自确认 bootloader warning。AOSP 也要求从 locked 到 unlocked 的转换包含物理交互。
- 不把 host-side `OKAY` 当作完成。必须重新读取 fastboot variables。
- 不在没有已证实硬砖恢复路径时，把 LK 写入视为“可随便回滚”。

## 稳定退出码

| Code | 含义 |
|---:|---|
| 0 | 检查通过，或 post-unlock 证据完整 |
| 10 | identity 不兼容 |
| 11 | ADB transport 缺失、未授权或有歧义 |
| 12 | 资产大小/hash 不匹配 |
| 20 | 需要人工输入、准备或操作 |
| 30 | destructive gate 被拒绝 |
| 40 | live device state 与已有 state/预期发生漂移 |

非零退出码不是让脚本“重试到成功”的提示。先查明原因；不要循环运行 exploit 或写入边界。
