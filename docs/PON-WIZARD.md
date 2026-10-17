# LuCI 接入向导（luci-app-pon-wizard）

把开通一只 PonWrt 光猫所需的**光猫侧**配置收敛到 LuCI 的一个页面里：
**网络 → PON → Wizard**。覆盖 [FLASHING.md](FLASHING.md) 的三块手工流程：

| 向导选项 | 对应文档 | 生成内容 |
| --- | --- | --- |
| 「桥接 2.5G 口」 | 6.2 | `br-wan`（pon0 + 2.5G 口）纯二层桥，`wan` 挂桥且 proto=none，删除 `wan6` |
| 「运营商 VLAN tag」 | 6.4 | `bridge-vlan <vid>`：pon0 带 tag、2.5G 口剥 tag（下游 PPPoE 拿 untagged） |
| 「管理访问方案」B/C | 6.7.2 / 6.7.4 | 一键生成单线复用（B：管理 VLAN；C：WAN 桥上挂新网段管理 IP + 收紧的防火墙区） |

配合 luci-app-pon 自带的 LOID/序列号配置页，「LOID + VLAN + 桥接 + 管理访问」
在同一处闭环。方案 C 搭配路由器侧 `luci-app-ap-modem` 插件时，两端各点一次即完成。

## 状态回读（关键设计）

页面打开时展示的是**从实际配置反推的当前状态**（`pon-wizard-apply status`），
不是仅读声明文件：

- 已按文档手工配过方案 B（或跑过 `ponwrt-single-wire.sh`）/方案 C 的光猫，
  会自动识别并**预勾选对应选项**（声明文件为空也照样识别）；
- 检测到的状态与保存的声明不一致时，页面顶部显示提示横幅；
- 保存即「收敛」：先中性化已存在的管理访问（删除的正是文档手工命令创建的那些
  段：`mgmtdev`/`mgmtwan`/`mgmtwan` 区/`Allow-mgmt-*` 规则/管理 bridge-vlan），
  再按表单目标重建——手工配置可被无感接管，不会出现两套并存。

## 安全机制

- **10 分钟自动回滚**：每次 apply 备份 `network`+`firewall` 到 `/root`，未在
  600 秒内点「Keep configuration」（或执行 `pon-wizard-apply confirm`）就自动恢复；
- 桥接步骤有保护：把 2.5G 口移出 `br-lan` 前检查剩余管理口，会摘空则拒绝执行；
- 「桥接」只做加法：取消勾选不会拆桥（拆桥语义不明确，需按 6.2 反向手工操作），
  但管理访问 B/C 取消勾选即清除对应配置。

## 文件与命令

| 文件 | 作用 |
| --- | --- |
| `/usr/libexec/pon-wizard-apply` | 后端：`status`（检测+JSON）/ `plan`（dry-run）/ `apply [--dry-run\|--yes]` / `confirm` / `revert` |
| `/etc/config/ponwizard` | 声明式配置（页面的「期望状态」） |
| `view/pon/wizard.js` + menu.d 子项 | 在 PON 菜单下追加 Wizard 标签（不改 luci-app-pon 本体） |

后端支持 `CONFIG_DIR`/`BACKUP_DIR`/`NETWORK_INIT` 等环境变量覆盖，可离线自测。

## 测试

离线测试装置（uci 模拟器 + 四种初始状态 fixture + 六组迁移断言）在构建服务器
`~/ponwiz-test/` 上运行，**56/56 通过**，覆盖：出厂/6.2 桥接/手工 B/手工 C 的
状态识别、出厂→桥接+VLAN+C 一键开通、C→B 切换（含中性化）、B→清除（还原
br-lan）、自动回滚定时器、confirm 解除、br-lan 摘空拒绝。真机安装验证待光猫
恢复可达后进行（apk 已在 10.0.0.108 编出：
`bin/packages/aarch64_cortex-a53/base/luci-app-pon-wizard-1.0.0-r1.apk`）。

## 构建

```sh
echo 'CONFIG_PACKAGE_luci-app-pon-wizard=y' >> .config && make defconfig
make package/luci-app-pon-wizard/compile -j$(nproc)
```

`configs/an7581.config`、`configs/an7583.config` 已默认选中，随固件发布。
