# Root cause: why sysupgrade left the device unbootable

Date: 2026-09-19
Device: Xiaomi AX3000T RD03, stock bootloader layout, iStoreOS 24.10.8, kernel 6.6.144

## TL;DR

`sysupgrade` was run **without `-n`**. That single choice is what broke the device.

When config is preserved, `stage2` skips the `/overlay` unmount. `rootfs_data`
backs `/overlay`, so it stays mounted, and a mounted UBIFS volume cannot be
removed or resized (`EBUSY`). Upstream's upgrade path removes `rootfs` *first*
and only then tries to remove `rootfs_data` — so when `rootfs_data` cannot be
freed, the new `rootfs` has to fit inside the space freed by the old one. Our
new rootfs is **153 LEB**, the old one was **139 LEB**, so `ubimkvol` failed
**after `rootfs` had already been deleted** → nothing to boot.

**Fix: always `sysupgrade -n` on this device.** With `-n`, `/overlay` is
unmounted, `rootfs_data` becomes removable, ~605 LEB are reclaimed, and the new
153 LEB rootfs fits with room to spare.

## The evidence chain

### 1. `stage2` only unmounts `/overlay` when no config backup was requested

`/lib/upgrade/stage2`:

```sh
231  ROOTFS_TYPE=$(rootfs_type)
232  if [ -n "$ROOTFS_TYPE" -a "$ROOTFS_TYPE" != "tmpfs" -a "$ROOTFS_TYPE" != "rootfs" ]; then
233  	date '+%Y-%m-%d %H:%M:%S' >>/overlay/upgrade.log
234  	v "Switching to ramdisk..."
235  	switch_to_ramfs
236  fi
...
244  if [ -z "$UPGRADE_BACKUP" ]; then          # <-- only without a config backup
245  	grep /overlay /proc/mounts > /dev/null && {
246  		/bin/mount -o noatime,remount,ro /overlay
247  		/usr/bin/umount -R -d -l /overlay 2>/dev/null || /bin/umount -l /overlay
248  	}
249  fi
```

`/sbin/sysupgrade` sets `SAVE_CONFIG=1` by default and only clears it for `-n`:

```
33   export SAVE_CONFIG=1
44   	-n) export SAVE_CONFIG=0;;
418  	[ $SAVE_CONFIG -eq 1 ] && json_add_string backup "$CONF_TAR"
```

The `backup` field reaches `do_stage2` as `UPGRADE_BACKUP`. Our flash log shows
it present:

```
ubus call system sysupgrade { "prefix": "/tmp/root", "path": "/tmp/sysupgrade.bin",
  "backup": "/tmp/sysupgrade.tgz", "command": "/lib/upgrade/do_stage2", ... }
```

→ `UPGRADE_BACKUP` non-empty → the unmount block at line 244 was **skipped**.

### 2. A mounted UBIFS volume cannot be removed or resized

Measured on the live device with `/overlay` mounted:

```
$ ubirsvol /dev/ubi0 -N rootfs_data -s 53329920
ubirsvol: error!: cannot UBI resize volume
          error 16 (Resource busy)
```

`ubirmvol` fails the same way. So while the system is running from the overlay,
**`rootfs_data` is immovable**.

### 3. Upstream deletes `rootfs` before it discovers `rootfs_data` is stuck

`/lib/upgrade/nand.sh`, in `nand_upgrade_prepare_ubi()`:

```sh
[ "$kern_ubivol" ] && ubirmvol /dev/$kern_ubidev -N "$CI_KERNPART"  || :   # kernel  (mtd8)
[ "$root_ubivol" ] && ubirmvol /dev/$root_ubidev -N "$CI_ROOTPART"  || :   # rootfs  (mtd9) -> 139 LEB freed
[ "$data_ubivol" ] && ubirmvol /dev/$root_ubidev -N rootfs_data     || :   # EBUSY, swallowed by "|| :"
...
ubimkvol /dev/$root_ubidev -N "$CI_ROOTPART" -s $rootfs_length             # needs 153 LEB, only 139 free
```

Two problems compound here:

* the `|| :` **silently swallows the `rootfs_data` failure**, and
* `rootfs` is already gone by the time the `ubimkvol` fails.

