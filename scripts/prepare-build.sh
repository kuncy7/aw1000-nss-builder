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

# Bump a package's PKG_RELEASE so a patched package is not confused with the
# stock one. Reads the current value instead of pinning an expected number: a
# pinned sed silently no-ops the moment upstream bumps the package, and the
# image then claims to be stock while carrying our patches.
pkg_release_bump() {
  local mk="$1" cur
  cur="$(sed -n 's/^PKG_RELEASE:=\([0-9]\{1,\}\)$/\1/p' "$mk" | head -1)"
  if [[ -z "$cur" ]]; then
    log::warn "no plain numeric PKG_RELEASE in $mk — leaving the version alone"
    return 0
  fi
  sed -i "s/^PKG_RELEASE:=$cur\$/PKG_RELEASE:=$((cur + 1))/" "$mk"
}

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
# Exception: the `wwan` feed (a fork of qosmio/nss-packages, see builder.yml)
# also carries its own copies of the NSS core packages (qca-nss-drv,
# qca-nss-ecm, …) that would shadow the Julius edma-nss versions if
# force-installed with `-p -a`. Install only the modem packages from it;
# everything else resolves from the nss feed (listed earlier in feeds.conf, so
# it wins for duplicates). This is the hybrid: modem from the wwan fork, the
# entire NSS data plane from Julius.
# Feeds we cherry-pick from rather than install wholesale:
#   wwan       - the fork also carries the NSS core packages (see above).
#   ddimension - a general-purpose feed (flashing tools, wpad variants, MQTT,
#                home automation …); we only want the wwand stack. The single
#                source package `wwand` builds wwand, wwand-qmi and the
#                datapath add-ons including wwand-datapath-rmnet_nss.
WWAN_PACKAGES="quectel-cm luci-proto-quectel kmod-rmnet-nss kmod-usb-net-qmi-wwan-quectel"
DDIMENSION_PACKAGES="wwand luci-app-wwand luci-proto-wwand"

feed_package_whitelist() {
  case "$1" in
    wwan) printf '%s' "$WWAN_PACKAGES" ;;
    ddimension) printf '%s' "$DDIMENSION_PACKAGES" ;;
  esac
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  feed_name="$(awk '{print $2}' <<<"$line")"
  whitelist="$(feed_package_whitelist "$feed_name")"
  if [[ -n "$whitelist" ]]; then
    log::info "Installing selected packages from feed: $feed_name ($whitelist)"
    # shellcheck disable=SC2086  # intentional word splitting of the package list
    ./scripts/feeds install -p "$feed_name" $whitelist
    continue
  fi
  log::info "Installing packages from feed: $feed_name"
  ./scripts/feeds install -a -p "$feed_name"
done <<<"$FEEDS_LINES"

log::info "Installing all remaining packages"
./scripts/feeds install -a

# The wwan fork carries copies of packages that belong to other feeds, and
# `feeds install -p wwan` claims them for dependencies too: quectel-cm now
# depends on sms-tool, so the fork's 2022 copy won over the packages feed — and
# that copy no longer builds (its upstream tarball stopped hashing to the pinned
# value, and the mirror 404s). Same story for libnl-nss, which has to match the
# nssinfo we build from the nss feed. Repoint both, and fail loudly if the
# repoint does not take.
#   reinstall - the package exists as a source package elsewhere; put it back
#               by feeds.conf order (sms-tool then comes from `packages`).
#   drop      - another feed already ships it inside a different source package
#               (libnl-nss is built by the nss feed's nss-userspace-oss, which
#               is installed from nss), so removing the fork's standalone copy
#               is the whole fix. Reinstalling by name would only find the
#               fork's copy again — `-p` is a preference, not a restriction.
repoint_from_wwan() {
  local pkg="$1" mode="$2"
  [[ -e "package/feeds/wwan/$pkg" ]] || return 0
  log::info "Repointing $pkg away from the wwan feed ($mode)"
  ./scripts/feeds uninstall "$pkg"
  [[ "$mode" == reinstall ]] && ./scripts/feeds install "$pkg"
  if [[ -e "package/feeds/wwan/$pkg" ]]; then
    log::error "$pkg still resolves from the wwan feed after the repoint"
    exit 1
  fi
  return 0
}
repoint_from_wwan sms-tool reinstall
repoint_from_wwan libnl-nss drop

# libnl-nss must still be available afterwards, from the nss feed's
# nss-userspace-oss — nssinfo links against it.
if [[ ! -e package/feeds/nss/nss-userspace-oss ]]; then
  log::error "nss-userspace-oss is not installed from the nss feed; libnl-nss would be missing"
  exit 1
fi

# Guard: qca-mcs is the one package duplicated between the nss feed (QSDK 14.0,
# kernel-6.18-ready) and the wwan feed (stale 12.5 copy that fails on 6.18 with
# implicit try_to_del_timer_sync). nss-tools hard-depends on kmod-qca-mcs, so a
# wrong resolution bricks the build an hour in — fail fast here instead.
if [[ -e package/feeds/wwan/qca-mcs ]]; then
  log::error "qca-mcs resolved from the wwan feed (stale 12.5); expected the nss feed"
  exit 1
fi

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

  # quectel.sh is NOT replaced any more. Our copy was qosmio's protocol handler
  # with the ash fix (`||`-joined assignments); the wwan feed now carries
  # xhikarishii's rewrite (1068 lines vs our 234) with split IPv6/dual-stack
  # PDP handling, reconnect route flushing and the nat64/PREF64 hook — a strict
  # superset that does not have the ash defect. Overwriting it would throw all
  # of that away.

  # IPv6 CGACT-race + CFUN=1 patch: deterministic IPv6-only dial on split-PDN
  # carriers (Orange PL) where a bare quectel-cm -6 hits verbose 241. Still ours
  # alone: the wwan feed's IPv6 work fixes PDP/route/APN handling but does not
  # touch the CGACT activation race. Idempotent (skip if already applied). Fails
  # the build loudly if it cannot apply rather than silently shipping stock.
  qcm_patch="$BUILDER_REPO/package-patches/quectel-cm/950-ipv6-cgact-race.patch"
  if [[ -f "$qcm_patch" ]] && ! grep -q 'QUECTEL_V6_RACE_MAX' "$quectel_cm_dir/src/QMIThread.c" 2>/dev/null; then
    log::info "Applying quectel-cm IPv6 CGACT-race patch"
    patch -p1 -d "$quectel_cm_dir" <"$qcm_patch"
    pkg_release_bump "$quectel_cm_mk"
  fi
done

# 2a-bis. rmnet -> NSS deferred attach (quectel-qmi-wwan).
# qmi_wwan_q attaches the qmap netdev to the NSS data path once, at USB-probe
# time. On the EDMA tree the NSS data plane is armed later (at runtime), so that
# single attempt races the arming and usually loses ("Device will not use NSS
# path: -1"), leaving rmnet off NSS for the device's whole life. The patch makes
# the qmap netdev self-attach via a bounded delayed-work retry until the data
# plane is armed -- timing independent, no module reload, no dropped data call.
# This removes the need for the modem-up qmi_wwan_q reload hack. Idempotent;
# fails loudly if it cannot apply (e.g. upstream bumped quectel-qmi-wwan).
qqw_patch="$BUILDER_REPO/package-patches/quectel-qmi-wwan/950-rmnet-nss-deferred-attach.patch"
qqw_618_patch="$BUILDER_REPO/package-patches/quectel-qmi-wwan/960-kernel-6.18-port.patch"
for qqw_dir in feeds/nss_packages/wwan/driver/quectel-qmi-wwan feeds/wwan/wwan/driver/quectel-qmi-wwan; do
  [[ -d "$qqw_dir" ]] || continue
  if [[ -f "$qqw_patch" ]] && ! grep -q 'qmap_nss_retry_work' "$qqw_dir/src/qmi_wwan_q.c" 2>/dev/null; then
    log::info "Applying quectel-qmi-wwan rmnet->NSS deferred-attach patch"
    patch -p1 -d "$qqw_dir" <"$qqw_patch"
    pkg_release_bump "$qqw_dir/Makefile"
  fi

  # Kernel 6.18 port. qmi_wwan_q hijacks usbnet's bottom half, which migrated
  # from a tasklet (dev->bh) to a work_struct (dev->bh_work) in 6.18; it also
  # calls hrtimer_init(), replaced by hrtimer_setup(). The patch version-gates
  # both (< 6.18 path untouched). It also adds KCFLAGS to Build/Compile: 6.18
  # kbuild dropped command-line EXTRA_CFLAGS from _c_flags, so the
  # -I qca-nss-rmnet include and -DCONFIG_QCA_NSS_DRV define would be silently
  # lost (NSS path compiled out). Must run after the deferred-attach patch.
  if [[ -f "$qqw_618_patch" ]] && ! grep -q 'usbnet_bh_func' "$qqw_dir/src/qmi_wwan_q.c" 2>/dev/null; then
    log::info "Applying quectel-qmi-wwan kernel-6.18 port patch"
    patch -p1 -d "$qqw_dir" <"$qqw_618_patch"
    # shellcheck disable=SC2016  # $(EXTRA_CFLAGS) is a make variable, not shell
    grep -q KCFLAGS "$qqw_dir/Makefile" || \
      sed -i 's|EXTRA_CFLAGS="$(EXTRA_CFLAGS)" M=|EXTRA_CFLAGS="$(EXTRA_CFLAGS)" KCFLAGS="$(EXTRA_CFLAGS)" M=|' "$qqw_dir/Makefile"
    pkg_release_bump "$qqw_dir/Makefile"
  fi
