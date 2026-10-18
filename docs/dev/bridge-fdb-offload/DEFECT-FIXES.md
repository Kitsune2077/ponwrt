# Bridge FDB offload — defect fixes

These are the fixes for the defects found in the review of the four-patch
series. They are folded into the patch bodies that introduce the code, not
added as follow-up patches:

| Patch | Fixes |
| --- | --- |
| `931-net-airoha-ppe-add-bridge-FDB-offload-table.patch` | D1, D3, D4, D5 |
| `933-net-airoha-report-a-port-parent-id-for-bridge-offload.patch` | defensive probe fix |
| `934-net-airoha-inspect-bridge-FDB-entries-held-by-PPE.patch` | D2 |
| `936-net-airoha-bridge-trigger-fdb-promotion-from-rx.patch` | stage-3 RX trigger (see below) |

`932-net-airoha-offload-bridge-ports-via-switchdev.patch` is unchanged.

Line numbers below refer to the tree produced by applying 931 → 934 on the
`553902f58` base (`airoha_ppe.c`, `airoha_eth.c`, `airoha_eth.h`). The verified
build logs are `~/kbuild/logs/31-fix-build-both.log` (both configurations) and
`~/kbuild/logs/33-apply-check.log` (patch order on a clean base).

## D1 — the FDB table was never destroyed (931)

`airoha_ppe_deinit()` flushed `ppe->fdb_table`, which removes every FDB entry
and frees the L2 flows promoted from it, but never destroyed the rhashtable
itself; the bucket table and the resize work leaked on every unload.

- `airoha_ppe.c:2454` — `rhashtable_destroy(&eth->ppe->fdb_table);` after
  `airoha_ppe_bridge_fdb_flush()` (2452) and before `l2_flows` is destroyed
  (2455).
- The order is safe: the flush frees the entries and unlinks them, so destroy
  only releases the (now empty) bucket table and cancels the resize work.

## D2 — the 934 worker read freed FDB entries (934)

The delayed work walked `ppe->fdb_table` and dereferenced `fdb->flows` and
`fdb->egress` while `airoha_ppe_bridge_fdb_update()` could remove an entry
from the table under `ppe_lock` (1536–1548) and `kfree()` it right after
unlocking. The rhashtable walk is RCU based, but `kfree()` does not wait for
an RCU grace period, so the walk could touch freed memory.

- `airoha_ppe.c:1762` — `spin_lock_bh(&ppe_lock)` now spans the whole
  `rhashtable_walk_enter/start/next/stop/exit` sequence in
  `airoha_ppe_fdb_refresh_work()` (1737). The walk itself only takes the
  rhashtable spinlock and an RCU read lock and does not sleep, so it is safe
  under `ppe_lock`; holding the lock is what keeps every inspected entry (and
  its flow list) alive, because the delete path cannot pass the
  remove→`kfree()` window while the worker holds the lock.
- `airoha_ppe_fdb_entry_is_active()` (1715) now asserts `ppe_lock` and uses
  the new locked variants `airoha_ppe_entry_idle_time_locked()` (1669) and
  `airoha_ppe_foe_flow_entry_update_locked()` (1640). This preserves the
  hardware idle-time refresh (`airoha_ppe_foe_flow_l2_entry_update()`) in the
  same critical section instead of re-taking `ppe_lock` recursively.
- No printing under the lock: the egress name, MAC and VID of the first
  active entry are copied at 1781–1784 (`strscpy`/`ether_addr_copy`), the
  lock is dropped at 1792 and the rate-limited messages are emitted at
  1794–1803.
- `fdb_refresh_period` still defaults to 0 (disabled).

## D3 — promote replaced and freed a foreign L2 flow (931)

`airoha_ppe_foe_l2_flow_commit_entry()` used
`rhashtable_lookup_get_insert_fast()` and, on an existing entry, called
`rhashtable_replace_fast()`: the replaced object was silently dropped even
though it may belong to the netfilter offload path, which still owns it.

- `airoha_ppe.c:1193` — return `-EEXIST` instead of replacing. The promote
  caller already looks the existing entry up at 1457 and reuses it
  (`airoha_ppe_foe_commit_subflow_entry()`), so the remaining race window is
  a clean failure: the error is propagated to the warn at 1488, the new entry
  is freed at 1491 and the frame stays in the software bridge.

## D4 — VLAN key mismatch made the feature inert under `vlan_filtering 1` (931)

The promote path hardcoded `key.vid = 0`, while the FDB table is keyed by
`fdb_info->vid` (`airoha_ppe_bridge_fdb_update()`, 1533). Under VLAN filtering
the lookup therefore never matched, and every entry with `vid != 0` was
additionally marked `AIROHA_FDB_F_NO_OFFLOAD` at insert time, so nothing could
ever be promoted.

- `airoha_ppe.c:1234` — `airoha_ppe_fdb_vlan_is_untagged(egress, vid)` now
  asks the bridge on the egress port with
  `br_vlan_get_info_rcu(egress, vid, &vinfo)` and checks
  `BRIDGE_VLAN_INFO_UNTAGGED`; `vid == 0` is the untagged domain of a bridge
  without VLAN filtering (or without a PVID) and is always untagged.
- `airoha_ppe.c:1350–1369` — work out the ingress VID: an untagged frame is
  classified into the PVID of its ingress port via
  `br_vlan_get_pvid_rcu(skb->dev)` (0 when the port is not a VLAN-filtering
  bridge port); a tagged frame uses `skb_vlan_tag_get_id()` when the tag is in
  skb metadata, or is recognised as tagged from
  `skb->protocol == ETH_P_8021Q/ETH_P_8021AD` when the tag is still in the
  packet (this driver does not strip tags on RX, so this check is still
  needed).
- `airoha_ppe.c:1375–1379` — tagged ingress frames are counted in the new
  `fdb_stats.vlan_rewrite` counter (`airoha_eth.h:770`) and skipped.
- `airoha_ppe.c:1382` — the lookup key is now `key.vid = vid` (the same VID
  the FDB table is keyed on).
