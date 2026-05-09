#!/usr/bin/env bash
# Prepare an OpenWrt source tree for build:
#   - apply patches from $BUILDER_REPO/patches/*.patch (if any)
#   - append custom feeds from FEEDS_LINES
#   - run feeds update/install
#   - copy device .config and run defconfig
#   - disable bundling of custom feeds into the image
#
# Required env:
#   OPENWRT_DIR    path to checked-out OpenWrt source (working dir is set here)
#   BUILDER_REPO   path to this repo
#   DEVICE_DIR     path to devices/<id>/  (relative to BUILDER_REPO)
#   FEEDS_LINES    newline-separated `src-git <name> <url>` lines
#
# Optional env:
#   COMMON_FILES   path to common/files (default: $BUILDER_REPO/common/files)

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

: "${OPENWRT_DIR:?OPENWRT_DIR required}"
: "${BUILDER_REPO:?BUILDER_REPO required}"
: "${DEVICE_DIR:?DEVICE_DIR required}"
: "${FEEDS_LINES:?FEEDS_LINES required}"

COMMON_FILES="${COMMON_FILES:-$BUILDER_REPO/common/files}"

cd "$OPENWRT_DIR"

# 1. Apply patches.
patches_dir="$BUILDER_REPO/patches"
if compgen -G "$patches_dir/*.patch" >/dev/null; then
  log::info "Applying patches from $patches_dir"
  while IFS= read -r patch; do
    log::info "  $patch"
    git apply --verbose "$patch"
  done < <(find "$patches_dir" -maxdepth 1 -type f -name '*.patch' | sort)
else
  log::info "No patches to apply."
fi

# 2. Configure feeds.
[[ -f feeds.conf ]] || cp feeds.conf.default feeds.conf

# Override nss_packages branch from builder.yml (feeds.conf.default may have a different branch).
if [[ -n "${NSS_BRANCH:-}" ]]; then
  log::info "Overriding nss_packages branch to: $NSS_BRANCH"
  sed -i "s|nss-packages\.git;[^ ]*|nss-packages.git;${NSS_BRANCH}|" feeds.conf
fi

log::info "Appending custom feeds:"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  log::info "  $line"
  echo "$line" >>feeds.conf
done <<<"$FEEDS_LINES"

# Update ALL feeds first so standard feeds (luci, packages, …) are available
# before custom feeds are indexed — custom LuCI packages include feeds/luci/luci.mk.
log::info "Updating all feeds"
./scripts/feeds update -a

# Install each custom feed individually so failures are obvious.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  feed_name="$(awk '{print $2}' <<<"$line")"
  log::info "Installing packages from feed: $feed_name"
  ./scripts/feeds install -a -p "$feed_name"
done <<<"$FEEDS_LINES"

log::info "Installing all remaining packages"
./scripts/feeds install -a

# 2a. Per-package post-install fixes for upstream incompatibilities.
# quectel-cm 1.6.5 ships CMakeLists.txt with cmake_minimum_required(VERSION <3.5),
# which CMake 4.x rejects. The CMake error message itself suggests this flag.
quectel_cm_mk="feeds/nss_packages/wwan/utils/quectel-cm/Makefile"
if [[ -f "$quectel_cm_mk" ]] && ! grep -q CMAKE_POLICY_VERSION_MINIMUM "$quectel_cm_mk"; then
  log::info "Patching $quectel_cm_mk for CMake 4.x compatibility"
  printf '\nCMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5\n' >>"$quectel_cm_mk"
fi

# 3. Drop in device .config and resolve.
log::info "Loading device config: $DEVICE_DIR/config"
cp "$BUILDER_REPO/$DEVICE_DIR/config" .config
make defconfig

# 4. Disable bundling of custom feeds into the image (we declared them as
#    src-git but don't want every package shipped by default).
log::info "Disabling CONFIG_FEED_<custom> entries"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  feed_name="$(awk '{print $2}' <<<"$line")"
  sed -i "s/^CONFIG_FEED_${feed_name}=.*/# CONFIG_FEED_${feed_name} is not set/" .config || true
done <<<"$FEEDS_LINES"
sed -i 's/^CONFIG_FEED_luci_extra=.*/# CONFIG_FEED_luci_extra is not set/' .config || true

# 5. Copy custom files (common first, then device-specific so device wins).
log::info "Applying overlay files"
mkdir -p files

if [[ -d "$COMMON_FILES" ]]; then
  log::info "  common: $COMMON_FILES"
  rsync -a "$COMMON_FILES/" files/
fi

if [[ -d "$BUILDER_REPO/$DEVICE_DIR/files" ]]; then
  log::info "  device: $BUILDER_REPO/$DEVICE_DIR/files"
  rsync -a "$BUILDER_REPO/$DEVICE_DIR/files/" files/
fi

# Lock down sshd_config if shipped.
if [[ -f files/etc/ssh/sshd_config ]]; then
  chmod 0600 files/etc/ssh/sshd_config
fi

log::info "Build environment ready."
