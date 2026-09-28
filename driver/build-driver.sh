#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the iwlwifi-backport deb for one kernel build, from the driver source directory that
# scripts/make-driver-src.sh assembles (released as driver-src.tar.gz, with this script in it).
# install.sh runs it on the board, against the running kernel (--check-running).
# https://github.com/dapalab/orin-iwlwifi
#
#   build-driver.sh --src DIR --headers DIR --config FILE --proc-versions FILE --target NAME \
#                   --desc TEXT --hdr-info TEXT --out DIR --work DIR [--suffix S] [--check-running]
#
#   --src           driver source dir: meta.env, backport.tar.gz, patches/, firmware/, SHA256SUMS
#   --headers       an L4T kernel-source headers tree (copied, never modified)
#   --config        the target kernel's .config (/proc/config.gz, decompressed)
#   --proc-versions accepted /proc/version strings, one per line
#   --check-running also check the module imports against the CRCs the running kernel's own in-tree
#                   modules import, and that --config is the running kernel's config (on-unit builds)
# Prints the path of the built deb on the last line.
set -euo pipefail
export LC_ALL=C
umask 022

SRCDIR='' HEADERS='' KCONFIG='' PVFILE='' TARGET='' KDESC='' HDR_INFO='' OUT='' WORK='' VSUFFIX='' CHECK_RUNNING=0
while [ $# -gt 0 ]; do
  case $1 in
    --src) SRCDIR=$2; shift ;;         --headers) HEADERS=$2; shift ;;
    --config) KCONFIG=$2; shift ;;     --proc-versions) PVFILE=$2; shift ;;
    --target) TARGET=$2; shift ;;      --desc) KDESC=$2; shift ;;
    --hdr-info) HDR_INFO=$2; shift ;;  --out) OUT=$2; shift ;;
    --work) WORK=$2; shift ;;          --suffix) VSUFFIX=$2; shift ;;
    --check-running) CHECK_RUNNING=1 ;;
    *) echo "build-driver.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
for v in SRCDIR HEADERS KCONFIG PVFILE TARGET KDESC HDR_INFO OUT WORK; do
  [ -n "${!v}" ] || { echo "build-driver.sh: missing argument for $v" >&2; exit 2; }
done
[ -s "$PVFILE" ] || { echo "$PVFILE is empty" >&2; exit 1; }
[ -f "$HEADERS/Module.symvers" ] || { echo "$HEADERS is not a prepared kernel headers tree" >&2; exit 1; }

BP_BRANCH='' BP_SHA='' BP_DATE='' FW_SHA='' FW_RELEASE='' FW_FILES='' DEB_REVISION='' MAINTAINER=''
. "$SRCDIR/meta.env"
: "${BP_BRANCH:?}" "${BP_SHA:?}" "${BP_DATE:?}" "${FW_SHA:?}" "${FW_RELEASE:?}" "${FW_FILES:?}"
: "${DEB_REVISION:?}" "${MAINTAINER:?}"
(cd "$SRCDIR" && sha256sum -c --quiet SHA256SUMS) || { echo "driver source checksum mismatch" >&2; exit 1; }

KVER=5.15.148-tegra
MODULES="compat/compat.ko net/wireless/cfg80211.ko net/mac80211/mac80211.ko
  drivers/net/wireless/intel/iwlwifi/iwlwifi.ko drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko"
