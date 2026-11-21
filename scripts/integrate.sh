#!/usr/bin/env bash
# integrate.sh — pasang KernelSU-Next + SUSFS built-in + NoMount ke kernel tree.
#
# Dijalankan di runner GitHub Actions, bukan di device. Tidak ada build di sini.
# Semua komponen dipin ke SHA (lihat VERSIONS.md). Kalau ada yang gagal, skrip
# berhenti dengan pesan jelas dan menulis .rej ke folder kerja untuk diunggah.
#
# env:
#   KERNEL_DIR    root kernel tree (sudah di-checkout)
#   KSU_SHA       SHA KernelSU-Next
#   SUSFS_COMMIT  commit susfs4ksu
#   NOMOUNT_SHA   SHA NoMount
#   WORKDIR       folder kerja (default /tmp/scarlet)

set -euo pipefail

: "${KERNEL_DIR:?KERNEL_DIR belum diisi}"
: "${KSU_SHA:?KSU_SHA belum diisi}"
: "${SUSFS_COMMIT:?SUSFS_COMMIT belum diisi}"
: "${NOMOUNT_SHA:?NOMOUNT_SHA belum diisi}"
WORKDIR="${WORKDIR:-/tmp/scarlet}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo "[integrate] $*"; }
warn() { echo "[integrate][WARN] $*" >&2; }
die()  { echo "[integrate][FATAL] $*" >&2; exit 1; }

mkdir -p "$WORKDIR"

cd "$KERNEL_DIR"
[ -f Makefile ] || die "tidak ada Makefile di $KERNEL_DIR"
KVER=$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{print v"."p"."s}' Makefile)
log "kernel tree: $PWD"
log "versi kernel: $KVER"
[ "$KVER" = "5.10.272" ] || warn "versi kernel $KVER, VERSIONS.md mencatat 5.10.272"

# ---------------------------------------------------------------------------
# 1. KernelSU-Next
# ---------------------------------------------------------------------------
log "== KernelSU-Next =="
KSU_SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/${KSU_SHA}/kernel/setup.sh"
curl -fsSL "$KSU_SETUP_URL" -o "$WORKDIR/ksu-setup.sh" \
    || die "gagal mengambil setup.sh KernelSU-Next pada $KSU_SHA"

# setup.sh men-checkout target yang diberikan, TAPI kalau checkout gagal dia
# diam-diam pakai branch default (ini diperingatkan di PRD 6.2). Karena itu
# SHA diverifikasi ulang setelahnya.
sh "$WORKDIR/ksu-setup.sh" "$KSU_SHA" || die "setup.sh KernelSU-Next gagal"

# setup.sh menaruh hasil clone di $GKI_ROOT/$REPO, dan REPO="$OWNER" = KernelSU-Next.
# (Diuji di run 44928994659: folder-nya memang KernelSU-Next, bukan KernelSU.)
KSU_DIR="$KERNEL_DIR/KernelSU-Next"

[ -d "$KSU_DIR" ] || die "folder KernelSU-Next tidak terbentuk di $KSU_DIR"
GOT_KSU=$(git -C "$KSU_DIR" rev-parse HEAD)
if [ "$GOT_KSU" != "$KSU_SHA" ]; then
    die "KernelSU-Next salah checkout: dapat $GOT_KSU, harusnya $KSU_SHA (setup.sh kemungkinan fallback ke branch default)"
fi
log "KernelSU-Next OK: $GOT_KSU"

if [ -e drivers/kernelsu ] && [ ! -L drivers/kernelsu ]; then
    die "drivers/kernelsu ada tapi bukan symlink; struktur tidak sesuai harapan"
fi
log "symlink drivers/kernelsu -> $(readlink drivers/kernelsu || echo '?')"

# ---------------------------------------------------------------------------
# 2. SUSFS sisi kernel (patch 50)
# ---------------------------------------------------------------------------
log "== SUSFS $SUSFS_COMMIT =="
# Ambil file lewat raw API GitLab, bukan git clone: clone penuh repo ini 746 MB,
# sedangkan 5 file yang dibutuhkan totalnya ~310 KB. Ref-nya commit, jadi tetap pinned.
SUSFS_P="$WORKDIR/susfs4ksu"
mkdir -p "$SUSFS_P/fs" "$SUSFS_P/include/linux" "$SUSFS_P/KernelSU"
GL_PROJ="simonpunk%2Fsusfs4ksu"
gl_raw() { # $1=path di repo, $2=tujuan
    local enc
    enc=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1")
    curl -fsSL --retry 3 \
        "https://gitlab.com/api/v4/projects/${GL_PROJ}/repository/files/${enc}/raw?ref=${SUSFS_COMMIT}" \
        -o "$2" || die "gagal mengambil '$1' dari susfs4ksu@${SUSFS_COMMIT}"
}
gl_raw "kernel_patches/50_add_susfs_in_gki-android12-5.10.patch" "$SUSFS_P/50.patch"
gl_raw "kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"  "$SUSFS_P/10.patch"
gl_raw "kernel_patches/fs/susfs.c"                              "$SUSFS_P/fs/susfs.c"
gl_raw "kernel_patches/include/linux/susfs.h"                   "$SUSFS_P/include/linux/susfs.h"
gl_raw "kernel_patches/include/linux/susfs_def.h"               "$SUSFS_P/include/linux/susfs_def.h"

