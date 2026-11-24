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

# Bandingkan dua SHA dengan aman kalau yang satu cuma prefix (mis. pin 12 karakter).
# Dipakai untuk memverifikasi hasil checkout, karena `git rev-parse` selalu
# mengembalikan 40 karakter.
sha_match() {
    local want="$1" got="$2"
    [ "${#want}" -le "${#got}" ] || return 1
    [ "${got:0:${#want}}" = "$want" ]
}

mkdir -p "$WORKDIR"

cd "$KERNEL_DIR"
[ -f Makefile ] || die "tidak ada Makefile di $KERNEL_DIR"
KVER=$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{print v"."p"."s}' Makefile)
log "kernel tree: $PWD"
log "versi kernel: $KVER"
[ "$KVER" = "5.10.274" ] || warn "versi kernel $KVER, VERSIONS.md mencatat 5.10.274"

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
if ! sha_match "$KSU_SHA" "$GOT_KSU"; then
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

# --- Rename tiga simbol yang di KernelSU-Next punya nama sama tetapi tipe
# atau tanda tangan berbeda. Kalau dibiarkan, patch 50 akan memanggil fungsi
# milik KernelSU-Next dengan argumen yang salah (bukan sekadar gagal link):
#
#   ksu_handle_execveat_sucompat : patch 50 int(int*,struct filename**,...)
#                                  KSU-Next long(const char __user**,int,pt_regs*)
#   ksu_handle_setresuid         : patch 50 int(uid_t,uid_t,uid_t)
#                                  KSU-Next int(uid_t,uid_t)
#   ksu_su_compat_enabled        : patch 50 struct static_key_true
#                                  KSU-Next bool __read_mostly
#
# Rinciannya di scripts/susfs_compat.c. Penggantinya disediakan di sana.
# Hanya baris tambahan ('+') yang disentuh; sudah diperiksa bahwa ketiga nama
# ini tidak pernah muncul di baris konteks patch 50.
sed -i -e 's/\bksu_handle_execveat_sucompat\b/susfs_ksu_handle_execveat_sucompat/g' \
       -e 's/\bksu_handle_setresuid\b/susfs_ksu_handle_setresuid/g' \
       -e 's/\bksu_su_compat_enabled\b/susfs_ksu_su_compat_enabled/g' \
       "$SUSFS_P/50.patch"
for n in susfs_ksu_handle_execveat_sucompat susfs_ksu_handle_setresuid susfs_ksu_su_compat_enabled; do
    grep -q "$n" "$SUSFS_P/50.patch" || die "rename '$n' tidak kena di patch 50"
done
grep -qE '\bksu_su_compat_enabled\b' "$SUSFS_P/50.patch" \
    && die "masih ada ksu_su_compat_enabled (bentrok tipe static_key_true vs bool)"
grep -qE '\bksu_handle_setresuid\b' "$SUSFS_P/50.patch" \
    && die "masih ada ksu_handle_setresuid (bentrok tanda tangan)"
grep -qE '\bksu_handle_execveat_sucompat\b' "$SUSFS_P/50.patch" \
    && die "masih ada ksu_handle_execveat_sucompat (bentrok tanda tangan)"
log "3 simbol di-rename agar tidak menabrak tanda tangan KernelSU-Next"

# --- Sesuaikan patch 50 dengan fs/namespace.c hasil 5.10.273 ---------------
# Stable 273 ("namespace: don't inherit MNT_UMOUNT in clone_mnt()") menambah
# |MNT_UMOUNT pada baris ini, jadi baris konteks di patch 50 harus ikut
# diperbarui; kalau tidak, hunk clone_mnt tidak bisa di-apply.
python3 - "$SUSFS_P/50.patch" <<'PYEOF' >&2 || die "penyesuaian konteks clone_mnt di patch 50 gagal"
import sys
p = sys.argv[1]
s = open(p).read()
old = " \tmnt->mnt.mnt_flags &= ~(MNT_WRITE_HOLD|MNT_MARKED|MNT_INTERNAL);\n"
new = " \tmnt->mnt.mnt_flags &= ~(MNT_WRITE_HOLD|MNT_MARKED|MNT_INTERNAL|MNT_UMOUNT);\n"
n = s.count(old)
if n == 1:
    open(p, "w").write(s.replace(old, new))
    print("[integrate] konteks clone_mnt patch 50 disesuaikan ke 5.10.273 (+MNT_UMOUNT)")
elif s.count(new) == 1:
    print("[integrate] konteks clone_mnt patch 50 sudah versi baru")
else:
    sys.exit("baris konteks clone_mnt tidak unik di patch 50 (count=%d)" % n)
PYEOF

