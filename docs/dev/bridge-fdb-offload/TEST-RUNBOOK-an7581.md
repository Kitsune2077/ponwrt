# HG5382A 无光纤 PPE 验证速查（Runbook）

目的：在没有光信号的情况下，验证 `931`–`940` 是否真的把桥接单播流量提升进 PPE。
适用镜像：包含 `940-net-airoha-route-rate-reached-to-bridge-slowpath.patch` 的构建。
测试台：Windows 主机两块网卡，分别接光猫 `lan1`（GDM4）与 `lan3`（DSA），
两端口都在 `br-lan` 内。

> 关键：测试帧必须是非 IP 以太网帧。IP/ICMP 帧会被 PPE 归类为 IPv4 流
> （`type=4/5`），不会走 L2B 路径；用 `ping` 测不到本功能。

## 0. 光猫侧配置

```sh
# 桥: lan1 + lan3 + lan4, 管理 192.168.1.1
uci -q delete network.ponwan
uci -q delete network.brwan
uci set network.@device[0].name='br-lan'
uci set network.@device[0].type='bridge'
uci -q delete network.@device[0].ports
uci add_list network.@device[0].ports='lan1'
uci add_list network.@device[0].ports='lan3'
uci add_list network.@device[0].ports='lan4'
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.netmask='255.255.255.0'
uci commit network
/etc/init.d/network reload

# DHCP 不下发默认网关/DNS，避免抢走 Windows 的 WiFi 默认路由
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='3'
uci add_list dhcp.lan.dhcp_option='6'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

## 1. Windows 侧

### 1.1 网络设置

```powershell
# LAN 网卡 metric 抬高，上网继续走 WiFi（非 IP 测试不依赖默认路由，
# 但可以避免 Windows 把管理网当成默认出口）
Set-NetIPInterface -InterfaceAlias '以太网 2' -InterfaceMetric 6000
Set-NetIPInterface -InterfaceAlias '以太网'   -InterfaceMetric 6000
```

非 IP 测试不需要静态邻居、ARP 或任何 IP 地址；目的 MAC 直接填接收网卡
`lan1` 的 MAC。先确认两块网卡的名字和 MAC：

```powershell
Get-NetAdapter | Format-Table Name, MacAddress, Status
```

### 1.2 发送非 IP 帧（`Ether(type=0x88b5)/Raw(...)`）

`0x88b5` 是本地/实验 EtherType，协议栈不会响应，适合做纯二层转发测试。
下面的 Scapy 脚本从 `lan3` 侧发出 300 帧，在 `lan1` 侧抓包，按帧内的
序号去重后打印实际到达数量。

```python
from scapy.all import *
import threading, time

LAN3, LAN1 = '以太网 2', '以太网'      # 发送 / 接收网卡
SRC,  DST  = '0c:9d:92:cb:8b:c5', '80:86:f2:01:cc:f0'
ETYPE, COUNT = 0x88b5, 300
MAGIC = b'PONWRT-L2B'

seen, lock = set(), threading.Lock()

def on_rx(p):
    if not p.haslayer(Ether) or p[Ether].type != ETYPE:
        return
    if p[Ether].dst.lower() != DST.lower():
        return
    payload = bytes(p[Raw].load) if p.haslayer(Raw) else b''
    if payload.startswith(MAGIC) and len(payload) >= len(MAGIC) + 4:
        seq = int.from_bytes(payload[len(MAGIC):len(MAGIC) + 4], 'big')
        with lock:
            seen.add(seq)

t = threading.Thread(target=lambda: sniff(iface=LAN1, timeout=10,
                                         prn=on_rx, store=False))
t.start(); time.sleep(1)

frames = [Ether(src=SRC, dst=DST, type=ETYPE) /
          Raw(MAGIC + i.to_bytes(4, 'big') + b'.' * 52)
          for i in range(COUNT)]
sendp(frames, iface=LAN3, inter=0.01, verbose=False)
t.join()

delivered = len(seen & set(range(COUNT)))
print(f'delivered {delivered}/{COUNT}, missing {COUNT - delivered}')
```

也可以直接使用 `docs/scripts/pppoe-l2b-test.ps1`，它封装了同一段发送/抓包
逻辑，并可选通过 SSH 读取光猫计数器：

```powershell
.\docs\scripts\pppoe-l2b-test.ps1 -TxIf '以太网 2' -RxIf '以太网' `
    -SrcMac '0c:9d:92:cb:8b:c5' -DstMac '80:86:f2:01:cc:f0' -Count 300
```

### 1.3 为什么不能改用 `ping` / ICMP

PPE 按报文内容分类。IPv4/ICMP 帧进入的是 IPv4 流（`type=4/5`，IPv4
5T/3T），不是 `PPE_PKT_TYPE_BRIDGE`，所以 940 的桥接 L2B 慢路径根本不会
被调用。之前的 300 帧 IP/ICMP 测试没有产生提升，就是这个原因；它不能用来
判断本功能是否工作。

只有非 IP 帧（例如 `0x88b5`）才会让 PPE 建出原生 L2B 表项。PPPoE 会话帧
（`0x8864`）在桥上是非 IP 的（载荷是 PPP，不是 IP 头），预期走同一条 L2B
路径，但端到端还需要光纤/OLT 才能验证。