for f in "$SUSFS_P/50.patch" "$SUSFS_P/10.patch" "$SUSFS_P/fs/susfs.c" \
         "$SUSFS_P/include/linux/susfs.h" "$SUSFS_P/include/linux/susfs_def.h"; do
    [ -s "$f" ] || die "file SUSFS kosong/gagal diunduh: $f"
done
log "5 file SUSFS terunduh ($(du -sk "$SUSFS_P" | cut -f1) KB)"

cp -f "$SUSFS_P/fs/susfs.c" fs/susfs.c
cp -f "$SUSFS_P/include/linux/susfs.h" "$SUSFS_P/include/linux/susfs_def.h" include/linux/
log "salin fs/susfs.c + include/linux/susfs{,_def}.h"

log "terapkan patch 50 (sisi kernel)"
if ! git apply --verbose "$SUSFS_P/50.patch" 2> "$WORKDIR/patch50.err"; then
    cat "$WORKDIR/patch50.err" >&2
    find fs security kernel mm block drivers -name '*.rej' 2>/dev/null | head -40 >&2
    die "patch 50 gagal (lihat log). Ini tidak diharapkan: pada uji lokal patch ini pas 27/27 file."
fi
log "patch 50 OK"

# ---------------------------------------------------------------------------
# 3. Bagian sisi KernelSU dari patch 10
# ---------------------------------------------------------------------------
log "== sisi KernelSU dari patch 10 =="
P10="$SUSFS_P/10.patch"
[ -f "$P10" ] || die "patch 10 tidak ditemukan"

# Hanya dua file yang memang cocok dengan struktur KernelSU-Next:
#   kernel/Kconfig  -> menambahkan CONFIG_KSU_SUSFS_*
#   kernel/Makefile -> hanya mencetak SUSFS_VERSION saat build
# Sisanya (32 file) tidak dipakai; penggantinya ada di scripts/susfs_compat.c
( cd "$KSU_DIR" && git apply --include='kernel/Kconfig' --include='kernel/Makefile' "$P10" ) \
    || die "hunk Kconfig/Makefile patch 10 gagal (struktur KernelSU-Next berubah?)"
log "CONFIG_KSU_SUSFS_* ditambahkan ke KernelSU-Next/kernel/Kconfig"

grep -q 'config KSU_SUSFS$' "$KSU_DIR/kernel/Kconfig" \
    || die "CONFIG_KSU_SUSFS tidak masuk ke Kconfig"

log "pasang susfs_compat.c (pengganti bagian sisi KernelSU)"
cp -f "$SCRIPTS_DIR/susfs_compat.c" "$KSU_DIR/kernel/susfs_compat.c"
if ! grep -q 'susfs_compat\.o' "$KSU_DIR/kernel/Kbuild"; then
    printf 'kernelsu-objs += susfs_compat.o\n' >> "$KSU_DIR/kernel/Kbuild"
fi
log "susfs_compat.c terpasang"

# ---------------------------------------------------------------------------
# 4. NoMount (built-in)
# ---------------------------------------------------------------------------
log "== NoMount $NOMOUNT_SHA =="
NOMOUNT_URL="https://raw.githubusercontent.com/maxsteeel/nomount/${NOMOUNT_SHA}/kernel/setup.sh"
curl -fsSL "$NOMOUNT_URL" -o "$WORKDIR/nomount-setup.sh" \
    || die "gagal mengambil setup.sh NoMount pada $NOMOUNT_SHA"
sh "$WORKDIR/nomount-setup.sh" "$NOMOUNT_SHA" || die "setup.sh NoMount gagal"

[ -f fs/nomount/Kconfig ] || die "fs/nomount/Kconfig tidak ada setelah setup"
# setup.sh NoMount menyisipkan baris ini sebelum endmenu terakhir.
grep -q 'fs/nomount/Kconfig' fs/Kconfig || die "source fs/nomount/Kconfig tidak masuk ke fs/Kconfig"
grep -q 'nomount' fs/Makefile || die "obj NOMOUNT tidak masuk ke fs/Makefile"
GOT_NM=$(git -C NoMount rev-parse HEAD)
if [ "$GOT_NM" != "$NOMOUNT_SHA" ]; then
    die "NoMount salah checkout: dapat $GOT_NM, harusnya $NOMOUNT_SHA"
fi
log "NoMount OK: $GOT_NM"

# ---------------------------------------------------------------------------
# 5. Ringkasan hasil
# ---------------------------------------------------------------------------
log "== ringkasan =="
log "KernelSU-Next : $GOT_KSU"
log "SUSFS        : $SUSFS_COMMIT (v2.4.0, patch 50 built-in)"
log "NoMount      : $GOT_NM"
log "integrasi selesai"
