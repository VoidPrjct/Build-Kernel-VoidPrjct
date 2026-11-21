// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_compat.c — sisi KernelSU yang dibutuhkan SUSFS built-in (patch 50)
 * saat KernelSU yang dipakai adalah KernelSU-Next.
 *
 * Kenapa file ini ada
 * -------------------
 * kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch dari susfs4ksu v2.4.0
 * tidak bisa dipasang pada KernelSU-Next: 14 dari 32 file gagal (sucompat.c,
 * kernel_umount.c, selinux_hide.c, core/init.c, supercall/*, sulog/*). Patch
 * itu ditulis untuk KernelSU resmi. Sementara patch 50 (sisi kernel) pas
 * 27/27 file, dan patch 50 mengharapkan sejumlah simbol milik pihak KernelSU.
 *
 * File ini mengisi kekosongan itu. Daftar di bawah bukan karangan: ia diambil
 * dari 71 baris `extern` di dalam 50_add_susfs_in_gki-android12-5.10.patch,
 * lalu setiap simbol dibandingkan satu per satu dengan KernelSU-Next
 * dev@32e25d58. Hasilnya ada tiga kelompok.
 *
 * (1) Sudah ada di KernelSU-Next, tanda tangan sama -> dipakai apa adanya:
 *       __ksu_is_allow_uid_for_current(uid_t)
 *       ksu_handle_input_handle_event(unsigned int *, unsigned int *, int *)
 *
 * (2) Tidak ada di pihak manapun -> disediakan di sini sebagai stub yang
 *     sengaja tidak melakukan apa-apa, karena KernelSU-Next sudah punya
 *     mekanisme sendiri dengan pola yang berbeda (kprobe / inline hook),
 *     sehingga meniru API KernelSU resmi hanya akan menambah jalur ganda:
 *       ksu_handle_execveat, ksu_handle_execveat_sucompat(*),
 *       ksu_handle_post_execveat_sucompat, ksu_handle_faccessat,
 *       ksu_handle_stat, ksu_handle_vfs_fstat, ksu_handle_sys_read,
 *       ksu_setup_preinit_file, ksu_preinit_handle_post_execveat,
 *       ksu_is_init_rc_hook_enabled, ksu_is_input_hook_enabled
 *     (*) yang ini justru ADA di KernelSU-Next tetapi dengan tanda tangan
 *         berbeda, jadi namanya di-rename di patch dan versi stub ditaruh di
 *         sini. Lihat catatan "bentrok" di bawah.
 *
 * (3) Ada di KernelSU-Next tetapi tipe/tanda tangannya berbeda -> TIDAK
 *     di-stub, melainkan dipakai versi KernelSU-Next, dan nama di patch 50
 *     di-rename supaya tidak salah panggil. Tiga kasus, ketiganya berbahaya
 *     kalau dibiarkan:
 *       a. ksu_handle_execveat_sucompat
 *            patch 50 : int  (int *fd, struct filename **, void *, void *, int *)
 *            KSU-Next : long (const char __user **, int, struct pt_regs *)
 *          Dipanggil di fs/exec.c saat sesi su. Kalau nama dibiarkan sama,
 *          KernelSU-Next akan membaca pointer argumen yang salah -> crash.
 *          Di-rename ke susfs_ksu_handle_execveat_sucompat.
 *       b. ksu_handle_setresuid
 *            patch 50 : int (uid_t ruid, uid_t euid, uid_t suid)
 *            KSU-Next : int (uid_t old_uid, uid_t new_uid)
 *          Dipanggil di kernel/sys.c. Kalau dibiarkan, hook setuid milik
 *          KernelSU-Next menerima arti argumen yang salah -> logika uid-nya
 *          rusak. Di-rename ke susfs_ksu_handle_setresuid, dan isinya memakai
 *          API KernelSU-Next yang setara (lihat fungsi itu).
 *       c. ksu_su_compat_enabled
 *            patch 50 : struct static_key_true   (lalu static_branch_likely)
 *            KSU-Next : bool __read_mostly = true
 *          Ini bukan sekadar beda tanda tangan: static_branch_likely() membaca
 *          struct static_key dari alamat sebuah bool. Di-rename ke
 *          susfs_ksu_su_compat_enabled dan didefinisikan dengan tipe yang
 *          benar, dalam keadaan MATI (lihat komentar di definisinya).
 *
 * Selain itu, patch 50 membaca dua variabel yang di KernelSU-Next bersifat
 * `static bool` alias tidak bisa dipakai lintas berkas: ksu_selinux_hide_enabled
 * dan ksu_selinux_hide_running (feature/selinux_hide.c). Keduanya
 * didefinisikan di sini sebagai false; patch 50 hanya membacanya, jadi nilainya
 * konsisten dan fitur SUSFS yang bergantung padanya sekadar tidak aktif --
 * KernelSU-Next punya implementasi selinux_hide sendiri.
 *
 * FILE INI BUKAN BAGIAN DARI PROYEK HULU MANA PUN. Kalau ada bug di sini,
 * itu bug di sini.
 */

#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/jump_label.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/susfs_def.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#include "ksu.h"
#include "objsec.h"
#include "policy/allowlist.h"
#include "selinux/selinux.h"

/*
 * Prototipe lebih awal: susfs_try_resolve_sids() memakainya, sedangkan
 * definisinya ada di bawah. susfs.h hanya mendeklarasikan susfs_init().
 */
u32 susfs_get_sid_from_name(const char *secctx_name);
bool susfs_is_sid_equal(const struct cred *cred, u32 sid2);

/*
 * Konteks domain. Empat yang pertama sama dengan definisi di patch 10.
 * KERNEL_SU_CONTEXT milik KernelSU-Next dipakai untuk domain ksu, dan di sana
 * namanya "u:r:ksu:s0" -- BUKAN "u:r:su:s0" milik KernelSU resmi.
 */
#define KERNEL_INIT_DOMAIN "u:r:init:s0"
#define KERNEL_ZYGOTE_DOMAIN "u:r:zygote:s0"
#define KERNEL_ZYGOTE_NEXT_DOMAIN "u:r:zygote_next:s0"
#define KERNEL_PRIV_APP_DOMAIN "u:r:priv_app:s0:c512,c768"

/*
 * SID yang diresolusi dari nama konteks. susfs_ksu_sid dipakai fs/susfs.c dan
 * juga di-extern oleh patch 50, jadi namanya tidak boleh berubah.
 */
u32 susfs_ksu_sid __read_mostly = 0;
u32 susfs_init_sid __read_mostly = 0;
u32 susfs_zygote_sid __read_mostly = 0;
u32 susfs_zygote_next_sid __read_mostly = 0;
u32 susfs_priv_app_sid __read_mostly = 0;

static bool susfs_sids_ready __read_mostly;
static unsigned long susfs_last_sid_try;

/*
 * Resolusi SID butuh SELinux policy yang sudah dimuat, dan policy itu dimuat
 * dari userspace. late_initcall() karena itu hampir selalu gagal.
 *
 * Variabel di atas tetap perlu terisi: patch 50 memakai susfs_ksu_sid secara
 * fungsional (AVC: `sad->tsid == susfs_ksu_sid`), dan bagian zygote_next hanya
 * punya SID sebagai pembandingnya. Percobaan ulang dibatasi paling cepat sekali
 * per detik sampai berhasil; fungsi ini dipanggil dari jalur yang juga dipakai
 * pemeriksaan domain, jadi tidak perlu timer sendiri.
 *
 * Pemeriksaan domain sendiri TIDAK bergantung pada nilai 0/terisi di sini --
 * lihat catatan di susfs_is_current_ksu_domain().
 */
static void susfs_try_resolve_sids(void)
{
	if (likely(susfs_sids_ready))
		return;
	if (!time_after(jiffies, susfs_last_sid_try + HZ))
		return;
	susfs_last_sid_try = jiffies;

	susfs_zygote_sid = 0;
	susfs_zygote_next_sid = 0;
	susfs_ksu_sid = 0;
	susfs_init_sid = 0;
	susfs_priv_app_sid = 0;

	susfs_zygote_sid = susfs_get_sid_from_name(KERNEL_ZYGOTE_DOMAIN);
	susfs_zygote_next_sid = susfs_get_sid_from_name(KERNEL_ZYGOTE_NEXT_DOMAIN);
	susfs_ksu_sid = susfs_get_sid_from_name(KERNEL_SU_CONTEXT);
	susfs_init_sid = susfs_get_sid_from_name(KERNEL_INIT_DOMAIN);
	susfs_priv_app_sid = susfs_get_sid_from_name(KERNEL_PRIV_APP_DOMAIN);

	if (susfs_ksu_sid && susfs_zygote_sid && susfs_init_sid) {
		susfs_sids_ready = true;
		pr_info("susfs: sid siap (ksu=%u init=%u zygote=%u zygote_next=%u priv_app=%u)\n",
			susfs_ksu_sid, susfs_init_sid, susfs_zygote_sid,
			susfs_zygote_next_sid, susfs_priv_app_sid);
	}
}

/*
 * susfs_set_batch_sid() dipanggil patch 10 dari selinux.c setelah policy
 * dimuat. Di sini fungsinya hanya memaksa satu percobaan resolusi.
 */
void susfs_set_batch_sid(void)
{
	susfs_last_sid_try = 0;
	susfs_sids_ready = false;
	susfs_try_resolve_sids();
}

/* ---- pemeriksaan domain: dipakai fs/susfs.c dan patch 50 ---------------- */

/*
 * Pemeriksaan domain TIDAK memakai variabel SID di atas. KernelSU-Next punya
 * is_sid_match() (selinux/selinux.c) yang sudah menangani persis masalah yang
 * saya khawatirkan: kalau cache SID belum terisi (policy belum dimuat), ia jatuh
 * ke perbandingan string lewat security_secid_to_secctx. Jadi is_ksu_domain()
 * benar sejak pemanggilan pertama, tanpa perlu hook "setelah policy dimuat"
 * maupun percobaan ulang. Memakai milik KernelSU-Next juga berarti definisi
 * domainnya satu sumber, bukan dua.
 *
 * susfs_try_resolve_sids() tetap dipanggil dari sini hanya untuk menjaga
 * susfs_ksu_sid terisi: patch 50 memakainya secara fungsional di jalur AVC
 * (50.patch L2640: `sad->tsid == susfs_ksu_sid`). Kalau nilainya 0, jalur itu
 * tidak pernah cocok. Dipanggil paling cepat sekali per detik sampai berhasil.
 */
bool susfs_is_current_ksu_domain(void)
{
	susfs_try_resolve_sids();
	return is_ksu_domain();
}

bool susfs_is_current_zygote_domain(void)
{
	return is_zygote(current_cred());
}

bool susfs_is_current_zygote_next_domain(void)
{
	/*
	 * KernelSU-Next tidak mengenal domain zygote_next, jadi di sini memang
	 * memakai SID hasil resolusi sendiri. Kalau policy tidak punya domain itu,
	 * susfs_zygote_next_sid = 0 dan tidak ada yang cocok -- yang benar.
	 */
	susfs_try_resolve_sids();
	return unlikely(current_sid() == susfs_zygote_next_sid && susfs_zygote_next_sid != 0);
}

bool susfs_is_current_init_domain(void)
{
	return is_init(current_cred());
}

u32 susfs_get_current_sid(void)
{
	return current_sid();
}

u32 susfs_get_sid_from_name(const char *secctx_name)
{
	u32 out_sid = 0;

	if (!secctx_name)
		return 0;
	if (ksu_security_secctx_to_secid(secctx_name, strlen(secctx_name), &out_sid))
		return 0;
	return out_sid;
}

bool susfs_is_sid_equal(const struct cred *cred, u32 sid2)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
	const struct task_security_struct *tsec = selinux_cred(cred);
#else
	const struct cred_security_struct *tsec = selinux_cred(cred);
#endif

	if (!tsec)
		return false;
	return tsec->sid == sid2;
}

