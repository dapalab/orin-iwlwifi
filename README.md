# orin-iwlwifi

An up-to-date Wi-Fi stack for **NVIDIA Jetson Orin** boards with an **Intel AX210**
card, running Jetson Linux (L4T) 36.x / Ubuntu 22.04:

- the latest [iwlwifi backport driver](https://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/backport-iwlwifi.git)
  and matching AX210 firmware (NVIDIA's stock kernel has no iwlwifi at all, and a kernel built
  with the in-tree one gets the 5.15 version),
- the latest [iwd](https://git.kernel.org/pub/scm/network/wireless/iwd.git) and
  [ell](https://git.kernel.org/pub/scm/libs/ell/ell.git), in place of wpa_supplicant and
  NetworkManager, installed on each board by one script.

> **Status: early.** Releases install and run on a Jetson Orin Nano developer kit; wider testing
> is still under way.

> **A community project.** This isn't published by, affiliated with, or endorsed by Intel or
> NVIDIA. If something goes wrong, please open an issue in
> [this repository](https://github.com/dapalab/orin-iwlwifi/issues) rather than with Intel,
> NVIDIA or the upstream projects.

## How it works

Each release is built from pinned upstream sources (listed in [`versions.json`](versions.json))
and contains:

| Asset | What |
|---|---|
| `libell0`, `iwd` debs | Built here from upstream + Debian's packaging, ready to install |
| `driver-src.tar.gz` | The backport driver source, our small [patches](patches/backport-iwlwifi/) for L4T, the AX210 firmware and the build script |
| `install.sh` | Runs on the board: installs the debs, builds the driver, configures iwd |
| `*.dsc`, `*.orig.tar.xz`, `*.debian.tar.xz`, `*.tar.sign` | Source packages for the debs: upstream's signed tarball + Debian's packaging with our changes |
| `SHA256SUMS` | Checksums of everything above |

Every release is built and published by one run of the [release workflow](.github/workflows/release.yml),
and each file carries a signed build attestation: `gh attestation verify <file> --repo dapalab/orin-iwlwifi`.

To build any of it yourself (on an arm64 machine with docker):

```bash
docker run --rm --security-opt seccomp=unconfined -v "$PWD:/src" -w /src \
  "$(jq -r .l4t.container versions.json)" scripts/build-debs.sh
scripts/make-driver-src.sh
docker run --rm -v "$PWD:/src" -w /src "$(jq -r .l4t.container versions.json)" \
  scripts/test-driver-build.sh 5.15.148-tegra-36.4.7-20250918154033   # test-compile the driver
scripts/assemble-release.sh 2026.09.28-1       # -> dist/release/
```

The driver is **built on the board**, against the kernel it runs. Every L4T 36 kernel calls
itself `5.15.148-tegra`, whether it's NVIDIA's stock kernel or your own build, so a prebuilt
module can't be matched to a board by version. Building it on the board always matches. Before
anything is installed, the new modules' symbol checksums are compared with the running kernel's,
and a mismatch stops the install.

## Quick start

On a freshly imaged board, connected by **ethernet**, with internet access:

```bash
curl -fsSLO https://github.com/dapalab/orin-iwlwifi/releases/download/<release>/install.sh
less install.sh                  # it's short: please read it
sudo bash install.sh             # installs the release it came from
sudo reboot
```

Nothing changes how the board is networked until the reboot. After it, iwd and
systemd-networkd manage Wi-Fi and ethernet, and NetworkManager and wpa_supplicant are masked.

## Options

| Option | What it does |
|---|---|
| `--psk-file <SSID>.psk` | Adds a Wi-Fi network. Repeat for more than one. [Details](#adding-wi-fi-networks) |
| `--country CC` | Fixes the Wi-Fi regulatory country, e.g. `US`. **Needed for 6 GHz networks.** `--country none` removes it. [Details](#6-ghz-networks-and-the-regulatory-country) |
| `--check` | Only checks the board is ready (L4T, AX210, build tools, headers, ethernet); changes nothing |
| `--latest` | Installs the newest release instead of the one the script came from |
| `--release TAG` | Installs the given release |
| `--from DIR` | Installs from release files already in `DIR` (for testing a local build) |

Settings go **after** `sudo`, because sudo drops variables set before it:

| Setting | Default |
|---|---|
| `ETH_IFACE` | the first on-board ethernet interface |
| `ETH_METRIC` | `100` (route metric for ethernet; lower wins) |
| `WIFI_METRIC` | `600` (route metric for Wi-Fi) |

```bash
sudo ETH_IFACE=eth0 bash install.sh --psk-file MyNetwork.psk --country US
```

### Adding Wi-Fi networks

Pass the network's iwd profile: the `<SSID>.psk` file iwd keeps in `/var/lib/iwd/` (format:
`man iwd.network`). It's copied in unchanged, so a profile taken from a board that has already
joined the network, including the WPA3 `SAE-PT-Group19`/`20` lines, works as is. Without
`--psk-file`, no network is added: copy a profile into `/var/lib/iwd/` later (mode 600), and iwd
picks it up without a restart.

### 6 GHz networks and the regulatory country

**Set `--country` to the country the board is used in if it will use a 6 GHz network.** Boards
that only use 2.4 or 5 GHz networks can leave it out.

*Without it,* the AX210 firmware picks the country itself. A Jetson has no BIOS to tell it, so
the card starts on the "world" rules, where every 6 GHz channel is off. It then guesses the
country from the access points around it. Until that guess comes in (usually within a couple of
minutes, but not always), the board can't see a 6 GHz network at all. The guess is also redone
whenever the board is disconnected, and a single nearby device advertising a different country
can switch 6 GHz off again. On a 6 GHz-only network, both show up as iwd failing to connect
with "Operation failed".

*With it,* the driver sets that country each time the firmware starts, and sets it again
whenever the firmware makes a guess of its own. 6 GHz is on from boot and stays on.

Only set the country the board is really used in: it decides which channels and power levels
the radio may use, which is a legal matter. For a board that moves between countries, leave it
out.

To **check** it after the reboot:

```bash
iw reg get                                   # phy#0 (self-managed) shows "country US";
                                             # the "global" country 00 above it is normal
sudo dmesg | grep 'regulatory country fixed'   # the driver applying it
```

To **change** it, run `install.sh` again with a new `--country` (see [Upgrading](#upgrading)),
or edit `options iwlmvm country=` in `/etc/modprobe.d/orin-iwlwifi.conf`, then reboot.
`--country none` removes it. [D16](docs/DECISIONS.md#d16--an-optional-fixed-regulatory-country)
has the full story.

## Upgrading

To upgrade an installed board, or give it a newer release's settings, run that release's
`install.sh` the same way, over ethernet, then reboot:

```bash
curl -fsSLO https://github.com/dapalab/orin-iwlwifi/releases/download/<release>/install.sh
sudo bash install.sh
sudo reboot
```

The board keeps its Wi-Fi profiles, its country and its route metrics unless you give them
again. Any file that `install.sh` replaces with different contents, including one edited by
hand, is copied to `/var/lib/orin-iwlwifi/replaced-<time>/` first, and the install log
(`/var/lib/orin-iwlwifi/install.log`) names each one. Each release's packages, including
the driver built for this board, stay in `/var/lib/orin-iwlwifi/<release>/`: to go back,
`sudo dpkg -i` the older release's `.deb` files there and reboot.
[D18](docs/DECISIONS.md#d18--installsh-can-run-again) has the details.

If a release turns out to have a problem, its release notes say so at the top and name the
release that fixes it. Check them before installing or going back to an older release.

**Pre-releases** (tags with a label, e.g. `2026.09.30-1-ftfix1`) are test builds of a single
change. `--latest` never picks them, and the next release installs over them.
[D20](docs/DECISIONS.md#d20--pre-releases-for-testing-changes-on-boards) explains how they work.

## The kernel is held

`install.sh` puts every `nvidia-l4t-*` package **on hold** before it runs apt, so an
`apt upgrade` can't replace your kernel behind your back. A new L4T release means re-imaging
the board, then running `install.sh` again. [D3](docs/DECISIONS.md#d3--hold-every-nvidia-l4t--package)
explains why.

## Behind the scenes

[`docs/DECISIONS.md`](docs/DECISIONS.md) records every design decision, why it was made and what
else was considered.

## Licence

This repository is [GPL-2.0-only](LICENSE), the same licence as the Linux kernel and the
backport driver our patches apply to.

The release assets carry their own licences: ell and iwd are mainly LGPL-2.1+, and the AX210
firmware is under Intel's redistribution licence (`LICENCE.iwlwifi_firmware`, shipped alongside
it, unmodified). See [NOTICE](NOTICE) for full attribution.