- `airoha_ppe.c:1410–1418` — after the lookup, the egress port must emit that
  VID untagged; otherwise the frame is counted in `fdb_stats.vlan_rewrite`
  and left to the software bridge.
- `airoha_eth.h:770–771` — `fdb_stats.tagged` became `fdb_stats.vlan_rewrite`
  and `fdb_stats.no_npu` was added. The now unused `AIROHA_FDB_F_NO_OFFLOAD`
  flag and `struct airoha_fdb_entry::flags` were removed
  (`airoha_eth.h:598`).
- Untagged/non-filtering bridges keep the previous behaviour (PVID 0 → vid 0
  → untagged); access ports with a PVID now match the bridge's FDB entries and
  are offloaded instead of silently never matching.

## D5 — promotion ignored a missing NPU (931)

`airoha_ppe_foe_commit_entry()` returns `-ENODEV` while `eth->npu` is unset
(it is only assigned by the nft-flowtable setup path), but the promote path
ignored that, mutated `l2_flows`/`fdb->flows` and counted a promotion that
never reached the PPE.

- `airoha_ppe.c:1333` — early `rcu_access_pointer(ppe->eth->npu)` check,
  counts `fdb_stats.no_npu` (`airoha_eth.h:771`) and returns before touching
  `l2_flows` or `fdb->flows`.
- `airoha_ppe.c:1022` — `airoha_ppe_foe_commit_subflow_entry()` now returns
  the hardware commit error and removes the just-added software subflow on
  failure (1076–1086) instead of returning success.
- Promote handles it: the reuse path at 1460 keeps the result in `err`, the
  new-entry path removes the `l2_flows` entry again at 1474, and the error is
  reported after unlocking at 1488. The netfilter call site in
  `airoha_ppe_foe_insert_entry()` is unchanged; only the leak on failure is
  gone.

## Defensive fix — an over-long switch id must not fail the probe (933)

`airoha_probe()` returned `-ENAMETOOLONG` when the `"airoha:<device>"` switch
id did not fit in the 32-byte buffer, which failed the whole ethernet device
for a cosmetic/hwdom-only loss.

- `airoha_eth.c:4902–4910` — on `snprintf()` truncation, `dev_warn()` and set
  `eth->switch_id_len = 0` instead of returning an error.
- `airoha_get_port_parent_id()` returns `-EOPNOTSUPP` for a zero length
  (`airoha_eth.c:4111`), which `switchdev_bridge_port_offload()` already
  tolerates; the only loss is the hardware domain, FDB replay and
  forwarded-mark masking. The `BUILD_BUG_ON(AIROHA_SWITCH_ID_LEN >
  MAX_PHYS_ITEM_ID_LEN)` (4109) and the comments (4096–4101) were kept/updated.

## What remained for stage 2 before 935

The following was the state after the stage-1 fixes; `935` below implements
the push framework and leaves the pop direction open.

- **VLAN tag push/pop.** Only "untagged in, untagged out" is offloaded. A
  tagged ingress frame (tag in the packet or in skb metadata) and an egress
  port whose member of the FDB VID is tagged both need a pop/push that the
  native AN7581 L2B template cannot express yet; they are counted in
  `fdb_stats.vlan_rewrite` and stay in the software bridge.
- **PCP.** `act->vlan.prio` is still dropped by the offload path;
  `AIROHA_FOE_IB2_PCP` exists in the FOE but is never set, so the priority of
  a pushed tag cannot be reproduced either.
- Everything else listed in `README.md` §6 (multicast/flooding, bridge
  ageing/refresh, stacked ports, hardware verification on AN7581) is
  unchanged by these fixes.

## Stage 2 — VLAN rewrite framework (935)

`935-net-airoha-support-vlan-rewrite-on-bridge-offload.patch` (md5
`b725286640a80ef43404fb00b07c99d1`) adds the egress VLAN action to the FDB
entry and teaches the promote path to push an 802.1Q tag. It is **opt-in**
and only the push direction is wired into the PPE; the pop direction is still
software and is the first thing a board has to settle.

### What is implemented

- `struct airoha_fdb_entry` now caches the egress action:
  `vlan_proto`, `egress_member`, `egress_untagged`, `egress_pvid`,
  `egress_pon` and `pcp`. It is resolved at `SWITCHDEV_FDB_ADD_TO_DEVICE`
  time with `br_vlan_get_info_rcu()` (membership and
  `BRIDGE_VLAN_INFO_UNTAGGED`), `br_vlan_get_pvid_rcu()` and
  `br_vlan_get_proto()` (bridge master), and refreshed on every promotion.
  The refresh is needed because 932 ignores the per-port switchdev VLAN
  notifications and a tagged/untagged flag change does not re-add the FDB
  entry.
- `vlan_rewrite` is a `bool` module parameter, default **0**. It gates every
  new tag path; 0 keeps the stage-1 forwarding unchanged.
- The promote matrix is now:

  | Ingress | Egress | Action |
  | --- | --- | --- |
  | untagged (PVID `vid`) | untagged | no rewrite; offloaded exactly as in stage 1 |
  | untagged (PVID `vid`) | tagged 802.1Q | **push** `vid`, `data.vlan.num = 1`; counted in `fdb_stats.vlan_push` |
  | tagged `vid` | untagged | **pop**, not implemented: `fdb_stats.vlan_pop` + `vlan_rewrite`, stays in software |
  | tagged `vid`, tag in packet | tagged same `vid`, LAN | keep the packet tag: no template VLAN; `vlan_rewrite` must be 1 |
  | tagged `vid`, tag in metadata | tagged same `vid` | push the tag back; `vlan_rewrite` must be 1 |
  | tagged `vid`, tag in packet | tagged same `vid`, PON | skipped: the GEM lookup would need `data->vlan`, which would also push a second tag |
  | tagged | tagged different `vid`/TPID | out of scope: `vlan_skip` + `vlan_rewrite`, stays in software |
  | priority tag (VID 0) | any | out of scope: `vlan_skip` + `vlan_rewrite`, stays in software |

