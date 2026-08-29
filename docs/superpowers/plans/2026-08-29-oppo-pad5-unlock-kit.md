# OPPO Pad 5 Unlock Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a Windows-first preview toolkit with a genuinely read-only validator and a separately gated, resumable unlock wizard for the exact tested OPPO Pad 5 firmware/kernel profile.

**Architecture:** A dependency-injected PowerShell module owns parsing, compatibility decisions, state validation, and external-tool execution. Two thin entry points expose separate trust boundaries: `Check-OPPOPad5.ps1` cannot call mutating ADB/Fastboot operations, while `Start-OPPOPad5Unlock.ps1` loads the same validators but requires an explicit destructive switch, a typed phrase, current-state revalidation, and hash readback before every write. Device-side shell scripts are fixed-input programs with no free-form command evaluation.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, Android Platform-Tools, POSIX `sh`/Android Toybox, JSON compatibility profiles, GitHub Actions.

---

## File map

- `src/UnlockKit.psm1`: pure parsers, compatibility matching, tool invocation wrappers, state-file validation, asset hashing, and safety gates.
- `config/compatibility.json`: the only supported OPD2506 build/kernel/partition/hash profile and pinned third-party asset metadata.
- `Check-OPPOPad5.ps1`: read-only audit/asset validation entry point; contains no install, push, reboot, `su`, block-device, or fastboot mutation calls.
- `Start-OPPOPad5Unlock.ps1`: advanced staged wizard for preparation, inactive-slot staging, unlock verification, persistent-root flash, and final verification.
- `device/verify-stage.sh`: root-side read-only verification and partition backup for the inactive slot.
- `device/write-lk.sh`: fail-closed LK writer with exact pre-hash, source hash, byte size, post-readback hash, and read-only restoration.
- `Start-ReadOnlyCheck.cmd` and `Start-UnlockWizard.cmd`: double-click Windows launchers.
- `tests/run-tests.ps1`: dependency-free regression harness covering both Windows PowerShell 5.1 and PowerShell 7.
- `tests/fixtures/*.json`: mock ADB/Fastboot transcripts and device snapshots.
- `.github/workflows/test.yml`: Windows dual-shell tests plus Linux shell syntax/static checks.
- `README.md`, `docs/TUTORIAL.zh-CN.md`, `docs/COMPATIBILITY.md`, `docs/SAFETY.md`, `THIRD_PARTY_NOTICES.md`, `SECURITY.md`: public guidance and evidence boundaries.

### Task 1: Compatibility contract and pure parsers

**Files:**
- Create: `config/compatibility.json`
- Create: `src/UnlockKit.psm1`
- Create: `tests/run-tests.ps1`
- Create: `tests/fixtures/adb-devices-single.txt`
- Create: `tests/fixtures/adb-devices-multiple.txt`
- Create: `tests/fixtures/fastboot-unlocked.txt`
- Create: `tests/fixtures/fastboot-false-okay.txt`

- [ ] **Step 1: Write failing parser and manifest tests**

Tests assert that one authorized device is selected, multiple devices are rejected without `-Serial`, exact serial selection works, malformed manifest hashes are rejected, and fastboot `OKAY` without `unlocked: yes` is not accepted.

- [ ] **Step 2: Run the harness and confirm failure**

Run: `pwsh -NoProfile -File .\tests\run-tests.ps1`

Expected: non-zero exit because `UnlockKit.psm1` does not yet exist.

- [ ] **Step 3: Implement the manifest and pure parser functions**

Required exported signatures:

```powershell
Read-UnlockCompatibilityManifest -Path <json>
ConvertFrom-AdbDevices -Text <string>
Select-AdbSerial -Devices <object[]> -Serial <optional string>
ConvertFrom-FastbootVariables -Text <string>
Test-FastbootUnlocked -Variables <hashtable>
Resolve-CompatibilityProfile -Manifest <object> -Snapshot <object>
```

