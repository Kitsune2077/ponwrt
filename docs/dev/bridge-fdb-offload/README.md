# Bridge FDB offload to the Airoha PPE (Plan A)

Staging area for four **draft** kernel patches that teach the AN7581 PPE to
forward bridged traffic (including PPPoE and other non-IP L2 traffic) in
hardware instead of letting the Linux software bridge forward every frame.

The apply order is the file order:

```
docs/dev/bridge-fdb-offload/
├── 0001-net-airoha-ppe-add-bridge-FDB-offload-table.patch
│       (airoha_eth.h, airoha_ppe.c)  bridge FDB table -> PPE offload
├── 0002-net-airoha-offload-bridge-ports-via-switchdev.patch
│       (airoha_eth.c)               netdev/switchdev notifiers
├── 0003-net-airoha-report-a-port-parent-id-for-bridge-offload.patch
│       (airoha_eth.c, airoha_eth.h) ndo_get_port_parent_id -> hwdom
├── 0004-net-airoha-inspect-bridge-FDB-entries-held-by-PPE.patch
│       (airoha_eth.h, airoha_ppe.c)  counting-only FDB ageing worker
└── README.md
```

## 0. Why these patches are *not* in `target/linux/airoha/patches-6.18/`

The patches in this directory are **not compiled and not tested**, and they are
**deliberately not installed** into the build tree. Dropping them into
`target/linux/airoha/patches-6.18/` (as `931-…`/`932-…`) would make every
GitHub Actions build fail if a hunk does not apply or if the code does not
compile, which would break the user's firmware builds for everybody. They are
kept here so that they can be reviewed, applied by hand, and only then promoted
into the patch series once they have been built and tested on hardware.

**Honesty statement:** this work is a *design + reviewable draft*. It has never
been compiled (no cross toolchain was available where it was written) and never
run on a device. At the time of writing, a build of the whole series **is being
attempted on a separate Debian 13 machine** by the same effort; until that
reports back, "not compiled" stays true for these four patches. The only
mechanical validation performed is that all four patches apply cleanly with
`git apply` against the exact post-patch driver state produced by
`linux-6.18.52 + target/linux/generic/{backport,pending,hack}-6.18 +
target/linux/airoha/patches-6.18` (see §5). Treat every claim about hardware
behaviour below as a hypothesis that must be verified on a board before these
patches are trusted.

## 1. Design

### 1.1 The mismatch: FDB key vs PPE key

* The Linux bridge only tracks `destination MAC (+VID) -> egress port`.
* The PPE L2B/FOE hash of the AN7581 is keyed on the **whole `(source MAC,
  destination MAC)` pair** of a flow (see `airoha_ppe_foe_get_entry_hash()` and
  `airoha_ppe_foe_set_bridge_addrs()`).

So the FDB alone can never produce a complete PPE key. This patch set therefore:

1. keeps a copy of the FDB in the driver, keyed on `destination MAC + VID`
   (`struct airoha_fdb_key`, `struct airoha_fdb_entry`, `ppe->fdb_table`);
2. resolves the **missing source MAC** from the first frame of every flow in the
   RX slow path, where hardware has already told us both MACs.

### 1.2 RX slow path promotion

For a bridged frame the PPE installs a slow-path entry in the hash slot
`AIROHA_RXD4_FOE_ENTRY` and hands the frame to the CPU. `airoha_ppe_check_skb()`
runs for those frames and, after `airoha_ppe_foe_insert_entry()`:

* `AIROHA_FOE_SLOWPATH_HANDLED` – an existing netfilter L2/L3 flow matched, done.
* `AIROHA_FOE_SLOWPATH_BRIDGE` – the hash slot holds an **unbound, native L2B
  entry** (`PPE_PKT_TYPE_BRIDGE`, AN7581 only) and no `(src, dst)` flow was
  found in `ppe->l2_flows`. `airoha_ppe_bridge_fdb_promote()` then

  1. looks the **destination MAC** (`VID 0`, untagged only) up in
     `ppe->fdb_table` to obtain the egress netdev,
  2. builds a `PPE_PKT_TYPE_BRIDGE` template with the existing
     `airoha_ppe_foe_entry_prepare()` (the PON GEM/T-CONT resolution included),
  3. registers it through the existing `airoha_ppe_foe_flow_commit_entry()`
     (which routes BRIDGE entries into `ppe->l2_flows`) and commits the
     per-flow entry for this RX hash with
     `airoha_ppe_foe_commit_subflow_entry()`.

The important property reused here is the one introduced by
`930-net-airoha-fix-native-l2b-entry-layout.patch`: for AN7581 BRIDGE entries,
`airoha_ppe_foe_commit_subflow_entry()` keeps the **hardware-learned key**
(source MAC, ingress VLAN, native `l2b.key`) and only copies the **egress
control** (`data`, `ib2`, `vlan1`, `vlan2`, `etype`) from the driver template.
The driver therefore never has to construct the L2B key itself: the RX slow
path already carries it, and only the "where does this frame have to go"
information comes from the FDB lookup.

Locks: `flow_offload_mutex` (needed because `airoha_ppe_foe_entry_prepare()`
asserts it for the PON mapping) is taken with `mutex_trylock()` because this
runs in the RX path, and `ppe_lock` protects `ppe->fdb_table`, `ppe->l2_flows`
and the FOE commit. Lock order stays `flow_offload_mutex -> ppe_lock`, the same
order the TC offload path uses.

