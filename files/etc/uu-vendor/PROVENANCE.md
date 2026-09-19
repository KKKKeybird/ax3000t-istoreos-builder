# UU Game Booster on AX3000T — what is baked into this image

## Why the H3C build and not the "AX3000T" one

Xiaomi's AX3000T stock firmware **does not contain a UU plugin at all**. Its
entire rootfs (3,645 files, squashfs/xz, extracted from `fw_1.0.106.bin`) has
zero hits for `uuplugin`, `uugamebooster`, `XU_ACC` or `manufactoryDataFile`.
Xiaomi downloads plugins at runtime: `/etc/init.d/pluginmanager` calls
`/usr/sbin/pluginmanager`, which pulls `.mpk` packages from `s.miwifi.com` into
`/userdisk/appdata/installPlugin/`. There is nothing to port out of it.

The porting guide this image follows is about **H3C Magic NX30 PRO**
(same MT7981B SoC as the AX3000T, hence "same config, directly reproducible").
Its stock firmware ships `/etc/init.d/uu` + `/usr/bin/h3c_uuplugin_monitor.sh`,
and its plugin is built for the vendor identity `h3c-nx30pro`.

## Why identity is the whole problem

`uuplugin` reports `(type, model, sn)` — readable on the device at
`http://<lan-ip>:16363/router`. UU's cloud decides from `type` whether the
router may accelerate PCs/phones at all:

| build | reported type | cloud verdict |
|---|---|---|
| UU generic OpenWrt (`openwrt-aarch64`) | `openwrt` / `OpenWrt` | console only — "this router model does not support acceleration" |
| H3C NX30 PRO vendor (`h3c-nx30pro`) | `h3c` / `NX30Pro` | full PC/phone acceleration |

The value is a compile-time constant in the binary, not configuration: setting
`UU_MODEL`/`UU_VENDOR`, writing `/var/model`, or adding `type=`/`model=` to
`uu.conf` all leave `/router` reporting `openwrt`/`OpenWrt`.

## Provenance of the shipped tarball

`/usr/sbin/uu/uu.tar.gz` — 1,483,259 bytes

* Fetched from UU's own distribution API, which is what H3C's monitor does:
  `https://router.uu.163.com/api/plugin?type=h3c-nx30pro&sn=<manucode>`
  -> `.../uuplugin/h3c-nx30pro/v14.9.4/uu.tar.gz`
* md5 `2afd39af94e5dda55dcfcb4bc220c5ce` — matches the md5 returned by that API
* Contents: `uuplugin` (3,422,320 B, ELF aarch64, dynamically linked against
  musl + libstdc++, md5 `5cc2a0d0671d717e46f92f84623e4746`),
  `xuplugin-guardian`, `uu.conf`

Runtime dependencies are satisfied by this image: `/lib/ld-musl-aarch64.so.1`,
`/usr/lib/libstdc++.so.6`, `/lib/libgcc_s.so.1`.

## Why `check_plugin_upgrade` is disabled in the monitor

`uuplugin_monitor.sh` normally fetches UU's md5 for its configured build
(`openwrt-aarch64` here), compares it with the local tarball, and deletes the
local copy when they differ. Left enabled, it would throw the vendor tarball
away on first boot and silently fall back to the console-only generic build.

Updating the vendor plugin therefore means re-running the extraction and
replacing `uu.tar.gz` + `uu.tar.gz.md5`; it is not automatic.

## Files

| path | role |
|---|---|
| `usr/sbin/uu/uu.tar.gz` | H3C vendor plugin tarball |
| `usr/sbin/uu/uu.tar.gz.md5` | its md5, for the monitor's integrity check |
| `usr/sbin/uu/uuplugin_monitor.sh` | UU's generic monitor, `check_plugin_upgrade` disabled |
| `usr/sbin/uu/uuplugin_monitor.config` | `router=openwrt`, `model=aarch64` (download path only) |
| `etc/init.d/uu-identity` | writes `/var/tmp/uu/h3c_info` from br-lan MAC, `START=98` |
| `etc/init.d/uuplugin` | starts the monitor, `START=99` |
| `etc/uci-defaults/99-uu-vendor` | enables both services on first boot (`files/` cannot register services itself) |

## Serial

`manucode` = `219801A4QC` + the 12 hex digits of `br-lan`'s MAC, uppercase
(22 chars, H3C-shaped). Derived per unit rather than baked in, so the same image
is correct on every router. It is deliberately not the serial of the NX30 PRO
whose firmware was used as the source, to avoid colliding with that unit in UU's
cloud.

Evidence that this is safe: two independent NX30 PRO stock dumps produced
byte-identical `init.d/uu` (sha256 `ef03ca22…aa269`) and
`h3c_uuplugin_monitor.sh` (sha256 `4d903469…d126`) while their `manucode`,
`ethaddr` and firmware revisions all differed — so the scripts are
model-generic and only the factory identity is per-device.
