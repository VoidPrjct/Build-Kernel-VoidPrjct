# VERSIONS — VoidPrjct-Scarlet

Semua komponen dipin ke tag atau SHA. Nilai di bawah dibaca langsung dari sumbernya
(API GitHub/GitLab atau source), bukan dari ingatan. Tanggal catat: 2026-11-21.

## Kernel

| Item | Nilai |
|---|---|
| Repo | `VoidPrjct/android_kernel_common-5.10` |
| Branch base | `android12-5.10` |
| Commit base | `b1f875995dfb999f995404924836d959fece46a5` (author 2026-05-11, commit 2026-10-26) |
| Pin dipaksakan | ya — workflow berhenti kalau tip branch ≠ SHA di atas |
| Versi kernel | `5.10.272` |
| Branch kerja | `scarlet/android12-5.10` |
| Upstream fork dari | `ramabondanp/android_kernel_common-5.10` |
| `arch/arm64/configs/gki_defconfig` | ada |
| ABI definition | `android/abi_gki_aarch64.xml` |

## Komponen

| Komponen | Sumber | Pin |
|---|---|---|
| KernelSU-Next | `KernelSU-Next/KernelSU-Next` | branch `dev`, SHA `32e25d58fc1a187e1abe7278904c31571235fc83` (2026-11-21) |
| SUSFS | `gitlab.com/simonpunk/susfs4ksu` | commit `45a05753` — "Bump version to 2.4.0" (2026-11-08), branch `gki-android12-5.10` |
| NoMount | `maxsteeel/nomount` | branch `master`, SHA `6849f00a342b` |
| Neutron Clang | `Neutron-Toolchains/clang-build-catalogue` | tag `06092026`, asset `neutron-clang-06092026.tar.zst` (77.768.187 byte) |
| AnyKernel3 | `osm0sis/AnyKernel3` | `master` @ `41f04bdb4ee3` (2026-10-27) |
| Manager APK | run `KernelSU-Next/KernelSU-Next` #`44888862619`, artifact `manager` (16.653.464 byte) | cocok dengan KSU-Next `dev` @ `32e25d58fc1a` |

Catatan versi SUSFS: **tidak ada tag `v2.4.0`** di susfs4ksu. Versi 2.4.0 hanya ada sebagai
commit message. Karena itu yang dipin adalah SHA `45a05753`, bukan tag.
Tag terakhir untuk branch ini adalah `1.4.2-gki-android12-5.10`.

## Hasil verifikasi patch (diuji, bukan asumsi)

| Uji | Hasil |
|---|---|
| `kernel_patches/50_add_susfs_in_gki-android12-5.10.patch` vs fork `5.10.272` | **27/27 file pas, 0 error** |
| `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch` vs KernelSU-Next `dev` | **14/32 file gagal** |
| patch 10 vs KernelSU resmi (`tiann/KernelSU`) | 31/32 (hanya `kernel/feature/selinux_hide.c` gagal) |
| patch 10 vs KSU-Next `v3.4.2` / `v3.2.0` / `legacy` / `v3.0.1-legacy` | 17 / 28 / 24 / 32 gagal |

Konsekuensi: SUSFS **built-in** dipakai lewat patch 50 (sisi kernel). Sisi KernelSU dari
patch 10 tidak bisa dipasang, jadi bagian yang dibutuhkan ditulis ulang di
`scripts/susfs_compat.c` terhadap API KernelSU-Next. Lihat `BUILD-LOG.md`.

## Uji device

| Item | Hasil |
|---|---|
| Status | **berhasil boot dan berjalan** (dilaporkan pemilik, 2026-11-21) |
| Build | run `44942666978`, zip `VoidPrjct-Scarlet-5.10.272-20261121.zip` |
| Kernel berjalan | `5.10.272-gb1f875995dfb` (cocok dengan pin base) |
| Android | 15 (API 35), aarch64 |
| KernelSU-Next | `Working` `BUILT-IN (GKI2)` `v3.4.2 (33555-6)`, hook `Tracepoint` |
| SUSFS | `Supported \| v2.4.0 (GKI)` — handshake versi berjalan |
| NoMount | metamodule `Installed \| NoMount v2.3.1 (785)` |
| SELinux | `Enforcing` |

Belum diuji: fungsi SUSFS satu per satu, dan device selain yang diuji di atas.

## Keputusan yang diambil pemilik

1. **Langsung full stack** — KSU-Next + SUSFS + NoMount ditulis sekaligus (bukan baseline dulu).
2. **SUSFS built-in 2.4.0 dipaksa** meski KernelSU-Next punya SUSFS sendiri (sebagai LKM `susfs_guard_lkm.ko`).
3. LKM `susfs_guard_lkm` milik KernelSU-Next **tidak dipakai** — dibuang dari build.

Yang masih menyimpang dari PRD dan diketahui:

- PRD §6.2 minta KernelSU-Next built-in: **dipenuhi.**
- PRD §6.3 minta SUSFS built-in: **dipenuhi** lewat patch 50.
- Sisi KernelSU dari patch 10 tidak dipakai (tidak bisa menempel). Penggantinya adalah kode
  porting di `scripts/susfs_compat.c`. Ini penyimpangan yang perlu dicatat di catatan rilis.
- Fitur SUSFS yang bergantung pada sucompat KernelSU (penyamaran `su` saat eksekusi) belum
  tentu setara, karena `feature/sucompat.c` KernelSU-Next berbeda dari KernelSU resmi.