Since FDB events can arrive from softirq (the bridge notifies from its RX
path), `airoha_ppe_bridge_fdb_update()` never sleeps: it uses
`rhashtable_lookup_insert_fast()`/`rhashtable_remove_fast()` (documented as
atomic-context safe) with `GFP_ATOMIC` allocations, and, unlike
`airoha_ppe_remove_egress_flows()`, it must not call `rhashtable_walk_enter()`
(that one cannot run in softirq). Each FDB entry therefore keeps a list of the
L2 flows promoted from it (`fdb->flows`, linked through the new
`struct airoha_flow_table_entry::fdb_node`), so removal is O(flows per
destination) and never walks a rhashtable.

### 1.3 What stays in software (v1 scope)

| Case | Behaviour | Reason |
| --- | --- | --- |
| Untagged unicast, learned destination | **offloaded** | egress needs no tag rewrite |
| `vid != 0` FDB entry | tracked, `AIROHA_FDB_F_NO_OFFLOAD`, not offloaded | tag push/pop on the native L2B entry unverified; `FLOW_ACTION_VLAN_POP` is a no-op in this driver |
| 802.1Q/802.1ad ingress frame | not promoted (counter `fdb_stats.tagged`) | same, the strip case cannot be expressed yet |
| broadcast/multicast/unknown unicast | not offloaded (flooding) | multicast replication (MDB, `AIROHA_FOE_IB2_MULTICAST`) not implemented |
| local/self FDB entries (`is_local`) | ignored | belong to the bridge itself |
| non-airoha egress port (DSA user port, VLAN device, wlan, LAG) | ignored | `airoha_is_valid_gdm_dev()` check; stacked ports need `switchdev_handle_fdb_event_to_device()` |
| frame arriving on the entry's own egress port | not promoted | the software bridge does not forward back out of the ingress port |
| `prio`/PCP of a VLAN push | not represented | the offload path drops `act->vlan.prio`; `AIROHA_FOE_IB2_PCP` exists in the FOE |

### 1.4 Data structures

```c
struct airoha_fdb_key {          /* rhashtable key, 8 bytes */
        u8 addr[ETH_ALEN];       /* destination MAC the bridge learned */
        u16 vid;                 /* bridge VLAN of the FDB entry */
};

struct airoha_fdb_entry {
        struct rhash_head node;  /* ppe->fdb_table */
        struct list_head list;   /* ppe->fdb_list, teardown */
        struct list_head flows;  /* promoted L2 flows (fdb_node) */
        struct airoha_fdb_key key;
        struct net_device *egress;   /* bridge port, refcounted */
        unsigned long flags;         /* AIROHA_FDB_F_* */
};
```

`struct airoha_ppe` gains `fdb_table`, `fdb_list` and the counters
`fdb_stats.promoted/no_entry/tagged` (currently only visible through a debugger
or a follow-up debugfs file, see §4.4).

## 2. Switchdev plumbing (patch 2)

* `airoha_netdevice_event()` handles `NETDEV_CHANGEUPPER` (link) and
  `NETDEV_PRECHANGEUPPER` (unlink) for airoha netdevs whose new upper device is
  a bridge master, calling `switchdev_bridge_port_offload(dev, dev, NULL,
  &airoha_switchdev_nb, &airoha_switchdev_blocking_nb, false, extack)` and
  `switchdev_bridge_port_unoffload()` respectively. Unoffload happens at
  `PRECHANGEUPPER` on purpose: the bridge only accepts
  `SWITCHDEV_BRPORT_UNOFFLOADED` while the netdev is still a bridge port
  (`br_port_get_rtnl()` lookup in `net/bridge/br.c`), the same ordering ocelot
  uses.
* The atomic and blocking notifier blocks are registered **globally**
  (`register_switchdev_notifier()` / `register_switchdev_blocking_notifier()`)
  in `airoha_probe()`, because `FDB_ADD/DEL_TO_DEVICE` is broadcast on the
  global chain (`call_switchdev_notifiers()` from `br_switchdev_fdb_notify()`);
  the per-port blocks passed to `switchdev_bridge_port_offload()` are only used
  by the bridge to replay its state. ocelot does both as well.
* `airoha_switchdev_event()` resolves `info.dev` (the bridge port the address
  was learned on = the egress port) back to `struct airoha_gdm_dev` and calls
  `airoha_ppe_bridge_fdb_update()`; `is_local` entries are ignored.
* The blocking block deliberately does nothing yet (VLAN membership and MDB
  objects are ignored): that is exactly why v1 only offloads untagged unicast
  destinations.

### 2.1 Patch 3: the port parent id, so the bridge can assign a hwdom

**Problem.** `switchdev_bridge_port_offload()` alone is not enough for the
bridge to treat a port as offloaded. `br_switchdev_port_offload()`
(`net/bridge/br_switchdev.c:837`) starts with

```c
err = netif_get_port_parent_id(dev, &ppid, false);   /* line 847 */
if (err)
        return err;
err = nbp_switchdev_add(p, ppid, tx_fwd_offload, extack);
```

and `netif_get_port_parent_id()` (`net/core/dev.c:10074`) only succeeds if the
netdev has a devlink switch port or an `ndo_get_port_parent_id`. An airoha GDM
netdev has neither, so the call failed with `-EOPNOTSUPP`, no port parent id
was recorded, and `nbp_switchdev_add()` never ran. Consequences, all verified
by reading the bridge code:

* `nbp_switchdev_hwdom_set()` (`br_switchdev.c:203`) never assigns a `hwdom`,
  so `nbp_switchdev_allowed_egress()` (`br_switchdev.c:67`) treats every
  offloaded port as "not allowed" and `skb->offload_fwd_mark` masking stays
  off — the software bridge can forward a frame the PPE has already forwarded
  (duplicate frames);