done

# 2a-ter. rmnet-nss: same 6.18 EXTRA_CFLAGS drop. Without KCFLAGS the
# -I qca-nss-drv include is lost and nss_api_if.h isn't found (hard build
# failure). KCFLAGS carries the include via KBUILD_CFLAGS instead.
for rmnet_dir in feeds/nss_packages/wwan/driver/rmnet-nss feeds/wwan/wwan/driver/rmnet-nss; do
  [[ -d "$rmnet_dir" ]] || continue
  rmnet_mk="$rmnet_dir/Makefile"
  if [[ -f "$rmnet_mk" ]] && ! grep -q KCFLAGS "$rmnet_mk"; then
    log::info "Adding KCFLAGS to $rmnet_mk for kernel 6.18"
    # shellcheck disable=SC2016  # $(EXTRA_CFLAGS) is a make variable, not shell
    sed -i 's|EXTRA_CFLAGS="$(EXTRA_CFLAGS)" M=|EXTRA_CFLAGS="$(EXTRA_CFLAGS)" KCFLAGS="$(EXTRA_CFLAGS)" M=|' "$rmnet_mk"
  fi
done

# 2a-quater. quectel-mhi-pcie (PCIe/M.2 modem driver): two 6.18 breakages.
# (1) The VFS no_llseek helper was removed (gone since 6.15); the feed's mon
# fops guards it behind a backwards `>= 6.14 ? no_llseek : noop_llseek` check,
# so 6.18 references the removed symbol. Replaced with noop_llseek (valid on
# all supported kernels; same behaviour the < 6.14 branch gave on 6.12).
# (2) hrtimer_init() was replaced by hrtimer_setup() (mhi_netdev_quectel.c and
# rmnet/rmnet_map_data.c), version-gated < 6.18 like quectel-qmi-wwan.
mhi_618_patch="$BUILDER_REPO/package-patches/quectel-mhi-pcie/950-kernel-6.18-port.patch"
for mhi_dir in feeds/nss_packages/wwan/driver/quectel-mhi-pcie feeds/wwan/wwan/driver/quectel-mhi-pcie; do
  [[ -d "$mhi_dir" ]] || continue
  if [[ -f "$mhi_618_patch" ]] && ! grep -q 'noop_llseek is valid on' "$mhi_dir/src/core/mhi_init.c" 2>/dev/null; then
    log::info "Applying quectel-mhi-pcie kernel-6.18 port patch"
    patch -p1 -d "$mhi_dir" <"$mhi_618_patch"
    pkg_release_bump "$mhi_dir/Makefile"
  fi
done