# --- Buka tiga simbol selinux_hide.c yang dibutuhkan patch 50 ---------------
# patch 50 (security/selinux/selinuxfs.c) mendeklarasikan:
#   extern struct page *fake_status;
#   extern struct static_key_false fake_status_initialize_key;
#   extern void initialize_fake_status(void);
#
# Ketiganya ADA di feature/selinux_hide.c KernelSU-Next, tetapi `static` --
# persis seperti KernelSU resmi sebelum patch 10 membukanya (lihat diff patch 10
# pada kernel/feature/selinux_hide.c: `-static ...` menjadi `+...`).
# Patch 10 tidak bisa dipasang ke KernelSU-Next, jadi bagian itu dikerjakan di
# sini. Tanpa ini vmlinux gagal link:
#   run 44933625571: undefined symbol fake_status, fake_status_initialize_key,
#   initialize_fake_status.
#
# Catatan: ksu_selinux_hide_enabled/_running sengaja TIDAK dibuka. Keduanya
# tetap `static` milik KernelSU-Next, dan patch 50 membaca variabel milik
# scripts/susfs_compat.c (false). Dengan begitu jalur selinuxfs milik patch 50
# tidak ikut berjalan berdampingan dengan kprobe selinux_hide milik KernelSU-Next.
SH="$KSU_DIR/kernel/feature/selinux_hide.c"
[ -f "$SH" ] || die "feature/selinux_hide.c tidak ditemukan di $SH"

sed -i -E \
  -e 's/^static DEFINE_STATIC_KEY_FALSE\(fake_status_initialize_key\);/DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);/' \
  -e 's/^static struct page \*fake_status = NULL;/struct page *fake_status = NULL;/' \
  -e 's/^static void initialize_fake_status\(\)/void initialize_fake_status(void)/' \
  "$SH"

grep -q '^DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);' "$SH" \
    || die "fake_status_initialize_key masih static (pola file berubah?)"
grep -q '^struct page \*fake_status = NULL;' "$SH" \
    || die "fake_status masih static (pola file berubah?)"
grep -q '^void initialize_fake_status(void)' "$SH" \
    || die "initialize_fake_status masih static (pola file berubah?)"
if grep -qE '^static (struct page \*fake_status|void initialize_fake_status)' "$SH"; then
    die "masih ada definisi static untuk simbol fake_status*"
fi
log "3 simbol selinux_hide dibuka untuk patch 50 (fake_status*)"

# --- Arahkan hook setprocattr KSU ke wrapper SUSFS ---------------------------
# Patch 50 (security/selinux/hooks.c) mengganti registrasi hook setprocattr:
#   LSM_HOOK_INIT(setprocattr, handle_selinux_setprocattr)  [CONFIG_KSU_SUSFS]
# Jadi di security_hook_heads tidak ada lagi 'selinux_setprocattr'; hook KSU
# gagal resolve/mencocokkan target (-ENOENT, muncul sebagai set_feature -38).
# Solusi: pasang hook KSU di wrapper. original = wrapper SUSFS, sehingga
# susfs_selinux_setprocattr (fake status) tetap dipanggil dari my_setprocattr.
sed -i \
  's/KSU_LSM_HOOK_INIT(setprocattr, "selinux_setprocattr", my_setprocattr, 0)/KSU_LSM_HOOK_INIT(setprocattr, "handle_selinux_setprocattr", my_setprocattr, 0)/' \
  "$SH"
grep -q 'KSU_LSM_HOOK_INIT(setprocattr, "handle_selinux_setprocattr", my_setprocattr, 0)' "$SH" \
    || die "target setprocattr tidak berhasil diarahkan ke wrapper susfs (pola berubah?)"
log "setprocattr KSU diarahkan ke wrapper susfs (handle_selinux_setprocattr)"

# --- lsm_hook.c: fallback pencocokan target berdasar nama simbol (kernel CFI) -
# Di kernel CFI (GKI android12-5.10 dengan CONFIG_CFI_CLANG), alamat hook yang
# tersimpan di security_hook_heads adalah trampoline CFI `sym.<hash>.cfi_jt`,
# sedangkan resolusi kallsyms bisa mengembalikan alamat body fungsi `sym`
# (terlihat di device: resolved `selinux_setprocattr+0x0/0x3b8` tapi slot head
# berisi varian .cfi_jt). Perbandingan alamat persis
# (`current_origin == target`) gagal -> enable selinux_hide selalu -ENOENT,
# yang muncul ke manager sebagai set_feature err -38 (ENOSYS dari goto unhook).
# Fix: fallback pencocokan nama kallsyms (prefix + batas '.'/'$').
LH="$KSU_DIR/kernel/hook/lsm_hook.c"
[ -f "$LH" ] || die "hook/lsm_hook.c tidak ditemukan di $LH"

