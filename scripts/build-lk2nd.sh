#!/usr/bin/env bash

set -Eeuo pipefail

log() {
    printf '[mido-lk2nd] %s\n' "$*"
}

fail() {
    printf '[mido-lk2nd] Error: %s\n' "$*" >&2
    exit 1
}

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/system-artifacts}"
LK2ND_REPOSITORY="${LK2ND_REPOSITORY:-https://github.com/msm8916-mainline/lk2nd.git}"
LK2ND_REF="${LK2ND_REF:-6752fb8abe45e079f13ed203c7198d5a93f965ed}"
LK2ND_BOOT_MEM_SIZE="${LK2ND_BOOT_MEM_SIZE:-0x04000000}"

[[ "$LK2ND_BOOT_MEM_SIZE" =~ ^0x[0-9a-fA-F]+$|^[0-9]+$ ]] ||
    fail "invalid LK2ND_BOOT_MEM_SIZE: $LK2ND_BOOT_MEM_SIZE"

for command in arm-none-eabi-gcc dtc git make sed sha256sum; do
    command -v "$command" >/dev/null || fail "missing required command: $command"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lk2nd-mido.XXXXXX")"
SOURCE_DIR="$WORK_DIR/lk2nd"

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT_DIR"
git init "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$LK2ND_REPOSITORY"
git -C "$SOURCE_DIR" fetch --depth=1 origin "$LK2ND_REF"
git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD

build_lk2nd() {
    make -C "$SOURCE_DIR" -j"$(nproc)" \
        TOOLCHAIN_PREFIX=arm-none-eabi- \
        LK2ND_BOOT_MEM_SIZE="$LK2ND_BOOT_MEM_SIZE" \
        lk2nd-msm8953
    [[ -f "$SOURCE_DIR/build-lk2nd-msm8953/lk2nd.img" ]] ||
        fail "lk2nd build output not found"
}

log "building default touchscreen image"
build_lk2nd
install -m 0644 "$SOURCE_DIR/build-lk2nd-msm8953/lk2nd.img" \
    "$OUTPUT_DIR/lk2nd.img"

MIDO_DTS="$SOURCE_DIR/lk2nd/device/dts/msm8953/msm8953-xiaomi-common.dts"
[[ -f "$MIDO_DTS" ]] || fail "mido lk2nd DTS not found"
FOCALTECH_COUNT="$(grep -c 'touchscreen-compatible = "edt,edt-ft5406"' "$MIDO_DTS" || true)"
(( FOCALTECH_COUNT > 0 )) || fail "expected FocalTech touchscreen entries not found"
sed -i 's/touchscreen-compatible = "edt,edt-ft5406"/touchscreen-compatible = "goodix,gt917d"/g' \
    "$MIDO_DTS"
rm -rf -- "$SOURCE_DIR/build-lk2nd-msm8953"

log "building forced Goodix touchscreen image"
build_lk2nd
install -m 0644 "$SOURCE_DIR/build-lk2nd-msm8953/lk2nd.img" \
    "$OUTPUT_DIR/lk2nd-goodix.img"

git -C "$SOURCE_DIR" rev-parse HEAD > "$OUTPUT_DIR/lk2nd-source-revision.txt"
printf '%s\n' "$LK2ND_BOOT_MEM_SIZE" > "$OUTPUT_DIR/lk2nd-boot-mem-size.txt"
cat > "$OUTPUT_DIR/FLASHING.txt" <<'EOF_FLASHING'
Required:
- Unlocked Xiaomi Redmi Note 4X Qualcomm (mido)
- A computer with fastboot installed
- A complete backup; flashing userdata erases existing data

Choose one lk2nd image:
- lk2nd.img: default touchscreen detection
- lk2nd-goodix.img: force Goodix GT917D for devices where default lk2nd has no touch

Flash from the original bootloader fastboot mode:
  fastboot erase boot
  fastboot erase system
  fastboot erase userdata
  fastboot flash boot lk2nd.img
  fastboot reboot

After the phone enters lk2nd fastboot mode:
  fastboot flash system bootfs-simg.img
  fastboot flash userdata rootfs-simg.img
  fastboot reboot

Use lk2nd-goodix.img instead of lk2nd.img only for the forced Goodix variant.
EOF_FLASHING

(
    cd "$OUTPUT_DIR"
    sha256sum ./*.img > SHA256SUMS
)

log "lk2nd images created in $OUTPUT_DIR"
