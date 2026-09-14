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