# 2a-quinque. wwand: pin the commit that carries the QMAP-version fix.
# After our forum report #38 (2026-09-06) the author fixed three things in
# ddimension/wwand 2a26903 ("rmnet_nss: take the QMAP header version from the
# driver, not from a default"): the datapath now derives QMAP v5 from
# qmap_size (31 KB = the sdx55 row = our RG500Q-EA), `option qmap_version`
# warns when it cannot raise the ladder, and a negotiated QMAP format with no
# `option mux_id` is a refusal instead of a dead link. The packaged r64 still
# pins 6ddec23e, one commit BEFORE that fix. Move the pin forward so this
# build can test it. Self-limiting: the edit only fires while the feed pins
# exactly that pre-fix commit, so the author's next release bump makes this
# block a no-op without any change here. The mirror hash is set to `skip`
# because the tarball changes with the pin; the feed is unpinned by design.
wwand_mk="feeds/ddimension/wwand/Makefile"
wwand_prefix="6ddec23e3ea9c6c6bbe1cd5feef207972137d840"
wwand_fix="2a269031000d9131af49422472f809d28c4821ef"
if [[ -f "$wwand_mk" ]] && grep -q "^PKG_SOURCE_VERSION:=$wwand_prefix\$" "$wwand_mk"; then
  log::info "wwand: feed pins pre-fix $wwand_prefix; moving to $wwand_fix (QMAP-version fix)"
  sed -i "s/^PKG_SOURCE_VERSION:=$wwand_prefix\$/PKG_SOURCE_VERSION:=$wwand_fix/" "$wwand_mk"
  sed -i 's/^PKG_MIRROR_HASH:=.*$/PKG_MIRROR_HASH:=skip/' "$wwand_mk"
  pkg_release_bump "$wwand_mk"
  grep -q "^PKG_SOURCE_VERSION:=$wwand_fix\$" "$wwand_mk" || { log::error "wwand pin override did not apply"; exit 1; }
fi

# 2b. nat46 + qca-nss-ecm MAP-T — NOW UPSTREAM IN THE EDMA TREE (no longer injected).
# Our fix was merged into JuliusBairaktaris/openwrt-nss-edma (commit b8a0af308e,
# "nat46: stage headers and add QCA MAP-T exports for ECM offload"): the tree's
# nat46 now ships Build/InstallDev, the Module.symvers copy, AND the full QCA MAP-T
# patch stack (102-mapt etc.). Re-adding our own export patch here would collide
# with that 102-mapt.patch (duplicate EXPORT_SYMBOLs), so this step is intentionally
# removed. The connmgr injection below (2c) builds against the tree's nat46 API.
# The second nat46 fix (PKG_EXTMOD_SUBDIRS:=nat46/modules, our 6.18 symvers
# collector fix) is ALSO upstream now — adopted into the EDMA tree by 2026-07-08
# (nat46 Makefile carries it with its own comment), so the former
# patches/010-nat46-pkg-extmod-subdirs-6.18.patch was dropped: re-applying it
# would fail `git apply` and abort section 1.

# 2b-bis. qca-nss-ecm: RAWIP interface type — NOW UPSTREAM, this is a tripwire.
# History: upstream first gated the flag on CONFIG_PACKAGE_kmod-qmi_wwan_q (the
# QModem driver name, never ours), then removed RAWIP altogether in "force off
# the interface types we do not validate" (0df7134), so we appended it
# ourselves. As of nss-packages 0ac177b ("qca-nss-ecm: classify a header-less
# modem as raw IP") Julius sets it himself and gates it properly — on
# NSS_DRV_RMNET_ENABLE and on the firmware line, because 11.4 has no raw-IP
# valid flag in the rule ABI and will not compile with the type enabled.
#
# So this block no longer fires: the grep finds his line and we skip. It is
# kept as a self-healing fallback — if the flag ever disappears from the
# Makefile again, we re-add it rather than silently losing modem acceleration.
# Note the grep matches the string anywhere in the file, including inside his
# make conditionals, which is what we want: when his gate deliberately excludes
# a configuration (11.4), skipping is the correct outcome, not a regression.
ecm_mk="feeds/nss/qca-nss-ecm/Makefile"
if [[ -f "$ecm_mk" ]] && ! grep -q 'ECM_INTERFACE_RAWIP_ENABLE=y' "$ecm_mk"; then
  log::info "Enabling ECM RAWIP interface support (rmnet offload)"
  cat >>"$ecm_mk" <<'EOF'

# aw1000-nss-builder: rmnet (ARPHRD_RAWIP) offload for the USB QMI modem —
# validated on AW1000 hardware; upstream forces it off as never-validated.
ECM_MAKE_OPTS+=ECM_INTERFACE_RAWIP_ENABLE=y
EOF
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