* `nbp_switchdev_sync_objs()` (`br_switchdev.c:782`) is never reached, so the
  bridge never replays its FDB over `SWITCHDEV_FDB_ADD_TO_DEVICE` at port
  join time. Patch 2 still receives *runtime* FDB events, because
  `br_switchdev_fdb_notify()` broadcasts them on the global chain, but
  addresses learned before the port was offloaded were invisible to the
  driver.

**What the patch does.** Implements `ndo_get_port_parent_id` for the airoha
netdevs and registers it in `airoha_netdev_ops`:

* the id is built **once** in `airoha_probe()` and stored in
  `struct airoha_eth` (`switch_id[]`, `switch_id_len`), so it cannot change
  while the device is alive;
* for the per-controller part of the id, the name of the ethernet platform
  device is used (`dev_name()`, e.g. `1e660000.ethernet` on the AN7581). The
  name carries the unit address of the controller in the SoC address space, so
  it is unique between controllers on the same system — which is exactly what
  Documentation/networking/switchdev.rst:103 ("Switch ID") requires: the same
  id for every port of a switch, unique between switches on one system;
* every airoha netdev reports the same id (all GDM ports of one controller
  share one PPE), so `nbp_switchdev_hwdom_set()` gives them one shared hwdom
  and `netdev_phys_item_id_same()` keeps working across a re-offload;
* the id has a `"airoha:"` prefix to namespace it against other switchdev
  drivers; `AIROHA_SWITCH_ID_LEN` is 24 bytes (well under
  `MAX_PHYS_ITEM_ID_LEN` = 32) and `airoha_probe()` refuses the device with
  `-ENAMETOOLONG` if the name does not fit, instead of truncating the id and
  silently collapsing two controllers into one hwdom.

This mirrors what sparx5 and lan966x do (`ppid->id_len = sizeof(base_mac)`),
but uses a string that is valid under the *real* constraint instead of a MAC
address, which the driver does not have per controller (each GDM port gets its
own `dev_addr` from the DTS or a random one, and those differ per port).

Nothing changes for a port that is not in a bridge: the callback is only ever
called from `netif_get_port_parent_id()`, i.e. from the bridge, from
`dev_get_port_parent_id()`/rtnetlink and from `phys_switch_id` in sysfs.

**Remains unverified.** That `dev_name(&pdev->dev)` is stable and unique on
this SoC (it is on every DT-based platform device, but not checked on the
AN7581 DTS in this tree); that nothing else on the device already publishes the
same `"airoha:*"` id; and, most importantly, that the resulting
`offload_fwd_mark` masking does not drop frames the PPE did *not* actually
forward — that needs a board, see §4.5.

### 2.2 Patch 4: the FDB ageing problem — counting only, deliberately

**Why patch 1 alone is not enough.** `br_fdb_cleanup()`
(`net/bridge/br_fdb.c:543`) keeps an entry alive only while

```c
if (test_bit(BR_FDB_STATIC, &f->flags) ||
    test_bit(BR_FDB_ADDED_BY_EXT_LEARN, &f->flags)) {
        ...
        continue;              /* static / ext-learn: no ageing */
}
if (time_after(this_timer, now))          /* this_timer = f->updated + delay */
        work_delay = min(work_delay, this_timer - now);
else
        fdb_delete(br, f, true);          /* everything else is deleted */
```

with `delay = hold_time(br)` (300 s by default). `f->updated` is only bumped
when the bridge itself sees a frame from that MAC (`br_fdb_update()`), and
`BR_FDB_OFFLOADED` is *not* consulted here at all — a dynamic entry with
`BR_FDB_OFFLOADED` is still aged out. A flow the PPE forwards never reaches
the bridge, so `f->updated` stays where it was, the entry is deleted after the
ageing time, patch 1 tears the promoted FOE down
(`airoha_ppe_bridge_fdb_update(add = false)`), traffic falls back to the
software bridge, is relearned and is offloaded again. The expected symptom is
a hiccup of roughly one ageing period per idle-ish destination, which has to
be measured on a board (§4.2).

**What the patch does — and, prominently, what it does NOT do.**

> **This patch does not refresh the bridge FDB entry. It only counts and logs
> the entries that would need refreshing.** The refresh cannot be done
> correctly from a driver in this kernel, and no API was invented for it.

The reasoning, all verified against the reference tree:

* `switchdev_fdb_notify()` / `switchdev_fdb_notify_struct()` do **not exist**
  in this kernel. A `grep` over the whole tree finds the enum value
  `SWITCHDEV_FDB_ADD_TO_BRIDGE` (`include/net/switchdev.h:213`) but only one
  sender (`drivers/net/ethernet/marvell/prestera`, which calls
  `call_switchdev_notifiers(SWITCHDEV_FDB_ADD_TO_BRIDGE, dev, ...)`) and **no
  consumer at all** — no bridge, vxlan or DSA notifier switches on that event
  value. So sending it from airoha would be a no-op that only produces log
  noise.
* The events that *do* reach the bridge are handled in `br_switchdev_event()`;
  `SWITCHDEV_FDB_OFFLOADED` is accepted there but only maintains
  `BR_FDB_OFFLOADED` bookkeeping, which `br_fdb_cleanup()` ignores (above).
* Therefore the only way a driver could keep a non-static entry alive would be
  a new/extended bridge-side API (for example teaching the bridge to bump
  `f->updated` on a `SWITCHDEV_FDB_ADD_TO_BRIDGE`-style notification, or a
  "refresh" op), which is exactly the kind of invention the patch set must not
  do on its own.

What is implemented instead:

* `fdb_refresh_period` module parameter (uint, `0644`), **default 0 =
  disabled** — the documented safe default, because enabling it only adds log
  output and cannot fix the ageing problem;
