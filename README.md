# AX3000T RD03 iStoreOS builder

This project builds the stock-bootloader layout for Xiaomi AX3000T RD03 from
the official `istoreos/istoreos` `istoreos-24.10` source branch.

Pinned iStoreOS source commit:

`fb971407ffd9a094e6f16d9c029f1f580ed5c2ad`

The build intentionally selects `xiaomi_mi-router-ax3000t`, not the
`-ubootmod` profile. It does not replace BL2 or FIP. The workflow fails if
either required image is absent or is 32 MiB or larger.

## Run

1. Create an empty GitHub repository.
2. Upload this folder's contents, preserving `.github/workflows/build.yml`.
3. Open **Actions**, select **Build iStoreOS for Xiaomi AX3000T RD03**, and
   choose **Run workflow**.
4. After a successful run, download the
   `AX3000T-RD03-iStoreOS-stock-layout` artifact.
5. Do not flash it until the two image hashes and build log have been checked.

The first-stage image must end in `initramfs-factory.ubi`. The second-stage
image must end in `squashfs-sysupgrade.bin`.

## Verified local build

The verified local image in `artifacts/` is iStoreOS 24.10.8 with OpenClash
0.47.156, `dnsmasq-full`, and adblock-fast/HaGeZi support. It uses kernel ABI
6.6.144 and the stock-layout `xiaomi_mi-router-ax3000t` profile. This image
was built locally; GitHub Actions remains a reproducible builder.

The sysupgrade image SHA-256 is recorded in `artifacts/SHA256SUMS` and its
manifest. Do not flash the `-ubootmod` profile. For U-Boot TFTP recovery use
router IP `192.168.10.1`, TFTP host `192.168.10.100`, and filename
`firmware_ubi.bin`; the included PowerShell helper can serve that file.

The recovery helpers are for temporary recovery only. Never commit router
backups, serial logs, credentials, private keys, or factory partition dumps.
