#!/usr/bin/env python3
"""scarlet-lockdown.py — kunci kebijakan frekuensi VoidPrjct-Scarlet.

Dijalankan di runner GitHub Actions, setelah scarlet-gaming.patch terpasang
dan setelah KernelSU-Next/SUSFS/NoMount diintegrasikan. Tidak ada build di sini.

Tiga hal dikerjakan:

1. Thermal throttling dimatikan di titik yang aman. Callback set_cur_state
   dari cooling device CPU dan GPU dijadikan no-op. Cooling device tetap
   terdaftar dan tetap mengembalikan pointer yang sah.

   Ini membedakan pendekatan ini dari scripts/no-thermal-throttle.patch, yang
   mengembalikan NULL dari fungsi REGISTRASI. Pemanggil vendor (devfreq Mali /
   MTK) hanya memeriksa IS_ERR, sehingga NULL lolos pemeriksaan, lalu dipakai
   sebagai cooling device -> crash saat probe -> bootloop.

   Jalur shutdown kritis TIDAK dimatikan. Itu ada di thermal_core.c dan
   sengaja dibiarkan hidup: perangkat yang benar-benar kepanasan tetap mati
   sendiri, bukan hang.

2. Governor dikunci ke "scarlet".
   CPU : tulis scaling_governor ditolak selama scarlet aktif.
   GPU : devfreq_add_device memaksa "scarlet". Fallback lama tidak cukup,
         karena simple_ondemand selalu dibangun (di-select UFS) sehingga
         vendor yang meminta simple_ondemand tetap mendapatkannya, dan GPU
         tidak pernah masuk ke scarlet. Governor "passive" dikecualikan:
         itu relasi parent-child antar device devfreq, bukan kebijakan frekuensi.
   Devfreq governor scarlet ditandai immutable (lihat governor_scarlet.c),
   sehingga governor_store menolak perpindahan.

3. Batas frekuensi dikunci ke maksimum.
   CPU : scaling_min_freq / scaling_max_freq ditolak.
   GPU : min_freq / max_freq ditolak.
   Governor scarlet sendiri sudah memaksa min = max = cpuinfo.max_freq
   (cpufreq) dan DEVFREQ_MAX_FREQ (devfreq).

Setiap penggantian diverifikasi jumlah kemunculannya. Kalau sebuah pola tidak
ditemukan tepat sekali, skrip berhenti: tidak ada pohon kernel yang setengah
diubah.

usage: scarlet-lockdown.py <kernel-dir>
"""

import os
import re
import sys


def log(msg):
    sys.stdout.write("[lockdown] %s\n" % msg)
    sys.stdout.flush()


def die(msg):
    sys.stderr.write("[lockdown][FATAL] %s\n" % msg)
    sys.exit(1)


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def sub_once(text, old, new, label):
    """Ganti satu kemunculan persis; gagal kalau tidak tepat satu."""
    n = text.count(old)
    if n != 1:
        die("%s: pola muncul %d kali (harus tepat 1)" % (label, n))
    return text.replace(old, new, 1)


def replace_func(text, header_re, new_def, label):
    """Ganti seluruh badan fungsi, dicocokkan lewat kurung kurawal."""
    m = re.search(header_re, text, re.M)
    if not m:
        die("%s: header fungsi tidak ditemukan" % label)
    start = m.start()
    brace = text.index("{", m.end() - 1)
    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    if depth != 0:
        die("%s: kurung kurawal tidak seimbang" % label)
    return text[:start] + new_def + text[i + 1:]


