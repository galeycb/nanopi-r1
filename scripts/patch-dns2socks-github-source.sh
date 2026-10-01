#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="${1:?OpenWrt source directory is required}"
patched=0

# Keep the feed's original SourceForge definition as the normal path. This
# helper is called only after that download path has failed.
for makefile in \
  "$SOURCE_ROOT/feeds/packages/net/dns2socks/Makefile" \
  "$SOURCE_ROOT/feeds/helloworld/dns2socks/Makefile"; do
  [ -f "$makefile" ] || continue
  grep -q '^PKG_NAME:=dns2socks$' "$makefile" || continue

  sed -i \
    -e '/^PKG_SOURCE:=SourceCode\.zip$/d' \
    -e '/^PKG_SOURCE_URL:=@SF\/dns2socks$/d' \
    -e '/^PKG_SOURCE_DATE:=2020-02-18$/d' \
    -e '/^PKG_HASH:=406b5003523577d39da66767adfe54f7af9b701374363729386f32f6a3a995f4$/d' \
    -e '/^UNZIP_CMD:=unzip -q -d \$(PKG_BUILD_DIR) \$(DL_DIR)\/\$(PKG_SOURCE)$/d' \
    -e '/^PKG_SOURCE_PROTO:=git$/d' \
    -e '/^PKG_SOURCE_URL:=https:\/\/github\.com\/rampageX\/dns2socks\.git$/d' \
    -e '/^PKG_SOURCE_VERSION:=feb7a0551ada1fb086982f24a9dd3c39a588d3ba$/d' \
    -e '/^PKG_SOURCE_SUBDIR:=dns2socks-\$(PKG_VERSION)$/d' \
    "$makefile"

  if grep -q '^PKG_RELEASE:=' "$makefile"; then
    sed -i '/^PKG_RELEASE:=/a PKG_SOURCE_PROTO:=git\nPKG_SOURCE_URL:=https://github.com/rampageX/dns2socks.git\nPKG_SOURCE_VERSION:=feb7a0551ada1fb086982f24a9dd3c39a588d3ba\nPKG_SOURCE_SUBDIR:=dns2socks-$(PKG_VERSION)' "$makefile"
  else
    sed -i '/^PKG_VERSION:=/a PKG_SOURCE_PROTO:=git\nPKG_SOURCE_URL:=https://github.com/rampageX/dns2socks.git\nPKG_SOURCE_VERSION:=feb7a0551ada1fb086982f24a9dd3c39a588d3ba\nPKG_SOURCE_SUBDIR:=dns2socks-$(PKG_VERSION)' "$makefile"
  fi

  grep -q '^PKG_SOURCE_PROTO:=git$' "$makefile" || {
    echo "::error::Failed to apply the dns2socks GitHub fallback to $makefile"
    exit 1
  }
  echo "Fallback enabled for dns2socks: $makefile"
  patched=1
done

if [ "$patched" -ne 1 ]; then
  echo "::error::Could not find a dns2socks Makefile to patch"
  exit 1
fi
