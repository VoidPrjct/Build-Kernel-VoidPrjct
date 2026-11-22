// SPDX-License-Identifier: GPL-2.0-only
/*
 *  drivers/cpufreq/cpufreq_scarlet.c
 *
 *  Governor "scarlet" — VoidPrjct-Scarlet gaming governor.
 *  Mengunci frekuensi CPU secara statis ke nilai maksimum yang didukung
 *  perangkat (cpuinfo.max_freq). Turunan langsung governor "performance";
 *  perbedaannya hanya nama dan paksaan min = max pada limits, supaya
 *  pengguna tidak bisa menurunkan plafon frekuensi selama governor aktif.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/cpufreq.h>
#include <linux/init.h>
#include <linux/module.h>

static void cpufreq_gov_scarlet_limits(struct cpufreq_policy *policy)
{
	unsigned int max = policy->cpuinfo.max_freq;

	pr_debug("locking to %u kHz (scarlet)\n", max);
	policy->min = max;
	policy->max = max;
	__cpufreq_driver_target(policy, max, CPUFREQ_RELATION_H);
}

static struct cpufreq_governor cpufreq_gov_scarlet = {
	.name		= "scarlet",
	.owner		= THIS_MODULE,
	.flags		= CPUFREQ_GOV_STRICT_TARGET,
	.limits		= cpufreq_gov_scarlet_limits,
};

#ifdef CONFIG_CPU_FREQ_DEFAULT_GOV_SCARLET
struct cpufreq_governor *cpufreq_default_governor(void)
{
	return &cpufreq_gov_scarlet;
}
#endif

MODULE_AUTHOR("VoidPrjct");
MODULE_DESCRIPTION("CPUfreq policy governor 'scarlet' (gaming, lock max freq)");
MODULE_LICENSE("GPL");

cpufreq_governor_init(cpufreq_gov_scarlet);
cpufreq_governor_exit(cpufreq_gov_scarlet);