def patch_cpufreq_cooling(kernel):
    path = os.path.join(kernel, "drivers/thermal/cpufreq_cooling.c")
    text = read(path)

    new_def = '''static int cpufreq_set_cur_state(struct thermal_cooling_device *cdev,
				 unsigned long state)
{
	/*
	 * VoidPrjct-Scarlet: throttling CPU dimatikan.
	 *
	 * Cooling device tetap terdaftar dan tetap mengembalikan pointer sah,
	 * tetapi tidak pernah memasang batas frekuensi. Kembali 0 tanpa
	 * menyentuh qos_req berarti plafon frekuensi CPU tidak pernah turun
	 * karena suhu, apa pun governor thermal yang aktif.
	 *
	 * Catatan: jalur shutdown kritis tidak dimatikan di sini. Itu ada di
	 * thermal_core.c dan sengaja dibiarkan hidup sebagai pengaman terakhir.
	 */
	return 0;
}'''

    text = replace_func(
        text,
        r"static int cpufreq_set_cur_state\(struct thermal_cooling_device \*cdev,\n"
        r"\t+ ?unsigned long state\)\n\{",
        new_def,
        "cpufreq_set_cur_state",
    )

    # Pastikan tidak ada sisa jalur yang masih memasang batas frekuensi.
    if "freq_qos_update_request(&cpufreq_cdev->qos_req" in text:
        die("cpufreq_cooling: qos_req masih dipakai setelah patch")

    write(path, text)
    log("CPU thermal throttling dimatikan (cpufreq_cooling set_cur_state no-op)")


def patch_devfreq_cooling(kernel):
    path = os.path.join(kernel, "drivers/thermal/devfreq_cooling.c")
    text = read(path)

    new_def = '''static int devfreq_cooling_set_cur_state(struct thermal_cooling_device *cdev,
					 unsigned long state)
{
	/*
	 * VoidPrjct-Scarlet: throttling GPU/devfreq dimatikan.
	 *
	 * Sama seperti sisi CPU: cooling device tetap ada, tetapi batas
	 * frekuensi (req_max_freq) tidak pernah dipasang, sehingga device
	 * devfreq tidak bisa diturunkan oleh trip point thermal.
	 */
	return 0;
}'''

    text = replace_func(
        text,
        r"static int devfreq_cooling_set_cur_state\(struct thermal_cooling_device \*cdev,\n"
        r"\t+ ?unsigned long state\)\n\{",
        new_def,
        "devfreq_cooling_set_cur_state",
    )

    if "dev_pm_qos_update_request(&dfc->req_max_freq" in text:
        die("devfreq_cooling: req_max_freq masih dipakai setelah patch")

    write(path, text)
    log("GPU thermal throttling dimatikan (devfreq_cooling set_cur_state no-op)")


def patch_cpufreq_core(kernel):
    path = os.path.join(kernel, "drivers/cpufreq/cpufreq.c")
    text = read(path)

    if "#include <linux/string.h>" not in text:
        text = sub_once(
            text,
            "#include <linux/slab.h>\n",
            "#include <linux/slab.h>\n#include <linux/string.h>\n",
            "cpufreq.c include string.h",
        )

    # store_one() dipakai untuk scaling_min_freq dan scaling_max_freq.
    old_macro = '''	unsigned long val;						\\
	int ret;							\\
									\\
	ret = sscanf(buf, "%lu", &val);					\\
'''
    new_macro = '''	unsigned long val;						\\
	int ret;							\\
									\\
	/* VoidPrjct-Scarlet: governor scarlet mengunci batas frekuensi,	\\
	 * jadi penulisan scaling_min_freq / scaling_max_freq ditolak.	\\
	 * Tanpa ini userspace (atau driver vendor) masih bisa menurunkan	\\
	 * plafon walau governor sudah memaksa min = max. */		\\
	if (policy->governor &&						\\
	    !strncmp(policy->governor->name, "scarlet",			\\
		     CPUFREQ_NAME_LEN))					\\
		return -EPERM;						\\
									\\
	ret = sscanf(buf, "%lu", &val);					\\
'''
    text = sub_once(text, old_macro, new_macro, "store_one guard")

    old_gov = '''	ret = sscanf(buf, "%15s", str_governor);
	if (ret != 1)
		return -EINVAL;

	if (cpufreq_driver->setpolicy) {
'''
    new_gov = '''	ret = sscanf(buf, "%15s", str_governor);
	if (ret != 1)
		return -EINVAL;

	/* VoidPrjct-Scarlet: selama governor scarlet aktif, userspace tidak
	 * boleh berpindah ke governor lain. */
	if (policy->governor &&
	    !strncmp(policy->governor->name, "scarlet", CPUFREQ_NAME_LEN) &&
	    strncmp(str_governor, "scarlet", sizeof(str_governor)))
		return -EPERM;

	if (cpufreq_driver->setpolicy) {
'''
    text = sub_once(text, old_gov, new_gov, "store_scaling_governor guard")

    write(path, text)
    log("CPU governor + batas frekuensi dikunci (cpufreq.c)")


