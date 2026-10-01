#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh: install orin-iwlwifi on a Jetson Orin (L4T 36.x) with an Intel AX210.
# https://github.com/dapalab/orin-iwlwifi
#
#   sudo bash install.sh                  install the release this script came from
#   sudo bash install.sh --latest         install the newest release (never a pre-release)
#   sudo bash install.sh --release TAG    install a given release (or pre-release, e.g. 2026.10.01-1-test1)
#   sudo bash install.sh --from DIR       install from release files already in DIR (for testing)
#   sudo bash install.sh --check          only run the checks; change nothing
#   Add --psk-file FILE to also add a Wi-Fi network: an iwd profile named <SSID>.psk, as iwd
#   writes it in /var/lib/iwd (see iwd.network(5)). It's copied in as is. Repeat for more networks.
#   Add --country CC (ISO 3166 code, e.g. US) to set the Wi-Fi regulatory country. Without it the
#   AX210 guesses the country from nearby access points, and until it does, 6 GHz is off. Only
#   set the country the board is used in: the firmware refuses one it doesn't see around it, and
#   6 GHz then stays off. See D16. On a board that already has one, --country none removes it.
#
# Settings go after sudo (sudo drops variables set before it), e.g. sudo ETH_IFACE=eth0 bash ...
#   ETH_IFACE      wired interface (default: the first on-board one)
#   ETH_METRIC     route metric for wired (default 100); WIFI_METRIC for Wi-Fi (default 600)
#
# Running it again on an installed board installs the release over it (to upgrade, or to pick up
# new settings) and keeps the country and route metrics the board has unless given again. Any
# file it replaces with different contents is copied to /var/lib/orin-iwlwifi/replaced-<time>/
# first. See D18.
#
# What it does, one function per step (see the bottom of this file):
#   1. check          L4T 36 on arm64, AX210 present, build tools and kernel headers installed,
#                     running over ethernet. Changes nothing; lists anything missing and stops.
#   2. hold_l4t       apt-mark hold every nvidia-l4t-* package
#   3. download       release files into /var/lib/orin-iwlwifi/<release>/, checked against SHA256SUMS
#   4. build_driver   build iwlwifi for the running kernel; stops if the kernel doesn't match
#   5. install_debs   iwd, libell0, then the driver
#   6. configure      iwd for Wi-Fi (incl. DHCP), systemd-networkd for ethernet; NetworkManager masked
#   7. record         write down what went in: /var/lib/orin-iwlwifi/installed
# Nothing changes how the board is networked until you reboot. There is no undo: to start over,
# re-image. Why each step is there: docs/DECISIONS.md.
set -Eeuo pipefail
# set -e exits without a word; say where, so a half-done install is never mistaken for a done one.
on_error() { local rc=$?; echo "[$(date +%T)] ERROR: install.sh line $1: $2 (exit $rc)" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
export LC_ALL=C
umask 022

RELEASE=@RELEASE@                   # filled in by the release workflow
REPO=dapalab/orin-iwlwifi
STATE=/var/lib/orin-iwlwifi
KVER=5.15.148-tegra
DRIVER_PKG=iwlwifi-backport-$KVER
ETH_IFACE=${ETH_IFACE:-}
ETH_METRIC=${ETH_METRIC:-}                # empty: what the board has, else 100
WIFI_METRIC=${WIFI_METRIC:-}              # empty: what the board has, else 600
BACKUP=$STATE/replaced-$(date +%Y%m%dT%H%M%S)

log() { echo "[$(date +%T)] $*"; }
die() { echo "[$(date +%T)] ERROR: $*" >&2; exit 1; }

# Version of an installed package ("hi" = installed and held), or nothing.
pkg_version() {
  dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$1" 2>/dev/null | awk '$1 ~ /^[ih]i/ { print $2 }' || true
}

# Write stdin to a file, creating its directory. A file already there with different contents
# is copied under $BACKUP first (an earlier install, or an edit made on the board).
write() {
  local new
  new=$(cat; echo .); new=${new%.}
  mkdir -p "$(dirname "$1")"
  if [[ -e $1 ]] && ! cmp -s "$1" <(printf '%s' "$new"); then
    mkdir -p "$BACKUP$(dirname "$1")"
    cp -p "$1" "$BACKUP$1"
    log "replacing $1 (old copy: $BACKUP$1)"
  fi
  printf '%s' "$new" > "$1"
  log "wrote $1"
}

# A setting the board already has: a route metric, the country.
# Nothing (and success) when the file isn't there yet, as on a freshly flashed board.
current_metric() { [[ -r $1 ]] || return 0; sed -n '/^RouteMetric=[0-9]*$/{s/^RouteMetric=//p;q}' "$1"; }
# Wi-Fi's is iwd's RoutePriorityOffset; releases before D21 had it in 25-wlan.network.
current_wifi_metric() {
  local m=''
  [[ ! -r /etc/iwd/main.conf ]] \
    || m=$(sed -n '/^RoutePriorityOffset=[0-9]*$/{s/^RoutePriorityOffset=//p;q}' /etc/iwd/main.conf)
  [[ -n $m ]] || m=$(current_metric /etc/systemd/network/25-wlan.network)
  echo "$m"
}
current_country() {
  local f=/etc/modprobe.d/orin-iwlwifi.conf
  [[ -r $f ]] || return 0
  sed -n 's/^options iwlmvm country=\([A-Za-z]*\)$/\1/p' "$f" | tail -1 | tr '[:lower:]' '[:upper:]'
}

# NVIDIA's kernel headers tree for the running kernel. /lib/modules/<kver>/build isn't trusted:
# on images with a custom kernel it can point into the machine the kernel was built on.
headers_tree() {
  local t
  for t in "$(readlink -f "/lib/modules/$KVER/build" 2>/dev/null || true)" \
           $(dpkg -L nvidia-l4t-kernel-headers 2>/dev/null | grep -E '/kernel-source$' || true); do
    [[ -n $t && -f $t/Module.symvers && -f $t/Makefile ]] && { echo "$t"; return 0; }
  done
  return 1
}

# First on-board wired interface (skips USB gadget, bridges, containers).
detect_eth() {
  local d n
  for d in /sys/class/net/*; do
    n=${d##*/}
    [[ -e $d/device && ! -d $d/wireless && $(cat "$d/type") == 1 ]] || continue
    case $n in usb*|l4tbr*|rndis*|docker*|veth*|br*|virbr*) continue ;; esac
    echo "$n"; return 0
  done
  return 1
}