/* ---------------------------------------------------------------------------
 * (1)+(2) Variabel yang dibaca patch 50 tetapi tidak bisa datang dari
 * KernelSU-Next.
 * ------------------------------------------------------------------------ */

/*
 * Di KernelSU-Next keduanya `static bool` di feature/selinux_hide.c, jadi
 * tidak punya simbol global. Patch 50 hanya membacanya (tidak pernah menulis),
 * jadi nilai false di sini konsisten: jalur SUSFS yang membutuhkannya -- yang
 * sekarang ditangani implementasi selinux_hide milik KernelSU-Next -- tidak
 * ikut berjalan.
 */
bool ksu_selinux_hide_enabled __read_mostly = false;
bool ksu_selinux_hide_running __read_mostly = false;

/*
 * static key milik KernelSU resmi. Patch 50 memakainya sebagai gerbang:
 *   fs/read_write.c : if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
 *                       ksu_handle_sys_read(fd);
 *   fs/stat.c       : if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
 *                       ksu_handle_vfs_fstat(fd, &stat->size);
 *   drivers/input/input.c : if (static_branch_unlikely(&ksu_is_input_hook_enabled))
 *                       ksu_handle_input_handle_event(&type, &code, &value);
 *
 * Tipe aslinya static_key_true (default hidup). Di sini sengaja didefinisikan
 * dalam keadaan mati (.enabled = 0), sehingga ketiga hook itu tidak pernah
 * dipanggil. Alasannya: hook tersebut milik fitur KernelSU resmi (init.rc,
 * fstat su, input), dan KernelSU-Next mengerjakannya sendiri dengan caranya
 * sendiri. Membiarkannya hidup hanya akan menjalankan dua mekanisme sekaligus.
 *
 * Inisialisasi langsung ke 0 dipilih daripada DEFINE_STATIC_KEY_TRUE() +
 * static_branch_disable() supaya keadaannya sudah benar sejak boot dan tidak
 * bergantung urutan init maupun jump-label patching.
 */