- [ ] **Step 4: Run both shells**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
```

Expected: all Task 1 cases pass on both hosts.

- [ ] **Step 5: Commit**

Commit message: `feat: add fail-closed compatibility contract`

### Task 2: Read-only validator boundary

**Files:**
- Create: `Check-OPPOPad5.ps1`
- Modify: `src/UnlockKit.psm1`
- Modify: `tests/run-tests.ps1`
- Create: `tests/fixtures/device-supported.json`
- Create: `tests/fixtures/device-wrong-kernel.json`

- [ ] **Step 1: Add failing command-policy tests**

The safe entry point must reject any planned command containing `install`, `push`, `reboot`, `setrw`, `dd if=`, `flash`, `flashing unlock`, `set_active`, or `su -c`. Tests also scan the file source for these forbidden operation tokens outside its help text.

- [ ] **Step 2: Implement injected read-only collection**

The validator may call only `adb devices -l`, individual `getprop`, `uname -r`, `dumpsys battery`, and read-only global settings queries. It produces a structured JSON report when `-OutputJson` is supplied and masks the serial in console output.

- [ ] **Step 3: Add exact mismatch reporting**

The output lists every mismatched field rather than returning a generic unsupported error. Active slot `_a` is reported as unverified for the preview destructive workflow even when the build and kernel match.

- [ ] **Step 4: Run both shells and source-policy checks**

Expected: supported fixture passes; wrong model/build/kernel, low battery, unauthorized device, and multiple-device fixtures fail with distinct messages.

- [ ] **Step 5: Commit**

Commit message: `feat: add physically read-only device validator`

### Task 3: Pinned asset verifier and fetcher

**Files:**
- Modify: `src/UnlockKit.psm1`
- Create: `Get-OPPOPad5Assets.ps1`
- Modify: `tests/run-tests.ps1`
- Create: `THIRD_PARTY_NOTICES.md`

- [ ] **Step 1: Add failing size/hash/source tests**

Tests cover correct files, same-size wrong content, truncated content, stale download partials, and a manifest URL changed without a hash change.

- [ ] **Step 2: Implement atomic downloads**

Small assets download to `.partial`, validate exact byte length and SHA-256, then atomically rename. The 9.49 GB OTA supports a caller-supplied path and resumable `curl.exe`; the tool refuses to use a completed-looking OTA until both size and SHA-256 match.

- [ ] **Step 3: Enforce redistribution boundaries**

KernelSU comes from its official release. GhostLock is attributed to its Apache-2.0 source commit. `lk.img` is never committed or attached because the tutorial repository has no license; it is fetched from the exact upstream commit and hash-checked. Google Platform-Tools are not redistributed and require the user to accept Google's SDK terms from the official page.

- [ ] **Step 4: Run offline fixture tests**

No network is required for tests; the downloader is injected and writes deterministic fixture bytes.

- [ ] **Step 5: Commit**

Commit message: `feat: verify pinned unlock assets atomically`

### Task 4: Guarded destructive state machine

**Files:**
- Create: `Start-OPPOPad5Unlock.ps1`
- Create: `device/verify-stage.sh`
- Create: `device/write-lk.sh`
- Modify: `src/UnlockKit.psm1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Add failing transition tests**

The mock matrix covers fresh locked stock, unsupported kernel, active `_a`, missing temporary root, unstaged inactive slot, wrong LK partition size, wrong stock prefix hash, interrupted write, fastboot disconnect, first unlock command returning `OKAY` while still locked, verified unlock, and already-complete persistent root.

- [ ] **Step 2: Implement signed-by-revalidation state**

The state file records serial, exact profile ID, source/target slots, asset hashes, partition backup hashes, patched `init_boot` hash, and completed stages. Every resume re-collects live identity and rejects drift; the state file alone never authorizes a write.

- [ ] **Step 3: Implement the write boundary**

Destructive stages require all of: `-EnableDestructive`, exact typed phrase `I UNDERSTAND OPD2506 DATA WILL BE ERASED`, supported profile, active `_b`, target `_a`, locked/green pre-state, battery at least 60, root context, exact staged stock hashes, exact source hashes, and local partition backups. `write-lk.sh` always restores the target block device to read-only in a trap and verifies exact bytes after writing.

- [ ] **Step 4: Implement unlock and persistent-root gates**

The wizard accepts `fastboot flashing unlock` success only after a second independent `getvar unlocked` returns `yes` and `getvar secure` returns `no`. It never flashes patched `init_boot_a` on host-side `OKAY` alone. Post-boot verification requires slot `_a`, `ro.boot.flash.locked=0`, `ro.boot.verifiedbootstate=orange`, `ksud 3.2.5`, and `uid=0(root)` after an ordinary reboot.

- [ ] **Step 5: Run the full mock matrix in both shells**

Expected: no destructive mock command is emitted in any failing precondition; the happy-path transcript emits commands in the documented order only.

- [ ] **Step 6: Commit**

Commit message: `feat: add revalidated unlock state machine`

### Task 5: Windows launchers and operator experience

**Files:**
- Create: `Start-ReadOnlyCheck.cmd`
- Create: `Start-UnlockWizard.cmd`
- Modify: `Check-OPPOPad5.ps1`
- Modify: `Start-OPPOPad5Unlock.ps1`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Add path/Unicode/space regression tests**

Run the scripts from a directory containing spaces and Chinese characters. Verify that no nested `cmd /c` string is used for file mutation and all real paths are passed as arguments.

- [ ] **Step 2: Implement double-click launchers**

The read-only launcher is the default recommendation. The advanced launcher displays the preview warning before importing the destructive script and never auto-confirms a phase.

