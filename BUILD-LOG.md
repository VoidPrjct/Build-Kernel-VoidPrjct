# BUILD-LOG — VoidPrjct-Scarlet

Catatan run, error, penyebab, perbaikan (PRD §9).

---

## 2026-11-21 — Persiapan

### Audit tahap 2 (selesai)

Dibaca langsung dari API GitHub/GitLab, bukan dari ingatan.

| Repo | Temuan |
|---|---|
| `VoidPrjct/Build-Kernel-VoidPrjct` | kosong total: 0 file, 0 commit, 0 workflow |
| `VoidPrjct/android_kernel_common-5.10` | 1 branch `android12-5.10` @ `b1f875995dfb`, Linux 5.10.272, `gki_defconfig` ada |
| Branch kerja `scarlet/android12-5.10` | belum ada |

### Koreksi terhadap PRD (dengan bukti)

1. **SUSFS "tag v2.4.0" tidak ada.** Tag tertinggi untuk `gki-android12-5.10` adalah
   `1.4.2-gki-android12-5.10`. Versi 2.4.0 hanya ada sebagai commit `45a05753`
   ("Bump version to 2.4.0", 2026-11-08). Yang dipin: SHA itu.
2. **Nama asset Neutron terverifikasi**, bukan tebakan: `neutron-clang-06092026.tar.zst`
   (satu-satunya asset pada release `06092026`).
3. **Patch SUSFS menyentuh 5 file**, bukan 2: patch 50, patch 10, `fs/susfs.c`,
   `include/linux/susfs.h`, `include/linux/susfs_def.h`.

### Masalah: patch sisi KernelSU tidak bisa dipasang di KernelSU-Next

Hasil uji patch sungguhan (`git apply --check`), bukan perkiraan:

| Target | `10_enable_susfs_for_ksu.patch` |
|---|---|
| KernelSU-Next `dev` (`32e25d58`) | 14/32 gagal |
| KernelSU-Next `v3.4.2` | 17/32 gagal |
| KernelSU-Next `v3.2.0` | 28/32 gagal |
| KernelSU-Next `legacy` | 24/32 gagal |
| KernelSU-Next `v3.0.1-legacy` | 32/32 gagal |
| KernelSU resmi (`tiann/KernelSU`) | 31/32 bisa |

File yang gagal di KSU-Next `dev`: `kernel/Kbuild`, `core/init.c`, `feature/kernel_umount.c`,
`feature/selinux_hide.c`, `feature/sucompat.c`, `hook/setuid_hook.c`, `include/ksu.h`,
`runtime/boot_event.c`, `selinux/rules.c`, `selinux/sepolicy.c`, `sulog/event.c`,
`sulog/event.h`, `supercall/dispatch.c`, `supercall/supercall.c`.

Penyebab: README susfs menyatakan patch-nya berbasis **KernelSU resmi (weishu)**.
KernelSU-Next sudah menulis ulang file-file itu dan punya SUSFS sendiri.

### Uji tabrakan hook (diminta pemilik)

SUSFS bawaan KernelSU-Next ternyata **LKM** (`kernel/susfs/Makefile`: `obj-m += susfs_guard_lkm.o`),
bukan built-in — jadi PRD §6.2 + §6.3 tidak bisa dipenuhi sekaligus.

Bila patch 50 dipaksa berdampingan dengan LKM itu, tabrakannya nyata pada fungsi yang sama:

| Fungsi | Patch 50 (compile time) | KSU-Next (runtime) |
|---|---|---|
| `s_show` (`kernel/kallsyms.c`) | menyisipkan filter `ksu_*`/`susfs_*` | `hk_inline_hook("s_show")` menimpa prolog |
| `vfs_statfs` (`fs/statfs.c`) | `susfs_statfs_by_dentry()` + spoof kstat | kprobe + `find_kernel_symbol_exact("vfs_statfs")` |
| `vfs_readlink` (`fs/namei.c`) | `susfs_open_redirect_spoof_vfs_readlink()` | `susfs_open_redirect.c` sendiri |
| tabel LSM | `selinux_hooks[]` saat compile | memanipulasi `security_hook_heads` saat runtime |

Bukan duplikat simbol linker, jadi build bisa hijau lalu rusak saat device jalan.

### Keputusan pemilik

1. Langsung full stack (bukan baseline dulu).
2. KernelSU-Next tetap dipakai.
3. SUSFS built-in dari patch 50 dipasang; **LKM `susfs_guard_lkm` milik KSU-Next dibuang.**

### Rancangan integrasi yang dipakai

Patch 50 (`kernel/reboot.c`) memanggil `ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)`,
dan `fs/susfs.c` memerlukan `susfs_is_current_ksu_domain()` dan kawan-kawan. Fungsi-fungsi
itu aslinya disediakan patch 10. Karena patch 10 tidak bisa dipasang, semuanya ditulis di
`scripts/susfs_compat.c` terhadap API KernelSU-Next:

- SID memakai `ksu_security_secctx_to_secid()` milik KSU-Next.
- Konteks domain ksu memakai `KERNEL_SU_CONTEXT` milik KSU-Next (`u:r:ksu:s0`),
  **bukan** `u:r:su:s0` milik KernelSU resmi.
- Dispatcher `CMD_SUSFS_*` disalin dari patch 10, dengan `default: return -EINVAL`
  supaya `reboot()` normal dan jalur KSU-Next sendiri tidak terganggu.
- Hanya dua hunk patch 10 yang dipakai: `kernel/Kconfig` (menambah `CONFIG_KSU_SUSFS_*`)
  dan `kernel/Makefile` (hanya mencetak versi).

### Risiko yang dicatat sebelum build pertama

- `feature/sucompat.c` KernelSU-Next berbeda dari KernelSU resmi. Fitur SUSFS yang
  bergantung pada sucompat (penyamaran `su` saat eksekusi) kemungkinan belum setara.
- Clang 24 (Neutron) jauh lebih baru dari toolchain 5.10 Google; warning-jadi-error
  dan kode lama yang gagal diprediksi muncul.
- Manager APK dari run `44888862619` adalah manager KernelSU-Next. Karena SUSFS kini
  built-in di kernel (bukan LKM KSU-Next), tab SUSFS di manager bisa saja tidak mengenali
  jalurnya. Akan diuji pemilik.

### Status

Belum ada run. Menunggu workflow di-push dan dijalankan.
