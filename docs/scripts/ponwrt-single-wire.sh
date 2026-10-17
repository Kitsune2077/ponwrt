#!/bin/sh
# PonWrt 单线复用：一根网线同时承载「运营商透传」和「光猫管理网」
#
# 背景：按 docs/FLASHING.md 第 6 节把 2.5G 口桥给下游路由器拨号后，光猫的管理地址
# 192.168.1.1 只留在千兆口那一侧的桥上，路由器（WAN 口 PPPoE）访问不到。若两台设备
# 之间只方便拉一根网线，本脚本把 2.5G 口改成「VLAN 干线」：
#
#     2.5G 口 ──┬── 运营商透传（保持原样：untagged，或沿用你已有的 bridge-vlan tag↔untag）
#               └── VLAN <VID> (tag)：光猫管理网 192.168.1.0/24
#
# 千兆口（lan2/lan3/lan4）行为不变：仍是 untagged 的 192.168.1.0/24，插电脑就能管理。
#
# 脚本只做「加法」：
#   * 运营商侧已有的 bridge-vlan（例如 OLT 带 tag 3114、2.5G 口剥 tag）原样保留；
#   * 只有在运营商桥还没做 VLAN 过滤时，才补一条 untagged 透传条目（--isp-vid）。
#   * 光猫还在出厂状态（wan 直接挂在 pon 上、没有独立运营商桥）时，脚本会把 pon 并进
#     管理桥，并把 wan 接口改成挂桥上的无协议接口、删除 wan6（等效第 6 节 ②③），
#     避免 pon 同时被接口和桥占用。
#
# 下游路由器侧（示例见 docs/FLASHING.md 6.7.2）：
#     WAN 口上建 VLAN <VID> 子接口，静态 192.168.1.2/24，
#     放进单独的防火墙区并开 masquerade，放行 lan → 该区。
#
# 用法（在光猫上以 root 执行）：
#   sh ponwrt-single-wire.sh --dry-run      # 只打印将要做的改动
#   sh ponwrt-single-wire.sh                # 应用；10 分钟内不确认自动回滚
#   sh ponwrt-single-wire.sh --keep         # 确认保留当前配置（取消自动回滚）
#   sh ponwrt-single-wire.sh --revert       # 立刻回滚到执行前的配置
#   sh ponwrt-single-wire.sh --status       # 查看状态
#
# 可选参数：
#   --vid <n>       管理 VLAN，默认 2100（必须与路由器侧一致）
#   --isp-vid <n>   仅在运营商桥没有 VLAN 过滤时使用，默认 2（只在光猫内部使用，线上仍是 untagged）
#   --2.5g <name>   2.5G 口名（默认从运营商桥里自动推断；先 ip -br link 确认）
#   --up <name>     运营商桥名（默认自动找端口里含 pon 的那个桥）
#   --timeout <s>   自动回滚等待秒数，默认 600
#   --force         已存在同名管理 VLAN 时也继续（默认拒绝）
#
# 说明：改动只落在 /etc/config/network，备份放在 /root/，属于 sysupgrade 保留范围。

set -eu

VID=2100
ISP_VID=2
PORT25=""
UPBR_OPT=""
TIMEOUT=600
ACTION=apply
DRY=0
FORCE=0

# 路径可覆盖，便于离线自测；正常使用时保持默认即可
CONFIG_DIR="${CONFIG_DIR:-/etc/config}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
KEEP_MARK="${KEEP_MARK:-/tmp/single-wire-keep}"
STATE="${STATE:-$BACKUP_DIR/single-wire.state}"
TIMER_PID_FILE="${TIMER_PID_FILE:-/tmp/single-wire-timer.pid}"
NETWORK_INIT="${NETWORK_INIT:-/etc/init.d/network}"
FIREWALL_INIT="${FIREWALL_INIT:-/etc/init.d/firewall}"
uci() { command uci -c "$CONFIG_DIR" "$@"; }
uci_del() { uci -q delete "$@" 2>/dev/null || true; }

