# LuCI 概览页 PON 状态卡片（luci-app-pon-overview）

把 `网络 → PON → 状态` 页里的常用信息浓缩成一张卡片，挂到 LuCI **状态 → 概览**
（Status → Overview）页里，不用再切进 PON 应用查看。

## 效果

概览页在「网络」与「DHCP 租约」之间会多出一张 **PON** 卡片（可点击标题右侧的
「隐藏」按钮折叠，状态记忆在浏览器本地），内容随页面轮询（约 5 秒）自动刷新：

| 项目 | ITU-T 线路（GPON / XG-PON / XGS-PON） | EPON 线路 |
| --- | --- | --- |
| 线路模式 / 线路状态 | ✓（Operational 等） | ✓ |
| 注册状态 | ONU 状态（O1…O7）+ ONU-ID | MPCP 状态 + LLID |
| 光信号 / 收发光功率 / 光模块温度 | ✓ | ✓ |
| 同步状态 | GTC / XGTC 状态 | — |
| OMCI 摘要 | 通道在线、OLT 设备、LOID 认证结果 | — |

卡片底部有「PON 状态 »」链接跳转到完整状态页。多 PON 线路的板子会渲染多张表。
文案复用 `luci-app-pon` 的翻译 msgid，装了 zh-cn 语言包时自动显示中文。

## 实现原理

- LuCI 的概览页本身是插件式的：`view/status/index.js` 会扫描
  `/www/luci-static/resources/view/status/include/*.js`，把每个 `baseclass.extend`
  的模块渲染成一张卡片（文件名前缀决定排序，本包是 `35_pon.js`）。
- 数据源与 PON 状态页完全相同：`ponctl --device <dev> status --json` 和
  `pondctl status --line <line>`，执行权限由 `luci-app-pon` 已有的 rpcd ACL
  覆盖（root 登录默认 `read/write = *`），因此本包**不需要**额外的 ACL 文件。
- 没有 PON 配置（`/etc/config/pon` 无 xpon 段）时卡片整体隐藏。

## 构建集成

包位于 `package/ponwrt/luci-app-pon-overview`，依赖 `luci-base` 与 `luci-app-pon`。
编进固件：

```sh
# menuconfig：LuCI → 3. Applications → luci-app-pon-overview
echo 'CONFIG_PACKAGE_luci-app-pon-overview=y' >> .config
make defconfig
make -j$(nproc)
```

不想重刷固件也可以热部署（单个静态 JS，无需重启服务，刷新浏览器即生效）：

```sh
scp package/ponwrt/luci-app-pon-overview/files/35_pon.js \
    root@192.168.1.1:/www/luci-static/resources/view/status/include/35_pon.js
```

## 已验证

2026-10 在 Nokia XG-040G-MD（PonWrt SNAPSHOT，LuCI Master）上热部署验证：
卡片正常出现在概览页，中文文案完整，光功率/温度随轮询实时变化，
「隐藏」按钮与「PON 状态 »」链接工作正常。
