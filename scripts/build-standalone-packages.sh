#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="${1:?OpenWrt source directory is required}"
OUTPUT_DIR="${2:?Standalone package output directory is required}"
FEED_DIR="$OUTPUT_DIR/feed"

rm -rf "$OUTPUT_DIR"
mkdir -p "$FEED_DIR"

requested_packages=(
  tcpdump
  ethtool
  iperf3
)

declare -A queued_packages=()
declare -A copied_packages=()
queue=()

MANIFEST="$(find "$SOURCE_DIR/bin/targets" -type f -name '*.manifest' -print -quit 2>/dev/null || true)"

find_ipk() {
  find "$SOURCE_DIR/bin" -type f -name "${1}_*.ipk" -print -quit
}

is_in_firmware() {
  local package="$1"
  [ -n "$MANIFEST" ] && grep -Eq "^${package}([[:space:]]|$)" "$MANIFEST"
}

trim() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

add_package_to_queue() {
  local package="$1"
  [ -n "$package" ] || return 0
  [ "${queued_packages[$package]+yes}" = yes ] && return 0
  queued_packages["$package"]=1
  queue+=("$package")
}

for package in "${requested_packages[@]}"; do
  add_package_to_queue "$package"
done

printf '%s\n' "# Requested packages" > "$OUTPUT_DIR/standalone-packages.txt"
printf '%s\n' "${requested_packages[@]}" >> "$OUTPUT_DIR/standalone-packages.txt"
printf '%s\n' "" "# Dependency closure" >> "$OUTPUT_DIR/standalone-packages.txt"

while ((${#queue[@]} > 0)); do
  package="${queue[0]}"
  queue=("${queue[@]:1}")

  [ "${copied_packages[$package]+yes}" = yes ] && continue

  ipk="$(find_ipk "$package")"
  if [ -z "$ipk" ]; then
    if is_in_firmware "$package"; then
      echo "Dependency already provided by firmware: $package"
      copied_packages["$package"]=firmware
      continue
    fi
    echo "::error::Could not find package or firmware provider for dependency: $package"
    exit 1
  fi

  echo "Selecting $package from $ipk"
  cp "$ipk" "$FEED_DIR/"
  copied_packages["$package"]="$ipk"
  printf '%s\n' "$package" >> "$OUTPUT_DIR/standalone-packages.txt"

  control="$(ar p "$ipk" control.tar.gz | tar -xzOf - ./control)"
  depends="$(printf '%s\n' "$control" | sed -n 's/^Depends: //p')"
  [ -n "$depends" ] || continue

  while IFS= read -r dependency_clause; do
    dependency_clause="$(printf '%s\n' "$dependency_clause" | sed -E 's/[[:space:]]*\([^)]*\)//g' | trim)"
    [ -n "$dependency_clause" ] || continue

    dependency=""
    IFS='|' read -r -a alternatives <<< "$dependency_clause"
    for alternative in "${alternatives[@]}"; do
      candidate="$(printf '%s\n' "$alternative" | trim)"
      candidate="${candidate#+}"
      [ -n "$candidate" ] || continue
      candidate_ipk="$(find_ipk "$candidate")"
      if is_in_firmware "$candidate" || [ -n "$candidate_ipk" ]; then
        dependency="$candidate"
        break
      fi
    done

    if [ -z "$dependency" ]; then
      echo "::error::Could not resolve dependency clause '$dependency_clause' required by $package"
      exit 1
    fi

    if ! is_in_firmware "$dependency"; then
      add_package_to_queue "$dependency"
    fi
  done < <(printf '%s' "$depends" | tr ',' '\n')
done

bash "$SOURCE_DIR/scripts/ipkg-make-index.sh" "$FEED_DIR" > "$FEED_DIR/Packages"
gzip -9fc "$FEED_DIR/Packages" > "$FEED_DIR/Packages.gz"

cat > "$OUTPUT_DIR/README.txt" <<'EOF'
This archive contains the requested OpenWrt packages and their runtime dependencies.

On the OpenWrt device, extract this archive and add the local feed temporarily:

  echo 'src/gz codex_standalone file:///tmp/standalone-packages/feed' >> /etc/opkg/customfeeds.conf
  opkg update
  opkg install tcpdump ethtool iperf3

The feed directory contains Packages and Packages.gz for dependency resolution.
The config file records the firmware build configuration used for this package set.
EOF

echo "Standalone package feed created at $FEED_DIR"
find "$FEED_DIR" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort
