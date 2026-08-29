#!/system/bin/sh
set -eu

# This script is intentionally physically read-only. It only reads properties and
# inactive-slot block devices; it never changes block-device mode or writes data.

PROFILE_ID='opd2506-cn-16.0.9.400-b-to-a'
EXPECTED_MODEL='OPD2506'
EXPECTED_DEVICE='OP6542L1'
EXPECTED_DISPLAY='OPD2506_16.0.9.400(CN01)'
EXPECTED_OTA='OPD2506_11.A.33_0330_202607091921'
EXPECTED_KERNEL='6.6.118-android15-8-ge58033dc8ea6-abogki498046332-4k'
EXPECTED_SLOT='_b'
EXPECTED_LOCKED='1'
EXPECTED_BOOT_STATE='green'
MIN_BATTERY='60'
LK_DEVICE='/dev/block/by-name/lk_a'
INIT_BOOT_DEVICE='/dev/block/by-name/init_boot_a'
LK_PARTITION_BYTES='16777216'
LK_PREFIX_BYTES='9416704'
LK_PREFIX_SHA256='0da00158fbed097d8ced1fb61bb2c3c5048fc3a9086996e65715e31ccbbbaede'
INIT_BOOT_BYTES='8388608'
INIT_BOOT_SHA256='745e8f8f9804d90d362286b9078b90850e0f5c0877ae641d71924729b77a6e28'

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

require_equal() {
    actual="$1"
    expected="$2"
    label="$3"
    [ "$actual" = "$expected" ] || fail "$label mismatch"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

[ "$(id -u)" = '0' ] || fail 'root shell is required for inactive-slot verification'
require_equal "$(getprop ro.product.model)" "$EXPECTED_MODEL" 'model'
require_equal "$(getprop ro.product.device)" "$EXPECTED_DEVICE" 'device'
require_equal "$(getprop ro.build.display.id)" "$EXPECTED_DISPLAY" 'display build'
require_equal "$(getprop ro.build.version.ota)" "$EXPECTED_OTA" 'OTA version'
require_equal "$(uname -r)" "$EXPECTED_KERNEL" 'kernel'
require_equal "$(getprop ro.boot.slot_suffix)" "$EXPECTED_SLOT" 'active slot'
require_equal "$(getprop ro.boot.flash.locked)" "$EXPECTED_LOCKED" 'flash-lock state'
require_equal "$(getprop ro.boot.verifiedbootstate)" "$EXPECTED_BOOT_STATE" 'verified-boot state'

battery="$(dumpsys battery | awk -F: '/^[[:space:]]*level:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
[ -n "$battery" ] || fail 'battery level could not be parsed'
[ "$battery" -ge "$MIN_BATTERY" ] || fail 'battery is below the destructive-work threshold'

[ -b "$LK_DEVICE" ] || fail 'lk_a block device is missing'
[ -b "$INIT_BOOT_DEVICE" ] || fail 'init_boot_a block device is missing'
lk_bytes="$(blockdev --getsize64 "$LK_DEVICE")"
init_boot_bytes="$(blockdev --getsize64 "$INIT_BOOT_DEVICE")"
require_equal "$lk_bytes" "$LK_PARTITION_BYTES" 'lk_a partition size'
require_equal "$init_boot_bytes" "$INIT_BOOT_BYTES" 'init_boot_a partition size'

lk_prefix_hash="$(head -c "$LK_PREFIX_BYTES" "$LK_DEVICE" | sha256sum | awk '{print $1}')"
init_boot_hash="$(sha256_file "$INIT_BOOT_DEVICE")"
require_equal "$lk_prefix_hash" "$LK_PREFIX_SHA256" 'lk_a stock prefix SHA-256'
require_equal "$init_boot_hash" "$INIT_BOOT_SHA256" 'init_boot_a stock SHA-256'

printf '{\n'
printf '  "schemaVersion": 1,\n'
printf '  "evidenceClass": "device-read-only-stage-audit",\n'
printf '  "profileId": "%s",\n' "$PROFILE_ID"
printf '  "targetSlot": "_a",\n'
printf '  "batteryPercent": %s,\n' "$battery"
printf '  "lkPartitionBytes": %s,\n' "$lk_bytes"
printf '  "lkStockPrefixSha256": "%s",\n' "$lk_prefix_hash"
printf '  "initBootPartitionBytes": %s,\n' "$init_boot_bytes"
printf '  "initBootStockSha256": "%s"\n' "$init_boot_hash"
printf '}\n'