struct static_key_true ksu_is_init_rc_hook_enabled = { .key = { .enabled = ATOMIC_INIT(0) } };
struct static_key_true ksu_is_input_hook_enabled = { .key = { .enabled = ATOMIC_INIT(0) } };

/*
 * Pengganti ksu_su_compat_enabled (lihat catatan bentrok (3c) di atas).
 * Mati: seluruh blok su-compat di fs/exec.c, fs/open.c, dan fs/stat.c
 * dilewati, sehingga tidak ada stub di bawah yang benar-benar dipanggil.
 */
struct static_key_true susfs_ksu_su_compat_enabled = { .key = { .enabled = ATOMIC_INIT(0) } };

/* ---------------------------------------------------------------------------
 * (2) Stub untuk API pihak KernelSU yang tidak ada di KernelSU-Next.
 *
 * Nilai balik yang mengembalikan int dipilih supaya tidak dianggap "menangani"
 * permintaan: di fs/exec.c hasilnya dipakai sebagai
 *     is_su_session = !ksu_handle_execveat(...);
 * jadi non-nol berarti "bukan sesi su" -- itu yang benar di sini, karena
 * sesi su diurus KernelSU-Next pada jalurnya sendiri.
 * ------------------------------------------------------------------------ */

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
			void *envp, int *flags)
{
	return -EINVAL;
}

