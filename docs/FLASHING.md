# PonWrt 刷机指南（以 FiberHome HG5382A 为例）

本指南描述如何把 PonWrt 固件刷入 Airoha AN7581/AN7583 平台的光猫，全程免拆机。
详细流程以 **FiberHome HG5382A**（2.5G 网口纯有线 XG-PON 光猫）为例，其它机型差异见文末。

> ⚠️ **免责声明**：刷机存在变砖、配置丢失、PON 无法注册的风险。
> 操作前请务必备份原厂固件与设备数据，并确保符合当地法规及运营商规定。
> 因刷机产生的任何后果由使用者自行承担。

---

## 0. 准备文件

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `*-fiberhome_hg5382a-sysupgrade.itb` | 本仓库 Releases（Actions 自动构建） | 正式刷机镜像 |
| `an7581-fiberhome-hg5382a-firstblock.bin`（或 `*-preloader.bin`） | [uboot-an758x Releases](https://github.com/pbs05/uboot-an758x/releases) | U-Boot BL2 引导 |
| `an7581-fiberhome-hg5382a-bl31-u-boot.fip` | 同上 | U-Boot 主体 |
| `an758x-stock2ubi` | [an758x-stock2ubi Releases](https://github.com/pbs05/an758x-stock2ubi/releases) | 原厂系统内使用的免拆刷入工具（aarch64） |
| FiberHome Factory 工具 | [fiberhome-factory](https://github.com/pbs05/fiberhome-factory) | 烽火 factory 镜像转换（GUI，Windows/macOS/Linux） |

uboot-an758x 请使用 **v2026.07-4 或更新**：更早的版本对 Winbond `W29N02KVSIAF`（部分 HG5382A
批次使用的 NAND）按错误的 ECC 位宽处理该芯片，配合 Stock2UBI 免拆刷入会导致设备读不到 `fip` 卷，
表现为“全灯不亮、`192.168.0.1` 打不开”。遇到这种情况不必换机，按
[救砖指南](UNBRICK.md) 走一遍串口恢复即可。

HG5382A 硬件概况（刷机前先了解）：

- SoC：Airoha AN7581，四核 Cortex-A53 + NPU 硬件转发，512MB 内存，并联 NAND
- 网口：`lan1` = **2.5G 电口**（MaxLinear GPY211 PHY）；`lan2`/`lan3`/`lan4` = 千兆电口
- 光口：XG-PON，系统内接口名为 `pon0`
- 原厂校准/身份数据分区：`factory`（含 PON 序列号、MAC、光模块 APONCAL 校准）

---

## 1. 备份原厂数据（不可跳过！）

1. 在原厂固件中开启 shell 权限（烽火机型一般通过维护账号 / SU 模式开启，
   可在恩山论坛搜索「HG5382A SU」获取对应运营商固件的开法）。
2. 将 `an758x-stock2ubi` 上传到光猫 `/tmp` 目录并运行：

   ```sh
   chmod +x /tmp/an758x-stock2ubi
   /tmp/an758x-stock2ubi
   ```

3. 浏览器打开 `http://<光猫IP>:3333/`，**逐个备份所有分区并下载到电脑保存**。
   - 最重要的是 `factory` 分区：PON 序列号、MAC、光模块校准数据都在里面，
     一旦丢失 PON 无法注册且难以恢复；
   - 其它分区也建议全部备份，作为救砖的最后手段。

## 2. 写入 U-Boot

仍在 `http://<光猫IP>:3333/` 页面：

1. 上传 `an7581-fiberhome-hg5382a-firstblock.bin`（或 `*-preloader.bin`，二选一）
   和 `an7581-fiberhome-hg5382a-bl31-u-boot.fip`；
2. 工具写入后会自动重启。

## 3. U-Boot Web 首次安装

1. 重启后电脑网线连光猫的 **`lan2` / `lan3` / `lan4`**（U-Boot 只启用内部交换机 `gdm1`，
   2.5G 的 `lan1` 要到 Linux 阶段才可用），访问 `http://192.168.0.1/` 进入 U-Boot 恢复界面
   （首次出现页面可能需要约 1 分钟；之后也可用**上电约 1 秒内按住 Reset** 进入）。
   PC 侧可以用 DHCP（U-Boot 自带 DHCP 服务，地址池 `192.168.0.100-199`）或静态 `192.168.0.x/24`；
2. 按顺序操作：
   1. **重建 UBI**；
   2. **写入 BL2**（`*-preloader.bin` 或 `*-firstblock.bin`，两者等价）——
      漏掉这一步，重启后 BL2 仍会因首块 ECC 不一致而读不到 `fip` 卷；
   3. **写入 `bl31-u-boot.fip`**；
   4. **恢复板级数据卷**（见第 4 节，转换后的 factory 镜像写入 `factory` 卷）；
   5. **上传 sysupgrade 镜像**：选择本仓库 Releases 里的
      `*-fiberhome_hg5382a-sysupgrade.itb`；
   6. **启动系统**。

## 4. factory 数据转换与恢复

烽火机型的原厂 `factory` 备份不能直接使用，需先用 FiberHome Factory 工具转换：

1. 打开 [fiberhome-factory](https://github.com/pbs05/fiberhome-factory) 工具，
   导入第 1 步备份的原厂 `factory` 镜像；
2. 核对身份信息（MAC、PON 序列号等）与原厂一致，**不要修改**；
3. 保存导出为 **1 MiB 布局**的新镜像；
4. 将导出的镜像写入 PonWrt 的 `factory` 卷（U-Boot Web 恢复页，
   或进系统后在 LuCI「网络 → PON → 配置 → PON board data」中恢复）。

## 5. PON 配置上线

1. 进入 LuCI（默认 `http://192.168.1.1/`，账号 `root`，无密码，请尽快设置密码）；
2. 在「网络 → PON → 配置」中确认 board data 已正确加载；
3. 编辑 `/etc/config/pon`，将模式与认证信息配置为**与原厂一致**：

   ```uci
   config xpon 'line0'
       option device 'pon0'
       option mode 'xgpon'        # 按原厂制式: xgpon / xgspon / epon-10g-1g / epon-10g-10g
       option serial_number '...'  # SN 认证: 原厂 PON SN; LOID 认证见 omci 段
   ```

   LOID 认证在 `line0_omci` 段填写 `loid` 与 `loid_password`；
4. 重启 PON 守护并观察注册状态：

   ```sh
   /etc/init.d/airoha-pond restart
   pondctl status --line line0
   ```

   `pon0` 指示灯（LOS 熄灭、注册灯常亮）亮起且 `ip link` 中 `pon0` 为 UP 即注册成功。

## 6. 桥接给下游路由器拨号（可选，2.5G 口跑满千兆以上带宽）

光猫做纯二层透传、由下游路由器 PPPoE 拨号时，需要把**光口 `pon0`** 与**2.5G 网口**
桥成一个**不带任何三层配置的桥**。多数机型（HG5382A、Nokia XG-040G-MD 等）的 2.5G 口
在系统里叫 `lan1`，下文以 `lan1` 为例；其它机型先用 `ip -br link` 确认 2.5G 口名再替换。

```
OLT ── pon0 ──[ br-wan（纯二层，无 IP/无协议）]── lan1 ── 下游路由器 WAN（PPPoE 拨号）
                                          └─ br-lan（其余网口）192.168.1.1，保留管理
```

### 6.1 首次安装后的默认配置

首次启动时板级初始化脚本（`etc/board.d/02_network`）会生成：

- `br-lan = lan1 lan2 lan3 lan4`，静态 192.168.1.1/24 并开启 DHCP 服务；
- `wan = pon0`，协议为 `dhcp`，同时生成一个 `dhcpv6` 的 `wan6` 接口。

也就是说 **`lan1` 默认在 `br-lan` 里、`pon0` 上还跑着 DHCP/DHCPv6 客户端**，两者都要处理掉，
光猫才不会往运营商二层网络里发自己的 DHCP 请求。

### 6.2 改成纯桥（SSH + UCI）

```sh
# ① 把 2.5G 口从默认 br-lan 里摘掉，其余网口继续做管理口
dev=$(uci show network | sed -n "s/^network\.\(.*\)\.name='br-lan'$/\1/p" | head -n1)
uci -q delete network.$dev.ports
uci add_list network.$dev.ports='lan2'
uci add_list network.$dev.ports='lan3'
uci add_list network.$dev.ports='lan4'

# ② 新建纯二层桥：光口 + 2.5G 口
uci set network.brwan='device'
uci set network.brwan.name='br-wan'
uci set network.brwan.type='bridge'
uci add_list network.brwan.ports='pon0'
uci add_list network.brwan.ports='lan1'

# ③ WAN 指向这个桥，并且不给它任何协议/IP
uci set network.wan.device='br-wan'
uci set network.wan.proto='none'
uci -q delete network.wan6

uci commit network
/etc/init.d/network restart
```

说明：

- `proto 'none'` 不是"关掉接口"：netifd 仍会把 `br-wan` 及其成员口（含 `pon0`）拉起，
  这正是 PON 数据通路需要的（板级脚本的注释即"netifd opens pon0 when the wan
  interface starts"）；
- `br-wan` 上**不要**配 IP，也**不要**开 DHCP 服务器；
- 同一个网口不能同时属于两个桥，所以 `lan1` 必须先从 `br-lan` 移除。

### 6.3 LuCI 等效操作

1. **网络 → 接口 → 设备**：编辑 `br-lan`，从端口列表移除 2.5G 口；
2. 同页新增设备：名称 `br-wan`、类型 `bridge`、端口勾选 `pon0` 与 2.5G 口；
3. **网络 → 接口**：编辑 `WAN` → 设备选 `br-wan`、协议选「无」；删除 `WAN6`；
4. 保存并应用。

### 6.4 运营商带 VLAN tag 时

- 下游路由器自己打 tag（最常见）：光猫侧保持上面的纯桥即可，无需任何 VLAN 配置。
- 需要光猫侧做 tag↔untag 转换（下游设备不方便打 tag）时，在 `br-wan` 上开 VLAN 过滤，
  `t` 为带 tag 侧、`u*` 为剥 tag 并设 PVID 侧：

```uc
config device
    option name 'br-wan'
    option type 'bridge'
    list ports 'pon0'
    list ports 'lan1'
    option vlan_filtering '1'

config bridge-vlan
    option device 'br-wan'
    option vlan '100'
    list ports 'pon0:t'     # 光口侧带 tag
    list ports 'lan1:u*'    # 2.5G 口侧剥 tag 且设为 PVID
```

IPTV 等其它业务 VLAN 用固件自带的 LuCI 应用「IPTV」配置更省事。

原厂光猫页面上的「802.1p / 优先级」在 PonWrt 里没有对应选项：Linux 桥插入 802.1Q 标签时
P-bit 固定为 0（`bridge vlan` 本身就没有优先级参数），这与绝大多数运营商（含 PPPoE 上网）
默认的 802.1p = 0 等价。只有 OLT 通过 OMCI 下发「按 VLAN + 802.1p 区分 GEM」的多业务映射时
才需要非 0 的 P-bit，注册后可用 `cat /sys/class/net/pon0/xpon/data_path` 查看 OLT 给出的映射
（`pbit_mask` 为 `ff` 表示任意 P-bit）；确需非 0 时，可让下游路由器自己打 tag（把 `lan1:u*`
改为 `lan1:t` 原样透传），或在光猫上用 tc 的 `vlan` action / VLAN 子接口的 `egress-qos-map`
显式设置。

### 6.5 验证

```sh
ip -br link                  # br-wan / pon0 / lan1 均应为 UP
ip -4 addr show br-wan       # 必须为空：桥上不能有 IP
bridge link show             # pon0 与 2.5G 口应挂在 br-wan 下
bridge vlan show             # 启用 VLAN 过滤时检查 tag 设置
pondctl status --line line0  # PON 注册状态（与第 5 节一致）
```

`pon0` 若未 UP，执行 `ip link set pon0 up`，或 `/etc/init.d/airoha-pond restart`。
想确认二层真的透传，可在光猫上抓 PPPoE 发现报文（`tcpdump` 随 `airoha-pon-debug` 提供）：

```sh
tcpdump -i pon0 -n -e 'pppoed or pppoes'
```

### 6.6 注意事项

- **不要**把 `pon0` 桥进 `br-lan`：运营商的二层网络会和局域网混在一起，光猫的 DHCP
  服务器还会与运营商侧 DHCP 冲突；
- 桥接后光猫的管理地址只保留在 `br-lan` 的其它网口上，别把 2.5G 口留在里面；
  想让下游路由器及其下面的设备也能打开管理页，见 6.7；
- `pon0` 与 2.5G 口是两个独立 GMAC，L2 转发由内核桥处理；PonWrt 默认开启 flow offload
  （`flow_offloading` 与 `flow_offloading_hw`，并额外生成 bridge 家族的 flowtable，端口
  覆盖 `pon0`/`lan1`），桥接流量有机会被卸载到 NPU/PPE。可用 `nft list flowtables` 确认
  flowtable 是否存在，并用 `iperf3` 实测吞吐、`ethtool -S` 检查有无丢包；
- 这些配置都在 `/etc/config/network` 中，属于 sysupgrade 保留范围，后续升级固件不会丢
  （但不要执行 U-Boot 恢复页的"重建 UBI"；三条固件更新路径见 [UPGRADE.md](UPGRADE.md)）。
- 另外**不要把 `lan2`/`lan3`/`lan4` 全部移出 `br-lan`**：U-Boot 阶段只启用内部交换机
  `gdm1`（就是这三个千兆口），全摘掉之后系统起不来时就没有网口能访问 `192.168.0.1` 了。

### 6.7 从下游路由器访问光猫管理页（`192.168.1.1`）

按第 6 节把 2.5G 口桥给下游路由器拨号之后，光猫自己的管理地址 `192.168.1.1` 只存在于
`br-lan` 上，下游路由器（下称「路由器」）的 WAN 口是 PPPoE，走不到这个地址。要让它对
**路由器本身**和**路由器后面的设备**都可见，有三种做法：

| 方案 | 需要的网线 | 光猫侧改动 | 适用场景 |
| --- | --- | --- | --- |
| A. 单独管理网线 | 2 根（2.5G 拨号 + 管理口互联） | 无 | 走线方便，改动最小 |
| B. 单线复用 | 1 根（只有 WAN 那根） | 2.5G 口改成 VLAN 干线 | 不方便再拉线 |
| C. 单线并存 + 插件 | 1 根（只有 WAN 那根） | `br-wan` 加一个管理 IP（不动桥） | 不方便再拉线、路由器装有 iStore，想省掉路由器侧手工配置（6.7.4） |

方案 A/B 在路由器侧是同一套思路：把接光猫的那个口（方案 A）或那条 VLAN（方案 B）配成
独立接口，放进独立防火墙区并开 masquerade。原因是光猫上只有 `192.168.1.0/24` 的直连
路由，回 `10.0.0.0/24` 的包会被它丢给默认网关；`masq '1'` 把下游设备的源地址改写成
路由器在光猫网段里的地址（`192.168.1.2`），光猫直接回给路由器就够了。路由器**自己**访问
`192.168.1.1` 用的是接口地址，不依赖 NAT。方案 C 把路由器侧整个交给 `luci-app-ap-modem`
插件（管理地址需换一个网段），见 6.7.4。

> **注意（方案 A/B）**：路由器自己的 LAN 网段**不能也是 `192.168.1.0/24`**。否则 LAN 桥与管理接口
> 同网段，内核的两条连接路由会产生歧义（`ping 192.168.1.1` 可能从 LAN 桥发出而不走管理
> 接口），masquerade 也救不回来。冲突时先把路由器 LAN 改成别的网段（如 `10.0.0.1/24`、
> `192.168.8.1/24`）再套用本节。方案 C 不受此限——它路由器侧走独立网段（下文以
> `192.168.9.0/24` 为例），LAN 与 `192.168.1.0/24` 同网段也不冲突，只是同样不能与管理
> 网段撞车。

#### 6.7.1 方案 A：单独一根管理网线

以「光猫 `lan4` ↔ 路由器 `lan2`、路由器 LAN 为 `10.0.0.1/24`」为例：

```
光猫 br-lan(192.168.1.1) ── lan4 ══ 网线 ══ lan2 ── 路由器（独立接口 192.168.1.2/24
                        （br-lan 成员）                    + masquerade，lan → modem 放行）
                                                              └── 下游设备 10.0.0.0/24
```

**光猫侧**：接路由器的那个口保持在 `br-lan` 里即可，不需要任何额外配置——`br-lan` 所在
防火墙区默认 `input ACCEPT`，会放行管理页。注意别把这个口桥进 `br-wan`。

**路由器侧**：把这个 LAN 口从路由器的 LAN 桥里摘出来，单独建一个静态接口并开 masquerade：

```sh
# ① 把接光猫的口从路由器的 LAN 桥里摘掉（这里以 lan2 为例）
dev=$(uci show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n1)
uci -q del_list network.$dev.ports='lan2'

# ② 新建管理接口：静态地址放在光猫网段里，但不要网关（默认路由还得走 PPPoE）。
#    地址要避开光猫的 DHCP 池（PonWrt 默认池从 192.168.1.100 起）
uci set network.modem=interface
uci set network.modem.proto='static'
uci set network.modem.device='lan2'
uci set network.modem.ipaddr='192.168.1.2'
uci set network.modem.netmask='255.255.255.0'
uci set network.modem.defaultroute='0'

# ③ 独立防火墙区并开 masquerade，只放行 lan → modem
uci add firewall zone
uci set firewall.@zone[-1].name='modem'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='modem'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='modem'

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
```

LuCI 等效操作：

1. **网络 → 接口 → 设备**：编辑 `br-lan`，把接光猫的端口从端口列表里移除；
2. **网络 → 接口 → 添加新接口**：名称 `modem`、协议「静态地址」、设备选那个口，
   IPv4 地址 `192.168.1.2`、掩码 `255.255.255.0`，**不要**填网关、不要在「高级设置」里
   勾默认路由；
3. **网络 → 防火墙**：新增区域 `modem`（入站 `拒绝`、出站 `接受`、转发 `拒绝`，
   勾选「IP 动态伪装」与「MSS 钳制」），网络选 `modem`；再在「区域转发」里加一条
   `lan → modem`；
4. 保存并应用。

#### 6.7.2 方案 B：单线复用（同一根网线同时跑上网和管理）

把 2.5G 口从「纯二层桥」改成「**VLAN 干线**」：运营商流量仍然 untagged 透传，下游
PPPoE 完全不受影响；光猫的管理网打成 VLAN tag 走同一根网线。

```
                                     ┌── untagged ──► 运营商二层（WAN 口 PPPoE，不变）
光猫 2.5G 口 ══ 一根网线 ══ 路由器 ──┤
                                     └── VLAN 2100 ─► 光猫 br-lan / 192.168.1.1
                                         (tag)        路由器 eth1.2100 = 192.168.1.2/24 + masq
```

**光猫侧**：本仓库带了一个脚本 [`docs/scripts/ponwrt-single-wire.sh`](scripts/ponwrt-single-wire.sh)，
它把管理网加到 2.5G 口上（原理和命令都写在脚本头部注释里，也可以照抄手动执行）：

- 让放 `pon0` 的那个桥打开 `vlan_filtering`，并把千兆口（`lan2`/`lan3`/`lan4`）并进同一个桥；
- **运营商侧已有的 `bridge-vlan` 原样保留**：如果你的光猫已经按 6.4 做了 tag↔untag
  （例如 OLT 侧带 tag `3114`、2.5G 口剥 tag 给下游拨号），脚本只做加法，不会动它；
  若运营商桥还没开 VLAN 过滤，脚本会补一条 untagged 透传条目（`--isp-vid`，默认 2）；
- 新增管理 VLAN：2.5G 口带 tag、千兆口不带 tag（所以**插在千兆口上的电脑行为完全不变**）；
- 管理 IP 从原来的桥挪到新桥的 VLAN 子接口（如 `br-wan.2100`）上，地址不变；
- 若光猫还在**出厂状态**（`wan` 接口还直接挂在 `pon0` 上、没建独立运营商桥），脚本会把
  `pon0` 并进管理桥，并把 `wan` 接口改成挂桥上的无协议接口、删除 `wan6`（等效 6.2 的
  ②③）——不这么做 `pon0` 会被接口和桥同时占用，netifd 报 device in use。此路径生成的
  管理子接口叫 `br-lan.<VID>`；更稳妥的做法仍是先按第 6 节建好 `br-wan` 再跑脚本，
  结果与上文示例一致。

以 FiberHome HG5382A（OLT 带 tag 3114，2.5G 口负责剥 tag 给下游 PPPoE）为例，脚本跑完后
`/etc/config/network` 里是这样：

```
config device 'brwan'
	option name 'br-wan'
	option type 'bridge'
	option vlan_filtering '1'
	list ports 'pon0' 'lan1' 'lan2' 'lan3' 'lan4'

config bridge-vlan            # 原有：运营商 tag↔untag，原样保留
	option device 'br-wan'
	option vlan '3114'
	list ports 'pon0:t' 'lan1:u*'

config bridge-vlan            # 新增：管理网
	option device 'br-wan'
	option vlan '2100'
	list ports 'lan1:t' 'lan2:u*' 'lan3:u*' 'lan4:u*'

config device 'singlewire'
	option name 'br-wan.2100'
	option type 'vlan'
	option ifname 'br-wan'
	option vid '2100'

config interface 'lan'
	option device 'br-wan.2100'
	option proto 'static'
	list ipaddr '192.168.1.1/24'
```

```sh
# 在光猫上执行（可以从任意千兆口 SSH 进去；脚本自带回滚保险）
sh ponwrt-single-wire.sh --dry-run   # 先看要做的改动
sh ponwrt-single-wire.sh             # 应用，10 分钟内不确认会自动回滚
sh ponwrt-single-wire.sh --keep      # 确认没问题，保留配置
sh ponwrt-single-wire.sh --revert    # 出问题立刻回滚
```

**路由器侧**：WAN 口上建一个 VLAN 2100 子接口，其余与方案 A 相同：

```sh
# ① WAN 口上的 VLAN 子接口（下面以 eth1 为例，用 ip -br link 确认实际设备名）
uci set network.modemvlan=device
uci set network.modemvlan.name='eth1.2100'
uci set network.modemvlan.type='vlan'
uci set network.modemvlan.ifname='eth1'
uci set network.modemvlan.vid='2100'

# ② 管理接口：静态 192.168.1.2/24，不要网关（默认路由还得走 PPPoE）
uci set network.modem=interface
uci set network.modem.proto='static'
uci set network.modem.device='eth1.2100'
uci set network.modem.ipaddr='192.168.1.2'
uci set network.modem.netmask='255.255.255.0'
uci set network.modem.defaultroute='0'

# ③ 独立防火墙区 + masquerade（与方案 A 相同）
uci add firewall zone
uci set firewall.@zone[-1].name='modem'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='modem'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='modem'

uci commit network && uci commit firewall
/etc/init.d/network reload && /etc/init.d/firewall reload
```

注意事项：

- 路由器 WAN 口的 PPPoE 仍然在 untagged 的 `eth1` 上，**不要**动 `network.wan`：加一个
  `eth1.<VID>` 子接口不会影响 PPPoE，即使管理 VLAN 配错了上网也还在；
- 运营商带 tag 时，先在光猫上按 6.4 配好 tag↔untag（下游 PPPoE 拿到的是 untagged 流量，
  不用改路由器），再跑脚本；脚本只做加法，已有的 `bridge-vlan` 一律保留。同一根线上还有
  别的 tagged 业务（IPTV 等）时同理，各自按 6.4 加一条 `bridge-vlan` 即可；
- 光猫侧 2.5G 口名不一定叫 `lan1`（多数机型是，先用 `ip -br link` 确认）。脚本会从运营
  商桥的端口里自动推断，推不出来时用 `--2.5g <口名>` 指定；
- `--vid`（默认 2100）两端必须一致；
- 单线复用生效后**不要**再把光猫的千兆口和 2.5G 口接进同一个下游二层网络：管理 VLAN 会
  在两条路径之间形成环，桥默认不开 STP，会变成广播风暴。

#### 6.7.3 验证与排错

方案 A（`lan2`）：

```sh
ip -br addr show lan2          # 应有 192.168.1.2/24
ip route | grep 192.168.1      # 192.168.1.0/24 dev lan2 scope link
ping -c 2 192.168.1.1          # 路由器自己能通
curl -sI http://192.168.1.1/   # 能取到 LuCI 的响应头
nft list chain inet fw4 srcnat_modem   # 区域开 masq 后会有这个链
```

方案 B（`eth1.2100`）：

```sh
ip -br addr show eth1.2100     # 应有 192.168.1.2/24
ip route | grep 192.168.1      # 192.168.1.0/24 dev eth1.2100 scope link
ping -c 2 192.168.1.1          # 路由器自己能通
curl -sI http://192.168.1.1/   # 能取到 LuCI 的响应头
ip -br addr show pppoe-wan     # PPPoE 应仍然在线：上网不受影响
nft list chain inet fw4 srcnat | grep 2100   # 会跳转到 srcnat_modem
```

光猫侧可以确认 VLAN 归属（`bridge` 命令随 iproute2 一起装，没有该命令时看
`ip -br addr show br-wan.2100` 有没有地址即可，桥名以脚本输出的实际名称为准）：

```sh
bridge vlan show               # 2.5G 口应同时有 untagged 的 VLAN 2 和 tagged 的 VLAN 2100
ip -br link                    # 2.5G 口与 pon0 都应为 UP
```

然后在任意下游设备上 `ping 192.168.1.1` / 打开 `http://192.168.1.1/` 应能直接访问。
`input 'REJECT'` 是有意为之：只允许下游主动访问光猫，不需要让光猫主动连路由器。

排错（按顺序看）：

```sh
# 方案 A：确认物理链路（0 = 没链路，先查网线两端）
cat /sys/class/net/lan2/carrier

# 方案 B：确认 VLAN 子接口、路由和 NAT
ip -br addr show eth1.2100
ip route show 192.168.1.0/24          # 应是 dev eth1.2100
nft list chain inet fw4 srcnat_modem
```

方案 B 里如果路由器自己能通、下游设备不通，多半是 masquerade 或 `lan → modem` 转发没
生效；如果两边都不通，先在光猫上确认 `br-wan.2100` 有地址、2.5G 口是 UP，再确认两端
VLAN 号一致（`uci show network | grep bridge-vlan`）。

方案 A 里 `carrier` 为 `0` 时先查网线两端，再回光猫确认那个口还在 `br-lan` 里：

```sh
# 在光猫上执行
uci show network | grep -A3 "name='br-lan'"   # ports 里应能看到 lan2/lan3/lan4
ip -br link                                   # 对应口应为 UP，而不是 DOWN
```

桥接时若把 `lan2`/`lan3`/`lan4` 一起移出了 `br-lan`，这些口会变成 `DOWN`、对端看不到
载波，光猫也就**没有任何有线管理入口**了。先换一个还在 `br-lan` 里的口试试；一个都不剩
时只能走串口控制台（接线见 [UNBRICK.md](UNBRICK.md) 的 USB-TTL 部分）：启动到 Linux 后在
控制台上登录，把口加回 `br-lan` 即可，不需要重刷固件：

```sh
# 在光猫的串口控制台上执行（段名以 uci show network 的实际输出为准）
uci show network | grep "device\["
uci add_list network.@device[0].ports='lan4'
uci commit network && /etc/init.d/network reload
```

另外多数机型 2.5G 口是 `lan1`，但换机型时一定先用 `ip -br link` 确认口名。

不想在路由器上做 NAT 也可以反过来：路由器接口保持 `192.168.1.2/24`，在**光猫**上加一条
回程路由，下游设备的源地址就可以原样保留：

```sh
# 在光猫上执行
uci add network route
uci set network.@route[-1].interface='lan'
uci set network.@route[-1].target='10.0.0.0/24'
uci set network.@route[-1].gateway='192.168.1.2'
uci commit network && /etc/init.d/network reload
```

两种做法二选一即可。接口本身不要配 IPv6：`net.ipv6.conf.all.forwarding=1` 时内核本来
就不会处理对端路由通告，光猫发的 RA 不会抢走默认路由。

这些改动都在路由器自己的 `/etc/config/network`、`/etc/config/firewall` 里，属于
sysupgrade 保留范围。

#### 6.7.4 方案 C：单线并存 + `luci-app-ap-modem` 插件（路由器侧免配置）

[iStore 仓库](https://github.com/linkease/openwrt-app-actions/tree/main/applications/luci-app-ap-modem)
的 `luci-app-ap-modem`（jjm2473 作）解决的是另一类问题：目标网段在链路上**已经 untagged
可达**，只是路由器没有通往它的路由和 NAT。它只在路由器 WAN 网卡上再挂一个静态 IP（放进
现有 `wan` 区蹭 masquerade），**不解 VLAN tag、不碰 `network.wan`**——PPPoE 帧是独立的
ethertype，与网卡上的 IP 天然并存，拨号完全不受影响。

按第 6 节桥接后 `br-wan` 是纯二层桥、没有 IP，那根线上只有运营商二层，插件的前提并不
成立，所以光猫侧仍要做一个**比方案 B 小得多的改动**：给 `br-wan` 加一个管理 IP，让管理
网以 untagged 形式与 PPPoE 同线并存。网段必须换新的（下文以 `192.168.9.0/24` 为例）：
`br-lan` 已占用 `192.168.1.0/24`，光猫上两个接口同网段会产生路由歧义（道理同上文对
路由器 LAN 的警告）。

```
                     ┌── untagged PPPoE ──► 运营商二层（不变）
光猫 br-wan ◄══ 一根网线 ══► 路由器 eth1
   └─ 新增管理 IP 192.168.9.1       ├─ pppoe-wan：照常拨号（插件不碰）
      （与 PPPoE 同线 untagged 并存） └─ 插件建的 vap_wan = 192.168.9.254（蹭 wan 区 masq）
```

**光猫侧**（SSH 进光猫执行；桥名不是 `br-wan` 时按 `uci show network` 的实际输出改）。
先用 `uci show network | grep bridge-vlan` 判断：按 6.4 做过 tag↔untag（如 OLT tag
3114）走情况 ②，没做过走情况 ①。

情况 ①（运营商流量 untagged、桥未开 VLAN 过滤）：管理 IP 直接挂桥上：

```sh
uci set network.mgmtwan=interface
uci set network.mgmtwan.proto='static'
uci set network.mgmtwan.device='br-wan'
uci set network.mgmtwan.ipaddr='192.168.9.1'
uci set network.mgmtwan.netmask='255.255.255.0'
uci set network.mgmtwan.defaultroute='0'
```

情况 ②（OLT 带 tag、已按 6.4 配好 `bridge-vlan` 3114 = `pon0:t` + 2.5G 口 `u*`）：线上
untagged 的流量在桥内属于 VLAN 3114，IP 挂在 `br-wan` 本体会落在默认 VLAN 1 里、从线上
够不着，必须挂到该 VLAN 的子接口——与 6.7.2 脚本生成 `br-wan.2100` 的模式完全相同，
原有的 `bridge-vlan` 3114 原样保留、无需改动：

```sh
uci set network.mgmtdev=device
uci set network.mgmtdev.name='br-wan.3114'
uci set network.mgmtdev.type='vlan'
uci set network.mgmtdev.ifname='br-wan'
uci set network.mgmtdev.vid='3114'

uci set network.mgmtwan=interface
uci set network.mgmtwan.proto='static'
uci set network.mgmtwan.device='br-wan.3114'
uci set network.mgmtwan.ipaddr='192.168.9.1'
uci set network.mgmtwan.netmask='255.255.255.0'
uci set network.mgmtwan.defaultroute='0'
```

防火墙（两种情况相同）：这个 IP 活在运营商广播域里（tag 场景下就是同 OLT 的用户 VLAN，
理论上其它用户可达），**不要**把它并进 `lan` 区，而是单独建区、`input` 收紧为 `REJECT`，
只放行 NAT 后源地址为 `192.168.9.254` 的流量——路由器自己和经过 masquerade 的下游设备
源地址都是它：

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='mgmtwan'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='mgmtwan'

# 只允许路由器（含经其 NAT 的下游设备）访问管理端口
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-mgmt-from-router'
uci set firewall.@rule[-1].src='mgmtwan'
uci set firewall.@rule[-1].src_ip='192.168.9.254/32'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22 80 443'
uci set firewall.@rule[-1].target='ACCEPT'

# 方便排错的 ICMP 放行（可选）
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-mgmt-ping'
uci set firewall.@rule[-1].src='mgmtwan'
uci set firewall.@rule[-1].src_ip='192.168.9.254/32'
uci set firewall.@rule[-1].proto='icmp'
uci set firewall.@rule[-1].icmp_type='echo-request'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit network && uci commit firewall
/etc/init.d/network reload && /etc/init.d/firewall reload
```

**路由器侧**全部交给插件：

1. iStore 应用市场或 `opkg install luci-app-ap-modem` 安装；
2. LuCI → 网络 → **Access AP / Modem**：勾选 **Enable**，在 **WAN** 标签页的「Virtual
   IP」填 `192.168.9.254`（**LAN 标签页留空**——那是给挂在路由器 LAN 下、管理 IP 在其它
   网段的 AP 用的），保存并应用；
3. 插件依赖 `wan` 区已开 masquerade（OpenWrt 默认开启），可用
   `uci show firewall | grep masq` 确认。

插件在每次开机/配置重载时按 `/etc/config/ap_modem` 自动生成并应用上述网络配置，取消
Enable 或 `/etc/init.d/ap_modem stop` 即自动清理。它要求路由器 `lan` 设备名为 `br-lan`、
`wan` 配置了 `device`（GL-MT5000 等原版配置均满足）。

验证（路由器上）：

```sh
ip -br addr show eth1          # 应看到 192.168.9.254/24（插件的 vap_wan）
ip -br addr show pppoe-wan     # PPPoE 仍在线：上网不受影响
ping -c 2 192.168.9.1          # 路由器自己能通
curl -sI http://192.168.9.1/   # 能取到光猫 LuCI 的响应头
```

然后任意下游设备打开 `http://192.168.9.1/` 即可。

注意事项：

- 那根线上可达的管理地址是 **`192.168.9.1` 而非 `192.168.1.1`**（同一个 LuCI、两个
  入口）；千兆口插电脑仍是 `192.168.1.1`，行为不变。若一定要在线上直达 `192.168.1.1`，
  只能回方案 B——插件不解 VLAN tag；
- 隔离性不如方案 B：管理 IP 挂在运营商广播域内，靠上面的源地址限制兜底；方案 B 的独立
  管理 VLAN 与运营商域完全隔离，安全性更好。本方案换来的是路由器侧零手工配置、光猫侧
  只加一个 IP；
- 光猫侧改动**不碰桥和端口成员**，配错最多少一个入口，不会像方案 B 那样有失去全部有线
  管理入口的风险。回滚：`uci delete network.mgmtwan`（情况 ② 再执行
  `uci delete network.mgmtdev`），删掉 `mgmtwan` 区与两条规则，重载 network/firewall 即可；
- 路由器 LAN 网段比方案 A/B 宽松：即使 LAN 也是 `192.168.1.0/24` 也不冲突（路由器侧
  管理网段是 `192.168.9.0/24`），但**不能**把 LAN 设成 `192.168.9.0/24`——插件会自动
  跳过与 LAN 重叠的虚拟 IP，导致配置不生效；
- 两端改动分别落在光猫的 `/etc/config/network`、`/etc/config/firewall` 与路由器的
  `/etc/config/ap_modem`，均属 sysupgrade 保留范围（路由器侧的网络配置由插件每次开机
  重新生成，无需手工持久化）。

## 7. 救砖

| 情况 | 处理 |
| --- | --- |
| 能进 U-Boot 恢复页 | 上电 1 秒内按住 Reset 进 `http://192.168.0.1/` 重刷（网线插 `lan2`/`lan3`/`lan4`） |
| 全灯不亮、`192.168.0.1` 打不开，串口停在 `Press x to load BL31 + U-Boot FIP via XMODEM` | 按 **[docs/UNBRICK.md](UNBRICK.md)** 用 TTL + XMODEM 把 fip 送进内存，再在恢复页里**重建 UBI 并重刷 BL2 与 fip**（只上传 sysupgrade 会重启又卡回 BL2） |
| 串口完全无输出 | 只能外部编程器写 NAND，或参考 [uboot-an758x README](https://github.com/pbs05/uboot-an758x)「手动刷机」一节 |

救砖所需的脚本与配图在 `docs/unbrick/` 与 `docs/images/`：`xmodem_send.ps1`（Windows）、
`xmodem_send.py`（Linux/macOS）、`serial_log.ps1`（抓日志）。

## 8. 其它机型差异

| 机型 | U-Boot 构建 target | 校准/身份数据分区 |
| --- | --- | --- |
| FiberHome HG5382A | `hg5382a` | `factory`（需 fiberhome-factory 转换） |
| FiberHome HG5585F CT/CU | `hg5585f-ct` / `hg5585f-cu` | `factory`（需转换） |
| Gemtek XG2010G | `xg2010g` | `dsd` |
| Nokia XG-040G-MD/TF/MF | `xg-040g-md` / `xg-040g-tf` / `xg-040g-mf` | `bosa`、`ri`（直接写入同名卷，无需转换） |
| UnionMan UNG00A | `ung00a` | `reservearea` |
| ZNXT ZN504XG-D / ZN515XG-D | `zn504xg-d` / `zn515xg-d` | `reservearea` |

网口命名以 `ip -br link` 为准：多数机型（HG5382A、Nokia XG-040G-MD 等）的 2.5G 口是
`lan1`，第 6 节的桥接示例按此编写。

`reservearea` / `dsd` 备份写入 PonWrt 的 `factory` 卷；Nokia 的 `bosa`、`ri` 写入同名卷。

## 9. 「硬件身份」页与板级身份字段

`luci-app-pon` 的「硬件身份」页由板级脚本声明的 identity 字段驱动（`etc/board.d/03_pon_data`）：
Nokia 机型写 `ri` 卷的 `pon_sn`/`board_mac`，Gemtek 写 `factory`，FiberHome（HG5382A、HG5585F
CT/CU）写转换后 `factory` 镜像里的 `0x2000` 基础 MAC、`0x2010` 八字节 PON SN、`0x2020` 设备序列号。
菜单项由 `/tmp/pon-board-identity.available` 门控，而这个标记文件只能由 `03_pon_data` 创建。

注意：板级探测（`preinit_config_board` → `board_detect`）注册在**挂载 overlay 之前**，启动早期只能
看到 squashfs 里的脚本。因此

- 用**新镜像刷机**、或 sysupgrade 到新镜像（`/etc/board.json` 不在保留列表里，会由新镜像首启重新
  生成）都无需额外操作；
- 只有**手工**把 identity 声明写进 `/etc/board.d/03_pon_data`（落在 overlay）时会踩坑：启动早期看
  不到它，标记不生成，菜单重启后消失。此时在 `/etc/rc.local` 的 `exit 0` 之前补一行：

  ```sh
  [ -f /etc/board.json ] && grep -q identity /etc/board.json && touch /tmp/pon-board-identity.available
  ```

验证：登录 LuCI 后请求 `/cgi-bin/luci/admin/network/pon/hardware`，返回 `200` 表示该节点已注册
（依赖不满足时 LuCI dispatcher 返回 `404`，可拿一个不存在的路径做对照）。

改动 `factory` 里的 SN/MAC 之前先整份备份 —— 写入工具自己也会把原镜像存到
`/tmp/pon-board-data.<目标>.<pid>.bin`，但 `/tmp` 重启即失：

```sh
# 卷号以 /sys/class/ubi/*/name 为准（HG5382A 上是 ubi0_3）
ssh root@192.168.1.1 "head -c 1048576 /dev/ubi0_3" > factory.bin
```