- The push uses the same template fields as the netfilter
  `FLOW_ACTION_VLAN_PUSH` path: `data.vlan.hdr[0].id = vid`,
  `.proto = htons(ETH_P_8021Q)`, `num = 1`. `airoha_ppe_foe_entry_prepare()`
  then sets `l2->vlan1`, `IB1 VLAN_LAYER = 1` and `VPM = 1`, and the native
  L2B commit copies `vlan1`/`vlan2`/`ib2` from the template.
- **PON (patch 925).** `airoha_ppe_pon_select_flow()` resolves the GEM/T-CONT
  from `data->vlan.hdr[data->vlan.num - 1].id`, i.e. the **outer/egress** VID,
  not the incoming frame's VID. Filling `data.vlan` with the pushed VID is
  therefore what makes a 3114 push resolve to the GEM configured for 3114;
  without it the lookup would use `AIROHA_PON_VID_ANY`. **No change to 925 is
  needed.** As before, the flow is rejected (`-EOPNOTSUPP`) when the eight
  P-bits do not all resolve to the same GEM/T-CONT, so a split mapping keeps
  that flow in software.
- **Link guard.** The bridge helpers are compiled under
  `#if IS_REACHABLE(CONFIG_BRIDGE) && IS_REACHABLE(CONFIG_BRIDGE_VLAN_FILTERING)`.
  In a `NET_AIROHA=y` + `BRIDGE=m` + `NET_DSA=n` build the fallback marks a
  non-zero VID as "not a member", so the push stays disabled instead of
  leaving an unresolved `br_vlan_get_*_rcu()` symbol in `vmlinux`.
- `fdb_stats` gained `vlan_push`, `vlan_pop` and `vlan_skip`; the existing
  `vlan_rewrite` remains the aggregate "needed a rewrite but stayed in
  software" counter. The counters are in memory only; they are not exported
  through debugfs yet, so a hardware test has to use `debugfs ppe/bind` and
  packet captures.

### What the module parameter does

```
# when airoha-eth is a module (the usual OpenWrt image)
modprobe airoha-eth
echo 1 > /sys/module/airoha_eth/parameters/vlan_rewrite
```

For a built-in driver the same file appears under
`/sys/module/airoha_eth/parameters/`. Writing 0 stops new promotions from
using a push but does **not** tear down flows that were already promoted;
delete/re-add the bridge port, flush the FDB entry or reload the driver to
retire them.

### Why it is opt-in

- The L2B egress tag insertion has never been run on an AN7581 board.
- The pop direction is missing, so the `pon0:t` + `lan1:u*` pair can only be
  accelerated in one direction; enabling the parameter must not be sold as
  "VLAN offload works both ways".
- The pushed tag is always 802.1Q with PCP 0. `br_vlan_get_info_rcu()` has no
  PCP, and the netfilter path does not encode `act->vlan.prio` either
  (`AIROHA_FOE_IB2_PCP` is a single bit and is never set by this driver), so
  non-zero PCP and 802.1ad cannot be reproduced.
- The cached egress flags are refreshed on promotion, but a VLAN flag change
  does not invalidate flows that are already bound; that is acceptable only
  while the feature is being measured.

### Hardware tests needed

1. **Two LAN ports, tagged VLAN, no PON.** This isolates tag push from the
   PON GEM machinery:
   ```sh
   ip link add br-vlan type bridge vlan_filtering 1
   ip link set lan1 master br-vlan
   ip link set lan2 master br-vlan
   bridge vlan add dev lan1 vid 100 pvid untagged
   bridge vlan add dev lan2 vid 100
   ip link set br-vlan up
   echo 1 > /sys/module/airoha_eth/parameters/vlan_rewrite
   ```
   Send untagged traffic from a host on `lan1` to a host on `lan2`.
   Expected: `tcpdump -e -i lan2` shows `802.1Q vlan 100`; `debugfs
   ppe/bind` shows an L2B entry with `vlan=100,0`, the `lan2` PSE port and
   `ib1` having `VLAN_LAYER=1`/`VPM=1`; the software bridge's forwarding
   counters stop increasing for that flow. Repeat with the parameter 0 and
   confirm the flow is no longer offloaded (stage-1 behaviour).
2. **`pon0:t` + `lan1:u*`, VLAN 3114.** Add `lan1` with `vid 3114 pvid
   untagged` and `pon0` with `vid 3114` (tagged). Confirm the PON GEM table
   maps 3114 and that all eight P-bits used by the service resolve to one
   GEM/T-CONT. Generate upstream traffic from the LAN host. Expected:
   `tcpdump -e -i pon0` shows `802.1Q vlan 3114`; `debugfs ppe/bind` shows
   `vlan=3114,0` and `etype` equal to the GEM Port-ID; the `pon0` software TX
   path is bypassed for that flow. If the P-bit mapping is split, the flow
   must stay in software (`prepare` returns `-EOPNOTSUPP`).
3. **Pop direction (expected to stay in software).** Send downlink traffic
   from `pon0` to the `lan1` host. With 935 there must be no L2B entry for
   that direction and the frame must still arrive untagged via the software
   bridge. This confirms the code does not mis-offload a pop case; it does
   not prove a pop implementation.
4. **Tagged-to-tagged same VID.** Two tagged LAN ports in VLAN 100: confirm
   the packet keeps exactly one tag and is offloaded. This validates the
   "tag already in the packet is left alone" assumption. If the tag is
   stripped or duplicated, remove that case from the matrix.
5. **PCP/TPID.** Send priority-tagged or PCP-marked traffic and confirm the
   pushed tag is PCP 0 / 802.1Q, as documented, or keep the parameter 0.

### What is still unverified / not implemented

- **Pop.** No strip/remove bit, TPID field or "remove tag" flag exists in
  `struct airoha_foe_l2b` or the `AIROHA_FOE_IB1`/`IB2` definitions; the
  netfilter path treats `FLOW_ACTION_VLAN_POP` as a no-op. The exact question
  is in the TODO next to the promote decision: does an L2B egress template
  with `VLAN_LAYER=0`, `VPM=0` and empty `vlan1`/`vlan2` strip the ingress
  tag, or leave it in the frame? Until a board answers that, tagged-in/
  untagged-out stays in software and `fdb_stats.vlan_pop` is a
  "would-have-popped" counter, not a success counter.
