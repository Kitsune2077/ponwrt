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
- `pon0` 与 2.5G 口是两个独立 GMAC，L2 转发由内核桥处理；PonWrt 默认开启 flow offload
  （`flow_offloading` 与 `flow_offloading_hw`，并额外生成 bridge 家族的 flowtable，端口
  覆盖 `pon0`/`lan1`），桥接流量有机会被卸载到 NPU/PPE。可用 `nft list flowtables` 确认
  flowtable 是否存在，并用 `iperf3` 实测吞吐、`ethtool -S` 检查有无丢包；
- 这些配置都在 `/etc/config/network` 中，属于 sysupgrade 保留范围，后续升级固件不会丢
  （但不要执行 U-Boot 恢复页的"重建 UBI"；三条固件更新路径见 [UPGRADE.md](UPGRADE.md)）。
- 另外**不要把 `lan2`/`lan3`/`lan4` 全部移出 `br-lan`**：U-Boot 阶段只启用内部交换机
  `gdm1`（就是这三个千兆口），全摘掉之后系统起不来时就没有网口能访问 `192.168.0.1` 了。

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
