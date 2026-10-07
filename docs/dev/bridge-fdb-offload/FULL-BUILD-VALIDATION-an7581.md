# PonWrt AN7581 full-build validation — four bridge-FDB-offload patches

**Verdict: SUCCESS.** Full OpenWrt firmware build on the build server, exit code 0, no errors,
no warnings, no OOM. All four patches (931–934) went through the target's quilt patch flow,
compiled, linked and packaged into the shipped images.

| | |
|---|---|
| Host | `10.0.0.108`, user `debian` (Debian 13.7, kernel 6.12.107+deb13-amd64) |
| CPU / RAM / swap | 4 cores / 7.7 GiB / 6.2 GiB (pre-existing swapfile, not added by this run) |
| Disk | `/` 110 GB, 46 GB free before, 13 GB free after |
| Repo | `https://github.com/Kitsune2077/ponwrt.git`, `--depth 1`, HEAD `675bcd29df86431bc093b34206b779e9dccf15f4` |
| Tree | `/home/debian/ponwrt` |
| Start / end (UTC) | 2026-10-07 03:09:49 → 06:24:52 |
| Wall time | 11 703 s = **3 h 15 min** |
| Command | detached `make -j4`, log `~/ponwrt/build.log` |
| Exit | `MAKE_EXIT=0` |
| Artifacts | 22 `.itb` + manifest/profiles/sha256sums, 334 MB, all 29 sha256 checks OK |

## 1. Recon

- `df -h /` → 110 G, 59 G used, **46 G free** before the build (13 G free after).
- `free -g` → 7 GiB RAM, 6 GiB swap already active (`swapon --show` unprivileged is absent from
  PATH, got it via sudo; the swapfile pre-existed, so no new swapfile was needed and none was added).
- `nproc` → 4.
- A **stale `~/ponwrt` from 2026-09-30 already existed** and did *not* contain 931–934. Its resolved
  absolute path was verified (`readlink -f` → `/home/debian/ponwrt`) before `rm -rf`, then the
  requested shallow clone was made. `~/kbuild` (8.9 GB) was left untouched.
- No dmesg OOM / "killed process" during the whole run. Peak load ≈ 7.3; swap usage peaked at 163 MiB.

## 2. Dependencies installed

One `apt-get install -y --no-install-recommends` transaction (after `apt-get update`), no full upgrade.
The requested list went in as-is plus two additions:

- **`python3-setuptools`** — required by the build's own prereq check (`include/u-boot.mk:41`). The
  very first `make` attempt died after 11 s with
  `Checking 'python3-setuptools'... failed` / `u-boot: Please install the Python3 setuptools module`.
  Log preserved as `~/ponwrt/build.attempt1-prereq.log`.
- **`squashfs-tools`** — listed in the repo README compile section and needed for the squashfs
  rootfs; it was the only one of the two not already present.

Nothing in the requested list was unavailable on Debian 13. Installed and verified: clang 19.1.7,
llvm, lld, gawk, gettext, libncurses-dev, python3 + python3-pyelftools, rsync, unzip, zlib1g-dev,
file, wget, git, subversion, swig, texinfo, uglifyjs, upx-ucl, xxd, zstd, cpio,
device-tree-compiler, ecj, fastjar, gperf, bison, flex, libelf-dev, libssl-dev, autoconf, automake,
libtool, pkgconf, ninja-build, cmake, patch, build-essential (gcc 14.2.0).

## 3. Clone + patches

```
git clone --depth 1 https://github.com/Kitsune2077/ponwrt.git ~/ponwrt     # exit 0, 4.4 s
```

The four patches are present and their md5s match the Windows tree byte-for-byte:

| patch | md5 |
|---|---|
| 931-net-airoha-ppe-add-bridge-FDB-offload-table.patch | `608b3216d7449a2ceab763a764d717f9` |
| 932-net-airoha-offload-bridge-ports-via-switchdev.patch | `a438a8c68836e9517df46dd3e5ead5e6` |
| 933-net-airoha-report-a-port-parent-id-for-bridge-offload.patch | `cde28d46a45d28f515431c57d13fe418` |
| 934-net-airoha-inspect-bridge-FDB-entries-held-by-PPE.patch | `63740b92849cfba5c67650b487766b02` |

## 4. Feeds

`./scripts/feeds update -a` → exit 0; `./scripts/feeds install -a` → exit 0; 294 MB of feeds.
Only benign `WARNING: No feed for package 'bmx7' / 'bmx7-json'` messages.

## 5. Configure (exactly the CI flow)

`.github/workflows/build-ponwrt.yml` lines 96–99 confirm:

```sh
./scripts/kconfig.pl + configs/an7581.config configs/release.config > .config   # exit 0
make defconfig                                                                  # exit 0
```

`make defconfig` prints pre-existing `recursive dependency detected` errors for `PACKAGE_qt5*` in
`tmp/.config-package.in` — upstream ImmortalWrt noise, does not fail the build.

### Key symbols

The `CONFIG_NET_AIROHA` / `CONFIG_NET_DSA` / `CONFIG_PCS_*` symbols live in the target kernel config,
not in the top-level `.config`. In the real kernel `.config` actually used
(`build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-6.18.52/.config`, taken verbatim
from `target/linux/airoha/an7581/config-6.18`):

| symbol | value |
|---|---|
| `CONFIG_NET_AIROHA` | **`=y` (built-in — matches CI; not `=m`)** |
| `CONFIG_NET_AIROHA_NPU` | `=y` |
| `CONFIG_NET_DSA` | `=y` |
| `CONFIG_NET_DSA_MT7530` | `=y` |
| `CONFIG_PCS_AIROHA` | `=y` |
| `CONFIG_PCS_AIROHA_AN7581` | `=y` |
| `CONFIG_PCS_AIROHA_AN7583` | not set |
| `CONFIG_PHYLINK` | `=y` |

Nothing was silently changed or overridden. `airoha-eth.ko` appears in the kernel's `modules.builtin`
list, which independently confirms `=y`.

## 6. Patch application — positive verification

`build.log` is OpenWrt's default quiet output and by design contains no per-patch "Applying" lines, so
verification was done against the prepped sources instead.

The quilt flow left `airoha_eth.c/.orig`, `airoha_eth.h/.orig`, `airoha_ppe.c/.orig`,
`airoha_regs.h/.orig`, `airoha_npu.c/.orig` in
`build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-6.18.52/drivers/net/ethernet/airoha/`.
Every added line of every hunk of each patch was machine-checked against the prepped tree:

| patch | added lines checked | missing |
|---|---|---|
| 931 | 251 | **0** |
| 932 | 94 | **0** |
| 933 | 45 | **0** |
| 934 | 95 | **0** |

No rejects, no fuzz, no reversed hunks; patch files themselves unchanged (md5s still identical).
Introduced code present in the prepped tree:

```
airoha_ppe.c:1420  int airoha_ppe_bridge_fdb_update(...)          (931/932)
airoha_ppe.c:1246  airoha_ppe_bridge_fdb_flush(...)               (931)
airoha_ppe.c:1287  airoha_ppe_bridge_fdb_promote(...)             (931)
airoha_eth.c:4085  .ndo_get_port_parent_id = airoha_get_port_parent_id,   (933)
airoha_eth.c:4201  switchdev_bridge_port_offload(...)                     (932)
airoha_eth.c:4234  NETDEV_PRECHANGEUPPER                                  (932)
airoha_eth.c:4242  NETDEV_CHANGEUPPER                                    (932)
```

## 7. modpost / link / packaging

Kernel linked clean at 12:36 local (16 min into the target stage), zero warnings in `build.log`
(`grep -ic warning` = 0, `error` = 0, `airoha` = 9 lines, all ordinary `make[3] -C ...` progress lines).

```
$ nm vmlinux
ffffffc0805e3128 t airoha_get_port_parent_id
ffffffc0805ef320 t airoha_ppe_bridge_fdb_promote
ffffffc0805f17e0 T airoha_ppe_bridge_fdb_update
```

The **shipped** image was verified too, not just the build tree: `ponwrt-airoha-an7581-fiberhome_hg5382a-squashfs-sysupgrade.itb`
was parsed as a FIT and its `kernel-1` node extracted (gzip, 5 900 650 → 13 824 008 bytes):

```
$ strings extracted-kernel | grep airoha_ppe_bridge_fdb
tairoha_ppe_bridge_fdb_promote
Tairoha_ppe_bridge_fdb_update
```

FIT contents: `kernel-1` (ARM64 OpenWrt Linux-6.18.52, load 0x8c000000), `fdt-1` (fiberhome_hg5382a DTB,
21 264 B, containing `ethernet@1fb64000` / `airoha,an7581-xpon-mac`, `airoha,an7581-pcs-eth` nodes),
`rootfs-1` (8 478 720 B squashfs). So patch → driver → vmlinux → FIT packaging is complete end to end.

## 8. Artifacts — `~/ponwrt/bin/targets/airoha/an7581/` (334 MB total)