- **PON GEM mapping for a pushed tag.** The code path uses the egress VID and
  compiles, but the GEM/T-CONT selection for 3114 has not been exercised on
  hardware. A wrong mapping would send the frame to the wrong GEM; test 2 is
  mandatory before enabling the parameter in a release.
- **The push itself.** `vlan1`/`IB1 VLAN_LAYER` are the netfilter path's
  encoding, but no AN7581 has been observed emitting the tag from an L2B
  entry created by the bridge path.
- **PCP** is always 0; **802.1ad** and other TPIDs are rejected.
- **Tag retention** for tagged-in/tagged-out same VID is an assumption.
- **VLAN flag changes** and bridge ageing: existing promoted flows are not
  invalidated when the port's tagged/untagged flag changes; only the next
  promotion sees the new state. The 934 worker is still inspection-only.
- **Counters** were not exported at the time of 935; 936 adds the subset
  relevant to the RX trigger to `ppe/config` (see below).
- No hardware has run any of this. The verification below is compile-only.

### Verification of 935

- Patch generated from `tree-verify` after 931–934 by diffing against a
  snapshot of the stage-1 tree; mail header preserved.
- Clean worktree at `553902f58`: `git apply --check` and `git apply` return 0
  for 931 → 932 → 933 → 934 → **935**; the three resulting driver files are
  byte-identical to `tree-verify`. Log:
  `~/kbuild/logs/36-stage2-apply-check.log`.
- Driver compile, `NET_AIROHA=m` / `NET_DSA=m`: `CONFIG_A_BUILD_RC=0`.
- Driver compile, `NET_AIROHA=y` / `NET_DSA=y` / `HSR=n`:
  `CONFIG_B_BUILD_RC=0`.
- Driver compile, `NET_AIROHA=y` / `BRIDGE=m` / `NET_DSA=n` (with
  `NET_SWITCHDEV=y` so the 932 callbacks have their real implementations):
  `CONFIG_C_BUILD_RC=0`, and `nm airoha_ppe.o` contains no `br_vlan_*`
  symbol. Log: `~/kbuild/logs/35-stage2-build.log`.
- Only the two pre-existing compiler warnings from the driver/PCS objects
  remain (`pcs-airoha-common.c:1426`, `airoha_ppe_debugfs.c:217`). The arm64
  defconfig also prints its usual `symbol value 'm' invalid for RFKILL`
  line; that is not from this series.

## Stage 3 — the missing RX trigger (936)

`936-net-airoha-bridge-trigger-fdb-promotion-from-rx.patch` (md5
`0c88c5dc62958b573b3c374b8823b232`) makes the bridge FDB promote path
reachable from a pure bridge. It is generated on top of the repaired
931–935 series: 931 with the on-demand NPU attach worker, the restored 932,
and the unchanged 933/934/935.

### Measured problem

On the HG5382A the bridge FDB reaches the driver (`bridge -c fdb show` marks
the lan1 entry `offload`) but `npu_attached` stays 0,
`/sys/kernel/debug/ppe/entries` contains no `BRIDGE` entry, and 300
lan3(DSA)→lan1(GDM) unicast frames are all forwarded by the software bridge.

There are two reasons:

1. `airoha_eth.c` only calls `airoha_ppe_check_skb()` for the
   `HIT_UNBIND_RATE_REACHED` (0x0f) CPU reason. That reason means the PPE has
   already learned an entry and wants it bound; it is not the reason of the
   first frame of a flow.
2. `airoha_ppe_hw_init()` — the only writer of `PPE_TB_HASH_CFG` (table
   enable), `PPE_TB_CFG_SEARCH_MISS` (forward-and-build) and
   `PPE_BIND_RATE` (`L2B_BIND`) — runs only from
   `airoha_ppe_offload_setup()`, i.e. from the NPU attach performed by the
   nft flowtable path. A pure bridge never attaches the NPU, so the PPE is
   never programmed to create the unbound L2B slot. `npu_attached` is the
   symptom, not just a consequence.

### What 936 does

- Adds `AIROHA_PPE_CPU_REASON_*` to `airoha_eth.h` with only the
  no-entry/software-forward reasons: `NO_FLOW` 0x07, `UN_HIT` 0x0d,
  `HIT_UNBIND` 0x0e, `HIT_UNBIND_RATE_REACHED` 0x0f and `HIT_PRE_BIND`
  0x1a. Exception reasons (TTL, fragments, option headers, VLAN violation,
  ...) are deliberately absent and stay with the software bridge. Only 0x0f
  is confirmed by the existing driver; the other four values follow the
  shared MediaTek-lineage encoding and have not been measured on an AN7581.
  The slot/eligibility validation below keeps a wrong reason from committing
  anything, but a board test should read `fdb_rx_no_flow` first.
- `airoha_eth.c` switches on the reason. 0x0f keeps the existing
  `airoha_ppe_check_skb()` path unchanged. 0x07/0x0d/0x0e/0x1a call the new
  `airoha_ppe_bridge_rx_slowpath()`, except for PON ingress. A frame is
  dispatched to exactly one of the two paths.
- `airoha_ppe_bridge_fdb_update()` schedules the existing NPU attach work
  item after a successful FDB insert, so `airoha_ppe_hw_init()` runs before
  the first bridged frame. The RX slow path schedules the same worker as a
  fallback. Nothing attaches in softirq; the worker still takes
  `flow_offload_mutex`, loads the NPU firmware and programs the PPE in
  process context.
- Adds `fdb_stats.rx_no_flow` (no-flow reasons seen on a bridged path) and
  `fdb_stats.rx_no_slot` (no usable unbound L2B slot). With `promoted` and
  `no_npu` they distinguish "trigger never ran" from "ran but the PPE had no
  slot". `promoted`, `no_entry`, `no_npu`, `rx_no_flow` and `rx_no_slot` are
  printed by `/sys/kernel/debug/ppe/config` next to `npu_attached`, so a
  board test can tell which case happened without a debugger.

### Hash/slot finding (why no hash is synthesized)