## 2. 判读

刷机、配好桥之后，先记录一次基线，再开始发送：

```sh
cat /sys/kernel/debug/ppe/config | grep -E 'npu_attached|fdb_'
sed -n '1,4p' /sys/kernel/debug/ppe/l2b_dbg
grep -E 'BND[[:space:]]+L2B' /sys/kernel/debug/ppe/entries || true
```

跑完第一轮 300 帧后，再执行同样的命令。判读表：

| 观察 | 含义 | 下一步 |
| --- | --- | --- |
| `npu_attached: 1`，`fdb_promoted` +1，`entries` 出现 `BND L2B` | 触发、提交、建表都成立 | 跑第二轮，确认转发停留在硬件 |
| `fdb_promoted` 不涨，`l2b_reject` 的 `TYPE` 或 `KEY` 增长 | 命中了别的布局/别的 MAC，不是本帧的 L2B 槽位 | 检查是否用了 IP 流量，或 FDB 目的 MAC 是否真的在 lan1 |
| `l2b_reject` 的 `ACCEPTED` 增长，但 `fdb_promoted` 不涨 | 门禁已通过，失败在 FDB/VLAN/egress 或提交 | `dmesg | grep -i promote` 看 `failed to promote` 的错误码 |
| `fdb_rx_no_flow` 增长但 `fdb_promoted` 不涨 | 帧进了慢路径，但没有可绑定的槽位 | 看 `l2b_dbg` 的 `TYPE`/`KEY`/`RANGE`/`NO_ENTRY`；确认是非 IP 帧 |
| `npu_attached` 仍为 0 | attach 工作项没被调度或失败 | 查 `fdb_no_npu` 与 `dmesg` |
| 用 ICMP/ping 测试 | 走 IPv4 流，不是 L2B | 换回 `Ether(type=0x88b5)/Raw(...)` |

### 2.1 一次成功的“长相”

第一轮（本机在 HG5382A 上实测）：

- `entries` 出现一行 `BND L2B`，MAC 对与测试的发送/接收网卡一致：

  ```text
  01e6c BND   L2B eth=0c:9d:92:cb:8b:c5->80:86:f2:01:cc:f0 etype=0000 data=007f0000 vlan=0,0 ib1=6500005f ib2=0003e720 packets=0 bytes=0
  ```

- `fdb_promoted` 从 0 变 1（它数的是“提升/提交的表项数”，不是帧数）。
- `l2b_dbg` 的 `l2b_reject:` 行末尾 `ACCEPTED=1`。
- 抓包 `delivered` 应等于 `sent`（第一轮提升前后都可能由软件桥转发，
  到达数量本身不能单独证明硬件转发）。

第二轮（**不要**重启、不要 `bridge fdb flush`、不要重载驱动，直接再发
300 帧）：

- `delivered 300/300`；
- `fdb_promoted` 仍为 1（同一 flow 不会重复提升，**停在 1 才是成功**）；
- `fdb_rx_no_flow` 不因这批测试帧增长，只随环境流量缓慢增长。

第二轮这三条合起来是本功能的核心证据：已经绑定的 L2B 表项由 PPE 直接
转发，帧不再被送到 CPU 的桥接慢路径。若仍在软件桥转发，
`fdb_rx_no_flow` 会随这 300 帧增长。

### 2.2 常见误判

- **用 `ping` 或 ICMP 测**：看不到 `BND L2B`，因为 IP 帧走 IPv4 流；
  可能看到别的 PPE 条目，但与桥接 L2B 无关。
- **看到 `fdb_promoted` 停在 1 就以为失败**：第一轮 0 → 1 后，后续同一
  flow 不再提升；停在 1 且第二轮 300/300 才是期望结果。
- **用 `etype=88b5` 去 grep `entries`**：`etype=` 是 FOE 的 L2B 元数据，
  不是帧的 EtherType。GDM 出口的 L2B 表项实测为 `etype=0000`；用
  `BND L2B`、MAC 对和计数器判断。
- **第一轮抓包看到软件转发就判失败**：提升发生在第一轮的某一帧，之前
  的帧由软件桥转发是正常的；以计数器变化和第二轮结果为准。
- **两轮之间清 FDB / 重启网络**：会重新走一遍提升，第二轮的“稳定在 1”
  就不再成立。

## 3. 已知限制

- 只有 `lan1` 与 `pon0` 是 GDM 口；`lan2/3/4` 是 DSA 口，**目标 MAC 落在
  DSA 口时不可卸载**（`airoha_netdev_is_offloadable()` 会拒绝）。
- 因此本测试必须是“**dst MAC 在 lan1**”（即从 lan3 发、到 lan1），反过来
  测不到。
- 带标签 VLAN 的下行（`pon0:t` → `lan1:u*`）需要硬件剥标签，当前没有实现
  tag pop；`vlan_rewrite` 默认 0，940 也会把带标签的帧留在软件桥。
- PPPoE（`0x8864`）预期走同一条非 IP/L2B 路径，但端到端需要光纤/OLT，
  目前**未验证**；不要用本 runbook 的结果声称 PPPoE 拨号或 PON 转发已成功。
- IP/ICMP 流量属于 IPv4 流路径，超出本功能范围。