* a `struct delayed_work` in `struct airoha_ppe`, initialised in
  `airoha_ppe_init()` and cancelled in `airoha_ppe_deinit()`, i.e. started and
  stopped with the PPE. It runs on `system_wq`, which may sleep: the walk is
  `rhashtable_walk_enter/start/next/stop/exit` over `ppe->fdb_table`, and the
  work item never runs from the RX path (`airoha_ppe_check_skb()` is
  untouched, so no new work in softirq and no sleeping there);
* for every FDB entry with at least one promoted flow, the PPE idle time is
  read through the **existing** `airoha_ppe_entry_idle_time()` helper, which
  re-validates the FOE under `ppe_lock` before reading the timestamp. An entry
  whose newest promoted flow was used less than `fdb_refresh_period` seconds
  ago is counted as "the hardware is really forwarding this, the bridge is
  about to age it out";
* the run logs a rate-limited sample line (`dev_info_ratelimited()`) plus a
  summary line (`N of M offloaded bridge entries are in use, no refresh
  available`). When the parameter is 0 the work item is never queued, so the
  default build behaves exactly like patch 3 alone;
* the work item re-arms itself with `mod_delayed_work()` only while the
  parameter is non-zero, so writing 0 stops it at the end of the current run.

**Remains unverified.** Whether the PPE idle time really distinguishes "in
use" from "idle" for a promoted `PPE_PKT_TYPE_BRIDGE` entry (it is the same
timestamp the netfilter L2 path uses, but the bridge path stores the learned
key differently, see §7.5); what `fdb_refresh_period` should be relative to
the bridge `ageing_time` (the parameter doubles as the idle threshold, which
is a simplification); and whether userspace could solve the problem instead —
`bridge fdb replace <mac> dev <port> master static` would, but that is a
configuration decision, not something a driver may impose.

Two smaller caveats, both by construction:

* the parameter is read when `airoha_ppe_init()` runs and from inside the work
  item. Setting it from 0 to a non-zero value at runtime therefore does **not**
  start the work item (there is no `module_param_cb()` setter); reload the
  module, or write a non-zero value before the driver is loaded. Writing 0 does
  stop it at the end of the current run;
* the walk is restarted or abandoned when the FDB table is rehashed under it
  (FDB events arrive from softirq, and `rhashtable_walk_next()` then returns
  `ERR_PTR(-EAGAIN)` **after rewinding the iterator**, which would double-count
  everything seen so far). The pass is abandoned with a one-line log and the
  next period retries; this is documented in the patch next to the walk.

## 3. Build

### 3.1 The base stack the patches expect (verified recipe)

The airoha patch series is **not self-contained**: `drivers/net/ethernet/airoha`
uses generic infrastructure that comes from the generic patch directories, so a
bare `linux-6.18.52` tarball is **not** a valid base and a driver built against
it fails on missing generic pieces (for example `select FWNODE_PCS` in
`drivers/net/pcs/airoha/Kconfig` is legitimate because
`include/linux/pcs/pcs-provider.h` is added by
`target/linux/generic/pending-6.18/737-03-net-pcs-implement-Firmware-node-…`,
`__field_prep()` comes from `backport-6.18/211-02-*` and `netdev_from_priv()`
from `backport-6.18/601-*`).

The base, in the order `include/quilt.mk:102-105` applies it:

1. `linux-6.18.52` (`LINUX_VERSION-6.18 = .52`)
2. `target/linux/generic/backport-6.18/*.patch` (175)
3. `target/linux/generic/pending-6.18/*.patch` (212)
4. `target/linux/generic/hack-6.18/*.patch` (71)
5. `target/linux/airoha/patches-6.18/*.patch` (163)

That state is what the four patches below were generated against and what they
are known to apply to.

### 3.2 Apply-only check (fast, no full build)

```sh
cd /path/to/ponwrt
for p in docs/dev/bridge-fdb-offload/000[1-4]-*.patch; do
        git apply --check "$p" || echo "FAILED: $p"
        git apply "$p"
done
# or, in the OpenWrt tree, install them into the target series and let quilt do it:
cp docs/dev/bridge-fdb-offload/0001-*.patch \
   target/linux/airoha/patches-6.18/931-net-airoha-ppe-add-bridge-FDB-offload-table.patch
cp docs/dev/bridge-fdb-offload/0002-*.patch \
   target/linux/airoha/patches-6.18/932-net-airoha-offload-bridge-ports-via-switchdev.patch
cp docs/dev/bridge-fdb-offload/0003-*.patch \
   target/linux/airoha/patches-6.18/933-net-airoha-report-a-port-parent-id-for-bridge-offload.patch
cp docs/dev/bridge-fdb-offload/0004-*.patch \
   target/linux/airoha/patches-6.18/934-net-airoha-inspect-bridge-FDB-entries-held-by-PPE.patch
make target/linux/prepare V=s          # applies generic + target patches, no compile
# on a failure the log names the patch; build_dir/target-*/linux-*/… holds the tree
```

The four patches must be applied **in file order**: 0001 adds the FDB table,
0002 the notifiers, 0003 the port parent id and 0004 the work item. They touch
overlapping files but disjoint regions, so each one applies on top of the
previous one and the result is byte-identical to the tree the patches were
generated from (verified, see §5).

### 3.3 Compile the kernel only

```sh
cp configs/an7581.config .config
make defconfig
make target/linux/compile V=s          # kernel + modules, no images
# a compile error is most likely in airoha_ppe.c (patches 1 and 4),
# airoha_eth.c (patches 2 and 3) or airoha_eth.h (patches 1, 3 and 4)
```