def patch_devfreq_core(kernel):
    path = os.path.join(kernel, "drivers/devfreq/devfreq.c")
    text = read(path)

    old_init = '''	devfreq->profile = profile;
	strscpy(devfreq->governor_name, governor_name, DEVFREQ_NAME_LEN);
'''
    new_init = '''	devfreq->profile = profile;
	strscpy(devfreq->governor_name, governor_name, DEVFREQ_NAME_LEN);
#ifdef CONFIG_DEVFREQ_GOV_SCARLET
	/*
	 * VoidPrjct-Scarlet: paksa governor scarlet.
	 *
	 * Fallback di bawah (dipakai saat governor yang diminta tidak ada)
	 * tidak cukup: simple_ondemand selalu dibangun karena di-select UFS,
	 * jadi vendor yang meminta simple_ondemand tetap mendapatkannya dan
	 * GPU tidak pernah masuk ke scarlet.
	 *
	 * Pengecualian "passive": itu relasi parent-child antara dua device
	 * devfreq, bukan kebijakan frekuensi. Menimpanya memutus rantai.
	 */
	if (strncmp(devfreq->governor_name, "passive", DEVFREQ_NAME_LEN))
		strscpy(devfreq->governor_name, "scarlet", DEVFREQ_NAME_LEN);
#endif
'''
    text = sub_once(text, old_init, new_init, "devfreq_add_device force scarlet")

    old_min = '''	if (!dev_pm_qos_request_active(&df->user_min_freq_req))
		return -EAGAIN;
'''
    new_min = '''	if (!dev_pm_qos_request_active(&df->user_min_freq_req))
		return -EAGAIN;

	/* VoidPrjct-Scarlet: governor scarlet mengunci batas frekuensi. */
	if (df->governor &&
	    !strncmp(df->governor->name, "scarlet", DEVFREQ_NAME_LEN))
		return -EPERM;
'''
    text = sub_once(text, old_min, new_min, "min_freq_store guard")

    old_max = '''	if (!dev_pm_qos_request_active(&df->user_max_freq_req))
		return -EINVAL;
'''
    new_max = '''	if (!dev_pm_qos_request_active(&df->user_max_freq_req))
		return -EINVAL;

	/* VoidPrjct-Scarlet: governor scarlet mengunci batas frekuensi. */
	if (df->governor &&
	    !strncmp(df->governor->name, "scarlet", DEVFREQ_NAME_LEN))
		return -EPERM;
'''
    text = sub_once(text, old_max, new_max, "max_freq_store guard")

    write(path, text)
    log("GPU governor + batas frekuensi dikunci (devfreq.c)")


def main():
    if len(sys.argv) != 2:
        die("usage: scarlet-lockdown.py <kernel-dir>")
    kernel = sys.argv[1]
    if not os.path.isdir(kernel):
        die("kernel dir tidak ada: %s" % kernel)

    patch_cpufreq_cooling(kernel)
    patch_devfreq_cooling(kernel)
    patch_cpufreq_core(kernel)
    patch_devfreq_core(kernel)

    log("lockdown selesai")


if __name__ == "__main__":
    main()
