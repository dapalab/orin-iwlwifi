# Behind the scenes

This is the project's notebook: every significant design decision, why it was made, what else was
considered, and what we measured along the way. It's written for anyone curious about how the
stack is put together, and for future maintainers wondering "why is it done like this?"

When an earlier decision turns out to be wrong, or right for the wrong reason, we leave the
original reasoning in place and add an **amendment** underneath, so the history stays honest.

Upstream facts were checked on **2026-09-27** unless an entry says otherwise.

## Contents

| | |
|---|---|
| [D1](#d1--build-the-driver-on-the-board) | Build the driver on the board |
| [D2](#d2--no-dkms) | No DKMS |
| [D3](#d3--hold-every-nvidia-l4t--package) | Hold every `nvidia-l4t-*` package |
| [D4](#d4--kernel-headers-from-nvidias-package-at-the-exact-installed-version) | Kernel headers from NVIDIA's package, at the exact installed version |
| [D5](#d5--prebuilt-ell-and-iwd-debs-from-debians-packaging) | Prebuilt ell and iwd debs, from Debian's packaging |
| [D6](#d6--fresh-images-only-installed-over-ethernet) | Fresh images only, installed over ethernet |
| [D7](#d7--network-setup-is-optional) | Network setup is optional |
| [D8](#d8--new-backport-branches-are-reviewed-never-automerged) | New backport branches are reviewed, never automerged |
| [D9](#d9--two-patches-to-backport-iwlwifi) | Two patches to backport-iwlwifi |
| [D10](#d10--versionsjson-is-the-single-source-of-truth) | `versions.json` is the single source of truth |
| [D11](#d11--licence-gpl-20-only) | Licence: GPL-2.0-only |
| [D12](#d12--names-orin-iwlwifi-everywhere) | Names: `orin-iwlwifi` everywhere |
| [D13](#d13--the-driver-ships-its-own-firmware) | The driver ships its own firmware |
| [D14](#d14--releases-one-workflow-run-dated-tags-attested) | Releases: one workflow run, dated tags, attested |

---

## D1 — Build the driver on the board

**Decision.** Releases ship the driver as source (`driver-src.tar.gz`). `install.sh` compiles it
on the board, against the kernel the board is running, and packages it as a local deb.

**Why.** A kernel module only loads on the exact kernel build it was compiled against, and every
L4T 36 kernel reports `uname -r` = `5.15.148-tegra`: NVIDIA's stock kernel of any 36.x release,
and any custom build of it. So there's nothing a prebuilt module deb could be matched against.
Building on the board uses the running kernel's own `/proc/config.gz`, which always matches.

**The safety check.** Before anything is installed, `build-driver.sh --check-running` compares
the symbol CRCs the new modules import with:

1. the `Module.symvers` of the headers tree it was built against, and
2. the CRCs the running kernel's own in-tree modules were linked against. The running kernel
   doesn't expose its CRCs directly, but every in-tree module records the ones it imports.

Any mismatch stops the install before anything on the board has changed. On NVIDIA's stock
36.4.7 kernel (measured 2026-09-28) the backport imports 502 kernel symbols; the in-tree modules
cover 483 of them. The other 19 (e.g. `timer_shutdown`, `pci_reset_function`) are checked only
against the headers' `Module.symvers`. A build takes about 2 minutes on an Orin Nano.

**Considered: prebuilt driver debs, one per known kernel**, each with a fingerprint
(`/proc/version` + config hash) checked in the package's `preinst`. It works, but every kernel
rebuild anywhere would need a new deb from us first. Building on the board has no such list to
maintain.

---

## D2 — No DKMS

**Decision.** Don't use DKMS to rebuild the driver when the kernel changes.

**Why.**

- DKMS rebuilds when it sees a new `uname -r`. Every L4T 36 kernel is `5.15.148-tegra`, so a
  kernel swap looks like no change at all, and DKMS would keep the old modules.
- DKMS builds against `/lib/modules/<kver>/build`. On images with a custom kernel, that link
  often points into the machine the kernel was built on, and dangles on the board.
- It isn't needed. A new kernel always arrives as a full re-image (D6), and `install.sh` runs
  again on the fresh image. The one other way the kernel can change, `apt upgrade`, is blocked
  by D3.

---

## D3 — Hold every `nvidia-l4t-*` package

**Decision.** Before it runs any apt command, `install.sh` runs:

```bash
apt-mark hold $(dpkg-query -W -f='${Package}\n' 'nvidia-l4t-*')
```

**Why.** L4T (kernel, boot chain, GPU and multimedia userspace) comes from the image and must stay
a matched set, and it's easy to break. `apt install nvidia-l4t-kernel-headers` without a
version picks the newest headers (36.4.7 at the time of writing), which
`Depends: nvidia-l4t-kernel (= <same version>)`. So apt also upgrades the kernel, OOT modules,
DTBs, display kernel, initrd, bootloader, tools, configs and xusb firmware to NVIDIA's newest
stock release. On a board running a custom kernel, that kernel and everything built into it are
gone, and the board has to be re-imaged.

With the hold in place, the same command fails with "held packages" and changes nothing.

**Why all of them, not just the kernel.** The upgrade above came in through the headers
package's dependency on the kernel. Holding only `nvidia-l4t-kernel` would still let apt move
other parts of the set out of step with it.

**Undo:** `apt-mark unhold <pkg>`. Upgrading L4T is a re-image, not an apt operation.

---

## D4 — Kernel headers from NVIDIA's package, at the exact installed version

**Decision.** The driver is built against NVIDIA's `nvidia-l4t-kernel-headers` tree, found via
`dpkg -L` rather than `/lib/modules/<kver>/build`. If the package is missing, `install.sh` says
how to install it at the **exact** version of the installed `nvidia-l4t-kernel`, never the
newest.

**Why.** `/lib/modules/<kver>/build` can dangle (D2). An unversioned install pulls the newest
headers, and with them a new kernel (D3). A custom kernel built from the same L4T release shares
the headers package's `Module.symvers`; the CRC check (D1) catches the case where it doesn't.

CI test-compiles the driver against the headers of every L4T release listed in
`versions.json`, so an upstream change that breaks the build shows up there, not on a board.

---

## D5 — Prebuilt ell and iwd debs, from Debian's packaging

**Decision.** CI builds `libell0` and `iwd` debs from the pinned upstream release, using Debian's
own packaging (salsa.debian.org, pinned by commit), in an Ubuntu 22.04 container (pinned by
digest) on a native arm64 runner. Releases ship them ready to install, next to their source
packages (D11).

**Sources are checked, not just downloaded.** ell and iwd come from kernel.org's release
tarballs, verified against kernel.org's detached `.tar.sign` (made over the uncompressed tar).
The keyring holds only `keys/ell-iwd-signing-key.asc`: Marcel Holtmann's key
(`E932 D120 BC2A EC44 4E55 8F01 06CA 9F5D 1DCF 2659`), which signed both 0.83 and 3.12, copied
from kernel.org's own key repository (`pgpkeys.git`). The check looks for gpg's `GOODSIG`
status rather than its exit code, because gpg exits 0 for an expired or revoked key too (the
same lesson as kea-containers' D2). A release signed by a different key fails the build until
someone reviews and adds that key.

Release tarballs rather than git tags, because the tarballs bundle the two private ell headers
iwd needs (`useful.h`, `asn1-private.h`) and they are what Debian's packaging expects. The
tarball's `ell/` sources are identical to the tag's commit (checked for 0.83).

**Why.** Ubuntu 22.04 ships iwd 1.26 and ell 0.49. Unlike the driver, userspace doesn't depend
on the kernel build, so there's no reason to compile it on each board.

**Changes to Debian's packaging, and why:**

- `systemd` instead of `systemd-dev` in `Build-Depends`: 22.04 has no `systemd-dev`; `systemd.pc`
  is in `systemd`.
- Units installed under `/lib/systemd`, where 22.04's own iwd put them, so upgrading from it
  moves no files.
- `iwd` depends on `libell0 (>= <the ell we built>)`, instead of the looser minimum Debian's
  symbols file computes: we only test iwd with the ell we built it against.

**The unit tests must really run in the container.** ell and iwd run their unit tests during
the package build. The first container build (2026-09-28) looked healthy but wasn't:

| | Native, on the Orin | Container, default settings |
|---|---|---|
| ell tests skipped | 62 lines | 186 lines |
| ell tests failed | 0 | 1 (`test-sysctl`) |

- The extra skips were every kernel-crypto test (checksums, ciphers, PBKDF2, UUIDs). They use
  `AF_ALG` sockets, and Docker's default seccomp profile blocks those. Under
  `--security-opt seccomp=unconfined`, `test-checksum` goes from 87 skipped tests to 1, the same
  as native. The container is ephemeral and runs only the pinned, signature-checked sources, so
  we accept the wider syscall surface over skipping the crypto tests iwd depends on.
- `test-sysctl` treats "permission denied" as "not root, fine", but as root in a container it
  gets "read-only file system" from `/proc/sys`. So the build now installs build dependencies
  as root and then builds and tests as an unprivileged user, which is how Debian builds anyway
  (`Rules-Requires-Root: no`).

A skipped test looks like a passed one in a summary line, so compare skip counts, not just
failures, whenever the build environment changes.

**Install order.** iwd first, then libell0: `libell0 0.83` declares `Breaks: iwd (<< 2.20)`,
so installing it while 22.04's iwd 1.26 is still there fails.

---

## D6 — Fresh images only, installed over ethernet

**Decision.** `install.sh` is for freshly imaged boards, connected by ethernet with internet
access. It doesn't migrate an existing install, run detached, or roll itself back.

**Why.** Boards are treated as stateless: a new kernel or L4T release means re-imaging the board
and running `install.sh` again. Over ethernet, a failed install can't cut the board off, so
`install.sh` needs none of the commit-and-rollback machinery an upgrade over the board's own
Wi-Fi would. Leaving that out is most of why `install.sh` can be short enough to read.

**One ordering rule that matters.** On a fresh image NetworkManager owns ethernet.
`install.sh` writes a systemd-networkd `.network` file for ethernet **before** it masks
NetworkManager, or the board comes back from the reboot with no wired network.

---

## D7 — Network setup is optional

**Decision.** Without options, `install.sh` adds no Wi-Fi network. With `--psk-file
<SSID>.psk` (repeatable), it copies that iwd profile into `/var/lib/iwd/` unchanged, root-owned,
mode 600. It checks only that the file is named `*.psk`, has a `Passphrase=` or
`PreSharedKey=` line and no Windows line endings.

**Why.** Many images already carry their own iwd profiles. A profile doesn't depend on the board,
so one file per network can go to every board, with nothing to configure per unit.
The file is iwd's own format, so it can carry everything iwd supports, such as the cached WPA3
`SAE-PT-Group19`/`SAE-PT-Group20` values used on 6 GHz. The file name is the SSID (iwd writes
`=` + hex for SSIDs with special characters), so there is no separate `--ssid` option to get
out of step with it. Secrets stay in the file, never on the command line, so they don't show up
in `ps` output or shell history.

**Amendment (2026-09-28).** The first version took `--ssid <name> --psk-file <file>`, with just
the passphrase in the file, and wrote the profile itself. Replaced because a complete iwd profile
is easier to hand out and can carry more than a passphrase.

---

## D8 — New backport branches are reviewed, never automerged

**Decision.** Renovate and `upstream-watch` open a PR (or an issue) for every new commit on the
tracked backport branch, every new `release/core*` branch and its firmware, every new ell or iwd
release, and every new L4T 36.x release. None of these are merged automatically.

**Why.** A board whose only network is the Wi-Fi this stack provides goes offline if an update
breaks it. Every bump gets a human look and a test on real hardware.

**Something to expect.** The newest backport branch isn't the one with the highest number:
`release/core24.70` (2026-09) is newer than `release/core105` (2026-05). The watcher goes by
commit date, not by name.

---

## D9 — Two patches to backport-iwlwifi

**Decision.** Keep our changes to the backport driver as two small patches in
`patches/backport-iwlwifi/`, applied at build time. Each has a header saying what it changes and
why.

- `0001-l4t-jammy-timer-apis.patch`: L4T 36 kernels report 5.15.148 but already export the newer
  timer APIs (`timer_shutdown()`, `timer_delete()` and friends). The backport only expects them
  from 5.15.154 or later and defines its own, and the build fails. The patch removes those four
  shims.
- `0002-iwlwifi-dbg-cfg-no-sysfs-fallback.patch`: L4T kernels set
  `CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y`, and the backport requests an optional debug file
  during probe. At boot, that request waited the full 60 s fallback timeout, so Wi-Fi came up a
  minute late. The patch uses `request_firmware_direct()`, which never falls back; firmware
  now loads about 40 ms after the module.

**Considered: carrying a forked backport tree.** Two patches are easier to review, and easy to
re-check against every new backport commit: if one stops applying, CI fails.

---

## D10 — `versions.json` is the single source of truth

**Decision.** Every upstream pin (ell, iwd, their Debian packaging, backport branch and commit,
linux-firmware commit and files, L4T headers packages) lives in `versions.json`. Scripts and
workflows read it; nothing is pinned anywhere else.

**Why.** One file to review in a bump PR, one file for Renovate to edit, and no way for two
scripts to disagree about which version is current. Git sources are pinned by full commit SHA;
downloaded packages by SHA-256; the build container by image digest.

**No clones needed.** kernel.org's cgit serves any commit as a tarball
(`snapshot/backport-iwlwifi-<sha>.tar.gz`) or a single file (`plain/<path>?id=<sha>`), and
salsa.debian.org serves the `debian/` directory of any commit as an archive. So the build
downloads a few MB instead of cloning linux-firmware (gigabytes). The backport snapshot was
checked to be identical to `git archive` of the same commit, and `driver-src.tar.gz` is
reproducible: the same pins give a byte-identical file.

---

## D11 — Licence: GPL-2.0-only

**Decision.** The repository is GPL-2.0-only.

**Why.** The patches in D9 modify GPL-2.0-only kernel code, so they must be GPL-2.0-only anyway.
Using the same licence for the scripts keeps the repository to one licence.

**What each release redistributes, and what that requires:**

| Asset | Licence | What we do |
|---|---|---|
| `libell0`, `iwd` debs | mainly LGPL-2.1+ (per each deb's `debian/copyright`) | Attach the matching upstream source and Debian packaging to the same release |
| `driver-src.tar.gz` | GPL-2.0 (backport-iwlwifi + our patches) | It is the source; keep the licence files in it |
| AX210 firmware | Intel's redistribution licence (`LICENCE.iwlwifi_firmware`) | Ship it unmodified, with the licence file; don't use Intel's name to promote the project |

This follows what Debian and Ubuntu do when they ship the same components. It isn't legal advice.

---

## D12 — Names: `orin-iwlwifi` everywhere

**Decision.** Everything the stack puts on a board carries the repository's name:

| What | Value | Set in |
|---|---|---|
| Deb version suffix | `+orin1`, e.g. `iwd 3.12-1+orin1` | `versions.json` (`deb.revision`) |
| Deb `Maintainer` | `orin-iwlwifi <245609868+dapalab@users.noreply.github.com>` | `versions.json` (`deb.maintainer`) |
| State directory | `/var/lib/orin-iwlwifi/` (downloaded release, install record) | `install.sh` |

**Why.** On a board, `dpkg -l`, the package metadata and the state directory all point back to
this repository. The suffix also sorts above Debian's own `3.12-1`, so a board never swaps our
build for an unmodified one with the same upstream version. The maintainer address is GitHub's
no-reply address for the `dapalab` account: it identifies the project without publishing a
personal address. Questions go to the issue tracker.

---

## D13 — The driver ships its own firmware

**Decision.** The driver deb installs the AX210 firmware pinned in `versions.json` (the `.ucode`
and `.pnvm` from the linux-firmware commit made for the tracked backport release) into
`/lib/firmware/updates/`. The kernel searches that directory before `/lib/firmware/`, so the
board loads our copy, not the one from Ubuntu's `linux-firmware` package.

**Why.** Intel publishes firmware for each backport release, and the driver is tested with that
pair. Ubuntu's copy can be a different build even when the API number matches. On the test board
(2026-09-28), jammy's `linux-firmware` `20220329.git681281e4-0ubuntu3.42` ships
`iwlwifi-ty-a0-gf-a0-89.ucode` build `1a492d28` and a different `.pnvm`; ours is build `d2579d43`,
which is the one the kernel log reports loading. Shipping the firmware also means:

- the driver works whatever `linux-firmware` version the image carries. The original jammy
  release has no API 89 firmware at all;
- an `apt upgrade` of `linux-firmware` doesn't change what the board runs. Firmware only changes
  through a reviewed bump in `versions.json` (D8, D10).

L4T also searches `/etc/firmware` before either directory, so `install.sh --check` refuses to
install if any `iwlwifi-*` files are there.

**Considered: using the firmware from Ubuntu's `linux-firmware` package.** It's one less thing to
ship, but the firmware would come from whatever that package holds, not the build tested with
the driver, and would change whenever the package is upgraded.

---

## D14 — Releases: one workflow run, dated tags, attested

**Decision.** A release is published by `release.yml`, started by hand from `main`. It runs
`build.yml` (the same workflow every push and pull request runs) and publishes the files that
run built and tested, nothing rebuilt in between. Tags are the date plus a counter
(`2026.09.28-1`) and are never reused or moved: a fix is a new release. Every file gets a build
provenance attestation, signed keylessly through GitHub's OIDC identity, and `SHA256SUMS`.

**Why.**

- *Publish what was tested.* The driver test-compile checks the `driver-src.tar.gz` artifact
  the same run uploaded, not a fresh download, so the tarball a board builds from is the one CI
  compiled.
- *Dated tags.* Releases follow the upstream pins in `versions.json`, not a version of our own,
  so a date says more than a number would. `install.sh` has its release tag written in when the
  release is assembled, so a downloaded `install.sh` always installs the release it came from.
- *Attestations, not a signing key.* There is no key to store, rotate or leak. `gh attestation
  verify` checks that a file was built by this repository's workflow (the same approach as
  kea-containers' keyless image signing).

**Branch protection** requires the `required` job, not the individual build jobs. The driver
test jobs are named after the headers version, which changes with `versions.json`; requiring
them directly would leave a bump PR waiting on a check under its old name.

**Considered: a release on every push to `main`.** Not every merge needs to reach boards, and a
release is what a new board installs; a person decides when.