If this is the first build of the series, the likely errors to look for are
missing declarations in `airoha_eth.h` (`switch_id`, `fdb_refresh_work`), a
`dev_info_ratelimited()` prototype problem in `airoha_ppe.c`, and the
`snprintf()`/`dev_name()` combination in `airoha_probe()`.

### 3.4 Full firmware

```sh
make -j"$(nproc)"                      # images land in bin/targets/airoha/an7581/
```

or use the GitHub Actions workflow **Build PonWrt Firmware**
(`workflow_dispatch`, `build_an7581=true`) — but only after the patches are
known to apply and compile, see §0.

### 3.5 Configuration requirements

Already satisfied by the current tree, kept here as a checklist:

* `CONFIG_NET_SWITCHDEV=y` (`target/linux/generic/config-6.18`; the airoha
  target config does not override it) — needed by patches 2 and 3
* `CONFIG_BRIDGE=y`, `CONFIG_BRIDGE_VLAN_FILTERING=y` (generic config)
* `CONFIG_NET_AIROHA=y`, `CONFIG_NET_AIROHA_NPU=y`
* `CONFIG_NET_AIROHA_FLOW_STATS` is **not** set for an7581, so the per-entry
  NPU counters are unavailable; use the FOE dump below instead.
* patch 4 needs no extra option: it is a module parameter
  (`fdb_refresh_period`, default 0) and a work item on `system_wq`.

### 3.6 Building on a Debian 13 machine (in progress)

A build of the whole series is being attempted on a separate Debian 13 machine
(with the kernel only, via the four-step base stack above). This README does
not yet claim that it succeeds; when it does, the checklists in §4 are the next
step. Until then, treat the patches as reviewed-but-uncompiled drafts.

## 4. Test plan

### 4.1 Prerequisites on the device

```sh
dmesg | grep -i -e airoha -e switchdev        # probe, no -EOPNOTSUPP storm expected
ls /sys/kernel/debug/ppe/                     # entries, bind, config (CONFIG_DEBUG_FS)
```

### 4.2 Observe the bridge and the hardware

```sh
# one terminal: watch the software FDB
bridge monitor fdb

# another: create the bridge and generate traffic
# (LAN netdev names come from `openwrt,netdev-name` in the board DTS, typically
#  lan1..lan4; check `ip -br link` first)
ip link add br-lan type bridge
for i in lan1 lan2 lan3 lan4; do ip link set $i up; ip link set $i master br-lan; done
ip link set br-lan up
bridge link show                              # ports must be listed

# learn MACs (ping between two hosts on lan1/lan2), then:
bridge fdb show br br-lan | head
cat /sys/kernel/debug/ppe/entries | grep -c BRIDGE   # > 0 once flows are promoted
```

`/sys/kernel/debug/ppe/entries` decodes the `PPE_PKT_TYPE_BRIDGE` rows added by
`930-net-airoha-fix-native-l2b-entry-layout.patch`; a promoted flow shows the
hardware-learned source MAC of the flow. Expected sequence: `bridge monitor`
prints `add … dev lanX`, and shortly after the FDB lookup the same destination
appears as a BRIDGE entry.

### 4.3 Prove the CPU is no longer forwarding

```sh
# on the AP/OLT
iperf3 -s
# on a LAN host
iperf3 -c <ap-lan-ip> -t 60 -P 4

top -b -n 5 -d 1 | grep -E 'softirq|ksoftirqd|iperf'   # or: mpstat -P ALL 1
grep -E 'qdma|eth' /proc/interrupts                     # interrupt rate must stay flat
```

Then compare with the same test after `bridge fdb flush br br-lan` (or with the
patches reverted): if the offload works, throughput and CPU/interrupt numbers
decide. Also useful:

```sh
grep -c OFFLOAD /proc/net/nf_conntrack   # 0 for this feature: bridged L2 traffic
nft list ruleset                         # may be empty; FDB offload needs no nft
```

The last two commands matter as a *contrast*: this feature is not the netfilter
path, so no `nft` ruleset and no conntrack entries are involved. A bridged
PPPoE or non-IP flow cannot be offloaded by `nf_flow_table` at all, which is
the whole point of Plan A.

### 4.4 Watching the FDB counters (optional, testing aid)

`fdb_stats.promoted / no_entry / tagged` are not exported yet. For a test build,
add this to `airoha_ppe_debugfs.c` next to the other files registered in
`airoha_ppe_debugfs_init()`:

```c
static int airoha_ppe_debugfs_fdb_show(struct seq_file *m, void *private)
{
        struct airoha_ppe *ppe = m->private;

        seq_printf(m, "promoted %lu\nno_entry %lu\ntagged %lu\n",
                   READ_ONCE(ppe->fdb_stats.promoted),
                   READ_ONCE(ppe->fdb_stats.no_entry),
                   READ_ONCE(ppe->fdb_stats.tagged));
        return 0;
}
DEFINE_SHOW_ATTRIBUTE(airoha_ppe_debugfs_fdb);
/* in airoha_ppe_debugfs_init(): */
debugfs_create_file("fdb", 0444, ppe->debugfs_dir, ppe, &airoha_ppe_debugfs_fdb_fops);
```

`promoted` must increase while unicast traffic flows, `tagged` should increase
only on tagged frames, and `no_entry` counts frames whose destination is unknown
(flooding) or not offloadable.

### 4.5 What patches 3 and 4 add to the test plan

Patch 3 (port parent id) — these must be checked *before* trusting the offload,
because they can change forwarding behaviour:

