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
| `kmod-nft-compat`, `kmod-nf-ipt` | built from this tree's own kernel sources |
| `dnsmasq-full`, adblock-fast, luci-app-store, argon theme | `ax3000t.config` |

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

The workflow verifies the build rather than trusting it: every requested
`CONFIG_PACKAGE_*` symbol is checked individually with `grep -qx`, and after
the build it asserts that the overlay, the OpenClash payload and `nft_compat.ko`
really landed in the rootfs staging tree the images are packed from.

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
manifest. Do not flash the `-ubootmod` profile. For U-Boot TFTP recovery use
router IP `192.168.10.1`, TFTP host `192.168.10.100`, and filename
`firmware_ubi.bin`; the included PowerShell helper can serve that file.

The recovery helpers are for temporary recovery only. Never commit router
backups, serial logs, credentials, private keys, or factory partition dumps.