msg() { echo "[single-wire] $*"; }
die() { echo "[single-wire] 错误: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--vid)     VID="$2"; shift 2 ;;
		--isp-vid) ISP_VID="$2"; shift 2 ;;
		--2.5g)    PORT25="$2"; shift 2 ;;
		--up)      UPBR_OPT="$2"; shift 2 ;;
		--timeout) TIMEOUT="$2"; shift 2 ;;
		--keep)    ACTION=keep; shift ;;
		--revert)  ACTION=revert; shift ;;
		--status)  ACTION=status; shift ;;
		--dry-run) DRY=1; shift ;;
		--force)   FORCE=1; shift ;;
		-h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
		*) die "未知参数 $1（--help 查看用法）" ;;
	esac
done

case "$VID" in ''|*[!0-9]*) die "--vid 需要 1..4094 之间的数字" ;; esac
[ "$VID" -ge 1 ] && [ "$VID" -le 4094 ] || die "--vid 超出范围（1..4094）"
case "$ISP_VID" in ''|*[!0-9]*) die "--isp-vid 需要 1..4094 之间的数字" ;; esac
[ "$ISP_VID" -ge 1 ] && [ "$ISP_VID" -le 4094 ] || die "--isp-vid 超出范围（1..4094）"
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout 需要 1 以上的秒数" ;; esac
[ "$TIMEOUT" -ge 1 ] || die "--timeout 需要 1 以上的秒数"

# ---------- 工具函数 ----------
dev_section() {   # $1 = uci 设备名 -> 段名（@device[0] / 命名段）
	uci show network | sed -n "s/^network\.\([^.]*\)\.name='$1'\$/\1/p" | head -n1
}
dev_ports() { uci -q get "network.$1.ports" 2>/dev/null || true; }
dev_name() { uci -q get "network.$1.name" 2>/dev/null || true; }
sections_with_ports() { uci show network | sed -n "s/^network\.\([^.]*\)\.ports=.*/\1/p"; }
find_upstream() {   # 端口里含 pon* 的桥设备段
	for s in $(sections_with_ports); do
		case "$(dev_ports "$s")" in
			*pon*) echo "$s"; return 0 ;;
		esac
	done
	return 1
}
first_pon_port() { for p in $(dev_ports "$1"); do case "$p" in pon*) echo "$p"; return 0 ;; esac; done; }
first_other_port() { for p in $(dev_ports "$1"); do case "$p" in pon*) ;; *) echo "$p"; return 0 ;; esac; done; }

do_revert() {
	[ -f "$STATE" ] || die "没有记录备份路径（$STATE），无法回滚"
	. "$STATE"
	[ -f "$BACKUP" ] || die "备份文件不存在: $BACKUP"
	kill_timer
	cp "$BACKUP" "$CONFIG_DIR/network"
	rm -f "$KEEP_MARK"
	"$NETWORK_INIT" reload
	"$FIREWALL_INIT" reload
	msg "已回滚到 $BACKUP 并重新加载网络"
}

write_state() { printf 'BACKUP=%s\n' "$1" > "$STATE"; }

kill_timer() {   # 杀掉挂起的自动回滚定时器（避免 revert/重复 apply 后旧定时器再触发）
	if [ -f "$TIMER_PID_FILE" ]; then
		kill "$(cat "$TIMER_PID_FILE" 2>/dev/null)" 2>/dev/null || true
		rm -f "$TIMER_PID_FILE"
	fi
}

# ---------- 找到管理接口 / 它所在的桥 ----------
find_lan_iface() {   # 优先名为 lan 的接口，其次找挂在 br-* 上的接口
	if uci -q get network.lan.device >/dev/null 2>&1; then echo lan; return 0; fi
	for s in $(uci show network | sed -n "s/^network\.\([^.]*\)\.device=.*/\1/p"); do
		case "$(uci -q get "network.$s.device" 2>/dev/null)" in
			br-*) echo "$s"; return 0 ;;
		esac
	done
	return 1
}

LAN_IF="$(find_lan_iface 2>/dev/null || true)"
LANDEV=""
[ -n "$LAN_IF" ] && LANDEV="$(uci -q get "network.$LAN_IF.device" 2>/dev/null || true)"
LAND=""
[ -n "$LANDEV" ] && LAND="$(dev_section "$LANDEV")"
# 应用之后：管理接口挂在 <桥>.<VID> 上，说明已经改过了
APPLIED=0
case "${LANDEV:-}" in *".$VID") APPLIED=1 ;; esac