```sh
# 1. the bridge must now accept the port as offloaded (no log line from patch 2)
dmesg | grep 'bridge port offload unavailable'          # must print nothing
bridge -d link show br-lan                              # hwdom / offload column set
cat /sys/class/net/lan1/phys_switch_id                  # must be identical for lan1..lan4
cat /sys/class/net/lan2/phys_switch_id                  # and stable across a reload

# 2. the FDB must be replayed at port-join time (patch 1 table, patch 2 notifier)
bridge fdb show br br-lan | wc -l
ip link set lan1 nomaster && ip link set lan1 master br-lan
# with patch 3 the entries learned before the re-join must be offloaded again
# without a new frame being sent

# 3. the risky part: masking must not drop frames
#    while hosts on lan1/lan2 talk, send from lan3 to a MAC that is NOT in the FDB
#    (e.g. a nonexistent address) and watch for a duplicate (bridge forwarding a
#    frame the PPE already forwarded) or for a silent drop
bridge monitor fdb &                                     # control: what the bridge learns
```

Patch 4 (counting only, default off):

```sh
# enable the inspection, then generate unicast traffic between two LAN hosts
echo 30 > /sys/module/airoha_eth/parameters/fdb_refresh_period   # name: see airoha_ppe.c
dmesg | grep -E 'offloaded bridge entries|is offloaded and in use'
# expected: "N of M offloaded bridge entries are in use, no refresh available"
# with N > 0 while traffic flows; after the bridge ageing time the entries are
# gone from `bridge fdb show` and the traffic falls back to software forwarding
# (that fallback is the bug this patch only measures)
bridge fdb show br br-lan | wc -l                        # drops after ~300 s of idle
```

If the module parameter name differs (the module is `airoha_eth`, not
`airoha_ppe`), read it back with `ls /sys/module/airoha_eth/parameters/`.

## 5. How these patches were produced (reproducible)

The hunk context is not guessed: it was generated against the exact post-patch
state of the driver.

```sh
# 1. the base state: vanilla kernel + the generic stack + the platform patches,
#    in exactly the order include/quilt.mk:102-105 uses
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.52.tar.xz
tar -xf linux-6.18.52.tar.xz && cd linux-6.18.52 && git init && git add -A
git commit -m "vanilla linux-6.18.52"
for d in generic/backport-6.18 generic/pending-6.18 generic/hack-6.18; do
        for p in /path/to/ponwrt/target/linux/$d/*.patch; do
                git apply --whitespace=nowarn "$p" || echo "FAILED $p"
        done
done
for p in /path/to/ponwrt/target/linux/airoha/patches-6.18/*.patch; do
        git apply --whitespace=nowarn "$p" || echo "FAILED $p"
done
git add -A && git commit -m "base state"          # <- patches 0001..0004 apply here
```

A few patches of the generic and platform series are written for slightly
different line numbers than this base, so `git apply` may reject them; in the
run that produced these patches, `git apply -C1` (reduced context) applied the
19 stragglers of the 621 generic + 163 platform patches, and 0001 and 0002 then
applied cleanly, which is what matters here: the state the four patches are
generated against is the state the repository's own build produces.

Two points of care, both caused by patch drift in the upstream files:

* the patches are written for the state produced by the repository patches, not
  for plain kernel master. For example the repository tree still has
  `airoha_ppe_set_mtu()` where master now has
  `airoha_ppe_set_xmit_frame_size()`, and the prototype hunk of patch 1 is
  anchored on the `airoha_ppe_remove_egress_flows()` line added by
  `925-net-airoha-add-PON-PPE-offload-metadata.patch`;
* the include block of `airoha_eth.c` in that state has `net/ip6_checksum.h`
  and `net/tcp.h` (from `916-02-net-airoha-Implement-HW-GRO-TCP-support.patch`),
  which is **not** the vanilla block; patch 2 was corrected for this and
  patches 3 and 4 touch no include line at all.

Verified for the complete sequence (this is the exact result of the check):

```
$ git apply --check 0001-...patch   # exit 0
$ git apply         0001-...patch
$ git apply --check 0002-...patch   # exit 0
$ git apply         0002-...patch
$ git apply --check 0003-...patch   # exit 0
$ git apply         0003-...patch
$ git apply --check 0004-...patch   # exit 0
$ git apply         0004-...patch
```

and the three resulting files are byte-identical (`sha256sum`) to the tree the
patches were generated from. Expect `git apply` to print an offset when these
patches are applied to a tree where the generic stack is missing or where a few
of the older number-prefixed patches are already part of the kernel version:
only line numbers move, the touched regions
(`airoha_netdev_ops`, `airoha_probe()`, the `struct airoha_ppe` /
`struct airoha_eth` definitions and `airoha_ppe_init()/deinit()`) do not
overlap the generic stack.

## 6. Known limitations of v1

1. **No VLAN tag rewrite.** FDB entries with `vid != 0` are tracked but marked
   `AIROHA_FDB_F_NO_OFFLOAD`; tagged ingress frames are not promoted. Tag
   push/pop on the AN7581 L2B entry needs hardware verification first — the
   driver still treats `FLOW_ACTION_VLAN_POP` as a no-op, so the strip case
   cannot be trusted. `prio`/PCP is dropped by the offload path as well
   (`AIROHA_FOE_IB2_PCP` exists but is never set).
2. **No flooding or multicast offload.** Broadcast, multicast and unknown
   unicast still go through the software bridge; bridge MDB entries
   (`SWITCHDEV_PORT_OBJ_ADD` with `SWITCHDEV_OBJ_ID_PORT_MDB`) are ignored, and
   `AIROHA_FOE_IB2_MULTICAST` is not programmed by this path.
