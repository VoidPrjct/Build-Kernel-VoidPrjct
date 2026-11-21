# VoidPrjct-Scarlet — Build-Kernel

Repo build untuk kernel GKI `android12-5.10` (Linux 5.10.272) dengan
KernelSU-Next built-in, SUSFS v2.4.0 built-in, dan NoMount built-in.

Tidak ada kompilasi di device. Semua build lewat GitHub Actions.

## Isi repo

| Path | Fungsi |
|---|---|
| `.github/workflows/build-scarlet.yml` | pipeline utama (PRD §7) |
| `scripts/integrate.sh` | pasang KSU-Next + patch SUSFS 50 + NoMount ke kernel tree |
| `scripts/susfs_compat.c` | pengganti bagian sisi KernelSU dari patch 10, karena tidak cocok dengan KSU-Next |
| `scripts/scarlet.fragment` | config fragment |
| `scripts/verify-config.sh` | verifikasi simbol di `out/.config` (PRD 6.6) |
| `scripts/package-anykernel.sh` | bungkus `Image` jadi zip AnyKernel3 |
| `VERSIONS.md` | semua pin SHA/tag |
| `BUILD-LOG.md` | catatan run, error, penyebab, perbaikan |

## Menjalankan

Actions → `build-scarlet` → Run workflow.

- `mode: check` — hanya memasang integrasi dan memverifikasi config. Cepat (~5 menit).
- `mode: build` — sampai `Image` dan zip AnyKernel3. Lama.

Pin default sudah terisi. `susfs_commit` = `45a05753` adalah commit "Bump version to 2.4.0".

## Secret

`KERNEL_PAT` — fine-grained PAT, hanya dua repo (`VoidPrjct/Build-Kernel-VoidPrjct` dan
`VoidPrjct/android_kernel_common-5.10`), izin Contents RW + Actions RW + Workflows RW +
Metadata R. Dipakai untuk clone fork dan push branch integrasi. GitHub memask nilai secret
di log otomatis.

## Status

Rilis diberi label **belum diuji di device**. Build hijau bukan bukti boot sukses.