int susfs_ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				       void *argv, void *envp, int *flags)
{
	return -EINVAL;
}

int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr,
				      void *argv, void *envp, int *flags,
				      int *retval)
{
	return -EINVAL;
}

int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
			 int *unused_flags)
{
	return -EINVAL;
}

int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)
{
	return -EINVAL;
}

void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
}

/*
 * KernelSU-Next punya fungsi bernama sama, tetapi `static` dan bertanda tangan
 * berbeda (runtime/ksud_integration.c), jadi tidak ada bentrok simbol.
 */
void ksu_handle_sys_read(unsigned int fd)
{
}

/*
 * struct user_arg_ptr hanya dideklarasikan di dalam fs/exec.c (bukan di
 * header), jadi tag-nya dimajukan di sini. Yang penting hanya bentuk
 * pointernya, dan itu dipakai apa adanya oleh pemanggil.
 */
struct user_arg_ptr;

int ksu_setup_preinit_file(struct filename **filename_ptr,
			   struct user_arg_ptr *argv_user)
{
	/* <= 0 berarti "bukan sesi preinit"; pemanggil butuh nilai > 0. */
	return 0;
}

int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
				     void *argv_user, void *envp_user,
				     int *flags, int *retval, int *preinit_fd)
{
	return 0;
}

/*
 * ---------------------------------------------------------------------------
 * (3b) susfs_ksu_handle_setresuid()
 *
 * Isinya disalin dari ksu_handle_setresuid() versi patch 10, dengan dua
 * penyesuaian:
 *   - pemanggilan disable_seccomp() dibuang. Di KernelSU-Next fungsi itu
 *     `static void disable_seccomp(void)` di policy/app_profile.c dan tidak
 *     bisa dipanggil dari luar; KernelSU-Next melakukan hal yang sama di
 *     jalurnya sendiri.
 *   - pemasangan fd manager (ksu_install_fd) dan keputusan umount tidak
 *     diduplikasi: KernelSU-Next sudah melakukannya di hook setuid-nya,
 *     sedangkan yang khas SUSFS di sini hanya penandaan TIF dan pekerjaan tunda.
 * Sisanya tetap sama, termasuk pemakaian ksu_uid_should_umount() -- fungsi itu
 * ada di KernelSU-Next dan memang inilah yang dipakai patch 10.
 * ------------------------------------------------------------------------ */