3. **Only entries learned for an airoha GDM port.** Ports stacked below or above
   the netdev (VLAN device, LAG/bond, DSA user port, wlan netdev) are skipped;
   supporting them needs `switchdev_handle_fdb_event_to_device()` plus a
   `foreign_dev_check` callback.
4. **FDB replay at port-offload time — addressed by patch 3, unverified on
   hardware.** `switchdev_bridge_port_offload()` needs a port parent id
   (`netif_get_port_parent_id()` → devlink switch port or
   `ndo_get_port_parent_id`); patch 3 adds `ndo_get_port_parent_id()` backed by
   `struct airoha_eth::switch_id`, so the bridge can now assign a hwdom and
   replay its FDB. The patch tolerates a failure (the bridge join must not
   fail) and logs `bridge port offload unavailable: <err>`. What is *not*
   verified: that the bridge now really replays, and that the
   `offload_fwd_mark` masking this enables does not drop frames the PPE did not
   forward.
5. **No ingress-port dimension.** The PPE L2B key modelled here is the MAC pair
   (plus ingress VLAN), so a promoted flow is not scoped to the port it was
   learned on. Frames that arrive on the entry's own egress port are filtered
   (`skb->dev == fdb->egress`), but the general case needs hardware validation.
6. **Bridge ageing vs. hardware forwarding — measured by patch 4, not fixed.**
   Offloaded flows never reach the bridge, so `br_fdb_update()` cannot refresh
   the FDB entry: after the bridge ageing time (300 s default) the entry is
   deleted, we drop the FOE, traffic falls back to the software bridge, is
   relearned and is offloaded again. `br_fdb_cleanup()` really does delete a
   dynamic entry that carries `BR_FDB_OFFLOADED` (verified by reading
   `net/bridge/br_fdb.c:543`), so this is not a theory. Patch 4 adds a
   counting/logging work item (`fdb_refresh_period`, default 0 = off) that
   reports how many offloaded entries are still in use; **it cannot refresh
   them**, see §2.2. A real fix needs a bridge-side refresh API, or a userspace
   decision to make the entries static.
7. **Stale flows on PON bearer changes.** `airoha_ppe_remove_egress_flows()`
   (patch 925) walks `eth->flow_table`, which does not contain the flows
   promoted from the FDB: a GEM/T-CONT remapping can leave a stale
   FDB-promoted FOE in place until it ages out.
8. **No notification back to the bridge.** The driver never sends
   `SWITCHDEV_FDB_OFFLOADED`, so `bridge fdb show` does not mark the entries as
   offloaded.
9. **AN7581 only.** Promotion is gated on `airoha_is_7581()` because only that
   SoC's native L2B layout is handled by the subflow path today. On AN7583 the
   FDB is tracked but nothing is promoted.
10. **An add for an already known `(MAC, VID)` is ignored** (`-EEXIST`), so the
    entry keeps the egress port it was first learned on. A MAC move is expected
    to arrive as `DEL` (old port) followed by `ADD` (new port), which is how the
    bridge notifies a moved entry; if an `ADD` alone ever shows up, the stale
    egress stays until the entry is deleted.
11. **Not compiled, not tested** (see §0), and the FDB table is never resized
    explicitly (`automatic_shrinking` is on, growth is handled by rhashtable).

## 7. Open questions / APIs that could not be fully verified

These are the places where a reviewer's input is needed; none of them is
guessed in code, each one is either unused or marked with a `TODO` in the
patches:

1. **`br_vlan_get_info_rcu()` / `br_vlan_get_pvid_rcu()`** — prototypes
   verified (`include/linux/if_bridge.h`: `int br_vlan_get_info_rcu(const struct
   net_device *dev, u16 vid, struct bridge_vlan_info *p_vinfo)`, the `_rcu`
   variant, so the caller must hold `rcu_read_lock()`), and
   `BRIDGE_VLAN_INFO_UNTAGGED`/`BRIDGE_VLAN_INFO_PVID` exist. **Not used**:
   `airoha_ppe_fdb_vlan_is_untagged()` simply returns "not offloadable" for
   `vid != 0` and carries a `TODO(AN7581 tag handling)`. Open question: does
   `br_vlan_get_info_rcu(egress, vid, &vinfo)` describe the *egress* tag state
   well enough to decide that no rewrite is needed for a frame forwarded in
   `@vid`, and what is required on the ingress side (the frame may have arrived
   tagged and the bridge would push/pop)? Compare with
   `br_vlan_fill_forward_path_mode()`.
2. **`switchdev_bridge_port_offload()` for a netdev that is its own bridge
   port** — signature and behaviour verified in `net/switchdev/switchdev.c` and
   `net/bridge/br_switchdev.c`, and it is called exactly like ocelot does. The
   prerequisite that used to fail is now implemented by patch 3
   (`ndo_get_port_parent_id()`). **Still open:** is relying on
   `dev_name(&pdev->dev)` as the switch id acceptable to a reviewer, or is a
   devlink switch port (with `devlink_compat_switch_id_get()`) the preferred
   long-term shape for this driver? And is `tx_fwd_offload = false` right, given
   that the PPE does forward some frames that still reach the CPU?
3. **`skb->offload_fwd_mark` / `BR_TX_FWD_OFFLOAD`** — passed as `false` to
   `switchdev_bridge_port_offload()`. Patch 3 now makes the bridge assign a
   hwdom, which is what enables `nbp_switchdev_allowed_egress()` masking, but
   the driver still never *sets* `skb->offload_fwd_mark` on the frames it hands
   to the stack. Should it, for the frames the PPE has already forwarded, so
   that the software bridge does not forward them a second time? This is the
   one place where patch 3 can turn a previously harmless failure into a
   behaviour change and it needs hardware validation.