For the 0x0f path the descriptor's `AIROHA_RXD4_FOE_ENTRY` index points at
the hardware-learned L2B entry that the PPE wants bound.
`airoha_ppe_foe_commit_subflow_entry()` relies on that: on AN7581 it
preserves the whole learned native `l2b` key (destination/source MAC,
`ingress_vlan`, the opaque `l2b.key`) and only copies `data`, `ib2`,
`vlan1`, `vlan2` and `etype` from the software template (930's fix).

For a no-flow frame the index is only usable under the same condition: the
slot must still hold this frame's unbound `BRIDGE` entry. The driver cannot
synthesize a native L2B entry from the frame alone. The
`airoha_ppe_foe_get_entry_hash()` helper produces a slot number, not the
`l2b.key`/`ingress_vlan` that the hardware compares, and the descriptor
carries no copy of them. Writing a software `struct airoha_foe_bridge`
template into the slot would be interpreted as an `airoha_foe_l2b` entry and
corrupt the learned source MAC, which is exactly the defect 930 fixed.

So 936 does not invent a hash. It validates the descriptor index against
`ppe_hash_mask` and `airoha_ppe_foe_is_bridge_slowpath()` (state != BIND,
packet type BRIDGE) under `ppe_lock`, and only then calls the existing
promote. If the slot is empty or foreign, the frame is counted in
`rx_no_slot` and stays with the software bridge. The first frame can therefore
be promoted only when the PPE created the unbound slot for it — which is why
the FDB add path now attaches and programs the PPE before traffic. There is
no half-working path that silently does nothing: the trigger and the two
failure cases are counted.

The input filter accepts a bridge port (`netif_is_bridge_port()`) and also a
DSA conduit (`netdev_uses_dsa()`). A frame from a DSA user port reaches the
driver on the conduit, which is not itself the bridge port; the FDB lookup
still resolves the real egress by destination MAC. Without the DSA case the
lan3(DSA)→lan1(GDM) test would skip every frame at the first check.

### Verification of 936

- Repaired series 931→935 reproduces the flashed `r0-98c1895` tree: after
  applying the repaired 931 (attach) + restored 932 + 933/934/935 onto
  `553902f58`, the sha256 of `airoha_eth.c`, `airoha_eth.h` and
  `airoha_ppe.c` is identical to `~/kbuild/tree-verify`:
  - eth.c `62c14963543ba27c4b0de57243cdb8cfc54550c8b26bccf19648757237cea8cd`
  - eth.h `4228c241c1da493b953a5470e4943a53e4ce7c189f325c6c535f4b235f2e1a7e`
  - ppe.c `0bafafa15f1278548d44afe400c0a5aef8f02fc25e5f3055ecfe199d857f18cc`
- 936 applies after that series with `git apply --check`/`git apply` rc=0.
- Driver compile in both configurations: `CONFIG_A_BUILD_RC=0` and
  `CONFIG_B_BUILD_RC=0`; only the two pre-existing warnings
  (`pcs-airoha-common.c:1426`, `airoha_ppe_debugfs.c:217`). Log:
  `~/kbuild/logs/38-936-build-both.log`.
- Not verified on hardware: whether the AN7581 PPE reports a no-flow reason
  for the first bridged frame *and* leaves the unbound L2B slot at the
  reported index. If it does, `rx_no_flow` and `promoted` rise; if the slot
  is absent, `rx_no_slot` rises and the frame stays in software. That is the
  first thing to read from a new build on the HG5382A.

## Stage 4 — diagnostic 937: where did the L2B slot go?

`937-net-airoha-add-l2b-slow-path-diagnostics.patch` (md5
`ff7d1b4bde9250f059a8d8715aa4c4c1`) is **instrumentation only**. It does
not build or commit an FOE entry, does not write a PPE register, and does
not change the forwarding decision. The frames still go to the software
bridge exactly as in 936.

### The self-build plan was a category error

The first 937 draft was going to build a native `struct airoha_foe_l2b`
from the frame and commit it at a hash computed by
`airoha_ppe_foe_get_entry_hash()`. The tree shows that is not how a
bridge flow reaches this PPE:

- `airoha_ppe_foe_flow_commit_entry()` sends `PPE_PKT_TYPE_BRIDGE` to the
  software `l2_flows` rhashtable *before* computing any hash
  (`airoha_ppe.c:1236-1237`); the only hardware commit of a bridge entry
  is `airoha_ppe_foe_commit_subflow_entry()` at the descriptor's
  `AIROHA_RXD4_FOE_ENTRY` index (`:1057-1120`). On AN7581 that function
  preserves the learned native key and only copies `data`, `ib2`,
  `vlan1`, `vlan2` and `etype` (`:1082-1089`).
- The `PPE_PKT_TYPE_BRIDGE` case of `airoha_ppe_foe_get_entry_hash()`
  (`:730-741`) only selects a *software* `foe_flow[]` bucket in the
  non-7581 insert path (`:1162`); it is not a hardware L2B slot
  allocator. There are no "software-installed native L2B entries" to
  copy the hash from.
- The native `l2b.key` at entry offset 12 (`struct airoha_foe_l2b`,
  `airoha_eth.h:392-409`, offsets asserted at `:498-502`) is learned by
  the hardware. The driver never writes it; 930 deliberately preserves
  it. No writer, formula, register or test dump in the tree defines it.
  A self-built entry would have to invent the one field the hardware
  compares against the packet.

This matches the design note of the MediaTek PPE this block derives from
(Felix Fietkau, "support creating mac address based offload entries"):
the hardware creates the L2 flow entry for bridged frames as well, tells
the CPU when the flow reaches the offload rate, and software fills in the
output/egress information. Software does not fabricate the L2 entry.

The diagnostic below exists to find out why the hardware-created entry is
missing on the HG5382A, not to work around it.

### What 937 records (read-only)

- The first 32 frames the gate refuses are kept in a fixed array filled
  from the RX softirq (no allocation, no descriptor or FOE writes). Each
  record has: descriptor `AIROHA_RXD4_FOE_ENTRY` index, raw
  `AIROHA_RXD4_PPE_CPU_REASON`, raw `ib1`, the raw word at the native L2B
  `ib2` offset (entry offset 44), the parsed `state`/`type`, the
  `bridge` bit, the ingress `ifindex`, the jiffies and the rejection
  reason (`RANGE`, `NO_ENTRY`, `BIND`, `TYPE`).
- A 32-entry histogram of the raw CPU reason, incremented for every GDM
  RX descriptor before the reason is dispatched. A wrong reason encoding
  now shows up instead of silently going to software.
- One `dev_info` per attach (bit-guarded) with `npu_attached`, `num_ppe`,
  and per PPE: `REG_PPE_UNBIND_AGE` (0x238) raw + `MIN_PACKETS`/`DELTA`,
  `REG_PPE_BIND_RATE` (`L2B_BIND`/`BIND`), `REG_PPE_TB_CFG`
  (`SEARCH_MISS`), `REG_PPE_TB_HASH_CFG` and `REG_PPE_HASH_SEED`.
- The same read-only registers in `/sys/kernel/debug/ppe/config` and the
  records/histogram in the new `/sys/kernel/debug/ppe/l2b_dbg`.

### The UNBIND_AGE gap

`airoha_ppe_hw_init()` programs `PPE_TB_HASH_CFG`, `PPE_TB_CFG` and
`PPE_BIND_RATE`, but it never writes `REG_PPE_UNBIND_AGE` (0x238). The
MediaTek PPE of the same lineage sets `MIN_PACKETS=1000` and `DELTA=3`
there. The AN7581 value printed by this patch is whatever the
bootloader/firmware left behind. If it is 0 or very small, an unbound
entry can age out before the CPU reads it, which would produce
`rx_no_slot ≈ rx_no_flow` without any hash or key problem. This round is
read-only: 937 does not write the register.

### What to read on the board

After the runbook traffic (lan3 DSA → lan1 GDM, 300 unicast frames):

```sh
cat /sys/kernel/debug/ppe/l2b_dbg
cat /sys/kernel/debug/ppe/config | grep -E \
    'npu_attached|fdb_|unbind_age|bind_rate|hash_cfg'
dmesg | grep -E 'PPE diagnostic|PPE[01]:'
cat /sys/kernel/debug/ppe/entries | grep -i l2b
```

How to read the first `l2b_dbg` records:

| Observation | Meaning | Next step |
| --- | --- | --- |
| `hash=ffff reject=RANGE` for all frames | descriptor index is the invalid sentinel: hardware built no slot | inspect `unbind_age`, `bind_rate`, `tb_cfg.search_miss`; likely a PPE config issue |
| valid `hash`, `reject=TYPE`, `type` ≠ 2 | hardware built an entry of another type at that index | check how the ingress path classifies the frame (L2 vs L3) |
| valid `hash`, `type=2`, `reject=BIND` | the slot is already bound | not a slow-path candidate; look at `fdb_promoted`/entries |
| valid `hash`, `type=2`, no reject | the gate accepted the slot and called promote | if `promoted` stays 0, the failure is in the FDB/VLAN side |
| `reason[0x07]` not the dominant index | the assumed no-flow reason is wrong | use the histogram to find the real reason |
| `unbind_age=00000000` | hardware has no unbound ageing configuration | candidate one-line follow-up: program `MIN_PACKETS`/`DELTA` |

### What the board measured (937)

The first 937 run on the HG5382A captured the same record 32 times for
bridged unicast frames (lan3 DSA → lan1 GDM) before our own traffic:

```text
idx ifindex hash reason ib1      ib2@44   state type bridge reject jiffies
01  2       05bc 0e     10000219 00000000 1     0    0      TYPE   4294939915
02  2       05bc 0e     10000319 00000000 1     0    0      TYPE   4294939915
03  2       05bc 0e     10000419 00000000 1     0    0      TYPE   4294939915
...
24  2       05bc 0e     10001719 00000000 1     0    0      TYPE   4294939934
```

`ib1` is `0x1000XXXX`: bit 28 sets state UNBIND, and the low 13 bits are
`AIROHA_FOE_IB1_UNBIND_PACKETS` (2, 3, ... 23 at bits 23:8) and
`AIROHA_FOE_IB1_UNBIND_TIMESTAMP` (0x19 at bits 7:0), not a packet type.
The raw reason histogram was dominated by `0x0e` HIT_UNBIND (1431) and
`0x0f` HIT_UNBIND_RATE_REACHED (901); the other reasons were 0x0d (173),
0x0c (89), 0x03 (63) and 0x07 (7). The hardware therefore does create
the native L2B entry and punts it correctly. The PPE registers were
`unbind_age=03e80003` (MIN_PACKETS 1000, DELTA 3), `bind_rate=001e001e`
(L2B_BIND 30, BIND 30), `tb_cfg=83c0cfb4` (SEARCH_MISS 3),
`hash_cfg=30001101`, `hash_seed=12345678`, `npu_attached=1`, `num_ppe=2`.

The gate rejected every one of those frames as `TYPE`: it decoded the
packet type with `AIROHA_FOE_IB1_BIND_PACKET_TYPE` (bits 27:25), the
field used by the software bridge template, but the native entry has no
such field there. The state decode was already right; the type decode
was not. `REG_PPE_UNBIND_AGE` is already programmed to 1000/3, so the
ageing hypothesis is dead and 938 must not touch it.

### What still must be confirmed on hardware

- Native `l2b.key` semantics, if a self-build is ever revisited: the
  field is still not defined by the tree. 938 preserves it untouched.
- Whether the native ingress-key offsets used by the layout check are
  stable across AN7581 variants; the measured HG5382A entry follows the
  layout asserted by 930.

### Fallback (unchanged)

Plan B remains per-MAC IPv4/IPv6 tc-flower rules through the normal
flow-offload slot allocation, which uses the software hash/slot path that
is already exercised by routed offload. It does not need `l2b.key`. It
should only be attempted after the diagnostic shows that the hardware
L2B path cannot be made to create the slot.

### Verification of 937

- Applies after 931→936 on a clean `553902f58` worktree with
  `git apply --check`/`git apply` rc=0 (tree `~/kbuild/tree-937-apply`).
- Driver compile in both configurations: `CONFIG_A_BUILD_RC=0` and
  `CONFIG_B_BUILD_RC=0`; only the same two pre-existing warnings
  (`pcs-airoha-common.c:1426` and the `ppe%u_gdm2_default_cpu_port`
  format warning, now at `airoha_ppe_debugfs.c:246`).
- No hardware write, no new commit path and no change to `fdb_stats`;
  the first 32 rejects and the reason histogram are the only new state.

## Stage 5 — 938: accept the native L2B entry

`938-net-airoha-accept-native-l2b-slowpath.patch` (md5
`5041a01b27766210a070d1b3c5eac6fe`) makes the slow-path gate
layout-aware. It is the fix for the layout mistake measured by 937; it
does not write a PPE register and does not change the FDB key.

### What the gate now reads

- `airoha_ppe_foe_is_native_l2b()` accepts a hardware-learned entry only
  on AN7581, and only when:
  - `FIELD_GET(AIROHA_FOE_IB1_PKT_TYPE, ib1)` has the value the
    hardware leaves for the native table (`AIROHA_FOE_PKT_TYPE_L2B`,
    measured zero), and
  - the state is not `AIROHA_FOE_STATE_BIND` (already checked by the
    caller), and
  - the native ingress key matches the frame: `l2b.dest_mac_hi` /
    `l2b.dest_mac_lo` (offset 4/10) and `l2b.src_mac_hi` /
    `l2b.src_mac_lo` (offset 16/22). A slot that does not hold this
    frame's `(source, destination)` pair is foreign and stays rejected.
- `airoha_ppe_foe_is_bridge_slowpath()` keeps the software bridge
  `PPE_PKT_TYPE_BRIDGE` test for entries written by the driver and uses
  the native helper for the hardware-learned layout.
- `airoha_ppe_foe_commit_subflow_entry()` now takes the chosen layout.
  For a native entry it writes only `l2b.data`, `l2b.ib2`, `l2b.vlan1`,
  `l2b.vlan2` and `l2b.etype`; the hardware-learned destination/source
  MACs, ingress VLAN and opaque `l2b.key` are not touched. The `0x0f`
  `HIT_UNBIND_RATE_REACHED` path uses the same helper and layout, so it
  no longer treats the native entry as an IPv4/L4 hash bucket.
- Range, `state != BIND`, the FDB ownership and egress re-check,
  `spin_lock_bh(&ppe_lock)`, `GFP_ATOMIC` and the no-sleep rule in the
  RX path are unchanged. A rejected frame still increments
  `fdb_rx_no_slot` and stays with the software bridge; `fdb_promoted`
  rises only after the commit reached the PPE. The 937 ring and reject
  breakdown (RANGE/NO_ENTRY/BIND/TYPE) are kept and simply stop
  recording once the gate accepts.

### What is deliberately not changed

`REG_PPE_UNBIND_AGE` is already `03e80003` (`MIN_PACKETS=1000`,
`DELTA=3`) on the HG5382A and stays untouched. `l2b.key` is not written
and not synthesized; the hardware owns it. No software L2B entry is
built.

### Verification of 938

- Applies after 931→937 on a clean `553902f58` worktree with
  `git apply --check`/`git apply` rc=0 (tree `~/kbuild/tree-938-apply`);
  the result matches the edited `tree-938` byte for byte.
- Driver compile in both configurations on `~/kbuild/tree-938`
  (`~/kbuild/logs/41-938-build-both.log`): `CONFIG_A_BUILD_RC=0` and
  `CONFIG_B_BUILD_RC=0`; only the same two pre-existing warnings
  (`pcs-airoha-common.c:1426` and the `ppe%u_gdm2_default_cpu_port`
  format warning in `airoha_ppe_debugfs.c`).
- The image is built by the normal `make target/install` flow, not
  repacked.

## Stage 6 — 939: make the diagnostic catch the test frames

`939-net-airoha-wrap-l2b-dbg-ring.patch` (md5
`bb115a9533de6d900a107ff9d86091da`) is **instrumentation only** once
more: it does not write a PPE or FOE entry, does not start a commit and
does not change the 938 gate or the forwarding decision.

### Why the ring has to wrap

938 made the gate layout-aware, but the HG5382A still refused every
bridged test frame: after 300 frames `fdb_rx_no_slot` rose by the same
+456 as `fdb_rx_no_flow`, `fdb_promoted` stayed 0 and no BRIDGE entry
appeared. 937 kept only the **first 32** refused frames after boot, and
on this board those slots were already full of ambient traffic
(`type=4/5`, IPv4/L4 entries) before the test started. A saturating
"first N" ring therefore cannot capture the frames under test, no
matter how long the run is.

939 turns the array into a wrapping ring: once all 32 slots have been
written the next record overwrites the oldest one, so the file always
holds the **last 32** refused frames. `recorded` is still the number of
valid slots, `total` is the lifetime record count and every record
carries its `seq` (the `total` value when it was written). Debugfs
starts at `head` when the ring is full and prints oldest to newest.

### What a record now holds

- The 937 fields: descriptor `AIROHA_RXD4_FOE_ENTRY`, raw
  `AIROHA_RXD4_PPE_CPU_REASON`, raw `ib1`, the word at the native L2B
  `ib2` offset (44), parsed `state`/`type`, ingress `ifindex`,
  `jiffies` and the reject reason.
- A raw dump of the candidate entry: 16 u32 words, **entry bytes
  0..63**, printed as four `raw+NN` lines. The copy is taken under the
  existing `ppe_lock` through `airoha_ppe_foe_get_entry_locked()`,
  before the lock is dropped; debugfs never dereferences the DMA entry.
  If 930's native layout is wrong, the dump shows where the
  hardware-learned destination/source MACs really are.
- `entry_dst`/`entry_src`, reconstructed from the same `l2b` fields the
  gate compares (offset 4/10 and 16/22), plus the frame's `skb_dst` and
  `skb_src` from `eth_hdr()`. A MAC-ownership mismatch is visible in
  the row without decoding the dump.

### Counters

Next to the `fdb_*` totals, `l2b_dbg` prints:

```text
l2b_reject: RANGE=... NO_ENTRY=... BIND=... TYPE=... KEY=... ACCEPTED=...
```

`RANGE`, `NO_ENTRY`, `BIND` and `TYPE` are the 937 categories. `KEY` is
new: the slot has the native L2B layout but its destination/source MACs
do not match this frame, i.e. the mismatch inside
`airoha_ppe_foe_is_native_l2b()`. `ACCEPTED` counts the candidates where
the gate passed and the commit was about to be attempted. The counters
count every rejection, including records that have already wrapped, so
`total` should equal `RANGE + NO_ENTRY + BIND + TYPE + KEY`.

### What to read on the board

```sh
cat /sys/kernel/debug/ppe/l2b_dbg
```

- `total` grows with every refused frame while `recorded` saturates at
  32: the printed rows are the **last** 32, not the first.
- `KEY` with `entry_dst != skb_dst` or `entry_src != skb_src` means the
  slot the descriptor points at belongs to another MAC pair; 938's key
  assumption is then wrong for this path. Compare the raw dump to find
  the real offsets.
- `RANGE` dominating still means the descriptor index is the `0xffff`
  sentinel; `NO_ENTRY` and `BIND` keep their 937 meaning.
- `ACCEPTED` rising while `fdb_promoted` stays 0 moves the failure to
  the FDB/VLAN/egress side, where 938 already logs the error.

### Verification of 939

- Applies after 931→938 on a clean `553902f58` worktree with
  `git apply --check`/`git apply` rc=0 for every patch
  (`~/kbuild/logs/42-939-apply-check.log`); the result matches the
  edited `tree-938-gen` byte for byte and leaves no `.rej`.
- Driver compile in both configurations
  (`~/kbuild/logs/43-939-build-both.log`):
  `CONFIG_A_BUILD_RC=0`, `CONFIG_B_BUILD_RC=0`; only the same two
  pre-existing warnings (`pcs-airoha-common.c:1426` and the
  `ppe%u_gdm2_default_cpu_port` format warning in
  `airoha_ppe_debugfs.c:246`).
- The image is built by the normal `make target/install` flow, not
  repacked.

## Stage 7 — 940: route HIT_UNBIND_RATE_REACHED to the bridge slow path

`940-net-airoha-route-rate-reached-to-bridge-slowpath.patch` (md5
`2150ac709f98d93065064a91cb2da2fb`) changes only the RX CPU-reason dispatch
and adds a read-only eligibility test. It does not change the FOE/PPE layout,
the ownership gate or the promote path.

### Measured trigger

On the HG5382A, a controlled 300-frame bridged test (lan3 DSA -> lan1 GDM,
all 300 frames forwarded by software) produced this CPU-reason histogram
delta:

| Reason | Delta |
| --- | --- |
| `0x0f` HIT_UNBIND_RATE_REACHED | +223 |
| `0x0e` HIT_UNBIND | +90 |
| `0x0d` UN_HIT | +25 |
| everything else | +0 |

`0x0f` is the hardware saying that the flow reached the minimum PPS and
should be bound. In 936's dispatch it still went to
`airoha_ppe_check_skb()`, the sub-flow path; the bridge RX slow path and its
938 gate were never entered for these frames, so `fdb_promoted` stayed 0.
The `l2b_dbg` ring independently confirmed that ambient IPv4-kind entries at
the L2B MAC offsets are rejected by the `KEY` ownership check, so the gate
itself is correct.

### What 940 changes

- `airoha_eth.c` 0x0f case: call `airoha_ppe_bridge_rx_is_candidate()`
  first. If it returns true, `airoha_ppe_bridge_rx_slowpath()` handles the
  frame; otherwise the original `airoha_ppe_check_skb()` path runs
  unchanged. The `if`/`else` calls exactly one handler, so a frame is never
  processed by both.
- New `airoha_ppe_bridge_rx_is_candidate()` in `airoha_ppe.c`, declared in
  `airoha_eth.h`. It writes nothing and checks:
  - the ingress is a bridge port or a DSA conduit;
  - the destination is unicast;
  - the NPU is attached;
  - the bridge FDB maps the destination MAC/VID to a valid airoha GDM
    egress different from the ingress;
  - the egress action is untagged-in/untagged-out, i.e. it needs no VLAN
    rewrite.
  It refreshes the cached egress VLAN flags under `ppe_lock`, like the
  promote path, but does not count or promote anything.
- The slow-path ownership gate is untouched: range, BIND state, native or
  software layout, MAC key, and the
  RANGE/NO_ENTRY/BIND/TYPE/KEY/ACCEPTED counters. A foreign slot still
  increments its reject counter and the frame stays in software. If the FDB
  test passes but the slot is foreign, the frame goes to the slow path (and
  is rejected there), not to `airoha_ppe_check_skb()`, so it cannot be
  committed twice.
- Non-bridge 0x0f flows (routed/nft, non-candidate bridge ports, tagged or
  rewrite cases, no NPU) keep the previous behaviour.

### Verification of 940

- Applies after 931 -> 939 on a clean `553902f58` worktree with
  `git apply --check`/`git apply` rc=0; the resulting `airoha_eth.c`,
  `airoha_eth.h` and `airoha_ppe.c` are byte-identical to the edited
  `tree-940-apply`, with no `.rej`.
- Driver compile in both configurations: `CONFIG_A_BUILD_RC=0`
  (`NET_AIROHA=m`/`NET_DSA=m`) and `CONFIG_B_BUILD_RC=0`
  (`NET_AIROHA=y`/`NET_DSA=y`/`HSR=n`); only the two pre-existing warnings
  (`pcs-airoha-common.c:1426` and `airoha_ppe_debugfs.c:246`).
- The image is built by the normal `make target/install` flow, not
  repacked, from the committed patch on this branch.
- Not verified on hardware: whether the 300-frame test now raises
  `fdb_promoted` and creates a BRIDGE entry. That is the next board step;
  `fdb_rx_no_flow` and `fdb_promoted` should both rise and `l2b_dbg`'s
  ACCEPTED counter should become non-zero.
