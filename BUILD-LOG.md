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

---

## Run 44928994659 — mode=check — GAGAL di langkah 5

Error pertama:

```
[integrate][FATAL] folder KernelSU tidak terbentuk
```

Penyebab: `kernel/setup.sh` KernelSU-Next menaruh hasil clone di `$GKI_ROOT/$REPO`
dengan `REPO="$OWNER"` = `KernelSU-Next`, jadi foldernya `KernelSU-Next`, bukan `KernelSU`.

Perbaikan: skrip tidak lagi mengasumsikan nama folder; dipakai variabel `KSU_DIR`.
Semua rujukan `KernelSU/` dan pemeriksaan adanya folder ikut diubah.
Commit `b887429`.

Catatan: SHA KernelSU-Next terverifikasi benar (`32e25d58fc1a`), jadi `setup.sh`
tidak fallback ke branch default.

---

## Run 44929497344 — mode=check — GAGAL di langkah 5

Berhasil sampai:

```
[integrate] KernelSU-Next OK: 32e25d58fc1a187e1abe7278904c31571235fc83
[integrate] symlink drivers/kernelsu -> ../KernelSU-Next/kernel
[integrate] 5 file SUSFS terunduh (328 KB)
[integrate] patch 50 OK
[integrate] CONFIG_KSU_SUSFS_* ditambahkan ke KernelSU-Next/kernel/Kconfig
[integrate] susfs_compat.c terpasang
[integrate] NoMount Setup Done!
```

Lalu gagal pada pemeriksaan milik skrip sendiri:

```
[integrate][FATAL] source fs/nomount/Kconfig tidak masuk ke fs/Kconfig
```

Penyebab: pemeriksaan memakai pola `NOMOUNT` (huruf besar), sedangkan baris yang
disisipkan NoMount adalah `source "fs/nomount/Kconfig"` (huruf kecil, tanpa kata
NOMOUNT). Integrasinya sendiri berhasil; cek saya yang salah.

Perbaikan: pola diganti `fs/nomount/Kconfig`, mengikuti pemeriksaan di
`kernel/setup.sh` NoMount sendiri.

Hasil penting dari run ini: **patch 50 terpasang bersih di tree fork 5.10.272**,
dua hunk patch 10 (Kconfig/Makefile) juga terpasang. Ini membuktikan asumsi
integrasi tahap 1 benar.

---

## Run 44929844514 — mode=build — GAGAL di langkah 5

Integrasi berjalan sampai selesai:

```
[integrate] patch 50 OK
[integrate] CONFIG_KSU_SUSFS_* ditambahkan ke KernelSU-Next/kernel/Kconfig
[integrate] susfs_compat.c terpasang
[integrate] NoMount Setup Done!
```

Lalu gagal pada pemeriksaan milik skrip sendiri:

```
[integrate][FATAL] NoMount salah checkout: dapat 6849f00a342b80338fb4398765f75f014dbcd557, harusnya 6849f00a342b
```

Penyebab: cek membandingkan SHA pin pendek (12 karakter) dengan keluaran
`git rev-parse HEAD` (40 karakter). NoMount-nya **benar** — cek saya yang salah.
Perbaikan: helper `sha_match()` yang membandingkan prefix, dipakai untuk
KernelSU-Next maupun NoMount.

---

## Audit kontrak patch 50 ↔ KernelSU-Next (sebelum run berikutnya)

Dilakukan tanpa menunggu CI, karena satu simbol kurang = link error setelah
satu jam build. Caranya: 71 baris `extern` di dalam patch 50 diekstrak, lalu
setiap simbol dibandingkan dengan KernelSU-Next `dev@32e25d58`.

### Hasil: 18 simbol `ksu_*` yang disentuh patch 50