extern u32 susfs_zygote_sid;
extern u32 susfs_zygote_next_sid;
extern struct work_struct susfs_extra_works;

static void susfs_handle_extra_susfs_work(void)
{
	if (!susfs_extra_works.func)
		return;
	if (work_pending(&susfs_extra_works))
		return;
	schedule_work(&susfs_extra_works);
}

static int handle_zygote_setresuid(uid_t ruid, bool zygote_next)
{
	/* Layanan terisolasi: paksa umount, sama seperti patch 10. */
	if (is_isolated_process(ruid)) {
		susfs_set_current_proc_no_su();
		susfs_set_current_proc_umounted();
		if (zygote_next)
			susfs_set_current_proc_umounted_for_zygote_next();
		goto do_susfs_work;
	}

	/* Aplikasi biasa yang menurut policy KernelSU-Next memang harus
	 * di-umount saat lahir. */
	if (likely(is_appuid(ruid) && ksu_uid_should_umount(ruid))) {
		susfs_set_current_proc_no_su();
		susfs_set_current_proc_umounted();
		if (zygote_next)
			susfs_set_current_proc_umounted_for_zygote_next();
		goto do_susfs_work;
	}

	/* Tidak di-umount, dan bukan uid yang diberi root: cukup tandai supaya
	 * jalur exec milik SUSFS tidak ikut campur. */
	if (!ksu_is_allow_uid_for_current(ruid))
		susfs_set_current_proc_no_su();

	return 0;

do_susfs_work:
	/* Umount tidak dilakukan di sini: kita masih di init namespace, dan
	 * KernelSU-Next sudah menangani umount di hook miliknya. */
	susfs_handle_extra_susfs_work();
	return 0;
}

int susfs_ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)
{
	if (current_uid().val != 0)
		return 0;

	/* Pastikan SID zygote_next sudah dicoba diresolusi sebelum dipakai. */
	susfs_try_resolve_sids();

	/*
	 * Hanya proses yang lahir dari zygote / zygote_next yang relevan.
	 * Untuk zygote, dipakai is_zygote() milik KernelSU-Next (tahan terhadap
	 * cache SID yang belum terisi). Zygote_next tidak dikenal KernelSU-Next,
	 * jadi di sana tetap membandingkan SID hasil resolusi sendiri -- dengan
	 * syarat SID-nya memang ada, supaya nilai 0 tidak pernah dianggap cocok.
	 */
	if (is_zygote(current_cred()))
		return handle_zygote_setresuid(ruid, false);

	if (susfs_zygote_next_sid && susfs_is_sid_equal(current_cred(), susfs_zygote_next_sid))
		return handle_zygote_setresuid(ruid, true);

	return 0;
}

