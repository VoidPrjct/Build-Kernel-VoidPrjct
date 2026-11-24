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

## Catatan bump kernel 5.10.274 -> 5.10.275

Upstream via merge tag `v5.10.275` (gregkh/linux) langsung ke branch
`android12-5.10`, konflik diresolusi manual (komit `99d99725`):

- nfsd, fanotify, fs/verity, f2fs: tetap versi android (lineage lama,
  pola yang sama dipakai merge aosp) -- perubahan 275 untuk subsistem ini di-drop.
- mm/mmap: vendor hook `addr` dipertahankan + `min_addr` (fix mmap_min_addr) 275 masuk.
- mm/mremap: struktur pgt versi fork (refactor get_old_pmd 275 di-drop).
- mm/Kconfig: SPF android + entry GUP_TEST (pengganti GUP_BENCHMARK).
- fs/dcache: `d_splice_alias_ops()` + export NS GKI (dibutuhkan fs/proc/base.c 275).
- overlayfs: signature `ovl_dir_read_merged()` 4-arg + `ovl_revert_creds()`.
- 8250_exar & pci.h: field baru 275 + `ANDROID_KABI_RESERVE` dipertahankan.

Verifikasi pasca-merge: `mglru.patch` apply bersih, SUSFS patch 50 apply
bersih (tanpa fuzz) di atas tree 275+MGLRU.

## Catatan rollback MGLRU (2026-11-24)

Build 5.10.275 + MGLRU (run #36) **bootloop** di device. MGLRU dihapus total
dari pipeline (integrate.sh, scarlet.fragment, scripts/mglru.patch) sambil
di-bisect: kernel tetap 5.10.275 (pin 99d99725). Patch MGLRU diarsipkan di
riwayat git repo build, bisa dihidupkan lagi kalau nanti mau diteruskan.

## PUTUSKAN: upstream 5.10.275 DITUNDA (2026-11-24)

Build #36 (275+MGLRU) dan #37 (275 tanpa MGLRU) dua-duanya **bootloop**.
Kesimpulan: pelakunya merge upstream 275-nya, bukan MGLRU. Maintainer lain
untuk device sejenis juga membatalkan update 275 dengan alasan sama.

- Branch `android12-5.10` fork dikembalikan ke `98ab0310` (274).
- Hasil merge 275 + resolusi konflik diarsipkan di branch `wip/upstream-275`
  (`99d99725`) — jangan dihapus, dipakai kalau nanti mau coba lagi pelan-pelan.
- MGLRU juga masih diarsip di riwayat git repo build ini.

## Revisi: MGLRU dipasang lagi di atas 274 (2026-11-24)

Setelah bisect: #36 (275+MGLRU) dan #37 (275 tanpa MGLRU) bootloop -> pelakunya
merge upstream 275, MGLRU belum terbukti bersalah. Sesuai keputusan user,
MGLRU dipasang kembali di atas base 274 (98ab0310). Patch yang dipakai =
versi fix 2-arg/3-arg (commit 3d3e2832, dengan page_lru eksplisit).
Catatan: kombinasi 274+MGLRU belum pernah diuji boot -- kalau build ini
bootloop juga, kandidat berikutnya MGLRU sendiri (hapus lagi).

## HASIL AKHIR bisect (2026-11-24, malam)

Build #39 (274 + MGLRU): boot jalan tapi crash/reboot 30 detik-1 menit.
Kesimpulan final: **MGLRU backport belum stabil di base ini** (dugaan kuat
crash saat reclaim/LRU aktif setelah userspace jalan). Keputusan: MGLRU
dihapus lagi dari pipeline. Konfigurasi stabil = 274 + KSU/SUSFS/NoMount +
scarlet, tanpa MGLRU. Patch tetap diarsip di riwayat git (commit 6ab86f69),
JANGAN dipasang lagi sebelum ada waktu debug serius (ramdump/last_kmsg).