# Other cfg80211 users on NVIDIA's L4T images that would load against the backported cfg80211
# and fail.
BLACKLIST="rtl8822ce"
PKG=iwlwifi-backport-$KVER
# release/core24.70 -> 24.70+git20260901.89933456-1+orin1
VERSION=${BP_BRANCH#release/core}+git${BP_DATE//-/}.${BP_SHA:0:8}-1$DEB_REVISION$VSUFFIX
CONFIG_SHA256=$(sha256sum "$KCONFIG" | cut -d' ' -f1)

if [ $CHECK_RUNNING = 1 ]; then
  [ "$(uname -r)" = "$KVER" ] || { echo "running kernel is $(uname -r), not $KVER" >&2; exit 1; }
  [ "$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)" = "$CONFIG_SHA256" ] \
    || { echo "--config is not the running kernel's /proc/config.gz" >&2; exit 1; }
fi

# --- kernel build tree: headers + target .config ----------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
cp -a "$HEADERS" "$WORK/ksrc"
cp "$KCONFIG" "$WORK/ksrc/.config"
make -s -C "$WORK/ksrc" ARCH=arm64 olddefconfig syncconfig > "$WORK/kconfig.log" 2>&1 \
  || { tail -20 "$WORK/kconfig.log" >&2; exit 1; }
# Only compiler-derived symbols may change (our gcc is Ubuntu 11.4, L4T kernels are built with
# Bootlin/Buildroot 11.3, no gcc plugin headers here). Anything else means the config didn't apply.
drift=$(diff <(grep '^CONFIG_' "$KCONFIG" | sort) <(grep '^CONFIG_' "$WORK/ksrc/.config" | sort) \
  | grep '^[<>]' | grep -vE 'CONFIG_(CC_VERSION_TEXT|GCC_VERSION|GCC_PLUGINS)=' || true)
[ -z "$drift" ] || { echo "$TARGET config drifted after olddefconfig:" >&2; echo "$drift" >&2; exit 1; }

# --- backport build ----------------------------------------------------------------------------
mkdir -p "$WORK/backport"
tar -xz -C "$WORK/backport" --strip-components=1 -f "$SRCDIR/backport.tar.gz"
for p in "$SRCDIR"/patches/*.patch; do
  patch -s -d "$WORK/backport" -p1 --no-backup-if-mismatch < "$p"
done
mkdir -p "$WORK/klib"
BPMAKE=(make -C "$WORK/backport" KLIB="$WORK/klib" KLIB_BUILD="$WORK/ksrc")
"${BPMAKE[@]}" defconfig-iwlwifi-public > "$WORK/backport-build.log" 2>&1
"${BPMAKE[@]}" -j"$(nproc)" >> "$WORK/backport-build.log" 2>&1 || { tail -40 "$WORK/backport-build.log" >&2; exit 1; }
grep -E 'warning:' "$WORK/backport-build.log" >&2 || true

# --- checks ------------------------------------------------------------------------------------
want_vermagic="$KVER SMP preempt mod_unload modversions aarch64"
for m in $MODULES; do
  v=$(/sbin/modinfo -F vermagic "$WORK/backport/$m")
  [ "$v" = "$want_vermagic" ] || { echo "$m vermagic '$v' != '$want_vermagic'" >&2; exit 1; }
done
# Every symbol the modules import must be exported, with the same CRC, by the kernel (per the
# headers' Module.symvers) or by another module in this package. The package's own exports
# replace the in-tree cfg80211/mac80211 ones listed in the kernel's file.
awk '!seen[$2]++ {print $2, $1}' "$WORK/backport/Module.symvers" "$WORK/ksrc/Module.symvers" | sort > "$WORK/exports"
for m in $MODULES; do /sbin/modprobe --dump-modversions "$WORK/backport/$m"; done \
  | awk '{print $2, $1}' | sort -u > "$WORK/imports"
join -a1 "$WORK/imports" "$WORK/exports" | awk 'NF != 3 || $2 != $3' > "$WORK/crc-bad"
[ ! -s "$WORK/crc-bad" ] || { echo "imports missing or with a different CRC:" >&2; cat "$WORK/crc-bad" >&2; exit 1; }
echo "imports checked against the headers' Module.symvers: $(wc -l < "$WORK/imports") symbols, 0 mismatches" >&2

if [ $CHECK_RUNNING = 1 ]; then
  # The running kernel doesn't expose its CRCs, but its in-tree modules record the ones they were
  # linked against. Any overlap with our imports must agree.
  find "/lib/modules/$KVER/kernel" -name '*.ko*' -print0 \
    | xargs -0 -n 1 /sbin/modprobe --dump-modversions 2>/dev/null \
    | awk '{print $2, $1}' | sort -u > "$WORK/running-crcs"
  awk '{print $2, $1}' "$WORK/backport/Module.symvers" | sort > "$WORK/own-exports"
  join -v1 "$WORK/imports" "$WORK/own-exports" > "$WORK/kernel-imports"
  join "$WORK/kernel-imports" "$WORK/running-crcs" | awk '$2 != $3' > "$WORK/crc-bad-running"
  [ ! -s "$WORK/crc-bad-running" ] || { echo "CRCs differ from the running kernel's in-tree modules:" >&2;
    cat "$WORK/crc-bad-running" >&2; exit 1; }
  echo "imports checked against the running kernel's in-tree modules:" \
    "$(join "$WORK/kernel-imports" "$WORK/running-crcs" | awk '{print $1}' | sort -u | wc -l)" \
    "of $(wc -l < "$WORK/kernel-imports") kernel symbols covered, 0 mismatches" >&2
fi

# --- package tree ------------------------------------------------------------------------------
R=$WORK/pkg
DOC=$R/usr/share/doc/$PKG
SHARE=$R/usr/share/$PKG
mkdir -p "$R/DEBIAN" "$R/lib/modules/$KVER/updates/iwlwifi-backport" "$R/lib/firmware/updates" \
  "$R/etc/modprobe.d" "$DOC" "$SHARE"
for m in $MODULES; do
  install -m 0644 "$WORK/backport/$m" "$R/lib/modules/$KVER/updates/iwlwifi-backport/"
done
strip --strip-debug "$R/lib/modules/$KVER/updates/iwlwifi-backport/"*.ko
for f in $FW_FILES; do install -m 0644 "$SRCDIR/firmware/$f" "$R/lib/firmware/updates/"; done
{ echo "# $PKG: other cfg80211 drivers would load against the backported cfg80211 and fail."
  for b in $BLACKLIST; do echo "blacklist $b"; done; } > "$R/etc/modprobe.d/iwlwifi-backport.conf"
echo "/etc/modprobe.d/iwlwifi-backport.conf" > "$R/DEBIAN/conffiles"
sed "s/^/$CONFIG_SHA256\t/" "$PVFILE" > "$SHARE/accepted-fingerprints"

install -m 0644 "$WORK/backport/COPYING" "$DOC/copyright"
install -m 0644 "$SRCDIR/firmware/LICENCE.iwlwifi_firmware" "$DOC/"
cp "$SRCDIR"/patches/*.patch "$DOC/"
{ echo "backport-iwlwifi $BP_BRANCH $BP_SHA"
  echo "patches: $(cd "$SRCDIR/patches" && sha256sum ./*.patch | tr '\n' ' ')"
  echo "linux-firmware $FW_SHA"
  (cd "$R/lib/firmware/updates" && sha256sum $FW_FILES)
  echo "kernel headers $HDR_INFO"
  echo "target $TARGET: $KDESC"
  echo "kernel config sha256 $CONFIG_SHA256"
  echo "built on $(hostname) with $(gcc --version | head -1)"
  (cd "$R/lib/modules/$KVER/updates/iwlwifi-backport" && sha256sum ./*.ko); } > "$DOC/BUILDINFO"
cat > "$WORK/changelog" <<EOF
$PKG ($VERSION) jammy; urgency=medium

  * Rebuild for Jetson Orin ($KDESC, $KVER).
  * backport-iwlwifi $BP_BRANCH, commit $BP_SHA, with patches:
$(cd "$SRCDIR/patches" && ls ./*.patch | sed 's|^\./|    |')
  * AX210 firmware from linux-firmware $FW_SHA ($FW_RELEASE release):
    $(echo $FW_FILES).

 -- $MAINTAINER  $(date -R)
EOF
gzip -9n -c "$WORK/changelog" > "$DOC/changelog.Debian.gz"

cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: arm64
Maintainer: $MAINTAINER
Depends: kmod
Section: kernel
Priority: optional
Installed-Size: $(du -sk --exclude=DEBIAN "$R" | cut -f1)
Description: Intel iwlwifi backport driver and AX210 firmware for the $KDESC
 backport-iwlwifi $BP_BRANCH (commit $BP_SHA): iwlwifi, iwlmvm and the
 backported cfg80211, mac80211 and compat modules, installed under
 /lib/modules/$KVER/updates/ so they take precedence over the in-tree driver.
 AX210 firmware ($(echo $FW_FILES)) from linux-firmware commit
 $FW_SHA, installed under /lib/firmware/updates/.
 .
 Built for one kernel build only: the preinst refuses to install on a kernel
 whose /proc/version and /proc/config.gz hash are not listed in
 /usr/share/$PKG/accepted-fingerprints. Every kernel rebuild needs a
 matching rebuild of this package.
EOF

cat > "$R/DEBIAN/preinst" <<'EOF'
#!/bin/sh
set -e
PKG=@PKG@
case "$1" in install|upgrade)
  # firmware_class.path (/etc/firmware on L4T) is searched before /lib/firmware/updates.
  if ls /etc/firmware/iwlwifi-* >/dev/null 2>&1; then
    echo "$PKG: /etc/firmware contains iwlwifi-* files that would shadow this package's firmware" >&2
    exit 1
  fi
  if [ -n "$IWLWIFI_BACKPORT_SKIP_FINGERPRINT" ]; then
    echo "$PKG: IWLWIFI_BACKPORT_SKIP_FINGERPRINT set, not checking the kernel build" >&2
  else
    cfg=$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)
    ver=$(cat /proc/version | sed 's/ *$//')
    accepted=$(cat <<'FP'
@FINGERPRINTS@
FP
)
    if ! printf '%s\n' "$accepted" | grep -qxF "$(printf '%s\t%s' "$cfg" "$ver")"; then
      echo "$PKG: running kernel is not the build these modules were compiled for" >&2
      echo "  /proc/version: $ver" >&2
      echo "  config sha256: $cfg" >&2
      exit 1
    fi
  fi
esac
exit 0
EOF
cat > "$R/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then depmod -a $KVER; fi
exit 0
EOF
cat > "$R/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in remove|purge|abort-install|abort-upgrade) depmod -a $KVER ;; esac
exit 0
EOF
sed -i -e "s|@PKG@|$PKG|" -e "/@FINGERPRINTS@/{r $SHARE/accepted-fingerprints
d}" "$R/DEBIAN/preinst"
chmod 0755 "$R/DEBIAN/preinst" "$R/DEBIAN/postinst" "$R/DEBIAN/postrm"

DEB=$OUT/${PKG}_${VERSION}_arm64.deb
dpkg-deb --root-owner-group -Zxz --build "$R" "$DEB" > /dev/null
echo "$DEB"