python3 - "$LH" <<'PYEOF2'
import sys
p = sys.argv[1]
s = open(p).read()

helper = '''// Fallback match by kallsyms symbol name. On CFI kernels (e.g. GKI
// android12-5.10 with CONFIG_CFI_CLANG), the address stored in
// security_hook_heads is the jump-table trampoline `sym.<hash>.cfi_jt`,
// while kallsyms name resolution may return the plain function body, so
// exact-address comparison fails. Compare names instead.
static bool ksu_lsm_hook_target_name_match(const char *target_name, void *addr)
{
    char buf[KSYM_SYMBOL_LEN];
    size_t len;

    if (!addr)
        return false;
    if (!kallsyms_lookup((unsigned long)addr, NULL, NULL, NULL, buf))
        return false;
    len = strlen(target_name);
    return strncmp(buf, target_name, len) == 0 &&
           (buf[len] == '\\0' || buf[len] == '.' || buf[len] == '$');
}

int ksu_lsm_hook(struct ksu_lsm_hook *hook)
'''
old_decl = 'int ksu_lsm_hook(struct ksu_lsm_hook *hook)\n'
old_cmp = 'if (current_origin == target) {'
new_cmp = ('if (current_origin == target ||\n'
           '                ksu_lsm_hook_target_name_match(hook->target_name, current_origin)) {')

if 'ksu_lsm_hook_target_name_match' in s:
    print('[integrate] lsm_hook.c: patch nama-target sudah terpasang')
else:
    n = s.count(old_decl)
    if n != 1:
        sys.exit('deklarasi ksu_lsm_hook tidak unik (count=%d)' % n)
    s = s.replace(old_decl, helper)
    n = s.count(old_cmp)
    if n != 1:
        sys.exit('perbandingan target tidak unik (count=%d)' % n)
    s = s.replace(old_cmp, new_cmp)
    open(p, 'w').write(s)
    print('[integrate] lsm_hook.c: fallback pencocokan nama simbol dipasang (CFI)')
PYEOF2

grep -q 'ksu_lsm_hook_target_name_match' "$LH" \
    || die "patch nama-target lsm_hook.c tidak masuk (pola file berubah?)"
log "lsm_hook.c: fallback pencocokan nama simbol (CFI) dipasang"

if ! git apply --verbose "$SUSFS_P/50.patch" 2> "$WORKDIR/patch50.err"; then
    cat "$WORKDIR/patch50.err" >&2
    warn "git apply gagal; coba git apply -3 (blob preimage biasanya ada di riwayat merge)"
    if git apply -3 "$SUSFS_P/50.patch" 2>> "$WORKDIR/patch50.err"; then
        log "patch 50 OK (git apply -3)"
    else
        warn "git apply -3 gagal; coba patch(1) dengan fuzz"
        # git apply atomik: tidak menyisakan hasil parsial. patch(1) hunk-per-hunk.
        if ! patch -p1 --batch --fuzz=10 -i "$SUSFS_P/50.patch" 2>> "$WORKDIR/patch50.err"; then
            cat "$WORKDIR/patch50.err" >&2
            find fs security kernel mm block drivers include -name '*.rej' 2>/dev/null | head -40 >&2
            die "patch 50 gagal di semua metode (git apply, git apply -3, patch --fuzz)"
        fi
        REJ=$(find fs security kernel mm block drivers include -name '*.rej' 2>/dev/null | head -40)
        [ -z "$REJ" ] || { echo "$REJ" >&2; die "ada .rej setelah patch 50 via patch(1)"; }
        log "patch 50 OK (patch --fuzz)"
    fi
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
if ! sha_match "$NOMOUNT_SHA" "$GOT_NM"; then
    die "NoMount salah checkout: dapat $GOT_NM, harusnya $NOMOUNT_SHA"
fi
log "NoMount OK: $GOT_NM"

# ---------------------------------------------------------------------------
# 5. Scarlet gaming: governor CPU/devfreq "scarlet" + label mode hook
# ---------------------------------------------------------------------------
log "== Scarlet gaming =="
for f in "$SCRIPTS_DIR/scarlet/cpufreq_scarlet.c" \
         "$SCRIPTS_DIR/scarlet/governor_scarlet.c" \
         "$SCRIPTS_DIR/scarlet-gaming.patch" \
         "$SCRIPTS_DIR/scarlet-lockdown.py" \
         "$SCRIPTS_DIR/no-thermal-throttle.patch" \
         "$SCRIPTS_DIR/no-critical-shutdown.patch"; do
    [ -s "$f" ] || die "file Scarlet gaming hilang: $f"
done

