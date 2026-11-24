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

# arm64 Image punya magic "ARM\x64" di offset 0x38 (56) menurut header boot
# resmi. Ini membedakan Image sungguhan dari berkas terpotong atau kosong --
# sesuatu yang tidak bisa ditangkap 'ls -l'.
MAGIC=$(dd if="$IMAGE" bs=1 skip=56 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "41524d64" ] || die "Image bukan arm64 Image: magic di 0x38 = '$MAGIC' (harus 41524d64)"
log "magic arm64 Image di 0x38: OK"

# Header arm64 (Documentation/arm64/booting.rst) menaruh image_size di offset
# 0x10, little-endian. Kalau ia lebih besar dari berkas, Image terpotong.
FILE_SIZE=$(stat -c %s "$IMAGE")
IMG_SIZE=$(dd if="$IMAGE" bs=1 skip=16 count=8 2>/dev/null | od -An -tu8 | tr -d ' ')
[ -n "$IMG_SIZE" ] && [ "$IMG_SIZE" -le "$FILE_SIZE" ] \
  || die "image_size di header ($IMG_SIZE) melebihi ukuran berkas ($FILE_SIZE)"
log "image_size header: $IMG_SIZE <= $FILE_SIZE"

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
# anykernel.sh TIDAK di-source oleh AnyKernel3; ia dibaca dengan
# file_getprop() = `grep "^name=" | tail -n1 | cut -d= -f2-`. Jadi nilai di sini
# harus polos: menambahkan tanda kutip akan ikut tercetak di layar recovery.
# Format: 5.10.27X-VoidPrjct-Scarlet (tanpa embel-embel KSU/SUSFS/NoMount).
sed -i -E "s|^kernel\.string=.*|kernel.string=${KERNEL_VERSION}-VoidPrjct-Scarlet|" anykernel.sh

# PRD 8: devicecheck dimatikan, dan nama device tidak boleh mengklaim device
# tertentu. device.name1 diisi label kernel (dipakai sebagian installer untuk
# mencetak nama kernel), device.name2..5 dihapus supaya tidak ada sisa nama
# contoh (maguro/toro/...). file_getprop memakai `tail -n1`, jadi jumlah baris
# tidak memengaruhi pembacaan -- ini murni kebersihan isi zip.
sed -i -E "s|^device\.name1=.*|device.name1=VoidPrjct-Scarlet|" anykernel.sh
sed -i -E '/^device\.name[2-5]=/d' anykernel.sh

# Cek hasil sed benar-benar kena; kalau tidak, lebih baik gagal daripada diam-diam salah.
for kv in 'do.devicecheck=0' 'do.modules=0' 'do.systemless=1' 'do.cleanup=1' 'do.cleanuponabort=0' 'BLOCK=boot'; do
  grep -q "^$kv\$" anykernel.sh || die "gagal set '$kv' di anykernel.sh (template berubah?)"
done
grep -q "^kernel.string=${KERNEL_VERSION}-VoidPrjct-Scarlet\$" anykernel.sh || die "kernel.string tidak terpasang"
grep -q '^device.name1=VoidPrjct-Scarlet$' anykernel.sh || die "device.name1 tidak terpasang"
if grep -qE '^device\.name[2-5]=' anykernel.sh; then
  die "masih ada device.name2..5 (nama device contoh dari template)"
fi
if grep -qE '^(kernel\.string|device\.name1)="' anykernel.sh; then
  die "nilai berkutip: anykernel.sh dibaca dengan grep/cut, kutip akan ikut tercetak"
fi

# Banner SCARLET: disisipkan sebelum dump_boot sehingga tampil paling awal
# di layar recovery saat flash. Font box-bar pilihan user (2026-11-24),
# semua baris ui_print pakai single-quote, backslash literal.
python3 - "$KERNEL_VERSION" <<'PYEOF' || die "penyisipan banner gagal"
import sys
path = "anykernel.sh"
s = open(path).read()
anchor = "\ndump_boot;"
assert s.count(anchor) == 1, "anchor dump_boot tidak unik"
banner = (
    'ui_print " ";\n'
    r"ui_print '=============================================';" + "\n"
    r"ui_print ' ____   ____    _    ____  _     _____ _____ ';" + "\n"
    r"ui_print '/ ___| / ___|  / \  |  _ \| |   | ____|_   _|';" + "\n"
    r"ui_print '\___ \| |     / _ \ | |_) | |   |  _|   | |  ';" + "\n"
    r"ui_print ' ___) | |___ / ___ \|  _ <| |___| |___  | |  ';" + "\n"
    r"ui_print '|____/ \____/_/   \_\_| \_\_____|_____| |_|  ';" + "\n"
    r"ui_print '---------------------------------------------';" + "\n"
    r"ui_print '      GKI KERNEL  |  ANDROID 12  |  5.10';" + "\n"
    r"ui_print '=============================================';" + "\n"
    'ui_print " ";\n'
)
s = s.replace(anchor, "\n" + banner + "dump_boot;", 1)
open(path, "w").write(s)
print("[ak3] banner SCARLET disisipkan")

# Boot lebih cepet (aman): jalankan SETELAH dump_boot (butuh SPLITIMG),
# sebelum write_boot. Tanpa ini driver di-probe seriel satu per satu dan
# console dihujani log -- keduanya makan waktu detik-an di fase init kernel.
# - module.async_probe=true : probe modul paralel (param global, 5.10 ada)
# - loglevel=4              : sama seperti 'quiet', console cuma warning ke atas
boot_anchor = "\nwrite_boot;"
assert s.count(boot_anchor) == 1, "anchor write_boot tidak unik"
fastboot = (
    "# boot lebih cepet: probe driver paralel + kurangi log kernel console\n"
    'patch_cmdline module.async_probe "module.async_probe=true";\n'
    'patch_cmdline loglevel "loglevel=4";\n'
)
s = s.replace(boot_anchor, "\n" + fastboot + "write_boot;", 1)
open(path, "w").write(s)
print("[ak3] patch_cmdline boot cepat disisipkan")
PYEOF

grep -q "ui_print ' ____   ____    _    ____  _     _____ _____ '" anykernel.sh || die "banner SCARLET tidak terpasang"
grep -q "GKI KERNEL  |  ANDROID 12  |  5.10" anykernel.sh || die "banner subtitle tidak terpasang"
grep -q 'patch_cmdline module.async_probe' anykernel.sh || die "patch_cmdline async_probe tidak terpasang"
grep -q 'patch_cmdline loglevel' anykernel.sh || die "patch_cmdline loglevel tidak terpasang"

sh -n anykernel.sh || die "anykernel.sh tidak lolos 'sh -n'"

ZIP_NAME="$(basename "$ZIP_OUT")"
zip -q -r9 "$ZIP_OUT" . -x '.git*' -x '*.zip' || die "zip gagal"

log "isi zip:"
unzip -l "$ZIP_OUT" | sed -n '1,20p'
log "ukuran: $(ls -l "$ZIP_OUT" | awk '{print $5}') byte -> $ZIP_NAME"