| Simbol | Di KernelSU-Next | Tindakan |
|---|---|---|
| `__ksu_is_allow_uid_for_current(uid_t)` | ada, sama | pakai apa adanya |
| `ksu_handle_input_handle_event(unsigned*, unsigned*, int*)` | ada, sama | pakai apa adanya |
| `ksu_is_init_rc_hook_enabled` | tidak ada | definisi sendiri, keadaan mati |
| `ksu_is_input_hook_enabled` | tidak ada | definisi sendiri, keadaan mati |
| `ksu_handle_execveat` | tidak ada | stub |
| `ksu_handle_post_execveat_sucompat` | tidak ada | stub |
| `ksu_handle_faccessat` | tidak ada | stub |
| `ksu_handle_stat` | tidak ada | stub |
| `ksu_handle_vfs_fstat` | tidak ada | stub |
| `ksu_handle_sys_read` | ada tapi `static`, tanda tangan beda | stub (tidak bentrok) |
| `ksu_setup_preinit_file` | tidak ada | stub, balik 0 |
| `ksu_preinit_handle_post_execveat` | tidak ada | stub, balik 0 |
| `ksu_selinux_hide_enabled` | ada tapi `static bool` | definisi sendiri (false) |
| `ksu_selinux_hide_running` | ada tapi `static bool` | definisi sendiri (false) |
| `ksu_handle_execveat_sucompat` | ada, **tanda tangan beda** | **rename** |
| `ksu_handle_setresuid` | ada, **tanda tangan beda** | **rename** |
| `ksu_su_compat_enabled` | ada, **tipe beda** | **rename** |
| `ksu_handle_sys_reboot` | tidak ada | dispatcher sendiri (`susfs_compat.c`) |

Selain itu, 11 simbol `susfs_*` yang di-extern patch 50 semuanya sudah
disediakan `fs/susfs.c`, dan seluruh 38 fungsi `susfs_*` yang dipanggil patch 50
punya penyedianya. Tidak ada yang menggantung.

### Tiga rename yang wajib, karena salah panggil = crash, bukan link error

1. `ksu_handle_execveat_sucompat`
   - patch 50: `int (int *fd, struct filename **, void *, void *, int *)`
   - KSU-Next: `long (const char __user **, int, struct pt_regs *)`
   - Dipanggil dari `fs/exec.c`. Kalau nama dibiarkan, KernelSU-Next membaca
     pointer argumen yang salah. → `susfs_ksu_handle_execveat_sucompat`.
2. `ksu_handle_setresuid`
   - patch 50: `int (uid_t ruid, uid_t euid, uid_t suid)`
   - KSU-Next: `int (uid_t old_uid, uid_t new_uid)`
   - Dipanggil dari `kernel/sys.c`. → `susfs_ksu_handle_setresuid`, dengan isi
     yang memakai API KernelSU-Next yang setara.
3. `ksu_su_compat_enabled`
   - patch 50: `struct static_key_true` (lalu `static_branch_likely()`)
   - KSU-Next: `bool __read_mostly = true`
   - `static_branch_likely()` membaca `struct static_key` dari alamat sebuah
     `bool`. → `susfs_ksu_su_compat_enabled`, didefinisikan dengan tipe benar.

Rename dilakukan dengan `sed` pada **baris tambahan patch saja**. Diperiksa
dulu: ketiga nama itu sama sekali tidak muncul di baris konteks patch 50
(2, 2, dan 6 kemunculan, semuanya baris `+`). Setelah rename, `git apply --check`
diulang pada tree probe: **masih pas**, jumlah baris patch tidak berubah.

### Porting `susfs_ksu_handle_setresuid`

Isi fungsinya disalin dari patch 10, dengan dua penyesuaian yang dicatat:

- `disable_seccomp()` tidak bisa dipanggil: di KernelSU-Next ia
  `static void disable_seccomp(void)` di `policy/app_profile.c`. Fungsi itu
  hanya mematikan seccomp untuk aplikasi ber-root, dan KernelSU-Next melakukan
  hal yang sama pada jalurnya sendiri.
- Keputusan umount dan pemasangan fd manager (`ksu_install_fd`) tidak
  diduplikasi, karena KernelSU-Next sudah menjalankannya di hook setuid-nya.
  Yang khas SUSFS dan tetap dikerjakan: penandaan `TIF_PROC_NO_SU` /
  `TIF_PROC_UMOUNTED` dan penjadwalan pekerjaan tunda (`susfs_extra_works`).

Bagian yang justru **tidak** disederhanakan: keputusan uid mana yang perlu
di-umount tetap memakai `ksu_uid_should_umount()` — dan fungsi itu memang ada
di KernelSU-Next, jadi perilakunya sama dengan upstream, bukan perkiraan.

### Static key: kenapa didefinisikan mati

