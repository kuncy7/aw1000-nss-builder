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

  # IPv6 CGACT-race + CFUN=1 patch: deterministic IPv6-only dial on split-PDN
  # carriers (Orange PL) where a bare quectel-cm -6 hits verbose 241. The feed
  # ships the source in-tree at a fixed version, so this applies with zero fuzz.
  # Idempotent (skip if already applied). Fails the build loudly if it can't
  # apply (e.g. upstream bumped quectel-cm) rather than silently shipping stock.
  qcm_patch="$BUILDER_REPO/package-patches/quectel-cm/950-ipv6-cgact-race.patch"
  if [[ -f "$qcm_patch" ]] && ! grep -q 'QUECTEL_V6_RACE_MAX' "$quectel_cm_dir/src/QMIThread.c" 2>/dev/null; then
    log::info "Applying quectel-cm IPv6 CGACT-race patch"
    patch -p1 -d "$quectel_cm_dir" <"$qcm_patch"
    sed -i 's/^PKG_RELEASE:=4$/PKG_RELEASE:=5/' "$quectel_cm_mk"
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

  # Export nat46's exported symbols (is_map_t_dev) to other modules. nat46 builds
  # in nat46/modules/, so its Module.symvers lands there — but OpenWrt copies the
  # shared symvers from $(PKG_BUILD_DIR)/Module.symvers. Without this copy the
  # symbol is in nat46's own symvers yet ABSENT from the one qca-nss-ecm links
  # against -> "modpost: is_map_t_dev undefined". Append the copy to Build/Compile
  # (before its endef). Idempotent.
  if [[ -f "$nat46_mk" ]] && ! grep -qF 'nat46/modules/Module.symvers $(PKG_BUILD_DIR)/Module.symvers' "$nat46_mk"; then
    log::info "Adding Module.symvers copy to nat46 Build/Compile in $nat46_mk"
    awk '
      /^define Build\/Compile$/ { incompile=1 }
      incompile && /^endef$/ {
        print "\t$(INSTALL_DATA) $(PKG_BUILD_DIR)/nat46/modules/Module.symvers $(PKG_BUILD_DIR)/Module.symvers"
        incompile=0
      }
      { print }
    ' "$nat46_mk" >"$nat46_mk.tmp" && mv "$nat46_mk.tmp" "$nat46_mk"
  fi
fi

# 2c. qca-nss-clients: add the MAP-T connection manager subpackage.
# The EDMA tree's qca-nss-clients ships the map/map-t/ source but defines no
# KernelPackage for it (only pppoe/qdisc/igs). Inject kmod-qca-nss-drv-map-t:
# the package definition, the `map-t=y` build flag (+ the nat46 staging include),
# and the BuildPackage eval. It drives the nat46 MAP-T API exported by the nat46
# patch above, giving NSS hardware offload of 464xlat/MAP-T. Idempotent.
nss_clients_mk="feeds/nss/qca-nss-clients/Makefile"
if [[ -f "$nss_clients_mk" ]] && ! grep -q 'qca-nss-drv-map-t' "$nss_clients_mk"; then
  log::info "Adding kmod-qca-nss-drv-map-t (MAP-T connmgr) to $nss_clients_mk"
  awk '
    /^ifneq \(\$\(CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc\),\)/ && !defdone {
      print "define KernelPackage/qca-nss-drv-map-t"
      print "  SECTION:=kernel"
      print "  CATEGORY:=Kernel modules"
      print "  SUBMENU:=Network Devices"
      print "  TITLE:=NSS connection manager for MAP-T"
      print "  DEPENDS:=@(TARGET_qualcommax||TARGET_ipq806x) \\"
      print "\t   +kmod-qca-nss-drv \\"
      print "\t   +kmod-nat46"
      print "  FILES:=$(PKG_BUILD_DIR)/map/map-t/qca-nss-map-t.ko"
      print "  AUTOLOAD:=$(call AutoLoad,51,qca-nss-map-t)"
      print "endef"
      print ""
      print "define KernelPackage/qca-nss-drv-map-t/description"
      print "NSS connection manager for MAP-T - hardware offload of 464xlat/MAP-T."
      print "endef"
      print ""
      defdone=1
    }
    /^NSS_CLIENTS_MAKE_OPTS\+=pppoe=y/ { afterpppoe=1 }
    afterpppoe && /^endif/ {
      print
      print ""
      print "ifneq ($(CONFIG_PACKAGE_kmod-qca-nss-drv-map-t),)"
      print "NSS_CLIENTS_MAKE_OPTS+=map-t=y"
      print "EXTRA_CFLAGS+= -I$(STAGING_DIR)/usr/include/nat46"
      print "endif"
      afterpppoe=0
      next
    }
    /^\$\(eval \$\(call KernelPackage,qca-nss-drv-igs\)\)/ {
      print
      print "$(eval $(call KernelPackage,qca-nss-drv-map-t))"
      next
    }
    { print }
  ' "$nss_clients_mk" >"$nss_clients_mk.tmp" && mv "$nss_clients_mk.tmp" "$nss_clients_mk"
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
