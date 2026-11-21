#!/usr/bin/env bash
# package-anykernel.sh — bungkus Image jadi zip AnyKernel3.
#
# usage: package-anykernel.sh <kernel-dir> <zip-out>
# env:   AK3_SHA, KERNEL_VERSION, OUT_DIR (default: <kernel-dir>/out)

set -euo pipefail

KERNEL_DIR="${1:?usage: package-anykernel.sh <kernel-dir> <zip-out>}"
ZIP_OUT="${2:?usage: package-anykernel.sh <kernel-dir> <zip-out>}"
AK3_SHA="${AK3_SHA:?AK3_SHA belum diisi}"
KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION belum diisi}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"

log() { echo "[ak3] $*"; }
die() { echo "[ak3][FATAL] $*" >&2; exit 1; }

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "Image tidak ditemukan di $IMAGE"
log "Image: $(ls -l "$IMAGE" | awk '{print $5}') byte"

WORK=$(mktemp -d)
git clone --quiet https://github.com/osm0sis/AnyKernel3.git "$WORK/ak3" || die "clone AnyKernel3 gagal"
git -C "$WORK/ak3" checkout --quiet "$AK3_SHA" || die "SHA AnyKernel3 $AK3_SHA tidak ada"
log "AnyKernel3: $(git -C "$WORK/ak3" rev-parse HEAD)"

cd "$WORK/ak3"
rm -rf .git
cp -f "$IMAGE" ./Image

[ -f anykernel.sh ] || die "anykernel.sh tidak ada di template"

# PRD 8: matikan devicecheck supaya banyak device GKI bisa flash.
# Ini TIDAK membuat device non-GKI bisa boot; hanya melewati cek nama device.
sed -i -E 's/^do\.devicecheck=.*/do.devicecheck=0/' anykernel.sh
sed -i -E 's/^do\.modules=.*/do.modules=0/' anykernel.sh
sed -i -E 's/^do\.systemless=.*/do.systemless=1/' anykernel.sh
sed -i -E 's/^do\.cleanup=.*/do.cleanup=1/' anykernel.sh
sed -i -E 's/^do\.cleanuponabort=.*/do.cleanuponabort=0/' anykernel.sh
sed -i -E 's/^BLOCK=.*/BLOCK=boot/' anykernel.sh
sed -i -E 's/^IS_SLOT_DEVICE=.*/IS_SLOT_DEVICE=auto/' anykernel.sh
sed -i -E 's/^RAMDISK_COMPRESSION=.*/RAMDISK_COMPRESSION=auto/' anykernel.sh
sed -i -E 's/^PATCH_VBMETA_FLAG=.*/PATCH_VBMETA_FLAG=auto/' anykernel.sh
sed -i -E "s|^kernel\.string=.*|kernel.string=VoidPrjct-Scarlet ${KERNEL_VERSION} (KernelSU-Next + SUSFS built-in + NoMount)|" anykernel.sh

# device.name1..5 dikosongkan (PRD 8)
sed -i -E 's/^device\.name[0-9]=.*/device.name1=/' anykernel.sh

# Cek hasil sed benar-benar kena; kalau tidak, lebih baik gagal daripada diam-diam salah.
for kv in 'do.devicecheck=0' 'do.modules=0' 'do.systemless=1' 'do.cleanup=1' 'do.cleanuponabort=0' 'BLOCK=boot'; do
  grep -q "^$kv\$" anykernel.sh || die "gagal set '$kv' di anykernel.sh (template berubah?)"
done
grep -q '^kernel.string=VoidPrjct-Scarlet ' anykernel.sh || die "kernel.string tidak terpasang"

sh -n anykernel.sh || die "anykernel.sh tidak lolos 'sh -n'"

ZIP_NAME="$(basename "$ZIP_OUT")"
zip -q -r9 "$ZIP_OUT" . -x '.git*' -x '*.zip' || die "zip gagal"

log "isi zip:"
unzip -l "$ZIP_OUT" | sed -n '1,20p'
log "ukuran: $(ls -l "$ZIP_OUT" | awk '{print $5}') byte -> $ZIP_NAME"