| file | bytes |
|---|---|
| ponwrt-airoha-an7581-fiberhome_hg5382a-squashfs-sysupgrade.itb | 14 409 992 |
| ponwrt-airoha-an7581-fiberhome_hg5382a-initramfs-recovery.itb | 12 189 696 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-ct-squashfs-sysupgrade.itb | 16 884 013 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-ct-initramfs-recovery.itb | 14 548 992 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-ct-usb-sfp-squashfs-sysupgrade.itb | 16 884 021 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-ct-usb-sfp-initramfs-recovery.itb | 14 548 992 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-cu-squashfs-sysupgrade.itb | 16 879 917 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-cu-initramfs-recovery.itb | 14 548 992 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-cu-usb-sfp-squashfs-sysupgrade.itb | 16 879 925 |
| ponwrt-airoha-an7581-fiberhome_hg5585f-cu-usb-sfp-initramfs-recovery.itb | 14 548 992 |
| ponwrt-airoha-an7581-gemtek_xg2010g-squashfs-sysupgrade.itb | 14 479 618 |
| ponwrt-airoha-an7581-gemtek_xg2010g-initramfs-recovery.itb | 12 189 696 |
| ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-squashfs-sysupgrade.itb | 14 819 629 |
| ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-initramfs-recovery.itb | 12 582 912 |
| ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-usb-sfp-squashfs-sysupgrade.itb | 14 819 637 |
| ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-usb-sfp-initramfs-recovery.itb | 12 582 912 |
| ponwrt-airoha-an7581-nokia_xg-040g-tf-ubi-squashfs-sysupgrade.itb | 14 455 054 |
| ponwrt-airoha-an7581-nokia_xg-040g-tf-ubi-initramfs-recovery.itb | 12 189 696 |
| ponwrt-airoha-an7581-unionman_ung00a-squashfs-sysupgrade.itb | 14 455 044 |
| ponwrt-airoha-an7581-unionman_ung00a-initramfs-recovery.itb | 12 189 696 |
| ponwrt-airoha-an7581-znxt_zn504xg-d-squashfs-sysupgrade.itb | 14 455 042 |
| ponwrt-airoha-an7581-znxt_zn504xg-d-initramfs-recovery.itb | 12 189 696 |
| ponwrt-airoha-an7581-znxt_zn515xg-d-squashfs-sysupgrade.itb | 16 937 218 |
| ponwrt-airoha-an7581-znxt_zn515xg-d-initramfs-recovery.itb | 14 548 992 |
| ponwrt-airoha-an7581.manifest | 5 934 |
| profiles.json | 14 330 |
| sha256sums | 3 577 |

`sha256sum -c sha256sums` → 29/29 OK. `version.buildinfo` = `r0-675bcd2`.

## 9. airoha-related errors / warnings

**None.** Zero occurrences of `error` or `warning` in `build.log`; the only nine `airoha` lines are
ordinary progress lines (`package/boot/arm-trusted-firmware-airoha`, `feeds/pon_drivers/airoha-xpon`,
`feeds/pon_userspace/airoha-pon-daemon|ponctl|pon-debug`, `package/boot/uboot-airoha`).
No patch rejection, no modpost complaint, no undefined symbol, no OOM.

## 10. Reproduce

On `10.0.0.108` (`ssh debian@10.0.0.108`):

```sh
sudo apt-get install -y --no-install-recommends ... python3-setuptools squashfs-tools   # see README_zh.md §编译
git clone --depth 1 https://github.com/Kitsune2077/ponwrt.git ~/ponwrt
cd ~/ponwrt
./scripts/feeds update -a && ./scripts/feeds install -a
./scripts/kconfig.pl + configs/an7581.config configs/release.config > .config
make defconfig
setsid nohup make -j4 > ~/ponwrt/build.log 2>&1 &
```

Logs and helper scripts (all on the server, `~/`):

| path | purpose |
|---|---|
| `~/ponwrt/build.log` | canonical full build log (exit marker `MAKE_EXIT=0`, `WALL_SECONDS=11703`) |
| `~/ponwrt/build.attempt1-prereq.log` | aborted first attempt (missing python3-setuptools) |
| `~/feeds.log`, `~/apt-install.log` | feeds and dependency install logs |
| `~/checkdeps.sh`, `~/clone.sh`, `~/configure.sh`, `~/deepverify.sh` | recon/deps, clone+md5, configure, hunk-level patch verification |
| `~/poll.sh`, `~/waitdone.sh`, `~/watch.sh`, `~/kcheck.sh`, `~/final.sh` | progress polling, kernel/symbol checks, final verification |
| `~/fitparse.py`, `~/fitrun.sh` | FIT (`.itb`) parser used to extract and symbol-check the shipped kernel |

Local copies of the logs: `build-server-an7581.log`, `build-server-an7581.attempt1-prereq.log`
in the workspace root.