`ksu_is_init_rc_hook_enabled`, `ksu_is_input_hook_enabled`, dan
`susfs_ksu_su_compat_enabled` diinisialisasi `.key.enabled = 0` (bukan
`DEFINE_STATIC_KEY_TRUE()` lalu di-disable saat init). Alasannya: keadaan sudah
benar sejak boot, tidak bergantung urutan init maupun jump-label patching.

Dampaknya: tiga hook milik KernelSU resmi (`ksu_handle_sys_read`,
`ksu_handle_vfs_fstat`, `ksu_handle_input_handle_event`) dan seluruh blok
su-compat di `fs/exec.c` / `fs/open.c` / `fs/stat.c` tidak pernah dipanggil.
Itu memang yang diinginkan: fitur-fitur tersebut sudah dikerjakan KernelSU-Next
dengan mekanismenya sendiri, dan menjalankan dua mekanisme sekaligus bukan
tujuan PRD.

### Resolusi SID: bug yang ditemukan sebelum sempat muncul di CI

Patch 10 memanggil `susfs_set_batch_sid()` dari `selinux.c`, yaitu **setelah**
SELinux policy dimuat. `late_initcall` berjalan sebelum itu, dan
`security_secctx_to_secid()` tanpa policy akan gagal — akibatnya semua SID
tetap 0 selamanya dan `susfs_is_current_ksu_domain()` selalu false.

Penggantinya: resolusi SID dicoba ulang dari dalam fungsi pemeriksaan domain
sendiri, dibatasi paling cepat sekali per detik (fungsi itu dipanggil dari
jalur panas), dan dipaksa sekali lagi saat perintah userspace pertama datang
lewat `ksu_handle_sys_reboot()`. Kalau tetap gagal, SID 0 membuat semua
pemeriksaan domain mengembalikan false — perilaku aman.

---

## Run 44930630905 — mode=build — GAGAL di langkah 7 (Unduh Neutron Clang)

Integrasi lolos seluruhnya (KernelSU-Next, patch 50, rename 3 simbol, patch 10
Kconfig/Makefile, susfs_compat.c, NoMount). Kernel **tidak** sampai dikompilasi.

```
neutron-clang-06092026.tar.zst
clang tidak ditemukan di dalam tarball
toolchain/neutron
toolchain/neutron/bin
toolchain/neutron/bin/clang        <-- ada, tapi ...
```

Penyebab: `bin/clang` di tarball Neutron adalah **symlink**, dan pencarian memakai
`find -type f`, yang menurut definisinya melewatkan symlink. Jadi clang-nya ada,
tapi tidak pernah ditemukan. Tidak ada kaitan dengan nama asset atau tag.

Perbaikan: kandidat tidak lagi disaring berdasarkan tipe berkas, melainkan
**diuji dengan menjalankannya** (`"$c" --version`). Ini juga menangani kasus
symlink rusak (mis. menunjuk path absolut mesin pembuat tarball): kandidat
berikutnya yang dicoba, dan `clang-24` yang berupa berkas nyata akan terpilih.
Diuji lokal pada dua layout tiruan: symlink sehat dan symlink rusak — keduanya
menghasilkan `BIN_DIR` yang benar.

Ditambahkan juga pemeriksaan kelengkapan `llvm-ar`, `llvm-nm`, `llvm-strip`,
`llvm-objcopy`, `llvm-objdump`, `ld.lld` dengan cara yang sama (dijalankan).
Kalau ada yang hilang, langkah ini berhenti sebelum build, bukan setelahnya.

### Perbaikan lain pada workflow di commit ini

- **`env.KVER` pada `with:` tidak bisa dipakai.** Nilai dari `GITHUB_ENV` masuk
  ke environment proses, bukan ke konteks ekspresi `${{ }}`. Nama artifact dan
  `path:` karena itu memakai `steps.package.outputs.*` (dari `GITHUB_OUTPUT`),
  yang selalu terbaca.
- **Rilis kini idempoten.** Tag memuat tanggal, jadi re-run pada hari yang sama
  menabrak rilis yang sudah ada dan `gh release create` langsung gagal. Sekarang
  diperiksa dulu: kalau ada, aset di-upload ulang dengan `--clobber` dan catatan
  diperbarui.
