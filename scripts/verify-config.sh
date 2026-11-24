#!/usr/bin/env bash
# verify-config.sh — pastikan simbol yang diminta benar-benar ada di .config.
# olddefconfig bisa membuang simbol yang dependensinya tidak terpenuhi tanpa
# memberi error, jadi langkah ini wajib (PRD 6.6).
#
# usage: verify-config.sh <path/.config>

set -uo pipefail
CONFIG="${1:?usage: verify-config.sh <path/.config>}"
[ -f "$CONFIG" ] || { echo "[verify][FATAL] $CONFIG tidak ada"; exit 1; }

WANT_Y=(
  CONFIG_KSU
  CONFIG_KSU_SUSFS
  CONFIG_KSU_SUSFS_SUS_PATH
  CONFIG_KSU_SUSFS_SUS_MOUNT
  CONFIG_KSU_SUSFS_SUS_KSTAT
  CONFIG_KSU_SUSFS_SPOOF_UNAME
  CONFIG_KSU_SUSFS_ENABLE_LOG
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  CONFIG_KSU_SUSFS_OPEN_REDIRECT
  CONFIG_KSU_SUSFS_SUS_MAP
  CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
  CONFIG_NOMOUNT
  CONFIG_LTO_CLANG
  CONFIG_LTO_CLANG_THIN
  CONFIG_MODVERSIONS
  # Fork ini memberi CONFIG_WERROR default y (init/Kconfig), jadi -Werror
  # berlaku global, termasuk untuk kode yang ditambahkan patch 50. Dijadikan
  # eksplisit supaya mematikannya (kalau suatu saat terpaksa) adalah keputusan
  # yang tercatat dan gagal di sini, bukan perubahan diam-diam.
  CONFIG_WERROR
  # Baseline GKI memakai CFI. ThinLTO tidak mematikannya (di 5.10 fork ini
  # CFI_CLANG hanya butuh LTO_CLANG + KALLSYMS; keduanya tetap terpenuhi), tapi
  # kalau suatu saat olddefconfig membuangnya, kernelnya jadi menyimpang dari
  # GKI tanpa pesan apa pun. Karena itu diperiksa.
  CONFIG_CFI_CLANG
  # Scarlet gaming: governor CPU + devfreq scarlet wajib built-in.
  CONFIG_CPU_FREQ_GOV_SCARLET
  CONFIG_CPU_FREQ_DEFAULT_GOV_SCARLET
  CONFIG_DEVFREQ_GOV_SCARLET
  # simple_ondemand wajib: di-select drivers/scsi/ufs/Kconfig (storage UFS).
  CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND
  # BORE: default y di init/Kconfig, tapi tetap diperiksa supaya kalau
  # olddefconfig membuangnya (mis. konflik Kconfig), build gagal di sini
  # dan bukan diam-diam jadi kernel tanpa BORE.
  CONFIG_SCHED_BORE
)
WANT_NOTSET=(
  CONFIG_LTO_CLANG_FULL
  CONFIG_LTO_NONE
  # Kalau aktif, "-g<hash>" ditempel setelah CONFIG_LOCALVERSION.
  CONFIG_LOCALVERSION_AUTO
  # Scarlet gaming: semua governor CPU/devfreq lain harus mati.
  CONFIG_CPU_FREQ_GOV_PERFORMANCE
  CONFIG_CPU_FREQ_GOV_POWERSAVE
  CONFIG_CPU_FREQ_GOV_USERSPACE
  CONFIG_CPU_FREQ_GOV_ONDEMAND
  CONFIG_CPU_FREQ_GOV_CONSERVATIVE
  CONFIG_CPU_FREQ_GOV_SCHEDHORIZON
  CONFIG_CPU_FREQ_GOV_REFLEX
  CONFIG_DEVFREQ_GOV_PERFORMANCE
  CONFIG_DEVFREQ_GOV_POWERSAVE
  CONFIG_DEVFREQ_GOV_USERSPACE
  CONFIG_DEVFREQ_GOV_PASSIVE
)
# Nama kernel: uname -r = <versi>-Scarlet.
WANT_LOCALVERSION="-Scarlet"

fail=0
echo "[verify] memeriksa $CONFIG"

for s in "${WANT_Y[@]}"; do
  if grep -qx "$s=y" "$CONFIG"; then
    printf '  OK      %s=y\n' "$s"
  else
    got=$(grep -E "^$s=|^# $s " "$CONFIG" | head -1)
    printf '  MISSING %s (ditemukan: %s)\n' "$s" "${got:-tidak ada sama sekali}"
    fail=1
  fi
done

for s in "${WANT_NOTSET[@]}"; do
  if grep -qx "# $s is not set" "$CONFIG"; then
    printf '  OK      %s tidak aktif\n' "$s"
  else
    got=$(grep -E "^$s=" "$CONFIG" | head -1)
    printf '  FAIL    %s masih aktif (%s)\n' "$s" "${got:-tidak ada}"
    fail=1
  fi
done

if grep -qxF "CONFIG_LOCALVERSION=\"${WANT_LOCALVERSION}\"" "$CONFIG"; then
  printf '  OK      CONFIG_LOCALVERSION="%s"\n' "$WANT_LOCALVERSION"
else
  got=$(grep -E '^CONFIG_LOCALVERSION=' "$CONFIG" | head -1)
  printf '  FAIL    CONFIG_LOCALVERSION harus "%s" (ditemukan: %s)\n' "$WANT_LOCALVERSION" "${got:-tidak ada}"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "[verify][FATAL] ada simbol yang tidak sesuai. olddefconfig kemungkinan membuangnya;"
  echo "[verify]          periksa dependency di Kconfig masing-masing."
  exit 1
fi

echo "[verify] semua simbol sesuai"
