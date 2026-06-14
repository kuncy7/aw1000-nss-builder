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
#
# Exception: the `wwan` feed (qosmio/nss-packages, wwan branch) also carries
# its own copies of the NSS core packages (qca-nss-drv, qca-nss-ecm, …) that
# would shadow the Julius edma-nss versions if force-installed with `-p -a`.
# Install only the modem packages from it; everything else resolves from the
# nss feed (listed earlier in feeds.conf, so it wins for duplicates).
WWAN_PACKAGES="quectel-cm luci-proto-quectel luci-app-pcimodem kmod-rmnet-nss kmod-quectel-mhi-pcie kmod-usb-net-qmi-wwan-quectel"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  feed_name="$(awk '{print $2}' <<<"$line")"
  if [[ "$feed_name" == "wwan" ]]; then
    log::info "Installing modem packages only from feed: wwan ($WWAN_PACKAGES)"
    # shellcheck disable=SC2086  # intentional word splitting of the package list
    ./scripts/feeds install -p wwan $WWAN_PACKAGES
    continue
  fi
  log::info "Installing packages from feed: $feed_name"
  ./scripts/feeds install -a -p "$feed_name"
done <<<"$FEEDS_LINES"

log::info "Installing all remaining packages"
./scripts/feeds install -a

# 2a. Per-package post-install fixes for upstream incompatibilities.
# The wwan packages live in feeds/nss_packages/wwan/ on the qosmio layout
# (nss_packages IS the wwan repo there) and in feeds/wwan/wwan/ when the wwan
# repo is added as a separate custom feed (the EDMA branch). Fix whichever exists.
for quectel_cm_dir in feeds/nss_packages/wwan/utils/quectel-cm feeds/wwan/wwan/utils/quectel-cm; do
  [[ -d "$quectel_cm_dir" ]] || continue

  # quectel-cm 1.6.5 ships CMakeLists.txt with cmake_minimum_required(VERSION <3.5),
  # which CMake 4.x rejects. The CMake error message itself suggests this flag.
  quectel_cm_mk="$quectel_cm_dir/Makefile"
  if [[ -f "$quectel_cm_mk" ]] && ! grep -q CMAKE_POLICY_VERSION_MINIMUM "$quectel_cm_mk"; then
    log::info "Patching $quectel_cm_mk for CMake 4.x compatibility"
    # Must be inserted after 'include cmake.mk' but before 'BuildPackage' --
    # appending at EOF lands after BuildPackage and is ignored.
    # shellcheck disable=SC2016  # $(INCLUDE_DIR) is a make variable, not shell
    sed -i '/^include $(INCLUDE_DIR)\/cmake\.mk$/a\\nCMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' "$quectel_cm_mk"
  fi

  # Fix quectel.sh for ash compatibility (|| assignments were joined on one line).
  quectel_sh="$quectel_cm_dir/files/quectel.sh"
  if [[ -f "$quectel_sh" ]]; then
    log::info "Replacing $quectel_sh with ash-compatible version"
    cp "$BUILDER_REPO/$DEVICE_DIR/quectel.sh" "$quectel_sh"
  fi
done

# 2b. nat46 + qca-nss-ecm MAP-T.
# The EDMA tree's nat46 is plain upstream ayourtch/nat46: it neither stages its
# headers nor exports the QCA MAP-T API (is_map_t_dev, xlate_*, nat46_get_rule_config,
# …) that qca-nss-ecm's MAP-T path (enabled whenever kmod-nat46 is selected) needs.
# Add both so 464xlat builds — and, once the qca-nss-clients map-t connmgr is built,
# can be NSS-offloaded. The MAP-T export patch is the QCA "Export APIs for
# acceleration engine" patch; the underlying functions it wraps (pairs_xlate_*,
# netdev_nat46_instance, nat46_xlate_rulepair_t) still exist by the same names in
# the current nat46, so it applies onto the current version (no old-version pin).
nat46_pkg="package/kernel/nat46"
if [[ -d "$nat46_pkg" ]]; then
  nat46_patch_src="$BUILDER_REPO/package-patches/nat46"
  if compgen -G "$nat46_patch_src/*.patch" >/dev/null; then
    log::info "Adding nat46 patches (qca-nss-ecm MAP-T dependency)"
    mkdir -p "$nat46_pkg/patches"
    cp "$nat46_patch_src"/*.patch "$nat46_pkg/patches/"
  fi

  # Stage nat46 headers so qca-nss-ecm can #include <nat46-core.h>. Upstream nat46
  # has no Build/InstallDev; insert one before the KernelPackage eval. Idempotent.
  nat46_mk="$nat46_pkg/Makefile"
  if [[ -f "$nat46_mk" ]] && ! grep -q 'Build/InstallDev' "$nat46_mk"; then
    log::info "Adding Build/InstallDev (stage nat46 headers) to $nat46_mk"
    awk '
      /^\$\(eval \$\(call KernelPackage,nat46\)\)/ {
        print "define Build/InstallDev"
        print "\t$(INSTALL_DIR) $(STAGING_DIR)/usr/include/nat46"
        print "\t$(INSTALL_DATA) $(PKG_BUILD_DIR)/nat46/modules/*.h $(STAGING_DIR)/usr/include/nat46/"
        print "endef"
        print ""
      }
      { print }
    ' "$nat46_mk" >"$nat46_mk.tmp" && mv "$nat46_mk.tmp" "$nat46_mk"
  fi
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