- **Kompilasi terarah diperbaiki.** Target `drivers/kernelsu/susfs_compat.o`
  dihapus: itu objek anggota dari gabungan `kernelsu-objs`, sedangkan
  `drivers/kernelsu/kernelsu.o` sudah mengompilasi **semua** berkas KernelSU-Next
  termasuk `susfs_compat.c` — sekaligus membuktikan baris
  `kernelsu-objs += susfs_compat.o` benar-benar terbaca.

### Audit tanda tangan: deklarasi `extern` multi-baris di patch 50

Pemeriksaan otomatis sebelumnya hanya membaca deklarasi satu baris, sehingga
justru melewatkan yang paling berisiko. Setelah diperbaiki, kelima deklarasi
`extern` panjang (execveat, execveat_sucompat, post_execveat_sucompat,
preinit_handle_post_execveat, handle_faccessat) dicocokkan parameter demi
parameter dengan definisi di `susfs_compat.c`: **semua sama persis**, termasuk
`int*` pada argumen dan urutan `void*`/`int*`.

### Audit `fs/susfs.c`: seluruh extern punya penyedia

Ini yang paling menentukan apakah kernel bisa di-link sama sekali. Tujuh `extern`
di `fs/susfs.c` dan penyedianya:

| Simbol | Penyedia | Bukti |
|---|---|---|
| `susfs_is_current_ksu_domain` | `susfs_compat.c` | patch 50 mendeklarasikannya 5x sebagai `bool(void)` |
| `setup_selinux` | KernelSU-Next | `kernel/selinux/selinux.c:129`, global, bukan `static` |
| `ksu_cred` | KernelSU-Next | `kernel/core/init.c:77` |
| `susfs_get_non_sus_mnt_id_from_mnt` | patch 50 | didefinisikan di `50.patch` L943 |
| `susfs_get_non_sus_vfsmnt_from_vfsmnt` | patch 50 | didefinisikan di `50.patch` L958 |
| `calculate_f_flags_wrapper` | patch 50 | L2297 |
| `statfs_by_dentry_wrapper` | patch 50 | L2293 |

Perhatikan `setup_selinux` dan `ksu_cred`: awalnya tampak seperti milik KernelSU
resmi yang tidak ada di KernelSU-Next, tetapi keduanya ternyata ada di sana
dengan nama sama. Kalau salah satu saja tidak ada, `fs/susfs.c` gagal di-link.

`fs/susfs.c` juga memanggil `setup_selinux("u:r:ksu:s0", cred)` — nama konteks
yang sama dengan `KERNEL_SU_CONTEXT` di KernelSU-Next, bukan `u:r:su:s0`.

---

## Run 44930988701 — dispatch DITOLAK (422) sebelum job berjalan

Saat mencoba dispatch `mode=check`, GitHub menolak:

```
Invalid Argument - failed to parse workflow: (Line: 222, Col: 14): An expression was expected
```

Penyebabnya bukan YAML dan bukan skrip: di dalam **komentar shell** pada langkah
packaging saya menulis ekspresi kosong (`${{ }}`) sebagai contoh. GitHub
mem-parsing seluruh isi berkas workflow sebagai templat, termasuk teks di dalam
komentar, sehingga tanda itu harus dianggap ekspresi dan gagal.

Pelajaran yang langsung diterapkan: sebelum push, workflow diperiksa untuk
(a) ekspresi kosong dan (b) `${{` tanpa `}}` pada baris yang sama. Pemeriksaan
itu sekarang bersih.

## Verifikasi konfigurasi ThinLTO ↔ CFI

Baseline GKI ternyata memakai `CONFIG_LTO_CLANG_FULL=y` + `CONFIG_CFI_CLANG=y`.
Fragment menggantinya ke ThinLTO, jadi pertanyaannya: apakah CFI ikut mati?

Diperiksa di `arch/Kconfig` fork ini:

- `CFI_CLANG` hanya `depends on LTO_CLANG && KALLSYMS`
- `LTO_CLANG` di-`select` oleh `LTO_CLANG_FULL` **maupun** `LTO_CLANG_THIN`
- `KALLSYMS` punya `default y` di 5.10
- `ARCH_SUPPORTS_LTO_CLANG_THIN` di-`select` arm64

Jadi ThinLTO + CFI sah berdampingan di pohon ini, dan CFI tidak akan dibuang
`olddefconfig`. Meskipun begitu, `CONFIG_CFI_CLANG` sekarang masuk daftar yang
diwajibkan `verify-config.sh`, supaya penyimpangan dari GKI tidak terjadi
diam-diam.