# The SSID an iwd profile is for: its file name, or "=" + hex for special characters (iwd.network(5)).
profile_ssid() {
  local stem
  stem=$(basename "$1" .psk)
  if [[ $stem == =* ]]; then printf '%b\n' "$(sed 's/../\\x&/g' <<<"${stem:1}")"
  else printf '%s\n' "$stem"; fi
}

# ------------------------------------------------------------------------ 1. check

check() {
  local missing=() tools=() t d f ax210=0 kpkg

  [[ $EUID -eq 0 ]] || missing+=("run as root: sudo bash $0")
  [[ $(uname -m) == aarch64 ]] || missing+=("not arm64 ($(uname -m))")
  grep -q '^# R36 ' /etc/nv_tegra_release 2>/dev/null \
    || missing+=("not Jetson Linux 36.x: $(head -1 /etc/nv_tegra_release 2>/dev/null || echo 'no /etc/nv_tegra_release')")
  [[ $(uname -r) == "$KVER" ]] || missing+=("running kernel is $(uname -r), expected $KVER")
  [[ -r /proc/config.gz ]] || missing+=("no /proc/config.gz: the driver is built with the running kernel's config")

  for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/vendor") == 0x8086 && $(cat "$d/device") == 0x2725 ]] && ax210=1
  done
  (( ax210 )) || missing+=("no Intel AX210 (PCI 8086:2725) found")

  for t in gcc make bc flex bison patch curl iw; do command -v "$t" >/dev/null || tools+=("$t"); done
  (( ${#tools[@]} == 0 )) || missing+=("build tools: sudo apt-get install ${tools[*]}")

  if ! headers_tree >/dev/null; then
    # Never install the headers unversioned: apt would take the newest, and with it a new kernel.
    kpkg=$(pkg_version nvidia-l4t-kernel)
    missing+=("kernel headers: sudo apt-get install nvidia-l4t-kernel-headers=${kpkg:-<version of nvidia-l4t-kernel>}")
  fi

  # The driver package's firmware goes in /lib/firmware/updates; L4T searches /etc/firmware first.
  if compgen -G '/etc/firmware/iwlwifi-*' >/dev/null; then
    missing+=("/etc/firmware has iwlwifi-* files that would be loaded instead of the new firmware")
  fi

  # Fresh image, on ethernet: the network is reconfigured at the reboot, over the wired link.
  [[ -n $ETH_IFACE ]] || ETH_IFACE=$(detect_eth || true)
  if [[ -z $ETH_IFACE || ! -e /sys/class/net/$ETH_IFACE ]]; then
    missing+=("no wired interface found${ETH_IFACE:+ ($ETH_IFACE)}; set ETH_IFACE")
  elif ! ip -4 route show default dev "$ETH_IFACE" | grep -q .; then
    missing+=("no IPv4 default route over $ETH_IFACE: connect the board by ethernet")
  fi
  [[ -e /run/systemd/resolve/stub-resolv.conf ]] || missing+=("systemd-resolved isn't running")

  for f in "${PSK_FILES[@]}"; do
    if [[ ! -r $f ]]; then missing+=("can't read --psk-file $f")
    elif [[ $f != *.psk ]]; then missing+=("$f: an iwd profile is named <SSID>.psk")
    elif grep -q $'\r' "$f"; then missing+=("$f has Windows line endings, which iwd can't read")
    elif ! grep -qE '^(Passphrase|PreSharedKey)=' "$f"; then missing+=("$f has no Passphrase= or PreSharedKey=")
    fi
  done
  if [[ -n $COUNTRY && $COUNTRY != NONE && ( ! $COUNTRY =~ ^[A-Z]{2}$ || $COUNTRY == ZZ ) ]]; then
    missing+=("--country $COUNTRY: use a two-letter ISO 3166 country code, e.g. US (or none)")
  fi

  if (( ${#missing[@]} )); then
    printf '  - %s\n' "${missing[@]}" >&2
    die "not ready to install; nothing was changed"
  fi
  log "checks passed: L4T $(sed -n 's/^# R\([0-9]*\) .*REVISION: \([0-9.]*\),.*/\1.\2/p' /etc/nv_tegra_release), AX210 found," \
      "headers $(pkg_version nvidia-l4t-kernel-headers), wired $ETH_IFACE"
}

# ------------------------------------------------------------------------ 2. hold L4T

hold_l4t() {
  # L4T (kernel, boot chain, GPU and multimedia userspace) comes from the image and must stay a
  # matched set: a new L4T or kernel means a re-image, not apt. Without the hold, installing
  # one package that depends on a newer nvidia-l4t-kernel replaces the kernel. See D3.
  # Undo: apt-mark unhold <package>
  local pkgs
  pkgs=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'nvidia-l4t-*' | awk '$1 == "installed" { print $2 }')
  apt-mark hold $pkgs >/dev/null
  log "held $(wc -w <<< "$pkgs") nvidia-l4t-* packages"
}

# ------------------------------------------------------------------------ 3. download

resolve_release() {
  if [[ -n $FROM ]]; then
    [[ $RELEASE != @RELEASE@ ]] || RELEASE=local
    return 0
  fi
  if (( LATEST )); then
    # github.com/<repo>/releases/latest redirects to .../releases/tag/<newest tag>
    RELEASE=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
    RELEASE=${RELEASE##*/}
  fi
  [[ $RELEASE =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+(-[a-z0-9]+)?$ ]] \
    || die "no release to install (got '$RELEASE'); use --latest or --release <tag>"
}

download() {
  local f
  DIR=$STATE/$RELEASE
  mkdir -p "$DIR"
  get() {
    if [[ -n $FROM ]]; then cp "$FROM/$1" "$DIR/"
    else curl -fsSL --retry 3 -o "$DIR/$1" "https://github.com/$REPO/releases/download/$RELEASE/$1"; fi
  }
  get SHA256SUMS
  ELL_DEB=$(awk '$2 ~ /^libell0_.*_arm64\.deb$/ { print $2 }' "$DIR/SHA256SUMS")
  IWD_DEB=$(awk '$2 ~ /^iwd_.*_arm64\.deb$/ { print $2 }' "$DIR/SHA256SUMS")
  [[ -n $ELL_DEB && -n $IWD_DEB ]] && grep -q ' driver-src\.tar\.gz$' "$DIR/SHA256SUMS" \
    || die "release $RELEASE doesn't list libell0, iwd and driver-src.tar.gz"
  for f in "$ELL_DEB" "$IWD_DEB" driver-src.tar.gz; do get "$f"; done
  (cd "$DIR" && sha256sum --check --quiet --ignore-missing SHA256SUMS) || die "checksum mismatch in $DIR"
  ELL_DEB=$DIR/$ELL_DEB IWD_DEB=$DIR/$IWD_DEB
  log "release $RELEASE: $(basename "$IWD_DEB"), $(basename "$ELL_DEB"), driver-src.tar.gz (checksums OK)"
}

# ------------------------------------------------------------------------ 4. build the driver

build_driver() {
  # Built against the running kernel's config and NVIDIA's headers. build-driver.sh then compares
  # the symbol CRCs the new modules import with the ones the running kernel's own modules use,
  # and stops on any mismatch, before anything is installed. See D1.
  local src=$DIR/driver-src work=$DIR/build
  rm -rf "$src" "$work"
  mkdir -p "$work"
  tar -xzf "$DIR/driver-src.tar.gz" -C "$DIR"
  zcat /proc/config.gz > "$work/config"
  sed 's/ *$//' /proc/version > "$work/proc-version"
  log "building the driver for this kernel (a few minutes; log: $work/build.log)"
  DRIVER_DEB=$("$src/build-driver.sh" --src "$src" --headers "$(headers_tree)" \
      --config "$work/config" --proc-versions "$work/proc-version" --check-running \
      --target "$(hostname)" --desc "kernel running on $(hostname)" \
      --hdr-info "nvidia-l4t-kernel-headers $(pkg_version nvidia-l4t-kernel-headers)" \
      --out "$DIR" --work "$work/tree" 2> "$work/build.log" | tail -1) \
    || { tail -30 "$work/build.log" >&2; die "driver build failed; nothing was installed. Log: $work/build.log"; }
  grep '^imports checked' "$work/build.log" | while read -r l; do log "$l"; done || true
  rm -rf "$work/tree"
  log "built $(basename "$DRIVER_DEB")"
}

# ------------------------------------------------------------------------ 5. install

install_debs() {
  # iwd first: libell0 0.83 declares Breaks: iwd (<< 2.20), which Ubuntu 22.04's iwd is.
  # --force-confold keeps any configuration file the image already has. See D5.
  local m f
  dpkg_i() { DEBIAN_FRONTEND=noninteractive dpkg -i --force-confdef --force-confold "$@" < /dev/null; }
  dpkg_i "$IWD_DEB" "$ELL_DEB"
  dpkg_i "$DRIVER_DEB"
  for m in compat cfg80211 mac80211 iwlwifi iwlmvm; do
    f=$(modinfo -F filename "$m" 2>/dev/null || true)
    [[ $f == /lib/modules/$KVER/updates/iwlwifi-backport/* ]] || die "$m resolves to '$f', not the new driver"
  done
  log "installed iwd $(pkg_version iwd), libell0 $(pkg_version libell0), $DRIVER_PKG $(pkg_version "$DRIVER_PKG")"
}

# ------------------------------------------------------------------------ 6. configure

# network_file <file name> <[Match] line> <route metric>: a systemd-networkd DHCP link
network_file() {
  write "/etc/systemd/network/$1" <<EOF
# Written by orin-iwlwifi install.sh
[Match]
$2

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
# Same client ID as NetworkManager used, so the DHCP server hands out the same address.
ClientIdentifier=mac
UseDomains=yes
RouteMetric=$3

[IPv6AcceptRA]
UseDomains=yes
RouteMetric=$3
EOF
}

configure() {
  WIFI_METRIC=${WIFI_METRIC:-$(current_wifi_metric)}
  write /etc/iwd/main.conf <<EOF
# Written by orin-iwlwifi install.sh. See iwd.config(5).
[General]
# iwd sets up wlan0's addresses (DHCP, IPv6) and routes itself, so a roam keeps the address
# instead of waiting for DHCP again (see D21). systemd-networkd leaves wlan0 alone.
EnableNetworkConfiguration=true
AddressRandomization=disabled
# 1 = use protected management frames when the AP offers them. 0 would make iwd skip 6 GHz.
ManagementFrameProtection=1

# Roaming (see D15). RoamThreshold is for 2.4 GHz; RoamThreshold5G covers 5 GHz and 6 GHz.
# Below the threshold, iwd waits 5 s and then scans for a better access point. Tune these
# against walk-test data.
RoamThreshold=-70
RoamThreshold5G=-70
# Seconds before trying again after a failed roam, or one that landed on a weak AP (default 60).
RoamRetryInterval=30
# Don't reuse cached keys (PMKSA): iwd 3.12 can apply an out-of-date one to a Fast Transition,
# and the access point then refuses the roam (see D19).
DisablePMKSA=true

[Network]
# DNS servers and the domain name go to systemd-resolved.
NameResolvingService=systemd
# The metric of wlan0's routes (iwd adds the interface index, e.g. 604): above ethernet's, so
# the wired link is preferred when both are up.
RoutePriorityOffset=${WIFI_METRIC:-600}
# Send the board's hostname in DHCP requests, on every network (patches/iwd/0001, D21).
SendHostname=true

[Scan]
# While disconnected, rescan at least every 10 s (the default backs off to 5 minutes).
MaximumPeriodicScanInterval=10

[Blacklist]
# 0 = never set an access point aside after a failed connect (see D17). The default puts it on
# a 60 s blacklist, which turns one lost authentication into a minute or more offline.
InitialTimeout=0

[DriverQuirks]
# Keep the kernel's wlan0 instead of recreating it.
DefaultInterface=*
# Keep Wi-Fi power save off (so do the udev rule and the iwlmvm option below).
PowerSaveDisable=iwlwifi
EOF

  # Wi-Fi power save off, at every level: steady latency, no doze and wake-up delays (see D22).
  write /etc/udev/rules.d/80-orin-iwlwifi-powersave-off.rules <<'EOF'
# Written by orin-iwlwifi install.sh: Wi-Fi power save off.
ACTION=="add", SUBSYSTEM=="net", ENV{DEVTYPE}=="wlan", RUN+="/usr/sbin/iw dev $name set power_save off"
EOF
  {
    echo '# Written by orin-iwlwifi install.sh. 1 = active: the AX210 firmware never enters power save.'
    echo 'options iwlmvm power_scheme=1'
    if [[ -n $COUNTRY ]]; then
      echo '# Regulatory country, from --country (see D16).'
      echo "options iwlmvm country=$COUNTRY"
    fi
  } | write /etc/modprobe.d/orin-iwlwifi.conf
  [[ -z $COUNTRY ]] || log "Wi-Fi regulatory country set to $COUNTRY"

  # systemd-networkd takes over ethernet at the reboot. The file must exist before
  # NetworkManager is masked below, or the board comes back with no wired network. See D6.
  local eth_file=/etc/systemd/network/10-$ETH_IFACE.network
  ETH_METRIC=${ETH_METRIC:-$(current_metric "$eth_file")}
  network_file "${eth_file##*/}" "Name=$ETH_IFACE" "${ETH_METRIC:-100}"
  # iwd configures Wi-Fi; networkd must not also run DHCP on it (see D21).
  write /etc/systemd/network/25-wlan.network <<'EOF'
# Written by orin-iwlwifi install.sh. iwd sets up Wi-Fi addresses and routes (see D21).
[Match]
Type=wlan

[Link]
Unmanaged=yes
EOF

  # The stock wait-online waits for every link networkd manages, so a board with its ethernet
  # unplugged would hold up boot for 2 minutes. Instead: online as soon as there's an IPv4
  # default route, on any link (see D22).
  write /etc/systemd/system/systemd-networkd-wait-online.service.d/orin-iwlwifi.conf <<'EOF'
# Written by orin-iwlwifi install.sh
[Service]
ExecStart=
ExecStart=/usr/bin/timeout 60 /bin/sh -c 'until ip -4 route show default | grep -q .; do sleep 1; done'
EOF

  # iwd (Wi-Fi) and systemd-networkd (ethernet) hand DNS servers to systemd-resolved; point
  # resolv.conf at its stub.
  ln -sfn ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  log "/etc/resolv.conf -> systemd-resolved"

  local f
  # Profiles added earlier stay; one given again with the same name replaces the old one.
  for f in "${PSK_FILES[@]}"; do
    install -d -m 700 /var/lib/iwd
    install -m 600 -o root -g root "$f" "/var/lib/iwd/$(basename "$f")"
    log "added Wi-Fi network '$(profile_ssid "$f")' (/var/lib/iwd/$(basename "$f"))"
  done

  # From the next boot: iwd (Wi-Fi) + systemd-networkd (ethernet) + systemd-resolved, no NetworkManager.
  systemctl disable --quiet NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
  systemctl mask --quiet NetworkManager.service wpa_supplicant.service
  systemctl enable --quiet iwd.service systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service systemd-resolved.service
  log "from the next boot: iwd, systemd-networkd, systemd-resolved; NetworkManager and wpa_supplicant masked"
}

# ------------------------------------------------------------------------ 7. record

record() {
  # If a board ever loses Wi-Fi, compare this with the running kernel first.
  write "$STATE/installed" <<EOF
release=$RELEASE
date=$(date -Is)
iwd=$(pkg_version iwd)
libell0=$(pkg_version libell0)
$DRIVER_PKG=$(pkg_version "$DRIVER_PKG")
country=${COUNTRY:-none}
nvidia-l4t-kernel=$(pkg_version nvidia-l4t-kernel)
nvidia-l4t-kernel-headers=$(pkg_version nvidia-l4t-kernel-headers)
kernel_config_sha256=$(zcat /proc/config.gz | sha256sum | cut -d' ' -f1)
proc_version=$(sed 's/ *$//' /proc/version)
EOF
}

# ------------------------------------------------------------------------ main

FROM='' PSK_FILES=() COUNTRY='' LATEST=0 CHECK_ONLY=0
while (( $# )); do
  case $1 in
    --latest)   LATEST=1 ;;
    --release)  RELEASE=${2:?--release needs a tag}; shift ;;
    --from)     FROM=$(readlink -f "${2:?--from needs a directory}"); shift ;;
    --psk-file) PSK_FILES+=("$(readlink -f "${2:?--psk-file needs a file}")"); shift ;;
    --country)  COUNTRY=${2:?--country needs a country code, e.g. US}; COUNTRY=${COUNTRY^^}; shift ;;
    --check)    CHECK_ONLY=1 ;;
    -h|--help)  sed -n '4,/^set /{/^set /d; s/^# \{0,1\}//; p}' "$0"; exit 0 ;;
    *)          die "unknown option $1 (see --help)" ;;
  esac
  shift
done

[[ -n $COUNTRY ]] || COUNTRY=$(current_country)   # keep the board's, unless given
check
[[ $COUNTRY != NONE ]] || COUNTRY=''
if (( CHECK_ONLY )); then log "ready to install; nothing was changed"; exit 0; fi
resolve_release
mkdir -p "$STATE"
exec > >(tee -a "$STATE/install.log") 2>&1
log "installing orin-iwlwifi $RELEASE${FROM:+ from $FROM}"
if [[ -e $STATE/installed ]]; then
  log "installing over $(sed -n 's/^release=//p' "$STATE/installed") (installed $(sed -n 's/^date=//p' "$STATE/installed"));" \
      "keeping country ${COUNTRY:-none}"
fi

hold_l4t
download
build_driver
install_debs
configure
record
log "done. Reboot to switch over: sudo reboot"
log "then check: iwctl station wlan0 show; networkctl; dmesg | grep iwlwifi"
