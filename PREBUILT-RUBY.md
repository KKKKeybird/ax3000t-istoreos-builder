# Prebuilt Ruby shipped in `files/`

## Why

`luci-app-openclash`'s Makefile declares `DEPENDS:=... +ruby +ruby-yaml`.
Building Ruby from source in the firmware build means the interpreter **plus ten
extension packages**, each re-entering Ruby's own build system. On the first
run that worked end to end ([run 35431786668]) `Build firmware` took **2h56m**
against **43m** for the same workflow without OpenClash — Ruby was nearly all of
the difference.

The result of that compile is byte-for-byte what OpenWrt already publishes as
prebuilt `aarch64_cortex-a53` packages, so we ship those instead and let
`files/` (the rootfs overlay) place them. The workflow strips
`+ruby +ruby-yaml` from OpenClash's `DEPENDS` so nothing tries to compile it.

## Why this is safe to do at the dependency level

OpenWrt assembles the image rootfs in `package/Makefile`:

```make
$(curdir)/install: ...
	$(call opkg,$(TARGET_DIR)) install $$(cat $(TMP_DIR)/opkg_install_list)
	...
	$(call prepare_rootfs,$(TARGET_DIR),$(TOPDIR)/files)
```

opkg resolves dependencies from the generated control files. With ruby removed
from `DEPENDS`, nothing asks opkg for it, so no unresolvable dependency. The
`files/` overlay is then applied **on top of** that rootfs, which is where our
copy lands.

## Provenance

Taken verbatim from the official OpenWrt 24.10.8 feed for this exact target:

```
https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/packages/
```

| package | version | ipk sha256 | size |
|---|---|---|---|
| `libruby3.3` | 3.3.10-r1 | `d04f3c86a630d1c71c8d3e942035f45ddd9e87c7b86fda399f57965223e8ade6` | 1428810 B |
| `libyaml` | 0.2.5-r1 | `f8d7ea129085fb75befc3f93012fe3b3b2379ec9a99badc22c1e659f049712b3` | 41796 B |
| `ruby-bigdecimal` | 3.3.10-r1 | `8db349bef09d4f148294f7a9d9f43ad67511f91ebbab655cfa909a77e0e3093c` | 44506 B |
| `ruby-date` | 3.3.10-r1 | `14d93c19255d72ce43e83f90daa6761feb3b524a612d989c300cb8cb31ca875d` | 63820 B |
| `ruby-digest` | 3.3.10-r1 | `dd42e2d42e89617acc48f4f4f643bcfeed131243122af3b615f0303f75c03a12` | 30339 B |
| `ruby-enc` | 3.3.10-r1 | `0f4964ce669f52bafd263256286fc152626926252276c5b506704af92539a93d` | 16547 B |
| `ruby-pstore` | 3.3.10-r1 | `27180640491c990e7db88be7c07ba5224d5f489398d0a5ca28c9cbe106d5f02f` | 7877 B |
| `ruby-psych` | 3.3.10-r1 | `d212c7fc0553f0d9d17d0d5c8776d30a7d7a60090142254cad0e83ad22a2cb1e` | 34929 B |
| `ruby-stringio` | 3.3.10-r1 | `d52bd94c617f4fd728917096f3c09dc099bff993a30d1128bf8b1d659690f5ac` | 14054 B |
| `ruby-yaml` | 3.3.10-r1 | `b88426778d4ee22ddf96d15a0c5496056c19d1b72cc9f599ef95a9ae2dde41d3` | 5390 B |
| `ruby` | 3.3.10-r1 | `7707485bb405ff7e59ec42611546605c0ceb0aa9795ce9a5b5db8ab7c22ff425` | 2847 B |

The `data.tar.gz` of each ipk was unpacked into `files/`; the opkg metadata
those packages also carry was left out, so nothing is registered in opkg's
database. Total: 78 files under `usr/lib/ruby`, 1.7 MB, plus
`usr/bin/ruby`, `usr/lib/libruby.so.3.3.10`, `usr/lib/libyaml-0.so.2.0.9`.

## Cross-check against a known-good install

The router this targets already runs the same package set from the same feed:

```
$ ruby -v
ruby 3.3.10 (2025-10-23 revision 343ea05002) [aarch64-linux-gnu]
$ find /usr/lib/ruby -type f | wc -l
78
$ ruby -ryaml -e 'puts YAML.class'
Module
```

`files/` carries exactly those 78 files, so the overlay reproduces a
configuration that is already known to work with OpenClash.

## Runtime dependencies, and why they are in `ax3000t.config`

Upstream `libruby3.3` declares `Depends: libc, libpthread, librt, libgmp10,
zlib`, and the ELF `DT_NEEDED` entries are `libc.so`, `libgcc_s.so.1`,
`libgmp.so.10`, `libruby.so.3.3`, `libz.so.1`. `libpthread`/`librt` are virtual
and provided by musl, but `libgmp10` and `zlib` are real packages, so both are
selected explicitly in `ax3000t.config`. They are small and compile quickly.

## Two fragile details, both asserted in the build

1. **Symlinks.** `libruby.so.3.3 -> libruby.so.3.3.10` and
   `libyaml-0.so.2 -> libyaml-0.so.2.0.9` are required for linking at runtime,
   and a symlink cannot be created through every upload path. The workflow
   asserts them with `test -L` so a broken upload fails the build instead of
   shipping a ruby that cannot start.
2. **The shim.** `/usr/bin/ruby` is a 151-byte shell script that execs
   `/usr/lib/ruby/ruby3.3-bin`; the workflow asserts both, and that the shim
   still mentions `ruby3.3-bin`.

## Updating

Bump `ruby` in the feed, re-download the eleven ipks, verify each against the
`SHA256sum` field of the feed's `Packages` index, re-unpack into `files/`, and
refresh the table above. The build will fail loudly if the file set or the
symlinks no longer line up.

[run 35431786668]: https://github.com/KKKKeybird/ax3000t-istoreos-builder/actions/runs/35431786668
