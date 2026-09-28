# orin-iwlwifi

An up-to-date Wi-Fi stack for **NVIDIA Jetson Orin** boards with an **Intel AX210**
card, running Jetson Linux (L4T) 36.x / Ubuntu 22.04:

- the latest [iwlwifi backport driver](https://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/backport-iwlwifi.git)
  and matching AX210 firmware (NVIDIA's stock kernel has no iwlwifi at all, and a kernel built
  with the in-tree one gets the 5.15 version),
- the latest [iwd](https://git.kernel.org/pub/scm/network/wireless/iwd.git) and
  [ell](https://git.kernel.org/pub/scm/libs/ell/ell.git), in place of wpa_supplicant and
  NetworkManager,

installed on each board by one script.

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
| `driver-src.tar.gz` | The backport driver source, our two small [L4T patches](patches/backport-iwlwifi/), the AX210 firmware and the build script |
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

To also add a Wi-Fi network, pass its iwd profile: the `<SSID>.psk` file iwd keeps in
`/var/lib/iwd/` (format: `man iwd.network`). It's copied in unchanged, so a profile taken from a
board that has already joined the network, including the WPA3 `SAE-PT-Group19`/`20` lines,
works as is. Repeat `--psk-file` for more than one network.

```bash
sudo bash install.sh --psk-file <SSID>.psk
```

`install.sh` puts every `nvidia-l4t-*` package **on hold** before it runs apt, so an
`apt upgrade` can't replace your kernel behind your back. A new L4T release means re-imaging
the board, then running `install.sh` again. [Behind the scenes](docs/DECISIONS.md) explains why.

## Behind the scenes

[`docs/DECISIONS.md`](docs/DECISIONS.md) records every design decision, why it was made and what
else was considered.

## Licence

This repository is [GPL-2.0-only](LICENSE), the same licence as the Linux kernel and the
backport driver our patches apply to.

The release assets carry their own licences: ell and iwd are mainly LGPL-2.1+, and the AX210
firmware is under Intel's redistribution licence (`LICENCE.iwlwifi_firmware`, shipped alongside
it, unmodified). See [NOTICE](NOTICE) for full attribution.
