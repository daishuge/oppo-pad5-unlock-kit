# Third-party notices

This repository contains original orchestration, validation, and documentation. It does not claim ownership of Android Platform-Tools, KernelSU, GhostLock, the modified LK image, or OPPO firmware.

## KernelSU

KernelSU is developed at <https://github.com/tiann/KernelSU>. The compatibility manifest pins Manager v3.2.5 from the official GitHub release. Kernel code is licensed under GPL-2.0-only; other upstream components are licensed under GPL-3.0-or-later. This repository downloads the official asset and does not modify or redistribute it.

## GhostLock

GhostLock is developed at <https://github.com/YuKongA/ghostlock-app> under Apache-2.0. The only tested artifact recorded by this preview corresponds to commit `e9e10f276c1d41596ec559e9359a930ef3e72302`. The toolkit requires the user to supply the APK and validates its exact byte length and SHA-256; the APK is not committed here.

## Modified LK image and original tutorial

The OPPO Pad 5 tutorial repository is <https://github.com/ZincGluxx/OPPO-Pad-5-Unlock>. At the time this toolkit was prepared, that repository did not publish a license. Therefore `lk.img` is not copied into this repository or its release assets. The fetcher references the file at exact upstream commit `e13b657dfaa925df38fbe73802e7e928aa00aa7e` and accepts it only when its size and SHA-256 match the compatibility manifest.

## Android Platform-Tools

Android SDK Platform-Tools are provided by Google under the Android SDK terms at <https://developer.android.com/tools/releases/platform-tools>. They are not bundled or automatically accepted on the user's behalf.

## OPPO firmware

The ColorOS package remains OPPO-provided firmware. It is never mirrored by this repository. Users must obtain it from an authorized source and validate the exact size, MD5, and SHA-256 recorded in the compatibility manifest.
