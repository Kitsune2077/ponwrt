# Bridge FDB offload — build verification (Debian 13, 10.0.0.108)

Status of the **draft** patches in this directory, as verified on a real build
machine. Keep this file next to `README.md`: `README.md` describes the design,
this file records what has actually been *proven* by a compiler.

## 1. What was verified

Build host: Debian 13.7 (trixie), 4 cores, 7 GB RAM, `gcc-aarch64-linux-gnu`
14.2.0, kernel source `linux-6.18.52` from `cdn.kernel.org`.

| Item | Result |
| --- | --- |
| Patch stack applied | `generic/files` overlay + `generic/backport-6.18` 175/175 + `generic/pending-6.18` 212/212 + `generic/hack-6.18` 71/71 + `airoha/patches-6.18` **163/163** = 621/621, **0 failures, 0 `.rej`** |
| `0001` | `git apply --check` rc=0 |
| `0002` (md5 `a438a8c68836e9517df46dd3e5ead5e6`) | `git apply --check` rc=0, no fuzz, no hand-rebasing |
| Driver compile (`0001`+`0002`), `NET_AIROHA=m` | **`RC=0`, zero `error:`** |
| Driver compile, `NET_AIROHA=y` (built-in) | **`RC=0`**, same two warnings |
| Objects produced | `airoha_ppe.o`, `airoha_eth.o`, `airoha_npu.o`, `airoha_ppe_debugfs.o`, `pcs-airoha-common.o`, `pcs-an7581.o`, `pcs-an7583.o` |
| New undefined symbols | 11, **all** resolve to `EXPORT_SYMBOL*` in-tree (`switchdev_bridge_port_offload/unoffload`, `register/unregister_switchdev[_blocking]_notifier`, `register/unregister_netdevice_notifier`, …); `airoha_ppe_bridge_fdb_update` is an intra-module `T` reference ⇒ **zero unresolved symbols** |
| Warnings caused by the drafts | **none** (proven by rebuilding the same tree with the drafts removed) |

`0003`/`0004` did not exist while this verification ran, so they are **not**
covered by it yet.

## 2. Corrections to earlier claims

* **"9 airoha patches fail on vanilla 6.18.52" — wrong.** They fail only when
  OpenWrt's generic kernel base is missing. With the stack below, all 163 apply.
* **`select FWNODE_PCS` in `drivers/net/pcs/airoha/Kconfig` is a dead
  reference — confirmed.** The symbol is defined neither in 6.18.52 nor anywhere
  in the generic 6.18 patch set; kconfig silently ignores an undefined `select`
  target, so it neither warns nor breaks the build. The generic PCS *provider*
  headers (`include/linux/pcs/pcs.h`, `pcs-provider.h`) come from
  `generic/pending-6.18/737-03-…`, which is why a bare kernel tree cannot
  compile the driver at all. Suggested cleanup: drop or rename the `select`.
* **`CONFIG_NET_AIROHA` can be silently capped at `=m`.** `net/dsa/Kconfig` has
  `depends on HSR || HSR=n`, and the arm64 defconfig ships `CONFIG_HSR=m`, so the
  expression evaluates to `m`, capping `NET_DSA` — and
  `drivers/net/ethernet/airoha/Kconfig`'s `depends on NET_DSA || !NET_DSA` then
  caps `NET_AIROHA` as well. `scripts/config -e NET_DSA -e NET_AIROHA` alone is
  not enough; `-d HSR` is required (see the recipe).

## 3. Reproducible recipe (exact commands used)

```sh
K=~/kbuild/linux-6.18.52      # vanilla linux-6.18.52, git-initialised
P=~/kbuild/patches            # patch dirs copied out of the repo
cp -fpR $P/files/. $K/                                      # (0) target/linux/generic/files overlay
bash ~/kbuild/apply_series.sh $K $P/generic/backport-6.18   # (1)
bash ~/kbuild/apply_series.sh $K $P/generic/pending-6.18    # (2)
bash ~/kbuild/apply_series.sh $K $P/generic/hack-6.18       # (3)
bash ~/kbuild/apply_series.sh $K $P/patches-6.18            # (4) target airoha series
bash ~/kbuild/apply_series.sh $K $P/fdb-offload             # (5) bridge-fdb-offload 0001..0004
# order fixed by include/quilt.mk:93-105: files -> backport -> pending -> hack -> target
cd $K
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
scripts/config --file .config -e COMPILE_TEST -e NET_VENDOR_AIROHA -e NET_AIROHA \
  -e NET_AIROHA_NPU -e NET_AIROHA_FLOW_STATS -e PCS_AIROHA -e PCS_AIROHA_AN7581 \
  -e PCS_AIROHA_AN7583 -e PHYLINK -e PAGE_POOL -e DEBUG_FS -e NET_SWITCHDEV -e IPV6 -e BRIDGE
scripts/config --file .config -d HSR -e NET_DSA -e NET_AIROHA   # -d HSR is REQUIRED (see §2)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) prepare modules_prepare
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) -k drivers/net/ethernet/airoha/ drivers/net/pcs/airoha/
```

Notes: `apply_series.sh <tree> <patchdir>` tries `git apply` (atomic) and falls
back to a `patch -p1 --dry-run` gate, so a failing patch leaves neither partial
hunks nor `.rej` files. If the build tree is a `git worktree`, restore the exec
bits afterwards or `scripts/cc-version.sh` fails.

## 4. Pre-existing warnings worth fixing (not ours)

Both come from patches already in `target/linux/airoha/patches-6.18/` and are
reproducible without the drafts:

1. `drivers/net/ethernet/airoha/airoha_ppe_debugfs.c:217` — from
   `925-net-airoha-add-PON-PPE-offload-metadata.patch`:
   `seq_printf(m, "ppe%u_gdm2_default_cpu_port: %u\n", i,` where the argument is
   `unsigned long` (`DFT_CPORT_MASK()` is `GENMASK()`-based) ⇒ change the second
   `%u` to `%lu`, or cast the argument to `(u32)`.
2. `drivers/net/pcs/airoha/pcs-airoha-common.c:1426` — from
   `606-net-pcs-airoha-fix-an7583-port-count.patch`:
   `"invalid PCS index %d\n", index` where `index` is `u64` ⇒ `%lld`, or cast to
   `(int)`. (The check is duplicated at 1422-1424, which is why gcc points at the
   second copy.)

## 5. Not verified yet

* `0003` (port parent id) and `0004` (FDB refresh) — not compiled.
* Any **runtime** behaviour: no board has run these patches. Everything the main
  `README.md` says about hardware behaviour remains a hypothesis.
* A full OpenWrt image build (`make world`) — out of scope for this pass; the
  compile check only covered `drivers/net/ethernet/airoha/` and
  `drivers/net/pcs/airoha/`.
