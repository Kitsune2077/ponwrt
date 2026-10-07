# Bridge FDB offload to the Airoha PPE (Plan A)

Staging area for two **draft** kernel patches that teach the AN7581 PPE to
forward bridged traffic (including PPPoE and other non-IP L2 traffic) in
hardware instead of letting the Linux software bridge forward every frame.

```
docs/dev/bridge-fdb-offload/
├── 0001-net-airoha-ppe-add-bridge-FDB-offload-table.patch   (airoha_eth.h, airoha_ppe.c)
├── 0002-net-airoha-offload-bridge-ports-via-switchdev.patch (airoha_eth.c)
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
been compiled (no cross toolchain was available) and never run on a device. The
only mechanical validation performed is that both patches apply cleanly with
`git apply` against the exact post-patch driver state produced by
`linux-6.18.52 + target/linux/airoha/patches-6.18/*` (see §5). Treat every
claim about hardware behaviour below as a hypothesis that must be verified on a
board before these patches are trusted.

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

## 3. Build

### 3.1 Apply-only check (fast, no full build)

```sh
cd /path/to/ponwrt
cp docs/dev/bridge-fdb-offload/0001-*.patch \
   target/linux/airoha/patches-6.18/931-net-airoha-ppe-add-bridge-FDB-offload-table.patch
cp docs/dev/bridge-fdb-offload/0002-*.patch \
   target/linux/airoha/patches-6.18/932-net-airoha-offload-bridge-ports-via-switchdev.patch

make target/linux/prepare V=s          # applies generic + target patches, no compile
# on a failure the log names the patch; build_dir/target-*/linux-*/… holds the tree
```

### 3.2 Compile the kernel only

```sh
cp configs/an7581.config .config
make defconfig
make target/linux/compile V=s          # kernel + modules, no images
# a compile error is most likely in airoha_ppe.c (patch 1) or airoha_eth.c (patch 2)
```

### 3.3 Full firmware

```sh
make -j"$(nproc)"                      # images land in bin/targets/airoha/an7581/
```

or use the GitHub Actions workflow **Build PonWrt Firmware**
(`workflow_dispatch`, `build_an7581=true`) — but only after the patches are
known to apply and compile, see §0.

### 3.4 Configuration requirements

Already satisfied by the current tree, kept here as a checklist:

* `CONFIG_NET_SWITCHDEV=y` (`target/linux/generic/config-6.18`; the airoha
  target config does not override it)
* `CONFIG_BRIDGE=y`, `CONFIG_BRIDGE_VLAN_FILTERING=y` (generic config)
* `CONFIG_NET_AIROHA=y`, `CONFIG_NET_AIROHA_NPU=y`
* `CONFIG_NET_AIROHA_FLOW_STATS` is **not** set for an7581, so the per-entry
  NPU counters are unavailable; use the FOE dump below instead.

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

## 5. How these patches were produced (reproducible)

The hunk context is not guessed: it was generated against the exact post-patch
state of the driver.

```sh
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.52.tar.xz   # LINUX_VERSION-6.18 = .52
tar -xf linux-6.18.52.tar.xz && cd linux-6.18.52 && git init
for p in /path/to/ponwrt/target/linux/airoha/patches-6.18/*.patch; do
        git apply --reject --include='drivers/net/ethernet/airoha/*' "$p"
        rm -f drivers/net/ethernet/airoha/*.rej
done
git add -A && git commit -m "driver after repo patches"     # reference state
# apply 0001 + 0002 here, then `git diff` to regenerate them
```

Two points of care, both caused by patch drift in the upstream files:

* the patches are written for the state produced by the repository patches, not
  for plain kernel master. For example the repository tree still has
  `airoha_ppe_set_mtu()` where master now has
  `airoha_ppe_set_xmit_frame_size()`, and the prototype hunk of patch 1 is
  anchored on the `airoha_ppe_remove_egress_flows()` line added by
  `925-net-airoha-add-PON-PPE-offload-metadata.patch`;
* hunk line numbers come from that reference tree (`git apply` tolerates small
  offsets, so they need no manual fixing when the numeric prefix changes).

Verified: `git apply --check` and `git apply` both succeed for patch 0001 and
then patch 0002 on that reference tree, and the result equals the reviewed code.
Expect `git apply` to print an offset when these patches are applied to a tree
where a few of the older number-prefixed patches are already part of the kernel
version (6.18.52 already contains most of the `0xx`-`3xx` upstream backports) or
where a repository patch applied only partially: the affected regions
(`airoha_dev_open()`/`airoha_dev_stop()`, the QDMA teardown helpers, the TX
path) do not overlap the hunks below, so only the line numbers move.

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
4. **FDB replay depends on `switchdev_bridge_port_offload()` succeeding, which it
   currently does not.** That function needs a port parent id
   (`netif_get_port_parent_id()` → devlink switch port or
   `ndo_get_port_parent_id`), and airoha netdevs have neither, so it returns
   `-EOPNOTSUPP`: the bridge never assigns a hardware domain to the port and
   never replays its FDB at port-offload time. The patch tolerates the failure
   (the bridge join must not fail) and the feature still works because FDB
   events are broadcast on the global switchdev chain — but only for entries
   that are learned or refreshed *after* the handler is registered. Adding
   `ndo_get_port_parent_id()` (the trick DSA uses in its legacy mode) or a
   devlink switch port is the clean fix.
5. **No ingress-port dimension.** The PPE L2B key modelled here is the MAC pair
   (plus ingress VLAN), so a promoted flow is not scoped to the port it was
   learned on. Frames that arrive on the entry's own egress port are filtered
   (`skb->dev == fdb->egress`), but the general case needs hardware validation.
6. **Bridge ageing vs. hardware forwarding.** Offloaded flows never reach the
   bridge, so `br_fdb_update()` cannot refresh the FDB entry: after the bridge
   ageing time (300 s default) the entry is deleted, we drop the FOE, traffic
   falls back to the software bridge, is relearned and is offloaded again. A
   periodic hiccup of this kind must be measured; assisted learning or an
   explicit `SWITCHDEV_FDB_OFFLOADED` notification would fix it.
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
   unresolved part is not the call but the prerequisite: verified in
   `net/core/dev.c` + `net/devlink/port.c` that
   `netif_get_port_parent_id(dev, &ppid, false)` returns `-EOPNOTSUPP` for a
   netdev without a devlink switch port or `ndo_get_port_parent_id`, hence the
   whole call fails on this SoC. Is adding `ndo_get_port_parent_id()`
   acceptable in this driver, or should the FDB handling stay a global notifier
   without bridge-port offload?
3. **`skb->offload_fwd_mark` / `BR_TX_FWD_OFFLOAD`** — not touched
   (`tx_fwd_offload = false`). Should the driver mark frames that the PPE has
   already forwarded, so that the software bridge does not forward them a second
   time?
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

## 8. Follow-ups (in rough priority order)

1. Add `ndo_get_port_parent_id()` (or a devlink switch port) so
   `switchdev_bridge_port_offload()` succeeds and the bridge replays its state;
   then verify `switchdev_bridge_port_unoffload()` ordering on unlink.
2. Verify AN7581 tag push/pop for the native L2B entry on hardware, then use
   `br_vlan_get_info_rcu()` + `BRIDGE_VLAN_INFO_UNTAGGED` to lift the
   `vid != 0` restriction, and plumb `act->vlan.prio` into `AIROHA_FOE_IB2_PCP`.
3. Offload bridge MDB entries and flooding to `AIROHA_FOE_IB2_MULTICAST`
   (`SWITCHDEV_PORT_OBJ_ADD/DEL` with `SWITCHDEV_OBJ_ID_PORT_MDB`).
4. Solve the FDB ageing/refresh problem (assisted learning, periodic refresh, or
   `SWITCHDEV_FDB_OFFLOADED`).
5. Make PON bearer changes invalidate FDB-promoted flows as well
   (`airoha_ppe_remove_egress_flows()` only walks `eth->flow_table`).
6. Export the `fdb_stats` counters through debugfs and add a selftest/trace
   point for promotion failures.
7. Consider `switchdev_handle_fdb_event_to_device()` so that stacked ports
   (VLAN on top of a GDM port, LAG) can be offloaded.
8. Re-measure the interaction with the netfilter path: both fill
   `ppe->l2_flows`, and `airoha_ppe_foe_l2_flow_commit_entry()` replaces an
   existing entry rather than merging with it.
