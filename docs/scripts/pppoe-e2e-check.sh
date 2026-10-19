#!/bin/sh
# pppoe-e2e-check.sh - read-only PPPoE passthrough / bridge-L2B check on the ONU
#
# Run this on the ONU after the fibre is connected and a PPPoE client has
# dialled through the bridged setup. It inspects the bridge membership, the
# VLAN configuration, the PPE entries and the bridge-offload counters.
#
# This script is READ-ONLY. It does not write /etc, /sys, the FDB or any
# module parameter, and it does not flush or reset counters. The only writes
# are to stdout. The vlan_rewrite off/on comparison is printed as suggested
# commands; it is not executed.
#
# Usage:
#   sh pppoe-e2e-check.sh [interval]
#
#   interval: seconds between the two counter snapshots, default 5.
#
# What to expect (measured on the HG5382A with the 940 image):
#   * a PPPoE session is non-IP at the bridge (EtherType 0x8864), so it takes
#     the same L2B path as the verified 0x88b5 test;
#   * a fresh promotion moves fdb_promoted by +1 and l2b_reject ACCEPTED by
#     +1, and adds a bound ("BND") "L2B" row to /sys/kernel/debug/ppe/entries;
#   * a second run without flushing the FDB keeps fdb_promoted flat while all
#     frames are still delivered. Flat is the steady state, not a failure.
#
# Important: the etype= column in ppe/entries is FOE L2B metadata, not the
# Ethernet frame type. The measured 0x88b5 bridge entry printed etype=0000,
# and the bridge promote path does not fill the PPPoE/GEM metadata for a GDM
# egress, so do not expect (or require) etype=8864 to identify the session.

set -u

INTERVAL="${1:-5}"
case "$INTERVAL" in
    ''|*[!0-9]*)
        echo "usage: sh $0 [interval-seconds]" >&2
        exit 2
        ;;
esac

PPE_DIR="/sys/kernel/debug/ppe"
CONFIG="$PPE_DIR/config"
ENTRIES="$PPE_DIR/entries"
L2B_DBG="$PPE_DIR/l2b_dbg"
VLAN_REWRITE="/sys/module/airoha_eth/parameters/vlan_rewrite"

section() {
    printf '\n===== %s =====\n' "$1"
}

as_int() {
    case "${1:-}" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

delta() {
    echo $(( $(as_int "$2") - $(as_int "$1") ))
}

# Print the part after "key:" from a captured block.
get_field() {
    printf '%s\n' "$1" | awk -v key="$2" '
        index($0, key) == 1 {
            sub("^[^:]*:[ \t]*", "", $0)
            print $0
            exit
        }'
}

get_reject_field() {
    printf '%s\n' "$1" | sed -n "s/.*$2=\([0-9][0-9]*\).*/\1/p" | head -n 1
}

snap_config() {
    [ -r "$CONFIG" ] || return 0
    grep -E '^(npu_attached|fdb_promoted|fdb_no_entry|fdb_no_npu|fdb_rx_no_flow|fdb_rx_no_slot):' "$CONFIG" 2>/dev/null || true
}

snap_l2b() {
    [ -r "$L2B_DBG" ] || return 0
    grep -E '^(fdb_rx_no_flow|fdb_rx_no_slot|fdb_promoted):|^l2b_reject:' "$L2B_DBG" 2>/dev/null | head -n 4 || true
}

count_bnd_l2b() {
    if [ ! -r "$ENTRIES" ]; then
        echo "n/a"
        return 0
    fi
    n=$(grep -cE 'BND[[:space:]]+L2B' "$ENTRIES" 2>/dev/null) || n=0
    echo "$n"
}

show_bridge() {
    br="$1"
    section "bridge $br"
    if [ ! -e "/sys/class/net/$br" ]; then
        echo "  $br is absent"
        return 0
    fi
    ip -d link show "$br" 2>/dev/null || echo "  ip -d link show $br failed"
    if [ -d "/sys/class/net/$br/brif" ]; then
        echo "  member ports (sysfs):"
        for p in "/sys/class/net/$br/brif"/*; do
            [ -e "$p" ] || continue
            echo "    ${p##*/}"
        done
    fi
    if command -v bridge >/dev/null 2>&1; then
        echo "  bridge link show (master $br):"
        bridge link show 2>/dev/null | grep -E "master ${br}([[:space:]]|$)" || echo "    (none)"
    fi
    if command -v brctl >/dev/null 2>&1; then
        brctl show "$br" 2>/dev/null || true
    fi
}

section "PPPoE passthrough end-to-end check (read-only)"
echo "  interval: ${INTERVAL}s; host: $(uname -n 2>/dev/null || echo unknown)"
echo "  kernel : $(uname -r 2>/dev/null || echo unknown)"
echo "  image  : $(cat /etc/openwrt_release 2>/dev/null | grep -E '^DISTRIB_(DESCRIPTION|REVISION)=' || true)"

show_bridge "br-lan"
show_bridge "br-wan"

section "bridge VLAN configuration"
if command -v bridge >/dev/null 2>&1; then
    # -c is colour output; it may not exist on old bridge tools.
    bridge -c vlan show 2>/dev/null || bridge vlan show 2>/dev/null || echo "  bridge vlan show failed"
else
    echo "  'bridge' command not found"
fi