cp -f "$SCRIPTS_DIR/scarlet/cpufreq_scarlet.c" drivers/cpufreq/cpufreq_scarlet.c
cp -f "$SCRIPTS_DIR/scarlet/governor_scarlet.c" drivers/devfreq/governor_scarlet.c
if ! git apply --verbose "$SCRIPTS_DIR/scarlet-gaming.patch" 2> "$WORKDIR/scarlet-patch.err"; then
    cat "$WORKDIR/scarlet-patch.err" >&2
    die "scarlet-gaming.patch gagal di base ini (Kconfig/Makefile/devfreq.c berubah?)"
fi
log "governor 'scarlet' (CPU + devfreq) + fallback devfreq terpasang"

# VoidPrjct-Scarlet lockdown: matikan thermal throttling + kunci governor dan
# batas frekuensi. HARUS dijalankan SETELAH scarlet-gaming.patch karena keduanya
# menyunting drivers/devfreq/devfreq.c. Skrip berhenti (exit 1) kalau ada pola
# yang tidak cocok tepat sekali, sehingga tidak ada kernel setengah diubah.
python3 "$SCRIPTS_DIR/scarlet-lockdown.py" "$KERNEL_DIR"

# Thermal dibiarkan stok. Patch no-thermal-throttle dan no-critical-shutdown
# TIDAK dipasang lagi: stub cooling yang mengembalikan NULL bukan ERR_PTR,
# sehingga pemanggil yang hanya memeriksa IS_ERR akan memakai pointer NULL.
# Di device MTK/Mali itu kandidat kuat bootloop saat probe gpufreq. Berkas
# patch tetap disimpan di repo, hanya tidak diterapkan.
log "thermal stok (no-thermal-throttle + no-critical-shutdown tidak dipasang)"

# Label mode hook: hook tetap tracepoint, hanya nama yang tampil di manager
# yang berubah Tracepoint -> Scarlet-Hook (kernel/supercall/dispatch.c KSU).
DISPATCH="$KSU_DIR/kernel/supercall/dispatch.c"
[ -f "$DISPATCH" ] || die "dispatch.c tidak ada di $KSU_DIR/kernel/supercall"
grep -qF 'strscpy(cmd.mode, "Tracepoint", sizeof(cmd.mode));' "$DISPATCH" \
    || die 'pola "Tracepoint" tidak ditemukan di dispatch.c (kode KSU berubah?)'
sed -i 's|strscpy(cmd\.mode, "Tracepoint", sizeof(cmd\.mode));|strscpy(cmd.mode, "Scarlet-Hook", sizeof(cmd.mode));|' "$DISPATCH"
grep -qF '"Scarlet-Hook"' "$DISPATCH" || die "label Scarlet-Hook gagal dipasang"
grep -qF '"Tracepoint"' "$DISPATCH" && die "masih ada label Tracepoint"
log "mode hook tampil sebagai Scarlet-Hook (hook tetap Tracepoint)"

# ---------------------------------------------------------------------------
# 6. BORE (Burst-Oriented Response Enhancer) - port 5.15.1.0 ke 5.10
# ---------------------------------------------------------------------------
# Patch ini mengubah kernel/sched/*, jadi diletakkan PALING AKHIR supaya kalau
# gagal, semua langkah sebelumnya sudah terverifikasi dan penyebabnya jelas.
# Tidak menyentuh berkas yang dipatch langkah lain (SUSFS/Scarlet), tapi karena
# `git apply` bersifat atomik, konflik di schedulers akan menggagalkan build di
# sini, bukan diam-diam.
log "== BORE scheduler =="
BORE_PATCH="$SCRIPTS_DIR/bore-5.1.0-510.patch"
[ -s "$BORE_PATCH" ] || die "patch BORE hilang: $BORE_PATCH"
if ! git apply --verbose "$BORE_PATCH" 2> "$WORKDIR/bore-patch.err"; then
    cat "$WORKDIR/bore-patch.err" >&2
    die "bore-5.1.0-510.patch gagal di base ini (kernel/sched/* berubah?)"
fi
grep -q 'Burst-Oriented Response Enhancer' kernel/sched/fair.c \
    || die "patch BORE masuk tapi header fair.c tidak berubah"
grep -q 'sched_bore_reweight' kernel/sched/core.c \
    || die "patch BORE masuk tapi sched_bore_reweight() tidak ada di core.c"
log "BORE 5.1.0 terpasang (fair.c + core.c + sysctl + Kconfig)"

# ---------------------------------------------------------------------------
# 7. Ringkasan hasil
# ---------------------------------------------------------------------------
log "== ringkasan =="
log "KernelSU-Next : $GOT_KSU"
log "SUSFS        : $SUSFS_COMMIT (v2.4.0, patch 50 built-in)"
log "NoMount      : $GOT_NM"
log "BORE         : 5.1.0 (port 5.15 ke 5.10, burst_score di sched_debug)"
log "integrasi selesai"