if [ "$ACTION" = "status" ]; then
	if [ "$APPLIED" = "1" ]; then
		echo "状态           : 已应用（管理接口 $LAN_IF 的 device = $LANDEV）"
	else
		echo "状态           : 未应用"
	fi
	echo "管理接口       : ${LAN_IF:-?} (device=${LANDEV:-?})"
	if [ -n "$LAND" ]; then echo "该设备段       : $LAND（端口 $(dev_ports "$LAND")）"; fi
	if u="$(find_upstream 2>/dev/null || true)" && [ -n "$u" ]; then
		echo "运营商桥       : $(dev_name "$u")（段 $u，端口 $(dev_ports "$u")）"
	else
		echo "运营商桥       : 未找到（pon 可能直接挂在某个接口上）"
	fi
	uci show network | grep -E "@bridge-vlan\[[0-9]+\]\.(vlan|ports)=" || echo "（没有 bridge-vlan 配置）"
	echo "管理子接口     :"
	ip -br addr show "${LANDEV:-none}" 2>/dev/null || echo "  ${LANDEV:-?} 不存在"
	echo "自动回滚标记   : $( [ -f "$KEEP_MARK" ] && echo 已确认保留 || echo 未确认 )"
	exit 0
fi

if [ "$ACTION" = "keep" ]; then
	touch "$KEEP_MARK"
	kill_timer
	msg "已标记保留当前配置，自动回滚不会再执行"
	exit 0
fi

if [ "$ACTION" = "revert" ]; then
	do_revert
	exit 0
fi

# ---------- 探测拓扑 ----------
[ "$(id -u)" = "0" ] || die "请用 root 执行"
[ -n "$LAN_IF" ] || die "找不到管理接口（默认叫 lan）"
if [ "$APPLIED" = "1" ]; then
	msg "看起来已经应用过（$LAN_IF 的 device 已是 $LANDEV）；如需重做请先 --revert"
	exit 0
fi
[ -n "$LAND" ] || die "找不到管理接口所在的设备段（$LANDEV）"
if uci show network | grep -q "@bridge-vlan\[[0-9]*\]\.device='$LANDEV'"; then
	[ "$FORCE" = "1" ] || die "$LANDEV 上已有 bridge-vlan 配置，请先自行合并，或加 --force"
fi

UPBR=""
if [ -n "$UPBR_OPT" ]; then
	UPBR="$(dev_section "$UPBR_OPT")"
	[ -n "$UPBR" ] || die "找不到名为 $UPBR_OPT 的设备段"
else
	UPBR="$(find_upstream 2>/dev/null || true)"
fi

if [ -n "$UPBR" ] && [ "$UPBR" != "$LAND" ]; then
	# 已有独立的运营商桥：保留它现有的 bridge-vlan，只补管理 VLAN
	UPNAME="$(dev_name "$UPBR")"
	PON="$(first_pon_port "$UPBR")"
	[ -n "$PORT25" ] || PORT25="$(first_other_port "$UPBR")"
	NEED_ISP_VLAN=0
	if [ "$(uci -q get "network.$UPBR.vlan_filtering" 2>/dev/null || echo 0)" != "1" ] \
	   || ! uci show network | grep -q "@bridge-vlan\[[0-9]*\]\.device='$UPNAME'"; then
		NEED_ISP_VLAN=1
	fi
else
	# 没有独立运营商桥：把 pon 并进 br-lan，运营商按 untagged 透传
	UPBR="$LAND"
	UPNAME="$(dev_name "$LAND")"
	PON="$(uci -q get network.wan.device 2>/dev/null || echo pon0)"
	case "$PON" in pon*) ;; *) PON="pon0" ;; esac
	[ -n "$PORT25" ] || die "没有独立的运营商桥，请用 --2.5g <2.5G口名> 指定（先 ip -br link 确认）"
	NEED_ISP_VLAN=1
	# 出厂状态 wan 直接占着 pon：并桥后改成挂桥上的无协议接口，否则 netifd 报 device in use
	FIX_WAN=0
	if [ "$(uci -q get network.wan.device 2>/dev/null || true)" = "$PON" ]; then
		FIX_WAN=1
	fi
