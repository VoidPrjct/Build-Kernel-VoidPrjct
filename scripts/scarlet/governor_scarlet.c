// SPDX-License-Identifier: GPL-2.0-only
/*
 *  drivers/devfreq/governor_scarlet.c
 *
 *  Governor devfreq "scarlet" — VoidPrjct-Scarlet gaming governor.
 *  Selalu merekomendasikan frekuensi maksimum (DEVFREQ_MAX_FREQ), sehingga
 *  perangkat devfreq (mis. GPU) berjalan di OPP tertinggi selama governor
 *  ini aktif. Turunan langsung governor "performance" dengan nama lain.
 */

#include <linux/devfreq.h>
#include <linux/module.h>
#include "governor.h"

static int devfreq_scarlet_func(struct devfreq *df,
				unsigned long *freq)
{
	/*
	 * target callback harus bisa menerima nilai ceiling, sesuai
	 * kontrak di devfreq.h; framework memotongnya ke OPP tertinggi.
	 */
	*freq = DEVFREQ_MAX_FREQ;
	return 0;
}

static int devfreq_scarlet_handler(struct devfreq *devfreq,
				unsigned int event, void *data)
{
	int ret = 0;

	if (event == DEVFREQ_GOV_START) {
		mutex_lock(&devfreq->lock);
		ret = update_devfreq(devfreq);
		mutex_unlock(&devfreq->lock);
	}

	return ret;
}

static struct devfreq_governor devfreq_scarlet = {
	.name = "scarlet",
	.get_target_freq = devfreq_scarlet_func,
	.event_handler = devfreq_scarlet_handler,
};

static int __init devfreq_scarlet_init(void)
{
	return devfreq_add_governor(&devfreq_scarlet);
}
subsys_initcall(devfreq_scarlet_init);

static void __exit devfreq_scarlet_exit(void)
{
	int ret;

	ret = devfreq_remove_governor(&devfreq_scarlet);
	if (ret)
		pr_err("%s: failed remove governor %d\n", __func__, ret);

	return;
}
module_exit(devfreq_scarlet_exit);
MODULE_LICENSE("GPL");