4. **PPPoE/inner ethertype handling by the L2B entry** — the template built from
   the FDB has `etype = 0` for a plain untagged bridged flow (no
   `FLOW_ACTION_VLAN_PUSH`, no DSA, no PPPoE match key), exactly like the
   existing netfilter L2 offload path, while the hardware-learned key is
   preserved. Whether that is correct for PPPoE session frames (ethertype
   0x8864) on the AN7581 can only be answered on hardware.
5. **FOE slot invalidation by hash** — `airoha_ppe_fdb_flows_flush()` reuses
   `airoha_ppe_foe_flow_remove_entry()` → `airoha_ppe_foe_remove_flow()`, which
   invalidates the FOE entry stored in `e->hash` without re-checking that the
   hardware still holds the same key there. This mirrors the existing netfilter
   path, but it is a known sharp edge if the PPE re-binds a slot between
   learning and removal.
6. **FDB event context** — FDB notifications may be delivered from softirq, so
   the update path is written to be atomic-safe (no `rhashtable_walk_enter()`,
   no mutex) and uses `GFP_ATOMIC`. This is a design decision based on
   `br_switchdev_fdb_notify()` being called from the bridge RX path, not
   something that could be verified on a board.
7. **Netdev reference lifetime** — each FDB entry holds a `dev_hold()` on its
   egress netdev (released with `dev_put()` when the entry is removed), so the
   promote path may use `netdev_priv()` without RCU protection. Verified that
   `dev_hold()`/`dev_put()` exist and are atomic-safe; the assumption that this
   keeps the airoha priv alive across the RX path has not been stress-tested.
8. **Switch id stability across reboots and re-probes (patch 3)** — the id is
   `"airoha:" + dev_name(&pdev->dev)`. Verified that the device name of a
   platform device is unique in the device model and constant for the life of
   the device; **not verified** that the AN7581 DTS gives the ethernet
   controller a unit address that cannot coincide with another switchdev
   device on the same system, nor that nothing else publishes an `"airoha:*"`
   switch id. A devlink switch port would sidestep both questions.
9. **PPE idle time for bridge-promoted flows (patch 4)** — the work item reads
   the idle time through `airoha_ppe_entry_idle_time()`, i.e. the same helper
   and the same `AIROHA_FOE_IB1_BIND_TIMESTAMP` field the netfilter L2 path
   uses. For a flow promoted from the FDB the FOE entry keeps the
   hardware-learned key while `e->data` holds the driver template, exactly the
   mismatch that `airoha_ppe_foe_flow_l2_entry_update()` handles by re-reading
   the subflow; **not verified** on hardware that the resulting idle value
   tracks traffic for a native L2B entry, nor what threshold separates "in use"
   from "idle" in practice (the module parameter doubles as both the walk
   period and the idle threshold). If the value is wrong, patch 4's counter is
   wrong — but it only logs, so the risk is bounded.
10. **Bridge refresh API (patch 4)** — there is no `switchdev_fdb_notify()` in
    this kernel and no consumer of `SWITCHDEV_FDB_ADD_TO_BRIDGE`, so the
    refresh itself is deliberately not implemented. Open question for a
    reviewer: is the intended long-term fix (a) add a bridge consumer that
    bumps `f->updated` on a driver notification, (b) have the driver only ever
    offload entries that userspace made static, or (c) drive it from userspace
    (`bridge fdb replace … static`, and a monitor/refresh daemon)? The patch
    set takes no position beyond "do not invent an API".

## 8. Follow-ups (in rough priority order)

1. **Build the series** (§3.6) and fix whatever the compiler finds; then boot it
   and check `dmesg` for the `bridge port offload unavailable` line from patch
   2, which must now be absent.
2. Verify that patch 3 makes the bridge assign a hwdom and replay its FDB
   (`bridge -d link show`, `/sys/class/net/<port>/phys_switch_id`,
   `bridge fdb show | grep -c offload`), and — critically — that
   `offload_fwd_mark` masking does not drop frames: compare forwarded traffic
   with and without the patch while a third host generates traffic to a MAC
   that is *not* in the FDB.
3. Verify AN7581 tag push/pop for the native L2B entry on hardware, then use
   `br_vlan_get_info_rcu()` + `BRIDGE_VLAN_INFO_UNTAGGED` to lift the
   `vid != 0` restriction, and plumb `act->vlan.prio` into `AIROHA_FOE_IB2_PCP`.
4. Offload bridge MDB entries and flooding to `AIROHA_FOE_IB2_MULTICAST`
   (`SWITCHDEV_PORT_OBJ_ADD/DEL` with `SWITCHDEV_OBJ_ID_PORT_MDB`).
5. Measure the ageing hiccup with `fdb_refresh_period` on (patch 4) and decide
   the real fix for it: `SWITCHDEV_FDB_OFFLOADED` does **not** work in this
   kernel (see §2.2), so it is either a bridge-side refresh API or an
   offload-only-static-entries policy driven from userspace.
6. Make PON bearer changes invalidate FDB-promoted flows as well
   (`airoha_ppe_remove_egress_flows()` only walks `eth->flow_table`).
7. Export the `fdb_stats` counters through debugfs and add a selftest/trace
   point for promotion failures; the patch 4 counters are a first step.
8. Consider `switchdev_handle_fdb_event_to_device()` so that stacked ports
   (VLAN on top of a GDM port, LAG) can be offloaded.
9. Re-measure the interaction with the netfilter path: both fill
   `ppe->l2_flows`, and `airoha_ppe_foe_l2_flow_commit_entry()` replaces an
   existing entry rather than merging with it.