- [ ] **Step 3: Add stable exit codes**

Use `0` for pass/already complete, `10` unsupported identity, `11` ambiguous transport, `12` asset mismatch, `20` user action required, `30` destructive gate denied, and `40` device state changed.

- [ ] **Step 4: Run launcher smoke tests without a device**

Injected fake Platform-Tools supply all transcripts. No process named `adb` or `fastboot` outside the fixture directory may be started.

- [ ] **Step 5: Commit**

Commit message: `feat: add separate safe and advanced launchers`

### Task 6: Public documentation

**Files:**
- Create: `README.md`
- Create: `docs/TUTORIAL.zh-CN.md`
- Create: `docs/COMPATIBILITY.md`
- Create: `docs/SAFETY.md`
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`
- Create: `LICENSE`

- [ ] **Step 1: Write the evidence boundary above the fold**

State that the original manual OPD2506 `_b` to `_a` path was observed on one device, while the new automation has only mock/CI coverage because the owner declined another destructive run. Do not use unsupported guarantee language.

- [ ] **Step 2: Write the complete Chinese tutorial**

Explain prerequisites, official Platform-Tools, exact supported identifiers, temporary GhostLock root, local OTA selection via the system file picker, inactive-slot verification, partition-only safety backups, KernelSU patching, LK write gates, physical unlock confirmation, post-wipe Manager bootstrap, persistent-root reboot proof, stop conditions, and rollback limits.

- [ ] **Step 3: Document recovery truthfully**

Fastboot-accessible failures can use verified stock partition images. A fully hard-bricked OPD2506 has no demonstrated free unauthenticated recovery path in this project; do not imply mtkclient or a public service-auth bypass is available.

- [ ] **Step 4: Run link, placeholder, secret, binary, and wording scans**

Fail on missing local Markdown targets, unfinished placeholder markers, device serials, private backup paths, `.img`/`.apk` files in Git, or unsupported guarantee language.

- [ ] **Step 5: Commit**

Commit message: `docs: publish evidence-bounded unlock guide`

### Task 7: CI and release hygiene

**Files:**
- Create: `.github/workflows/test.yml`
- Create: `.github/ISSUE_TEMPLATE/device-report.yml`
- Create: `.gitignore`
- Modify: `tests/run-tests.ps1`

- [ ] **Step 1: Add Windows dual-shell CI**

Run the complete harness under Windows PowerShell 5.1 and PowerShell 7 on `windows-latest`. Parse every `.ps1`/`.psm1` through the PowerShell AST parser before functional tests.

- [ ] **Step 2: Add Linux shell checks**

Run `bash -n` and `shellcheck` on `device/*.sh`. Tests inspect those scripts for dynamic device/partition paths outside the strict `a|b` whitelist.

- [ ] **Step 3: Add a structured compatibility report template**

Reports request only model, device, build, kernel, starting slot, stage, hashes, and redacted logs. They explicitly tell reporters to remove serial numbers and personal data.

- [ ] **Step 4: Run the exact CI commands locally where available**

Do not connect a real Android device. Record local PowerShell versions and mock result counts in the release notes.

- [ ] **Step 5: Commit**

Commit message: `ci: test unlock kit across shells and failure modes`

### Task 8: Preview publication

**Files:**
- Modify: `D:/codex/project/README.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Initialize and inspect the clean repository**

Confirm Git contains only source, docs, JSON, YAML, CMD, and shell text files. Scan tracked content for personal serials, personal notes, backup paths, tokens, APKs, and images.

- [ ] **Step 2: Create the public GitHub repository**

Repository name: `oppo-pad5-unlock-kit`. Description must include `preview` and `OPD2506 16.0.9.400 only`.

- [ ] **Step 3: Push and wait for CI**

Require all Windows and Linux jobs to pass. If GitHub CI exposes a shell-specific failure, fix it and rerun before any release.

- [ ] **Step 4: Publish a prerelease**

Tag `v0.1.0-preview.1`. Attach only a source ZIP and SHA-256 manifest generated from tracked text; do not attach `lk.img`, OTA ZIP, Platform-Tools, personal backups, or an untraceable APK.

- [ ] **Step 5: Verify the public page anonymously**

Confirm the README warning, tutorial links, license, CI badge, tag, release assets, and issue template are visible from public URLs.

- [ ] **Step 6: Update local project registry and commit**

Record purpose, path, public source, preview status, entry points, and verification method in `D:/codex/project/README.md`.

## Self-review

The plan covers the dual A+C request, forbids real-device execution during development, separates safe and destructive code paths, distinguishes mock evidence from the prior manual observation, tests both supported Windows shells, and refuses unlicensed binary redistribution. Function names and stage names are consistent across tasks. The plan contains no unfinished placeholder marker or unspecified implementation step.
