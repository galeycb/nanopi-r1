#!/usr/bin/env bash

set -euo pipefail

SOURCE_DIR="${1:?OpenWrt source directory is required}"
OUTPUT_DIR="${2:?Standalone package output directory is required}"
FEED_DIR="$OUTPUT_DIR/feed"

rm -rf "$OUTPUT_DIR"
mkdir -p "$FEED_DIR"

requested_packages=(
  tcpdump
  iperf3
)

declare -A queued_packages=()
declare -A copied_packages=()
queue=()

MANIFEST="$(find "$SOURCE_DIR/bin/targets" -type f -name '*.manifest' -print -quit 2>/dev/null || true)"

find_package() {
  find "$SOURCE_DIR/bin" -type f \
    \( -name "${1}_*.ipk" -o -name "${1}_*.apk" \) \
    -print -quit
}

is_in_firmware() {
  local package="$1"
  [ -n "$MANIFEST" ] && grep -Eq "^${package}([[:space:]]|$)" "$MANIFEST"
}

trim() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# OpenWrt has used two package containers over time. Older builds use an ar
# container, while current ipkg-build emits a gzip-compressed tar container
# even though the filename still ends in .ipk. Keep both formats readable.
extract_archive_member() {
  local archive="$1"
  local member="$2"

  tar -xOzf "$archive" "$member" 2>/dev/null \
    || tar --zstd -xOf "$archive" "$member" 2>/dev/null \
    || tar -xOJf "$archive" "$member" 2>/dev/null \
    || tar -xOjf "$archive" "$member" 2>/dev/null \
    || tar -xOf "$archive" "$member" 2>/dev/null
}

extract_control_archive() {
  local archive_name="$1"

  case "$archive_name" in
    *.gz)  tar -xzOf - ./control 2>/dev/null ;;
    *.zst) tar --zstd -xOf - ./control 2>/dev/null ;;
    *.xz)  tar -xJOf - ./control 2>/dev/null ;;
    *.bz2) tar -xjOf - ./control 2>/dev/null ;;
    *)     tar -xOf - ./control 2>/dev/null ;;
  esac
}

extract_package_metadata() {
  local package_file="$1"
  local metadata=""
  local member=""

  # Legacy Debian-style IPK.
  if metadata="$(ar p "$package_file" control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null)"; then
    printf '%s\n' "$metadata"
    return 0
  fi

  # Current OpenWrt IPK/APK tar container. Find the control archive first,
  # then extract its control file without storing binary data in a shell var.
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    case "$member" in
      */control.tar|*/control.tar.gz|*/control.tar.zst|*/control.tar.xz|*/control.tar.bz2|control.tar|control.tar.gz|control.tar.zst|control.tar.xz|control.tar.bz2)
        if metadata="$(extract_archive_member "$package_file" "$member" | extract_control_archive "$member")"; then
          printf '%s\n' "$metadata"
          return 0
        fi
        ;;
    esac
  done < <(
    tar -tzf "$package_file" 2>/dev/null \
      || tar --zstd -tf "$package_file" 2>/dev/null \
      || tar -tjf "$package_file" 2>/dev/null \
      || tar -tJf "$package_file" 2>/dev/null \
      || tar -tf "$package_file" 2>/dev/null
  )

  # APK packages store dependency metadata in .PKGINFO rather than control.
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    case "$member" in
      */.PKGINFO|.PKGINFO)
        if metadata="$(extract_archive_member "$package_file" "$member")"; then
          printf '%s\n' "$metadata"
          return 0
        fi
        ;;
    esac
  done < <(
    tar -tzf "$package_file" 2>/dev/null \
      || tar --zstd -tf "$package_file" 2>/dev/null \
      || tar -tjf "$package_file" 2>/dev/null \
      || tar -tJf "$package_file" 2>/dev/null \
      || tar -tf "$package_file" 2>/dev/null
  )

  return 1
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

  package_file="$(find_package "$package")"
  if [ -z "$package_file" ]; then
    if is_in_firmware "$package"; then
      echo "Dependency already provided by firmware: $package"
      copied_packages["$package"]=firmware
      continue
    fi
    echo "::error::Could not find package or firmware provider for dependency: $package"
    exit 1
  fi

  echo "Selecting $package from $package_file"
  cp "$package_file" "$FEED_DIR/"
  copied_packages["$package"]="$package_file"
  printf '%s\n' "$package" >> "$OUTPUT_DIR/standalone-packages.txt"

  if ! control="$(extract_package_metadata "$package_file")"; then
    echo "::error::Could not read package metadata from $package_file"
    exit 1
  fi
  depends="$(printf '%s\n' "$control" | sed -n 's/^Depends: //p')"
  if [ -z "$depends" ]; then
    depends="$(printf '%s\n' "$control" | sed -n 's/^depend[[:space:]]*=[[:space:]]*//p' | paste -sd, -)"
  fi
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
  opkg install tcpdump iperf3

The feed directory contains Packages and Packages.gz for dependency resolution.
The config file records the firmware build configuration used for this package set.
EOF

echo "Standalone package feed created at $FEED_DIR"
find "$FEED_DIR" -maxdepth 1 -type f \( -name '*.ipk' -o -name '*.apk' \) -printf '%f\n' | sort