## Ruang nama TIF untuk penanda proses

`susfs_def.h` memakai bit TIF 33, 34, 35. Diperiksa pada
`arch/arm64/include/asm/thread_info.h` fork ini: bit tertinggi yang dipakai
adalah **26** (`TIF_TAGGED_ADDR`), jadi 33–35 bebas. KernelSU-Next memakai bit
63 (`TIF_KSU_DISABLE_ESCAPE_WITH_ROOT`), juga tidak bertabrakan.

---

## Run 44931056217 — mode=check — GAGAL di langkah 9 (kompilasi terarah)

Kemajuan: langkah 7 (unduh toolchain) dan langkah 8 (konfigurasi + verifikasi
config) **berhasil**. Kegagalan tinggal di kompilasi terarah:

```
== drivers/kernelsu/kernelsu.o ==
-- KernelSU-Next version: 33555
-- KernelSU-Next tag: v3.4.2
make[4]: *** No rule to make target 'drivers/kernelsu/kernelsu.o'.  Stop.
```

Penyebab pastinya (diperiksa di `scripts/Makefile.build` fork ini, bukan
ditebak): kbuild punya aturan generik

```
$(obj)/%.o: $(src)/%.c ... FORCE
```

yang dipakai untuk target objek tunggal. Untuk `kernelsu.o`, aturan itu butuh
`drivers/kernelsu/kernelsu.c`, sedangkan di KernelSU-Next tidak ada berkas
seperti itu: `kernelsu` adalah nama modul, sumbernya `kernelsu-objs`. Karena
tidak ada sumber yang cocok, target itu memang tidak punya aturan. Jadi bukan
karena "objek gabungan tidak didukung" — penjelasan pertama saya kurang tepat,
dan saya catat yang benar.

Perbaikan: pakai **target direktori** `make drivers/kernelsu/`, yang membangun
`built-in.a` untuk direktori itu, dan karenanya membangun `kernelsu.o` beserta
seluruh `kernelsu-objs` — termasuk `susfs_compat.o`. Ini sama sekali tidak
bergantung pada aturan `%.o: %.c`, dan sekaligus membuktikan baris
`kernelsu-objs += susfs_compat.o` yang kita tambahkan benar-benar terbaca.

Untuk `fs/susfs.c` target satuan tetap dipakai (`make fs/susfs.o`) karena
`fs/susfs.c` memang ada di pohon setelah integrasi, sehingga aturan generik tadi
berlaku.

Catatan lain dari run ini: kbuild melaporkan KernelSU-Next **v3.4.2** (versi
33555), cocok dengan SHA yang dipin.

---

## Run 44931389321 — mode=check — GAGAL di langkah 9, tetapi sampai ke kode

Target direktori bekerja: kompilasi berjalan sampai berkas sungguhan.

```
../security/selinux/include/objsec.h:28:10: fatal error: 'flask.h' file not found
make[3]: *** [../scripts/Makefile.build:274: drivers/kernelsu/infra/file_wrapper.o] Error 1
```

Penyebab, diperiksa di `security/selinux/Makefile` fork ini:

```
$(addprefix $(obj)/,$(selinux-y)): $(obj)/flask.h
$(obj)/flask.h: scripts/selinux/genheaders/genheaders FORCE
```

`flask.h` dan `av_permissions.h` dihasilkan di **objtree**
(`out/security/selinux/`), dan keduanya hanya menjadi prasyarat objek
`security/selinux` sendiri. Sementara `objsec.h` (yang meng-`#include "flask.h"`)
dipakai berkas KernelSU — bahkan sebelum kode kita, KernelSU-Next sendiri sudah
meng-`#include "objsec.h"` di `kernel/selinux/`. Kbuild tidak punya cara tahu
hubungan itu, karena `#include` tidak terlihat oleh make.

Ini bukan cuma masalah mode check: pada `make Image` dengan `-j`, kbuild membangun
`vmlinux-dirs` secara paralel tanpa urutan, jadi `drivers/kernelsu` **bisa**
dikompilasi sebelum `security/selinux` menghasilkan header itu. KernelSU-Next
hidup dengan risiko ini di hulu; di sini tidak dibiarkan bergantung pada nasib.

