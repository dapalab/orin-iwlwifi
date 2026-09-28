#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Assemble driver-src.tar.gz, the release asset install.sh builds the driver from on the board:
#
#   driver-src/
#     build-driver.sh      the build script (driver/build-driver.sh)
#     meta.env             the pins it builds, from versions.json
#     backport.tar.gz      backport-iwlwifi at the pinned commit
#     patches/             our patches (patches/backport-iwlwifi/)
#     firmware/            the AX210 firmware files at the pinned linux-firmware commit, + licence
#     SHA256SUMS           checked by build-driver.sh before it builds
#
#   scripts/make-driver-src.sh [OUTDIR]     (default: dist/)
set -euo pipefail
export LC_ALL=C
umask 022

TOP=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$TOP/dist}
j() { jq -er "$1" "$TOP/versions.json"; }

BP_URL=$(j .backport.repo)      BP_BRANCH=$(j .backport.branch)
BP_SHA=$(j .backport.commit)    BP_DATE=$(j .backport.date)
FW_URL=$(j .firmware.repo)      FW_SHA=$(j .firmware.commit)
FW_RELEASE=$(j .firmware.release) FW_LICENCE=$(j .firmware.licence)
mapfile -t FW_PATHS < <(j '.firmware.files[]')
DEB_REVISION=$(j .deb.revision) MAINTAINER=$(j .deb.maintainer)

STAGE=$TOP/build/driver-src
rm -rf "$STAGE"
mkdir -p "$STAGE/patches" "$STAGE/firmware" "$OUT"

# kernel.org's cgit serves any commit as a tarball (snapshot/) or one file of it (plain/?id=),
# so there's nothing to clone. The commit is in the URL; SHA256SUMS records what we got.
curl -fsSL --retry 3 -o "$STAGE/backport.tar.gz" "$BP_URL/snapshot/backport-iwlwifi-$BP_SHA.tar.gz"
tar -tzf "$STAGE/backport.tar.gz" | sed -n 1p | grep -qx "backport-iwlwifi-$BP_SHA/" \
  || { echo "backport snapshot is not commit $BP_SHA" >&2; exit 1; }
for f in "${FW_PATHS[@]}" "$FW_LICENCE"; do
  curl -fsSL --retry 3 -o "$STAGE/firmware/${f##*/}" "$FW_URL/plain/$f?id=$FW_SHA"
done

install -m 755 "$TOP/driver/build-driver.sh" "$STAGE/"
install -m 644 "$TOP"/patches/backport-iwlwifi/*.patch "$STAGE/patches/"
cat > "$STAGE/meta.env" <<EOF
# Pinned sources this directory was assembled from (versions.json)
BP_URL=$BP_URL
BP_BRANCH=$BP_BRANCH
BP_SHA=$BP_SHA
BP_DATE=$BP_DATE
FW_URL=$FW_URL
FW_SHA=$FW_SHA
FW_RELEASE=$FW_RELEASE
FW_FILES="${FW_PATHS[*]##*/}"
DEB_REVISION=$DEB_REVISION
MAINTAINER="$MAINTAINER"
EOF
(cd "$STAGE" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)

# Same inputs, same tarball: fixed order, owner and timestamps.
tar -C "$TOP/build" --sort=name --owner=0 --group=0 --numeric-owner --mtime="$BP_DATE" \
  -cf - driver-src | gzip -9n > "$OUT/driver-src.tar.gz"
echo "$OUT/driver-src.tar.gz"
