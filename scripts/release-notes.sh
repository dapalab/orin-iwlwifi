#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Print the release notes (Markdown) for a release built from versions.json:
#
#   scripts/release-notes.sh TAG [OWNER/REPO]      (default repo: dapalab/orin-iwlwifi)
set -euo pipefail
export LC_ALL=C

TOP=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: release-notes.sh TAG [OWNER/REPO]}
REPO=${2:-dapalab/orin-iwlwifi}
j() { jq -er "$1" "$TOP/versions.json"; }
REV=$(j .deb.revision)
HEADERS=$(jq -r '[.l4t.headers[].version | sub("^.*-tegra-"; "") | sub("-[0-9]+$"; "")] | join(", ")' \
  "$TOP/versions.json")

cat <<EOF
## Install

On a freshly imaged Jetson Orin (Jetson Linux 36.x) with an Intel AX210, connected by ethernet:

\`\`\`bash
curl -fsSLO https://github.com/$REPO/releases/download/$TAG/install.sh
less install.sh
sudo bash install.sh
sudo reboot
\`\`\`

Add \`--psk-file <SSID>.psk\` to also add a Wi-Fi network (an iwd profile; see the README).

## What's in it

| Component | Version | From |
|---|---|---|
| iwd | $(j .iwd.tag) (deb \`$(j .iwd.debian.version)$REV\`) | kernel.org release tarball, signature checked; Debian packaging \`$(j .iwd.debian.commit | cut -c1-12)\` |
| ell | $(j .ell.tag) (deb \`$(j .ell.debian.version)$REV\`) | kernel.org release tarball, signature checked; Debian packaging \`$(j .ell.debian.commit | cut -c1-12)\` |
| iwlwifi backport | \`$(j .backport.branch)\` at \`$(j .backport.commit | cut -c1-12)\` ($(j .backport.date)) | built on the board by \`install.sh\` |
| AX210 firmware | $(j .firmware.release): $(jq -r '[.firmware.files[] | sub("^.*/"; "")] | join(", ")' "$TOP/versions.json") | linux-firmware \`$(j .firmware.commit | cut -c1-12)\` |

The driver was test-compiled in CI against NVIDIA's kernel headers for Jetson Linux $HEADERS.

## Verify

Every file was built by this repository's release workflow, which signed a build attestation for it:

\`\`\`bash
sha256sum --check SHA256SUMS
gh attestation verify <file> --repo $REPO
\`\`\`
EOF