section "PPPoE session / interfaces"
ps w 2>/dev/null | grep -E '[p]pppd|[p]pppoe' || echo "  no pppd/pppoe process on the ONU"
if ip -br link show >/dev/null 2>&1; then
    ip -br link show 2>/dev/null | grep -Ei 'pppoe|ppp[0-9]' || true
else
    ip link show 2>/dev/null | grep -Ei 'pppoe|ppp[0-9]' || true
fi
echo "  (If the PPPoE client is the downstream router, no pppd process is expected here.)"

section "PPE debugfs"
if [ ! -r "$CONFIG" ]; then
    echo "  $CONFIG is not readable."
    echo "  Check that the 931-940 image is running and debugfs is mounted:"
    echo "    mount | grep debugfs"
    echo "  This script made no changes."
    exit 1
fi

echo "  npu_attached: $(get_field "$(snap_config)" 'npu_attached:')"
echo "  vlan_rewrite parameter: $(cat "$VLAN_REWRITE" 2>/dev/null || echo '(parameter file absent)')"

section "bound L2B entries (PPPoE session frames are non-IP)"
if [ -r "$ENTRIES" ]; then
    rows=$(grep -E 'BND[[:space:]]+L2B' "$ENTRIES" 2>/dev/null || true)
    if [ -n "$rows" ]; then
        printf '%s\n' "$rows"
    else
        echo "  (no BND L2B row)"
    fi
    echo "  BND L2B row count: $(count_bnd_l2b)"
    if grep -qE 'BND[[:space:]]+L2B.*etype=8864' "$ENTRIES" 2>/dev/null; then
        echo "  BND L2B row with etype=8864: yes"
    else
        echo "  BND L2B row with etype=8864: no"
    fi
    echo "  NOTE: etype= is FOE L2B metadata, not the frame EtherType. The measured"
    echo "        0x88b5 entry printed etype=0000; a PPPoE L2B row may also print"
    echo "        0000. Judge by the BND L2B row and the counters, not by etype=."
else
    echo "  $ENTRIES is not readable"
fi

section "counter deltas over ${INTERVAL}s"
C1=$(snap_config)
L1=$(snap_l2b)
B1=$(count_bnd_l2b)
sleep "$INTERVAL"
C2=$(snap_config)
L2=$(snap_l2b)
B2=$(count_bnd_l2b)

for key in npu_attached fdb_promoted fdb_no_entry fdb_no_npu fdb_rx_no_flow fdb_rx_no_slot; do
    v1=$(get_field "$C1" "$key:")
    v2=$(get_field "$C2" "$key:")
    printf '  %-16s %8s -> %-8s (delta %s)\n' "$key" "$v1" "$v2" "$(delta "$v1" "$v2")"
done

printf '  %-16s %8s\n' "l2b_reject" "$(get_field "$L1" 'l2b_reject:')"
printf '  %-16s %8s\n' "  -> after" "$(get_field "$L2" 'l2b_reject:')"
for key in RANGE NO_ENTRY BIND TYPE KEY ACCEPTED; do
    r1=$(get_reject_field "$L1" "$key")
    r2=$(get_reject_field "$L2" "$key")
    printf '  %-20s %8s -> %-8s (delta %s)\n' "l2b_reject.$key" "$r1" "$r2" "$(delta "$r1" "$r2")"
done
printf '  %-16s %8s -> %-8s\n' "BND L2B rows" "$B1" "$B2"

section "softirq (%si): top -bn1 | head -3"
if command -v top >/dev/null 2>&1; then
    top -bn1 2>/dev/null | head -3 || echo "  top failed"
    echo "  (BusyBox top may label the softirq column %sirq; read the softirq percentage.)"
else
    echo "  top not found; use /proc/stat or mpstat if available."
fi

section "vlan_rewrite off/on comparison (suggested commands, not executed)"
cat <<'EOF'
  The parameter is read above. To compare, run the two passes manually:

    echo 0 > /sys/module/airoha_eth/parameters/vlan_rewrite
    # generate PPPoE traffic, then read ppe/config, ppe/l2b_dbg and ppe/entries
    echo 1 > /sys/module/airoha_eth/parameters/vlan_rewrite
    # repeat the same traffic and the same reads

  On the untagged lan3->lan1 test in TEST-RUNBOOK-an7581.md the parameter
  should not change the result: the test needs no tag rewrite. Use a tagged
  VLAN case to exercise the push path. Writing 0 stops new promotions from
  using a push but does not tear down flows that are already promoted; flush
  or delete the FDB entry, or reload the driver, between the two passes if a
  clean comparison is needed.

  This script did not write the parameter, the FDB, /etc or /sys.
EOF

section "how to read the result"
cat <<'EOF'
  Fresh promotion (first run after boot/FDB flush):
    fdb_promoted +1, l2b_reject ACCEPTED +1, at least one BND L2B row,
    and the PPPoE traffic is still delivered.

  Steady state (second run, no flush):
    fdb_promoted delta 0, a BND L2B row is present, fdb_rx_no_flow grows only
    with ambient traffic. Flat fdb_promoted here is success, not a failure.

  No promotion:
    fdb_rx_no_flow rises while fdb_promoted does not. Read the l2b_reject
    TYPE/KEY/RANGE/NO_ENTRY values, confirm the session frames are non-IP
    (0x8864), and confirm the destination MAC is on a GDM port (lan1/pon0),
    not on a DSA port (lan2/3/4).

  This script is read-only; all suggested writes above are printed only.
EOF