`ubimkvol` failure → `cannot create rootfs volume` → `return 1` → upgrade aborts
→ **device has no rootfs**.

### 4. Decisive corroboration from the recovery itself

The recovery record states:

> mtd9 有足够空闲 LEB，本次可用 **139** 个，每个 126,976 字节

139 is **exactly** the size of the deleted `rootfs`. If `rootfs_data` had been
freeable, far more would have been available. So `rootfs_data` gave up *zero*
LEBs — independently confirming the `EBUSY` path.

### 5. The space arithmetic

| | LEB | bytes |
|---|---|---|
| mtd9 total | 624 | |
| reserved (bad block / UBI overhead) | −19 | |
| `rootfs_data` (immovable here) | −460 | 58,408,960 |
| **freed by deleting old `rootfs`** | **139** | 17,649,664 |
| **new `rootfs` needs** | **153** | 19,412,992 |
| shortfall | **−14** | ≈ 1.8 MiB |

With `-n`, `rootfs_data` is removable: reclaim ≈ 605 LEB, need 153 → fits.

## Why the image is fine and why earlier flashes worked

* The image is structurally valid: POSIX tar, `BOARD=xiaomi_mi-router-ax3000t`,
  4,351,604 B FIT kernel, 19,412,992 B squashfs readable end-to-end. Every
  expected file is present, including `lib/modules/6.6.144/nft_compat.ko`.
* `platform.sh` and `nand.sh` are **byte-identical** between the old system and
  the new image (`aa62b2f3…` / `98a2240e…`), and `board_name` is
  `xiaomi,mi-router-ax3000t`, so the correct branch runs. Nothing about the
  board detection or the upgrade scripts changed.
* Earlier flashes "worked" because the incoming rootfs was no larger than the
  outgoing one, so it always fit in the 139 LEB that deleting `rootfs` frees.
  This is a latent upstream bug that only bites once the image grows past the
  previous rootfs volume size.

## Fixes

### A. Always `sysupgrade -n` (no change needed, do this now)

`-n` → `SAVE_CONFIG=0` → no `backup` field → `UPGRADE_BACKUP` empty → `stage2`
unmounts `/overlay` → `rootfs_data` removable → 605 LEB reclaimed → upgrade
proceeds normally.

Re-apply configuration selectively afterwards. Do **not** restore the old `/etc`
wholesale.

### B. Space guard shipped in the firmware

`files/lib/upgrade/nand.sh` is a patched copy of the stock script. Before it
deletes anything it computes whether the incoming rootfs can fit:

```
need  = ceil(rootfs_length / LEB)
can   = old_rootfs_reserved_ebs + avail_eraseblocks
if need > can:
    try ubirmvol rootfs_data          # the step upstream intended
    recompute
if need > can:
    refuse, return 1                  # nothing has been erased
```

Against the exact numbers from the failed flash it decides:

```
need = 153 LEB,  can = 139 LEB  ->  insufficient
ubirmvol rootfs_data -> EBUSY, still 139
-> refuse: "rootfs will not fit: need 153 LEB, can reclaim 139 LEB"
```

so the upgrade is refused **while the old rootfs is still intact** and the device
stays bootable. A refused upgrade is recoverable; a half-applied one is not.

Note this file only takes effect on the *next* firmware since `/lib/upgrade/` is
part of the rootfs being replaced — but the script that runs during an upgrade is
the one from the currently-installed system, so the guard protects the upgrade
*after* the one that installs it.

### C. Never `sysupgrade` from the running system when the image grew

The most reliable path is to boot the initramfs recovery system and run
`sysupgrade` from there: `/overlay` is not mounted, so the full volume rebuild
works regardless of sizes, and a failed write leaves you in RAM rather than with
a dead device.

## Measured facts used above

| item | value |
|---|---|
| mtd9 total LEB | 624 |
| reserved PEBs | 19 |
| `rootfs` volume | 139 LEB / 17,649,664 B |
| `rootfs_data` volume | 460 LEB / 58,408,960 B |
| available LEB (before upgrade) | 0 |
| LEB size | 126,976 B |
| new image root component | 19,412,992 B → 153 LEB |
| new image kernel component | 4,351,604 B |
| `ubirsvol` on mounted `rootfs_data` | `EBUSY (16)` |
