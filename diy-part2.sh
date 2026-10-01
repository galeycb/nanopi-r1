#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate

# NanoPi R1 may expose eMMC and SD as different mmcblk indexes across boots.
# Avoid hardcoding /dev/mmcblk0p2 in the sunxi U-Boot environment when building it.
if grep -q '^CONFIG_TARGET_sunxi_cortexa7_DEVICE_friendlyarm_nanopi-r1=y' .config; then
  UENV_DEFAULT="package/boot/uboot-sunxi/uEnv-default.txt"
  if [ -f "$UENV_DEFAULT" ] && grep -q 'root=/dev/mmcblk0p2' "$UENV_DEFAULT"; then
    sed -i 's#fatload mmc 0 #fatload mmc \\$mmc_bootdev #g' "$UENV_DEFAULT"
    sed -i 's#root=/dev/mmcblk0p2#root=PARTUUID=${uuid}#g' "$UENV_DEFAULT"
    if ! grep -q 'part uuid mmc' "$UENV_DEFAULT"; then
      sed -i '/^setenv fdt_high/a setenv mmc_rootpart 2\npart uuid mmc ${mmc_bootdev}:${mmc_rootpart} uuid' "$UENV_DEFAULT"
    fi
  fi
fi