/* ---------------------------------------------------------------------------
 * Pintu masuk perintah ksu_susfs dari userspace.
 *
 * kernel/reboot.c hasil patch 50:
 *     ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
 *     if (ret) goto orig_flow;   // non-nol -> reboot() berjalan seperti biasa
 *     return ret;                // nol     -> permintaan sudah dilayani susfs
 *
 * Magic milik KernelSU-Next ditangani kprobe-nya sendiri di
 * supercall/supercall.c. Karena itu fungsi ini mengembalikan non-nol untuk
 * semua magic selain SUSFS_MAGIC, supaya reboot() normal tidak tercaplok.
 * ------------------------------------------------------------------------ */

/* dari fs/susfs.c */
extern void susfs_add_sus_path(void __user **user_info);
extern void susfs_add_sus_path_loop(void __user **user_info);
extern void susfs_set_hide_sus_mnts_for_non_su_procs(void __user **user_info);
extern void susfs_add_sus_kstat(void __user **user_info);
extern void susfs_update_sus_kstat(void __user **user_info);
extern void susfs_set_uname(void __user **user_info);
extern void susfs_enable_log(void __user **user_info);
extern void susfs_set_cmdline_or_bootconfig(void __user **user_info);
extern void susfs_add_open_redirect(void __user **user_info);
extern void susfs_add_sus_map(void __user **user_info);
extern void susfs_set_priority_uid_filter(void __user **user_info);
extern void susfs_set_avc_log_spoofing(void __user **user_info);
extern void susfs_get_enabled_features(void __user **user_info);
extern void susfs_show_variant(void __user **user_info);
extern void susfs_show_version(void __user **user_info);
extern void susfs_init(void);

#define KSU_INSTALL_MAGIC1 0xDEADBEEF

int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
	if (magic1 != KSU_INSTALL_MAGIC1)
		return -EINVAL;

	/* Bukan untuk SUSFS: biarkan reboot() lanjut ke jalur aslinya. */
	if (magic2 != SUSFS_MAGIC)
		return -EINVAL;

	if (current_uid().val != 0)
		return -EINVAL;

	/* Permintaan dari userspace hanya datang setelah boot, jadi ini titik
	 * yang pasti untuk menyegarkan SID. */
	susfs_try_resolve_sids();

	switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case CMD_SUSFS_ADD_SUS_PATH:
		susfs_add_sus_path(arg);
		return 0;
	case CMD_SUSFS_ADD_SUS_PATH_LOOP:
		susfs_add_sus_path_loop(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
		susfs_set_hide_sus_mnts_for_non_su_procs(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case CMD_SUSFS_ADD_SUS_KSTAT:
	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
		susfs_add_sus_kstat(arg);
		return 0;
	case CMD_SUSFS_UPDATE_SUS_KSTAT:
		susfs_update_sus_kstat(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case CMD_SUSFS_SET_UNAME:
		susfs_set_uname(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case CMD_SUSFS_ENABLE_LOG:
		susfs_enable_log(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
		susfs_set_cmdline_or_bootconfig(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	case CMD_SUSFS_ADD_OPEN_REDIRECT:
		susfs_add_open_redirect(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	case CMD_SUSFS_ADD_SUS_MAP:
		susfs_add_sus_map(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
	case CMD_SUSFS_SET_PRIORITY_UID_FILTER:
		susfs_set_priority_uid_filter(arg);
		return 0;
#endif
	case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
		susfs_set_avc_log_spoofing(arg);
		return 0;
	case CMD_SUSFS_SHOW_ENABLED_FEATURES:
		susfs_get_enabled_features(arg);
		return 0;
	case CMD_SUSFS_SHOW_VARIANT:
		susfs_show_variant(arg);
		return 0;
	case CMD_SUSFS_SHOW_VERSION:
		susfs_show_version(arg);
		return 0;
	default:
		/* Perintah tak dikenal: jangan caplok reboot()-nya, sama seperti
		 * yang diandalkan ksu_susfs di userspace (sentinel 126). */
		return -EINVAL;
	}
}

/*
 * susfs_init() menyiapkan susfs_extra_works (INIT_WORK) dan mencatat versi.
 * Harus jalan sebelum pekerjaan tunda bisa dijadwalkan.
 */
static int __init susfs_compat_init(void)
{
	susfs_init();
	susfs_set_batch_sid();
	return 0;
}
late_initcall(susfs_compat_init);
