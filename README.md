# AX3000T RD03 iStoreOS builder

This project builds the stock-bootloader layout for Xiaomi AX3000T RD03 from
the official `istoreos/istoreos` `istoreos-24.10` source branch.

Pinned sources:

| what | pin |
|---|---|
| iStoreOS | `fb971407ffd9a094e6f16d9c029f1f580ed5c2ad` |
| OpenClash | `c3a33c1d3407956fdf8f0e0b7c1a4c52e6ad9593` (tag `v0.47.156`) |

The build intentionally selects `xiaomi_mi-router-ax3000t`, not the
`-ubootmod` profile. It does not replace BL2 or FIP. The workflow fails if
either required image is absent or is 32 MiB or larger.

## What ends up in the image

| component | how |
|---|---|
| OpenClash 0.47.156 | built from source (`luci-app-openclash` copied in by the workflow) |
| UU Game Booster, H3C NX30 PRO vendor build | rootfs overlay `files/usr/sbin/uu/` |
| Ruby 3.3.10 for OpenClash | rootfs overlay `files/` — **prebuilt**, see [`PREBUILT-RUBY.md`](PREBUILT-RUBY.md) |
| `kmod-nft-compat`, `kmod-nf-ipt` | built from this tree's own kernel sources |
| `libgmp10`, `zlib` | `ax3000t.config` (runtime libraries for the prebuilt Ruby) |
| `dnsmasq-full`, adblock-fast, luci-app-store, argon theme | `ax3000t.config` |

OpenClash declares `+ruby +ruby-yaml` in its `DEPENDS`, but the workflow strips
that and ships the prebuilt packages instead: compiling Ruby from source was
almost the whole cost of the first run that included OpenClash (2h56m for
`Build firmware`, against 43m without it).

## Run

1. Create an empty GitHub repository.
2. Upload this folder's contents, preserving `.github/workflows/build.yml`
   and the whole `files/` tree. Pushing with `git` is preferred; if you upload
   through the web UI, keep the directory structure intact.
3. Open **Actions**, select **Build iStoreOS for Xiaomi AX3000T RD03**, and
   choose **Run workflow**.
4. After a successful run, download the
   `AX3000T-RD03-iStoreOS-stock-layout` artifact.
5. Do not flash it until the two image hashes and build log have been checked.

The first-stage image must end in `initramfs-factory.ubi`. The second-stage
image must end in `squashfs-sysupgrade.bin`.

Build outputs are collected into a **fresh `dist/` directory** on every run, so
the uploaded artifact contains only that run's images plus `SHA256SUMS`,
`BUILD-METADATA.txt`, `build.config` and `feeds-pinned.txt`. An earlier version
wrote into the repo's `artifacts/`, which still holds a previously verified
local image, and the first successful run therefore shipped a stale sysupgrade
image alongside the new one — a real hazard for anyone picking a file to flash.
`artifacts/` is now left untouched by the build.

The workflow verifies the build rather than trusting it: every requested
`CONFIG_PACKAGE_*` symbol is checked individually with `grep -qx`; the overlay,
the prebuilt Ruby (including its symlinks), the OpenClash payload and
`nft_compat.ko` are all asserted to have reached the rootfs staging tree the
images are packed from; and `Build firmware` prints a timestamped heartbeat
every two minutes, because OpenWrt's own output goes silent for many minutes
inside a single package and a healthy build otherwise looks hung.

## UU Game Booster

Xiaomi's own firmware contains **no** UU plugin — its entire rootfs (3,645
files) has zero hits for `uuplugin`/`uugamebooster`/`XU_ACC`; Xiaomi downloads
plugins at runtime from its own cloud. The port therefore ships the **H3C
NX30 PRO vendor build**, which is the same MT7981B SoC.

The whole point is the identity the plugin reports. UU's cloud decides from it
whether a router may accelerate PCs at all:

| build | reports | result |
|---|---|---|
| UU generic OpenWrt | `type:openwrt` / `model:OpenWrt` | console only — "this router model does not support acceleration" |
| H3C NX30 PRO vendor | `type:h3c` / `model:NX30Pro` | full PC/phone acceleration |

`files/etc/uu-vendor/PROVENANCE.md` records where the tarball came from, its
md5, and why `check_plugin_upgrade` had to be disabled inside the monitor.