fi
[ -n "${PON:-}" ] || PON="pon0"
[ -n "${UPNAME:-}" ] || UPNAME="br-lan"
[ -n "${PORT25:-}" ] || die "推断不出 2.5G 口，请用 --2.5g <口名> 指定"

# 2.5G 口必须是目标桥的成员（bridge-vlan 引用非成员口时内核会静默忽略，配了也不生效）
case " $(dev_ports "$UPBR") " in
	*" $PORT25 "*) ;;
	*) die "$PORT25 不在桥 $UPNAME 的端口列表里，请用 --2.5g 指定实际的桥成员口" ;;
esac
if [ "$NEED_ISP_VLAN" = "1" ] && [ "$VID" = "$ISP_VID" ]; then
	die "管理 VLAN 与运营商 VLAN 都是 $VID，请用 --vid/--isp-vid 错开"
fi

# 管理 VLAN 是否已被占用
if uci show network | grep -q "@bridge-vlan\[[0-9]*\]\.vlan='$VID'"; then
	[ "$FORCE" = "1" ] || die "已经有 VLAN $VID 的 bridge-vlan，请换 --vid，或加 --force"
fi
if [ "$NEED_ISP_VLAN" = "1" ] && uci show network | grep -q "@bridge-vlan\[[0-9]*\]\.vlan='$ISP_VID'"; then
	die "已经有 VLAN $ISP_VID 的 bridge-vlan（用于运营商 untagged 条目），请用 --isp-vid 换一个"
fi

# 需要并进桥的端口 vs 需要挂到管理 VLAN 的端口
CUR_UP_PORTS="$(dev_ports "$UPBR")"
PORTS_TO_ADD=""
for p in $(dev_ports "$LAND"); do
	[ "$p" = "$PORT25" ] && continue
	[ "$p" = "$PON" ] && continue
	case " $CUR_UP_PORTS " in *" $p "*) continue ;; esac
	PORTS_TO_ADD="$PORTS_TO_ADD $p"
done
PORTS_TO_ADD="$(echo $PORTS_TO_ADD)"

FINAL_PORTS="$CUR_UP_PORTS $PORTS_TO_ADD"
MGMT_PORTS=""
for p in $FINAL_PORTS; do
	[ "$p" = "$PORT25" ] && continue
	[ "$p" = "$PON" ] && continue
	MGMT_PORTS="$MGMT_PORTS $p"
done
MGMT_PORTS="$(echo $MGMT_PORTS)"
[ -n "$MGMT_PORTS" ] || msg "警告：桥里没有千兆口，管理网只会走 2.5G 口"

echo "--- 当前 ---"
echo "br-lan 桥      : $(dev_name "$LAND")（段 $LAND，端口 $(dev_ports "$LAND")）"
[ "$LAND" != "$UPBR" ] && echo "运营商桥       : $UPNAME（段 $UPBR，端口 $CUR_UP_PORTS）"
echo "PON 设备       : $PON"
echo "2.5G 口        : $PORT25"
echo "管理口         : ${MGMT_PORTS:-（无）}"
echo "lan 接口       : $LAN_IF (device=$LANDEV, proto=$(uci -q get "network.$LAN_IF.proto"))"
echo "--- 计划 ---"
[ -n "$PORTS_TO_ADD" ] && echo "* 把 $PORTS_TO_ADD 并入桥 $UPNAME"
echo "* $UPNAME 打开 vlan_filtering"
if [ "$NEED_ISP_VLAN" = "1" ]; then
	echo "* 新增 bridge-vlan $ISP_VID（运营商 untagged 透传）：$PON:u* $PORT25:u*"
