#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Put a release's assets together, as the release workflow uploads them:
#
#   scripts/assemble-release.sh TAG [DIR]      (default DIR: dist/release/)
#
# Takes the output of build-debs.sh and make-driver-src.sh from dist/, adds install.sh with
# the release tag filled in, and writes SHA256SUMS. On a board, `install.sh --from DIR` installs
# from such a directory without downloading anything.
set -euo pipefail
export LC_ALL=C
umask 022

TOP=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: assemble-release.sh TAG [DIR]}
REL=${2:-$TOP/dist/release}
[[ $TAG =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+(-[a-z0-9]+)?$ ]] || { echo "tag must look like 2026.09.28-1 (or 2026.09.28-1-label for a pre-release)" >&2; exit 2; }

rm -rf "$REL"
mkdir -p "$REL"
cd "$TOP/dist"
# The debs boards install, their source packages (the licence asks us to offer the source
# alongside), and the driver source.
cp libell0_*_arm64.deb iwd_*_arm64.deb ./*.dsc ./*.orig.tar.xz ./*.debian.tar.xz ./*.tar.sign \
  driver-src.tar.gz "$REL/"
sed "s/^RELEASE=@RELEASE@ /RELEASE=$TAG /" "$TOP/install.sh" > "$REL/install.sh"
grep -q "^RELEASE=$TAG " "$REL/install.sh" || { echo "couldn't set RELEASE in install.sh" >&2; exit 1; }
cd "$REL"
sha256sum -- * > SHA256SUMS.tmp
mv SHA256SUMS.tmp SHA256SUMS
ls -l "$REL"
