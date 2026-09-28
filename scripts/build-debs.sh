#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the libell0 and iwd debs for Ubuntu 22.04 arm64 from the upstream releases and Debian
# packaging pinned in versions.json. Runs as root inside the container pinned there (it installs
# build dependencies, then builds as an unprivileged user); CI runs it the same way:
#
#   docker run --rm --security-opt seccomp=unconfined -v "$PWD:/src" -w /src \
#     "$(jq -r .l4t.container versions.json)" scripts/build-debs.sh [OUTDIR]
#
# seccomp=unconfined: Docker's default seccomp profile blocks AF_ALG sockets, so ell's and iwd's
# kernel-crypto unit tests would all be skipped instead of run. See docs/DECISIONS.md D5.
#
# Output (default dist/): libell0, libell-dev and iwd debs, and for ell and iwd the source
# package (.dsc, .orig.tar.xz, .debian.tar.xz) with kernel.org's .tar.sign for the tarball.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
umask 022

TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$TOP/dist}
WORK=$TOP/build/debs
die() { echo "build-debs.sh: $*" >&2; exit 1; }

apt-get update -qq
apt-get install -qq -y --no-install-recommends ca-certificates curl gnupg jq xz-utils dpkg-dev fakeroot > /dev/null
j() { jq -er "$1" "$TOP/versions.json"; }
REVISION=$(j .deb.revision)
MAINTAINER=$(j .deb.maintainer)

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
export GNUPGHOME=$WORK/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg -q --import "$TOP/keys/ell-iwd-signing-key.asc"

# fetch <ell|iwd>: the upstream tarball, signature checked, with Debian's debian/ added, in
# $WORK/<name>-<version>/. Sets DIR to that directory.
fetch() {
  local name=$1 v url repo commit want
  v=$(j ".$name.tag") url=$(j ".$name.tarball") url=${url//\{v\}/$v}
  repo=$(j ".$name.debian.repo") commit=$(j ".$name.debian.commit") want=$(j ".$name.debian.version")
  cd "$WORK"
  curl -fsSL --retry 3 -o "${name}_$v.orig.tar.xz" "$url"
  curl -fsSL --retry 3 -o "$name-$v.tar.sign" "${url%.xz}.sign"
  # kernel.org signs the uncompressed tarball. Look for GOODSIG, not gpg's exit code: gpg also
  # exits 0 when the key has expired or been revoked.
  xz -cd "${name}_$v.orig.tar.xz" | gpg --batch --status-fd 1 --verify "$name-$v.tar.sign" - 2> /dev/null \
    | grep -q '^\[GNUPG:\] GOODSIG ' || die "$name $v: signature doesn't check out against keys/"
  tar -xJf "${name}_$v.orig.tar.xz"
  DIR=$WORK/$name-$v
  # salsa.debian.org (GitLab) serves the debian/ directory of any commit as an archive.
  curl -fsSL --retry 3 "${repo%.git}/-/archive/$commit/$name-$commit.tar.gz?path=debian" \
    | tar -xz -C "$DIR" --strip-components=1
  [[ $(dpkg-parsechangelog -l "$DIR/debian/changelog" -S Version) == "$want" ]] \
    || die "$name packaging at $commit isn't version $want (versions.json)"
}

# rebrand <dir> <changelog line>...: our Maintainer (without Debian's Uploaders), and a
# changelog entry for our version: Debian's + deb.revision.
rebrand() {
  local dir=$1 src ver line; shift
  src=$(dpkg-parsechangelog -l "$dir/debian/changelog" -S Source)
  ver=$(dpkg-parsechangelog -l "$dir/debian/changelog" -S Version)$REVISION
  sed -i -e "s|^Maintainer:.*|Maintainer: $MAINTAINER|" -e '/^Uploaders:/,/^[^ ]/{/^Uploaders:/d;/^ /d}' \
    "$dir/debian/control"
  { echo "$src ($ver) jammy; urgency=medium"; echo
    for line; do echo "  * $line"; done
    echo; echo " -- $MAINTAINER  $(date -R)"; echo
    cat "$dir/debian/changelog"; } > "$dir/debian/changelog.new"
  mv "$dir/debian/changelog.new" "$dir/debian/changelog"
}

# build <dir>: install its build dependencies (as root), then build source + binary packages and
# run the unit tests as an unprivileged user, as Debian does. As root, ell's test-sysctl would
# try to write /proc/sys, which is read-only in a container.
build() {
  local log=$1.log
  apt-get build-dep -qq -y "$1" > /dev/null
  id builder > /dev/null 2>&1 || useradd --system --home-dir "$WORK" builder
  chown -R builder: "$WORK"
  (cd "$1" && runuser -u builder -- env HOME="$WORK" dpkg-buildpackage -us -uc) > "$log" 2>&1 \
    || { tail -40 "$log" >&2; die "build failed, see $log"; }
  grep -E '^# (TOTAL|PASS|SKIP|XFAIL|FAIL|ERROR):' "$log" || true
}

# --- ell --------------------------------------------------------------------------------------
fetch ell
ELL_DIR=$DIR ELL_V=$(j .ell.tag)
rebrand "$ELL_DIR" "Rebuild for Ubuntu 22.04 (Jetson Linux 36) by https://github.com/dapalab/orin-iwlwifi"
build "$ELL_DIR"
ELL_VER=$(dpkg-parsechangelog -l "$ELL_DIR/debian/changelog" -S Version)
# iwd builds against the ell we just built, not Ubuntu's 0.49.
apt-get install -qq -y "$WORK/libell0_${ELL_VER}_arm64.deb" "$WORK/libell-dev_${ELL_VER}_arm64.deb" > /dev/null

# --- iwd --------------------------------------------------------------------------------------
fetch iwd
IWD_DIR=$DIR
# Ubuntu 22.04 has no systemd-dev: systemd.pc is in systemd.
sed -i 's/^ systemd-dev,$/ systemd,/' "$IWD_DIR/debian/control"
# Units under /lib/systemd, where 22.04's own iwd put them, so upgrading from it moves no files.
sed -i 's|^usr/lib/systemd/|lib/systemd/|' "$IWD_DIR/debian/iwd.install"
# Depend on the ell we build and test with, not the older minimum Debian's symbols file allows.
# The first ${shlibs:Depends} in debian/control is the iwd package's.
sed -i "0,/^ \${shlibs:Depends},\$/s//&\n libell0 (>= $ELL_V),/" "$IWD_DIR/debian/control"
grep -q "^ libell0 (>= $ELL_V),$" "$IWD_DIR/debian/control" || die "couldn't add the libell0 dependency"
rebrand "$IWD_DIR" "Rebuild for Ubuntu 22.04 (Jetson Linux 36) by https://github.com/dapalab/orin-iwlwifi" \
  "systemd units under /lib/systemd; build-depends on systemd, not systemd-dev." \
  "Depends on libell0 (>= $ELL_V), the ell it is built and tested with."
build "$IWD_DIR"

# --- output -----------------------------------------------------------------------------------
cd "$WORK"
cp libell0_*.deb libell-dev_*.deb iwd_*.deb ./*.dsc ./*.orig.tar.xz ./*.debian.tar.xz ./*.tar.sign "$OUT/"
chown -R --reference="$TOP" "$TOP/build" "$OUT"
ls -l "$OUT"