fi
printf '* 新增 bridge-vlan %s（管理网）：%s:t%s\n' "$VID" "$PORT25" "$(for p in $MGMT_PORTS; do printf ' %s:u*' "$p"; done)"
echo "* 新增 VLAN 子接口 ${UPNAME}.$VID，接口 $LAN_IF 的 device 改成它（地址不变）"
if [ "$LAND" != "$UPBR" ]; then echo "* 删除多余的桥设备段 $LAND"; fi
[ "${FIX_WAN:-0}" = "1" ] && echo "* wan 接口改为挂到 $UPNAME、proto=none（wan6 删除），不再直接占用 $PON"
echo "--------------"

if [ "$DRY" = "1" ]; then
	msg "--dry-run：未做任何改动"
	exit 0
fi

# ---------- 备份 + 自动回滚保险 ----------
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/network.pre-single-wire.$TS"
cp "$CONFIG_DIR/network" "$BACKUP"
cp "$CONFIG_DIR/firewall" "$BACKUP_DIR/firewall.pre-single-wire.$TS" 2>/dev/null || true
write_state "$BACKUP"
msg "已备份 $CONFIG_DIR/network -> $BACKUP"

rm -f "$KEEP_MARK"
kill_timer
(
	sleep "$TIMEOUT"
	if [ -f "$KEEP_MARK" ]; then
		rm -f "$TIMER_PID_FILE"
		exit 0
	fi
	cp "$BACKUP" "$CONFIG_DIR/network"
	"$NETWORK_INIT" reload
	"$FIREWALL_INIT" reload
	rm -f "$TIMER_PID_FILE" "$KEEP_MARK"
	logger -t single-wire "未在 ${TIMEOUT}s 内确认，已自动回滚网络配置"
) </dev/null >/dev/null 2>&1 &
echo $! > "$TIMER_PID_FILE"
msg "已启动自动回滚：${TIMEOUT}s 内执行 '$0 --keep' 确认，否则恢复原配置"

# ---------- 应用 ----------
for p in $PORTS_TO_ADD; do
	uci add_list "network.$UPBR.ports=$p"
done
uci set "network.$UPBR.vlan_filtering"='1'

if [ "$NEED_ISP_VLAN" = "1" ]; then
	uci add network bridge-vlan >/dev/null
	uci set "network.@bridge-vlan[-1].device=$UPNAME"
	uci set "network.@bridge-vlan[-1].vlan=$ISP_VID"
	uci add_list "network.@bridge-vlan[-1].ports=$PON:u*"
	uci add_list "network.@bridge-vlan[-1].ports=$PORT25:u*"
fi

uci add network bridge-vlan >/dev/null
uci set "network.@bridge-vlan[-1].device=$UPNAME"
uci set "network.@bridge-vlan[-1].vlan=$VID"
uci add_list "network.@bridge-vlan[-1].ports=$PORT25:t"
for p in $MGMT_PORTS; do
	uci add_list "network.@bridge-vlan[-1].ports=$p:u*"
done

uci_del network.singlewire
uci set network.singlewire=device
uci set network.singlewire.name="$UPNAME.$VID"
uci set network.singlewire.type='vlan'
uci set network.singlewire.ifname="$UPNAME"
uci set network.singlewire.vid="$VID"

uci set "network.$LAN_IF.device=$UPNAME.$VID"

# 原来那个只放千兆口的桥不再需要
if [ "$LAND" != "$UPBR" ]; then
	uci_del "network.$LAND"
fi

# 出厂状态并桥时，wan 不再直接占 pon（等效 FLASHING 6.2 ③）
if [ "${FIX_WAN:-0}" = "1" ]; then
	uci set "network.wan.device=$UPNAME"
	uci set network.wan.proto='none'
	uci_del network.wan6
fi

uci commit network

"$NETWORK_INIT" reload
sleep 4
"$FIREWALL_INIT" reload

msg "配置已应用，检查结果："
echo "  ip -br addr show $UPNAME.$VID      # 应看到管理地址（如 192.168.1.1/24）"
echo "  bridge vlan show                   # 2.5G 口应同时有运营商 VLAN 与 tagged 的 $VID"
echo "  ip -br link | grep $PORT25         # 2.5G 口应为 UP"
echo
echo "确认无误后执行： sh $0 --keep"
echo "有问题立即执行： sh $0 --revert"
