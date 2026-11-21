// SPDX-License-Identifier: GPL-2.0
/*
 * susfs_compat.c — bagian sisi KernelSU yang dibutuhkan SUSFS built-in.
 *
 * Latar belakang (terverifikasi, lihat VERSIONS.md dan BUILD-LOG.md):
 *   kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch dari susfs4ksu v2.4.0
 *   tidak bisa dipasang di KernelSU-Next: 14 dari 32 file gagal (sucompat.c,
 *   kernel_umount.c, selinux_hide.c, core/init.c, supercall/*, sulog/*).
 *   Patch itu memang ditulis untuk KernelSU resmi (weishu), bukan KernelSU-Next.
 *
 * Patch 50 (sisi kernel) pas 27/27 file, dan patch itu memanggil:
 *     ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)   dari kernel/reboot.c
 * serta, lewat fs/susfs.c, memerlukan:
 *     susfs_is_current_ksu_domain(), susfs_is_sid_equal(),
 *     susfs_get_sid_from_name(), susfs_get_current_sid()
 *
 * Jadi file ini mengisi bagian sisi KernelSU itu terhadap API KernelSU-Next.
 * Isi fungsi diambil dari 10_enable_susfs_for_ksu.patch, dengan penyesuaian:
 *   - pemanggilan SID memakai ksu_security_secctx_to_secid() milik KernelSU-Next
 *   - SID ksu memakai KERNEL_SU_CONTEXT milik KernelSU-Next ("u:r:ksu:s0"),
 *     bukan "u:r:su:s0" milik KernelSU resmi
 *
 * FILE INI BUKAN BAGIAN DARI PROYEK HULU MANA PUN. Kalau ada bug, itu bug di sini.
 */

#include <linux/cred.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/susfs_def.h>

#include "ksu.h"
#include "objsec.h"
#include "selinux/selinux.h"

/* Konteks domain: patch 10 mendefinisikan ini sendiri; KSU-Next sudah punya
 * KERNEL_SU_CONTEXT / ZYGOTE_CONTEXT / INIT_CONTEXT di selinux/selinux.h. */
#define KERNEL_INIT_DOMAIN "u:r:init:s0"
#define KERNEL_ZYGOTE_DOMAIN "u:r:zygote:s0"
#define KERNEL_ZYGOTE_NEXT_DOMAIN "u:r:zygote_next:s0"
#define KERNEL_PRIV_APP_DOMAIN "u:r:priv_app:s0:c512,c768"

u32 susfs_ksu_sid __read_mostly = 0;
u32 susfs_init_sid __read_mostly = 0;
u32 susfs_zygote_sid __read_mostly = 0;
u32 susfs_zygote_next_sid __read_mostly = 0;
u32 susfs_priv_app_sid __read_mostly = 0;

static inline void susfs_set_sid(const char *secctx_name, u32 *out_sid)
{
	int err;

	if (!secctx_name || !out_sid) {
		pr_err("susfs: secctx_name || out_sid is NULL\n");
		return;
	}

	err = ksu_security_secctx_to_secid(secctx_name, strlen(secctx_name), out_sid);
	if (err) {
		pr_err("susfs: failed setting sid for '%s', err: %d\n", secctx_name, err);
		return;
	}
	pr_info("susfs: sid '%u' is set for secctx_name '%s'\n", *out_sid, secctx_name);
}

/* Dipakai fs/susfs.c */
bool susfs_is_current_ksu_domain(void)
{
	return unlikely(current_sid() == susfs_ksu_sid);
}

bool susfs_is_current_zygote_domain(void)
{
	return unlikely(current_sid() == susfs_zygote_sid);
}

bool susfs_is_current_zygote_next_domain(void)
{
	return unlikely(current_sid() == susfs_zygote_next_sid);
}

bool susfs_is_current_init_domain(void)
{
	return unlikely(current_sid() == susfs_init_sid);
}

u32 susfs_get_current_sid(void)
{
	return current_sid();
}

u32 susfs_get_sid_from_name(const char *secctx_name)
{
	u32 out_sid = 0;
	int err;

	if (!secctx_name) {
		pr_err("susfs: secctx_name is NULL\n");
		return 0;
	}
	err = ksu_security_secctx_to_secid(secctx_name, strlen(secctx_name), &out_sid);
	if (err) {
		pr_err("susfs: failed getting sid from secctx_name: %s, err: %d\n",
		       secctx_name, err);
		return 0;
	}
	return out_sid;
}

bool susfs_is_sid_equal(const struct cred *cred, u32 sid2)
{
	const struct task_security_struct *tsec = selinux_cred(cred);

	if (!tsec)
		return false;
	return tsec->sid == sid2;
}

/* Patch 10 memanggil ini dari selinux.c setelah policy dimuat. Di sini
 * dijalankan sekali lewat late_initcall; kalau SID belum bisa diresolusi,
 * fs/susfs.c akan menganggap semuanya bukan domain ksu (perilaku aman). */
void susfs_set_batch_sid(void)
{
	susfs_set_sid(KERNEL_ZYGOTE_DOMAIN, &susfs_zygote_sid);
	susfs_set_sid(KERNEL_ZYGOTE_NEXT_DOMAIN, &susfs_zygote_next_sid);
	susfs_set_sid(KERNEL_SU_CONTEXT, &susfs_ksu_sid);
	susfs_set_sid(KERNEL_INIT_DOMAIN, &susfs_init_sid);
	susfs_set_sid(KERNEL_PRIV_APP_DOMAIN, &susfs_priv_app_sid);
}

/* ---------------------------------------------------------------------------
 * Pintu masuk perintah ksu_susfs dari userspace.
 *
 * kernel/reboot.c hasil patch 50:
 *     ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
 *     if (ret) goto orig_flow;   // non-zero -> reboot() jalan seperti biasa
 *     return ret;                // nol     -> permintaan sudah dilayani susfs
 *
 * Karena KSU-Next menangani magic-nya sendiri lewat kprobe di
 * supercall/supercall.c, fungsi ini mengembalikan non-zero untuk semua magic
 * selain SUSFS_MAGIC, supaya alur reboot() normal tidak dicaplok.
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

#define KSU_INSTALL_MAGIC1 0xDEADBEEF

int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
	if (magic1 != KSU_INSTALL_MAGIC1)
		return -EINVAL;

	/* Bukan untuk SUSFS: biarkan reboot() lanjut, KSU-Next menangani magic-nya
	 * sendiri lewat kprobe di supercall/supercall.c. */
	if (magic2 != SUSFS_MAGIC)
		return -EINVAL;

	if (current_uid().val != 0)
		return -EINVAL;

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
		return -EINVAL;
	}
}

/* dari fs/susfs.c */
extern void susfs_init(void);

static int __init susfs_compat_init(void)
{
	susfs_init();
	susfs_set_batch_sid();
	return 0;
}
late_initcall(susfs_compat_init);
