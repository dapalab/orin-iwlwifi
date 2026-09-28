#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Test-compile the driver from driver-src.tar.gz against one of the NVIDIA L4T kernel headers
# packages listed in versions.json (l4t.headers), with the same build-driver.sh install.sh runs
# on a board, minus the checks that need a running kernel. CI runs it for every listed version,
# on a native arm64 runner (the headers ship prebuilt arm64 build tools), in the build container:
#
#   docker run --rm -v "$PWD:/src" -w /src "$(jq -r .l4t.container versions.json)" \
#     scripts/test-driver-build.sh HEADERS_VERSION [driver-src.tar.gz]
#
# HEADERS_VERSION is a l4t.headers[].version, e.g. 5.15.148-tegra-36.4.7-20250918154033.
# driver-src.tar.gz defaults to dist/driver-src.tar.gz (scripts/make-driver-src.sh).
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
umask 022

TOP=$(cd "$(dirname "$0")/.." && pwd)
VER=${1:?usage: test-driver-build.sh HEADERS_VERSION [driver-src.tar.gz]}
TARBALL=$(readlink -f "${2:-$TOP/dist/driver-src.tar.gz}")
WORK=$TOP/build/driver-test/$VER
die() { echo "test-driver-build.sh: $*" >&2; exit 1; }

apt-get update -qq
apt-get install -qq -y --no-install-recommends ca-certificates curl jq build-essential bc flex bison \
  kmod > /dev/null
SHA=$(jq -er --arg v "$VER" '.l4t.headers[] | select(.version == $v) | .sha256' "$TOP/versions.json") \
  || die "$VER isn't listed in versions.json l4t.headers"
REPO=$(jq -er .l4t.repo "$TOP/versions.json")

rm -rf "$WORK"
mkdir -p "$WORK"
DEB=nvidia-l4t-kernel-headers_${VER}_arm64.deb
curl -fsSL --retry 3 -o "$WORK/$DEB" "$REPO/pool/main/n/nvidia-l4t-kernel-headers/$DEB"
echo "$SHA  $WORK/$DEB" | sha256sum --check --quiet || die "$DEB doesn't match its sha256 in versions.json"
dpkg-deb -x "$WORK/$DEB" "$WORK/headers"
KSRC=$(find "$WORK/headers/usr/src" -type d -name kernel-source -print -quit)
[[ -n $KSRC ]] || die "no kernel-source tree in $DEB"

tar -xzf "$TARBALL" -C "$WORK"
# No board, so nothing to fingerprint: the package is built to prove the driver compiles and
# links against these headers, and is never installed.
echo "CI test build: nvidia-l4t-kernel-headers $VER" > "$WORK/proc-version"
DEB_OUT=$("$WORK/driver-src/build-driver.sh" --src "$WORK/driver-src" --headers "$KSRC" \
  --config "$KSRC/.config" --proc-versions "$WORK/proc-version" \
  --target "L4T ${VER#*-tegra-}" --desc "NVIDIA stock L4T ${VER#*-tegra-} kernel (CI test build)" \
  --hdr-info "nvidia-l4t-kernel-headers $VER" --out "$WORK/out" --work "$WORK/tree" | tail -1)
echo "built $(basename "$DEB_OUT") against nvidia-l4t-kernel-headers $VER"
rm -rf "$WORK/tree" "$WORK/headers"
chown -R --reference="$TOP" "$TOP/build"
