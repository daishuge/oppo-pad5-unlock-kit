#!/system/bin/sh
set -eu

# This is the only LK write boundary. It is deliberately restricted to the one
# exact OPD2506 B-to-A profile recorded in config/compatibility.json.

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
LK_PARTITION_BYTES='16777216'
LK_STOCK_PREFIX_BYTES='9416704'
LK_STOCK_PREFIX_SHA256='0da00158fbed097d8ced1fb61bb2c3c5048fc3a9086996e65715e31ccbbbaede'
LK_IMAGE_BYTES='9416784'
LK_IMAGE_SHA256='eef2ed953a97e4f895b54cb8f06ac8d33e37e6376cedf263f4824e25aa4cb654'
CONFIRMATION_PHRASE='I UNDERSTAND OPD2506 DATA WILL BE ERASED'

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

[ "$#" -eq 2 ] || fail 'usage: write-lk.sh /absolute/path/to/lk.img "confirmation phrase"'
LK_IMAGE="$1"
[ "$2" = "$CONFIRMATION_PHRASE" ] || fail 'exact destructive confirmation phrase is missing'
case "$LK_IMAGE" in
    /*) ;;
    *) fail 'LK image path must be absolute' ;;
esac
[ -f "$LK_IMAGE" ] || fail 'LK image is not a regular file'

[ "$(id -u)" = '0' ] || fail 'root shell is required'
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
require_equal "$(blockdev --getsize64 "$LK_DEVICE")" "$LK_PARTITION_BYTES" 'lk_a partition size'
require_equal "$(wc -c < "$LK_IMAGE" | tr -d '[:space:]')" "$LK_IMAGE_BYTES" 'LK image size'
require_equal "$(sha256sum "$LK_IMAGE" | awk '{print $1}')" "$LK_IMAGE_SHA256" 'LK image SHA-256'

stock_hash="$(head -c "$LK_STOCK_PREFIX_BYTES" "$LK_DEVICE" | sha256sum | awk '{print $1}')"
require_equal "$stock_hash" "$LK_STOCK_PREFIX_SHA256" 'lk_a stock prefix SHA-256'

cleanup() {
    original_status="$?"
    cleanup_status="$original_status"
    blockdev --setro "$LK_DEVICE" >/dev/null 2>&1 || cleanup_status='90'
    readonly_state="$(blockdev --getro "$LK_DEVICE" 2>/dev/null || printf 'unknown')"
    [ "$readonly_state" = '1' ] || cleanup_status='91'
    trap - EXIT INT TERM HUP
    exit "$cleanup_status"
}
trap cleanup EXIT INT TERM HUP

blockdev --setrw "$LK_DEVICE"
dd if="$LK_IMAGE" of="$LK_DEVICE" bs=1048576
sync

readback_hash="$(head -c "$LK_IMAGE_BYTES" "$LK_DEVICE" | sha256sum | awk '{print $1}')"
require_equal "$readback_hash" "$LK_IMAGE_SHA256" 'lk_a post-write readback SHA-256'

blockdev --setro "$LK_DEVICE"
require_equal "$(blockdev --getro "$LK_DEVICE")" '1' 'lk_a read-only state after write'
trap - EXIT INT TERM HUP
printf '{"bytesWritten":%s,"modifiedSha256":"%s","blockDeviceReadOnly":true}\n' "$LK_IMAGE_BYTES" "$readback_hash"