Perbaikan: direktori `security/selinux/` dibangun lebih dulu, di kedua mode.
Host tool `genheaders` sudah dibangun oleh `make prepare` (terbukti di log run
ini, baris `HOSTCC scripts/selinux/genheaders/genheaders`), jadi langkah ini
tidak butuh `make scripts` terpisah. Karena kbuild inkremental, build penuh
sesudahnya tidak mengerjakan ulang objek apa pun.

### Perubahan susfs_compat.c pada commit ini (belum pernah diuji kompilasi)

1. `susfs_is_current_ksu_domain()` sekarang memanggil `is_ksu_domain()` milik
   KernelSU-Next, bukan membandingkan SID hasil resolusi sendiri. Alasannya
   ditemukan saat membaca `selinux/selinux.c`: `is_sid_match()` sudah menangani
   keadaan "cache SID belum terisi" dengan jatuh ke perbandingan string lewat
   `security_secid_to_secctx`. Jadi fungsinya benar sejak pemanggilan pertama —
   masalah urutan `late_initcall` vs pemuatan policy hilang seluruhnya, bukan
   sekadar dikompensasi timer.
2. Domain zygote/init memakai `is_zygote()` / `is_init()` milik KernelSU-Next.
3. Percobaan resolusi SID dipertahankan, tetapi perannya berubah menjadi hanya
   mengisi variabel — karena patch 50 memakai `susfs_ksu_sid` **secara
   fungsional** (L2640: `sad->tsid == susfs_ksu_sid`), bukan sekadar
   kompatibilitas simbol. Kalau nilainya 0, jalur AVC itu tidak pernah cocok.
4. Perbandingan `zygote_next` diberi syarat `!= 0`, supaya "belum diketahui"
   tidak pernah berarti "cocok".

---

## Run 44931777498 — mode=check — GAGAL, tetapi hampir seluruhnya lolos

Urutan build yang baru bekerja: `security/selinux/` dibangun lebih dulu, dan
`flask.h` punya penyedia saat dibutuhkan. **Seluruh berkas KernelSU-Next
terkompilasi**, termasuk `selinux/inode.c` dan `selinux/selinux.c` yang juga
memakai `objsec.h`:

```
CC      drivers/kernelsu/selinux/selinux.o
CC      drivers/kernelsu/supercall/dispatch.o
CC      drivers/kernelsu/feature/selinux_hide.o
...
CC      drivers/kernelsu/susfs_compat.o
```

Yang gagal hanya berkas kita sendiri, dan penyebabnya sepele:

```
susfs_compat.c:10:59: error: '/*' within block comment [-Werror,-Wcomment]
   10 | ... supercall/*, sulog/*). Patch
```

Saya menulis direktori bergaya `supercall/*` di dalam komentar blok. Diperiksa
ulang dengan penyaring komentar: sekarang tidak ada lagi urutan `/*` di dalam
komentar blok mana pun.

### Yang justru lebih penting dari error itu: `-Werror` berlaku global

`init/Kconfig` fork ini memberi:

```
config WERROR
	bool "Compile the kernel with warnings as errors"
	default y
```

dan `Makefile` baris 797: `KBUILD_CFLAGS-$(CONFIG_WERROR) += -Werror`.

Jadi seluruh kode yang ditambahkan patch 50 (`fs/exec.c`, `fs/open.c`,
`fs/stat.c`, `fs/read_write.c`, `fs/susfs.c`, `kernel/sys.c`, `kernel/reboot.c`,
`security/selinux/*`, `drivers/input/input.c`) juga harus bebas peringatan
dengan Clang 24. Ini risiko nyata untuk build penuh: SUSFS v2.4.0 ditulis untuk
GKI 5.10 yang biasanya dibangun dengan Clang yang jauh lebih tua, sedangkan
peringatan baru bisa muncul di compiler yang lebih baru.

Keputusan: `-Werror` **dibiarkan aktif** (itu baseline GKI). `CONFIG_WERROR`
sekarang masuk daftar wajib di `verify-config.sh`, supaya kalau suatu saat
terpaksa dimatikan, itu jadi keputusan yang tercatat dan menggagalkan verifikasi
-- bukan perubahan diam-diam.

Catatan tambahan: `-Werror=implicit-function-declaration` aktif terlepas dari
`CONFIG_WERROR` (Makefile baris 524), jadi setiap prototipe yang hilang tetap
fatal. Audit simbol sebelumnya menutup risiko itu.
