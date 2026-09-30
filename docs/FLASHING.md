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

1. 重启后电脑网线连光猫，访问 `http://192.168.0.1/` 进入 U-Boot 恢复界面
   （首次出现页面可能需要约 1 分钟；之后也可用**上电约 1 秒内按住 Reset** 进入）；
2. 按顺序操作：
   1. **重建 UBI**；
   2. **写入 `bl31-u-boot.fip`**；
   3. **恢复板级数据卷**（见第 4 节，转换后的 factory 镜像写入 `factory` 卷）；
   4. **上传 sysupgrade 镜像**：选择本仓库 Releases 里的
      `*-fiberhome_hg5382a-sysupgrade.itb`；
   5. **启动系统**。

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

HG5382A 的 2.5G 口（`lan1`）与光口（`pon0`）都是独立的标准网口，做二层桥即可。
`/etc/config/network` 示例（纯透传，光猫不拨号）：

```uc
config device
    option name 'br-wan'
    option type 'bridge'
    list ports 'pon0'
    list ports 'lan1'
```

下游路由器 WAN 口接 2.5G 网口（`lan1`）直接 PPPoE 拨号。

若运营商上网业务带 VLAN tag（如 VLAN 100），而下游路由器不方便打 tag，
在 br-wan 上开启 VLAN 过滤做 tag↔untag 转换：

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

## 7. 救砖

- **能进 U-Boot**：上电 1 秒内按住 Reset 进 `http://192.168.0.1/` 重刷；
- **完全无响应**：TTL 串口（115200）+ XMODEM 方式恢复，见
  [uboot-an758x README](https://github.com/pbs05/uboot-an758x)「手动刷机」一节。

## 8. 其它机型差异

| 机型 | U-Boot 构建 target | 校准/身份数据分区 |
| --- | --- | --- |
| FiberHome HG5382A | `hg5382a` | `factory`（需 fiberhome-factory 转换） |
| FiberHome HG5585F CT/CU | `hg5585f-ct` / `hg5585f-cu` | `factory`（需转换） |
| Gemtek XG2010G | `xg2010g` | `dsd` |
| Nokia XG-040G-MD/TF/MF | `xg-040g-md` / `xg-040g-tf` / `xg-040g-mf` | `bosa`、`ri`（直接写入同名卷，无需转换） |
| UnionMan UNG00A | `ung00a` | `reservearea` |
| ZNXT ZN504XG-D / ZN515XG-D | `zn504xg-d` / `zn515xg-d` | `reservearea` |

`reservearea` / `dsd` 备份写入 PonWrt 的 `factory` 卷；Nokia 的 `bosa`、`ri` 写入同名卷。
