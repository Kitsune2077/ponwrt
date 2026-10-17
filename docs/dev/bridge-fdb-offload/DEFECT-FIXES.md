# Bridge FDB offload — defect fixes

These are the fixes for the defects found in the review of the four-patch
series. They are folded into the patch bodies that introduce the code, not
added as follow-up patches:

| Patch | Fixes |
| --- | --- |
| `931-net-airoha-ppe-add-bridge-FDB-offload-table.patch` | D1, D3, D4, D5 |
| `933-net-airoha-report-a-port-parent-id-for-bridge-offload.patch` | defensive probe fix |
| `934-net-airoha-inspect-bridge-FDB-entries-held-by-PPE.patch` | D2 |

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

## What remains for stage 2

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
