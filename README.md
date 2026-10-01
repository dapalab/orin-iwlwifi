# orin-iwlwifi

Up-to-date Wi-Fi for **NVIDIA Jetson Orin** boards with an **Intel AX210** card, running
Jetson Linux (L4T) 36.x / Ubuntu 22.04.

One script installs:

- the latest Intel Wi-Fi driver ([iwlwifi backport](https://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/backport-iwlwifi.git))
  and AX210 firmware. NVIDIA's stock kernel has no driver for the AX210 at all, and a kernel
  built with the in-tree one gets the older 5.15 version.
- the latest [iwd](https://git.kernel.org/pub/scm/network/wireless/iwd.git), a modern Wi-Fi
  client, in place of wpa_supplicant and NetworkManager.

> **Status: early.** Releases install and run on a Jetson Orin Nano developer kit; wider testing
> is still under way.
>
> **A community project,** not published by, affiliated with, or endorsed by Intel or NVIDIA.
> If something goes wrong, please [open an issue here](https://github.com/dapalab/orin-iwlwifi/issues)
> rather than with Intel, NVIDIA or the upstream projects.

## What you need

- A Jetson Orin with an Intel AX210, on Jetson Linux 36.x
- An **ethernet** connection with internet access. Networking switches over at the reboot, so
  ethernet is your way back in if anything goes wrong.
- A few minutes: the driver is built on the board, which takes about two.

## Install

```bash
curl -fsSLO https://github.com/dapalab/orin-iwlwifi/releases/latest/download/install.sh
less install.sh          # worth a look before running anything with sudo
sudo bash install.sh
sudo reboot
```

The script checks the board first. If anything is missing, it says what and stops without
changing anything. Nothing about the board's networking changes until you reboot.

After the reboot, iwd runs Wi-Fi, including its addresses (DHCP), so a roam between access
points keeps the address ([why](docs/DECISIONS.md#d21--iwd-configures-wi-fi-addresses)).
systemd-networkd runs ethernet, and NetworkManager and wpa_supplicant are switched off
(masked). To see that Wi-Fi is up:

```bash
iwctl station wlan0 show     # "connected" once you've added a network
networkctl                   # every link and its state
```

## Options

Most boards only need these two:

| Option | What it does |
|---|---|
| `--psk-file <SSID>.psk` | Adds a Wi-Fi network. Repeat it for more than one. [More](#adding-wi-fi-networks) |
| `--country CC` | Sets the Wi-Fi country, e.g. `US`. **Recommended for 6 GHz networks.** [More](#6-ghz-and-the-country-setting) |

```bash
sudo bash install.sh --psk-file MyNetwork.psk --country US
```

<details>
<summary>All options and settings</summary>

| Option | What it does |
|---|---|
| `--check` | Only checks the board is ready (L4T, AX210, build tools, kernel headers, ethernet); changes nothing |
| `--latest` | Installs the newest release instead of the one the script came from |
| `--release TAG` | Installs the given release |
| `--from DIR` | Installs from release files already in `DIR` (for testing a local build) |
| `--country none` | Removes a country set earlier |

Settings go **after** `sudo`, because sudo drops variables set before it:

| Setting | Default |
|---|---|
| `ETH_IFACE` | the first on-board ethernet interface |
| `ETH_METRIC` | `100` (route metric for ethernet; lower wins) |
| `WIFI_METRIC` | `600` (route metric for Wi-Fi: iwd's `RoutePriorityOffset`, plus the interface index) |

```bash
sudo ETH_IFACE=eth0 bash install.sh --psk-file MyNetwork.psk
```

</details>

### Adding Wi-Fi networks

Give `--psk-file` the network's iwd profile: the `<SSID>.psk` file iwd keeps in `/var/lib/iwd/`
(format: `man iwd.network`). It's copied in unchanged, so a profile from a board that has
already joined the network works as is.

You can also add networks later: copy the profile into `/var/lib/iwd/` (mode 600) and iwd
picks it up straight away.

### 6 GHz and the country setting

If the board will use a **6 GHz network**, pass `--country` with the country it's used in.
The AX210 picks its country from the beacons of nearby access points, and 6 GHz stays off until
it has one. With `--country`, the driver confirms that country as soon as the firmware sees
it, and doesn't confirm a different one, so a nearby device advertising another country
is less likely to keep 6 GHz off. Boards on 2.4 or 5 GHz networks can leave it out.

The firmware still has the last word: it only uses a country it has seen around it. If
`iw reg get` shows another country (or `00`) for long, something nearby is probably
advertising a different one. A network that's also on 5 GHz keeps the board connected
meanwhile. The kernel log shows each time the firmware guessed another country:

```bash
dmesg | grep 'firmware guessed'   # e.g. "firmware guessed CN; answered US ..., refused"
```

Only set the country the board is really in: it decides which channels and power levels the
radio may legally use. A country the firmware doesn't see around the board is never taken,
and 6 GHz then stays off.

The code is the country's two-letter
[ISO 3166-1 alpha-2 code](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2#Officially_assigned_code_elements)
(`US`, `CA`, `GB`, `DE`, …). The rules for each country come from tables inside the AX210
firmware, and Intel doesn't publish which countries they cover, so check after the reboot that
the board shows the country you set.

To check it after the reboot:

```bash
iw reg get     # look for "country US" under phy#0 (self-managed); the "global" 00 above it is normal
```

To change it, run `install.sh` again with a new `--country` (or `--country none`), or edit
`/etc/modprobe.d/orin-iwlwifi.conf`, then reboot.
[D16](docs/DECISIONS.md#d16--an-optional-regulatory-country) explains how it works.

## Upgrading

Run the newer release's `install.sh` the same way, then reboot:

```bash
curl -fsSLO https://github.com/dapalab/orin-iwlwifi/releases/latest/download/install.sh
sudo bash install.sh
sudo reboot
```

The board keeps its Wi-Fi networks, country and route metrics. If the script replaces a file
you've edited, it saves a copy in `/var/lib/orin-iwlwifi/replaced-<time>/` first and says so
in its log.

**Before installing or going back to an older release**, check its release notes: if a
release has a known problem, a note at the top says so and names the release that fixes it.

<details>
<summary>Going back, and pre-releases</summary>

Each release's packages, including the driver built for the board, stay in
`/var/lib/orin-iwlwifi/<release>/`. To go back, `sudo dpkg -i` the older release's `.deb` files
from there and reboot. [D18](docs/DECISIONS.md#d18--installsh-can-run-again) has the details.

**Pre-releases** (tags with a label, e.g. `2026.10.01-1-test1`) are test builds of a single
change. `--latest` never picks them, and the next release installs over them.
[D20](docs/DECISIONS.md#d20--pre-releases-for-testing-changes-on-boards) explains how they work.

</details>

## Good to know

- **The kernel is held.** `install.sh` puts every `nvidia-l4t-*` package on hold, so an
  `apt upgrade` can't swap the kernel out from under the driver. For a new L4T release,
  re-image the board and run `install.sh` again.
  ([Why](docs/DECISIONS.md#d3--hold-every-nvidia-l4t--package))
- **The driver is built on the board.** Every L4T 36 kernel calls itself `5.15.148-tegra`,
  whether it's NVIDIA's or your own build, so a prebuilt driver can't be matched to a board.
  Building it on the board always matches, and the install stops if the result doesn't fit the
  running kernel. ([Why](docs/DECISIONS.md#d1--build-the-driver-on-the-board))
- **Every decision is written down.** [`docs/DECISIONS.md`](docs/DECISIONS.md) explains why
  things are done the way they are, and what else was considered.

## Building from source

Each release is built from pinned upstream sources (listed in [`versions.json`](versions.json))
by one run of the [release workflow](.github/workflows/release.yml). Every file carries a
signed build attestation: `gh attestation verify <file> --repo dapalab/orin-iwlwifi`.

<details>
<summary>What's in a release, and how to build it yourself</summary>

| Asset | What |
|---|---|
| `libell0`, `iwd` debs | Built here from upstream + Debian's packaging, ready to install |
| `driver-src.tar.gz` | The backport driver source, our small [patches](patches/backport-iwlwifi/) for L4T, the AX210 firmware and the build script |
| `install.sh` | Runs on the board: installs the debs, builds the driver, configures iwd and systemd-networkd |
| `*.dsc`, `*.orig.tar.xz`, `*.debian.tar.xz`, `*.tar.sign` | Source packages for the debs: upstream's signed tarball + Debian's packaging with our changes |
| `SHA256SUMS` | Checksums of everything above |

On an arm64 machine with docker:

```bash
docker run --rm --security-opt seccomp=unconfined -v "$PWD:/src" -w /src \
  "$(jq -r .l4t.container versions.json)" scripts/build-debs.sh
scripts/make-driver-src.sh
docker run --rm -v "$PWD:/src" -w /src "$(jq -r .l4t.container versions.json)" \
  scripts/test-driver-build.sh 5.15.148-tegra-36.4.7-20250918154033   # test-compile the driver
scripts/assemble-release.sh 2026.09.28-1       # -> dist/release/
```

</details>

## Licence

This repository is [GPL-2.0-only](LICENSE), the same licence as the Linux kernel and the
backport driver our patches apply to.

The release assets carry their own licences: ell and iwd are mainly LGPL-2.1+, and the AX210
firmware is under Intel's redistribution licence (`LICENCE.iwlwifi_firmware`, shipped alongside
it, unmodified). See [NOTICE](NOTICE) for full attribution.
