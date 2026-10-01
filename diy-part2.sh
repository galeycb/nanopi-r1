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

# PassWall depends on dns2socks. The upstream package currently downloads
# SourceCode.zip from SourceForge, which intermittently returns an HTML page
# to GitHub-hosted runners. Use a fixed GitHub mirror of the same source tree
# so PassWall builds remain reproducible.
DNS2SOCKS_MAKEFILE="feeds/packages/net/dns2socks/Makefile"
if [ -f "$DNS2SOCKS_MAKEFILE" ] && grep -q '^PKG_NAME:=dns2socks$' "$DNS2SOCKS_MAKEFILE"; then
  sed -i \
    -e '/^PKG_SOURCE:=SourceCode\.zip$/d' \
    -e '/^PKG_SOURCE_URL:=@SF\/dns2socks$/d' \
    -e '/^PKG_SOURCE_DATE:=2020-02-18$/d' \
    -e '/^PKG_HASH:=406b5003523577d39da66767adfe54f7af9b701374363729386f32f6a3a995f4$/d' \
    -e '/^UNZIP_CMD:=unzip -q -d \$(PKG_BUILD_DIR) \$(DL_DIR)\/\$(PKG_SOURCE)$/d' \
    "$DNS2SOCKS_MAKEFILE"
  sed -i '/^PKG_RELEASE:=2$/a PKG_SOURCE_PROTO:=git\nPKG_SOURCE_URL:=https://github.com/rampageX/dns2socks.git\nPKG_SOURCE_VERSION:=feb7a0551ada1fb086982f24a9dd3c39a588d3ba\nPKG_SOURCE_SUBDIR:=dns2socks-$(PKG_VERSION)' "$DNS2SOCKS_MAKEFILE"
  echo "Patched dns2socks to use the fixed GitHub source mirror"
fi
