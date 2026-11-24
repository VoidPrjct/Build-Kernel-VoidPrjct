# VERSIONS — pin komponen VoidPrjct-Scarlet

Semua komponen dipin ke SHA. Kalau pin berubah, ubah di sini dan di
`.github/workflows/build-scarlet.yml` (input default), lalu jalankan ulang.

| Komponen | Pin | Catatan |
|---|---|---|
| Kernel base | `98ab0310f2aec486e84d5d60c36d0575dfb5482a` | android12-5.10, Linux 5.10.274 |
| KernelSU-Next | `896f45a78c0806cfd585c4e14e6989f867b143d7` | dev, 2026-11-21 "kernel: susfs (LKM): fix lsm_hook" |
| SUSFS (susfs4ksu) | `45a05753` | v2.4.0, patch 50 built-in |
| NoMount | `6849f00a342b` | built-in |
| AnyKernel3 | `41f04bdb4ee3` | osm0sis/AnyKernel3 |
| Neutron Clang | `06092026` | Neutron-Toolchains/clang-build-catalogue |

## Catatan bump KernelSU-Next

Pin sebelumnya `32e25d58`, naik 91 commit ke `896f45a7`.
Perubahan besar di upstream: SUSFS dipindah ke `kernel/susfs/` sebagai LKM
terpisah (`susfs_guard_lkm.o`) dengan engine hook sendiri.

Build ini mode built-in, dan `kernel/susfs/` TIDAK ada di `kernel/Kbuild`,
jadi direktori itu tidak ikut dikompilasi. SUSFS tetap dipasang lewat patch 50
(sisi kernel) + `scripts/susfs_compat.c` (sisi KSU), sama seperti sebelumnya.

Simbol yang dipakai `susfs_compat.c` masih utuh di commit ini:
`__ksu_is_allow_uid_for_current`, `ksu_uid_should_umount`,
`ksu_security_secctx_to_secid`, `ksu_handle_setresuid`,
`ksu_install_fd`, `KSU_INSTALL_MAGIC1`.

`feature/selinux_hide.c`, `supercall/dispatch.c`, `kernel/Kconfig`, dan
`kernel/Makefile` identik dengan pin lama, jadi tiga rename simbol SELinux dan
hunk Kconfig/Makefile dari patch 10 tetap berlaku.

Status uji: build hijau belum berarti boot sukses.