## Why `kmod-nft-compat` is mandatory

Without it `xtables-nft-multi iptables-nft -j DNAT` fails with
`Extension DNAT revision 0 not supported, missing kernel module?`. UU's NAT
capability check then fails and it refuses to accelerate any device — it can
list devices but "点加速失败".

It cannot be installed after the fact. This image has its own kernel ABI hash
(`6.6.144~df1294ec…`), no published kmod feed matches it, and loading a kmod
built for a different config panics the kernel even when the vermagic string
looks identical. It has to be built by this workflow, from this tree.

## Legacy UU package workflow

`Build UU Game Booster packages for AX3000T` (`build-uu.yml`) builds the
*generic* UU IPKs, which are console-only. It predates the vendor port above
and is kept only for reference; the firmware workflow no longer uses it.

## Verified local build

The verified local image in `artifacts/` is iStoreOS 24.10.8 with OpenClash
0.47.156, `dnsmasq-full`, and adblock-fast/HaGeZi support. It uses kernel ABI
6.6.144 and the stock-layout `xiaomi_mi-router-ax3000t` profile. That image
predates the UU vendor port, so it does not contain it.

The sysupgrade image SHA-256 is recorded in `artifacts/SHA256SUMS` and its
manifest.

The recovery helpers are for temporary recovery only. Never commit router
backups, serial logs, credentials, private keys, or factory partition dumps.

## Recovery — read this before flashing

**Flashing this firmware has already bricked the router once.** The build was
fine; the `sysupgrade` run left the device with no `rootfs` volume at all.

Root cause, now established: `/lib/upgrade/stage2` only unmounts `/overlay` when
no config backup was requested — i.e. when you pass **`-n`**. `rootfs_data`
backs `/overlay`, and a mounted UBIFS volume cannot be removed (`EBUSY`), so
without `-n` the upgrade can only reuse the space freed by deleting the old
`rootfs`. The old rootfs was 139 LEB; the new one needs 153 LEB; `ubimkvol`
failed *after* `rootfs` had already been deleted. Full analysis:
[`docs/recovery/ROOT-CAUSE-sysupgrade-rootfs.md`](docs/recovery/ROOT-CAUSE-sysupgrade-rootfs.md).

Three hard rules that came out of it:

- **Always `sysupgrade -n`.** Not for config hygiene — it changes what the
  upgrade script is able to do. Without it `/overlay` is never unmounted, so
  `rootfs_data` is immovable and any image whose rootfs grew past the previous
  volume size will fail and leave the device unbootable. With `-n` roughly
  605 LEB are reclaimed and it just works. Re-apply config selectively afterwards.
- **Never install a kernel module built elsewhere.** A mismatched `.ko` panics
  the kernel on load and puts the device into a reboot loop. Module-
  configuration mismatches are fixed by rebuilding, never with
  `opkg --force-depends`.
- **Watch the rootfs volume size.** If the new rootfs is larger than the
  installed `rootfs` volume, prefer flashing from the initramfs recovery system
  (`/overlay` is not mounted there, so the full volume rebuild always works).
  `files/lib/upgrade/nand.sh` adds a guard that refuses such an upgrade *before*
  erasing anything, so a wrong attempt is recoverable instead of fatal —
  but it only takes effect from the build that installs it onward.


Recovery parameters (measured on this device — U-Boot only, needs a **wired**
connection and a serial console to be useful):

| | |
|---|---|
| Router U-Boot IP | `192.168.10.1` |
| Computer TFTP IP | `192.168.10.100` (`/24`, no gateway) |
| Requested filename | `firmware_ubi.bin` |
| Serial | `115200 8N1`, GND/TX/RX only — **never connect the 3.3V/5V pin** |
| U-Boot menu | `4. Upgrade firmware` |
| ⛔ | **Never pick menu 5 (ATF BL2) or 6 (ATF FIP)** — those touch the boot chain |

> The bundled `scripts/tftp_recovery_server.ps1` is a reference implementation
> only. It hit two compatibility problems against this device's U-Boot (OACK
> `timeout` negotiation, and a duplicate ACK around block 256). The recovery
> that actually succeeded used **Tftpd64 4.70**. Prefer it.

