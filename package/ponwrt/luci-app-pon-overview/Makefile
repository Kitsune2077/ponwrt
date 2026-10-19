# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2026 Kitsune2077

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon-overview
PKG_VERSION:=1.1.0
PKG_RELEASE:=2

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Kitsune2077 <km2077@foxmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pon-overview
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PON optical module card for the LuCI overview page
  DEPENDS:=+luci-base +luci-app-pon
  PKGARCH:=all
endef

define Package/luci-app-pon-overview/description
  Ships a LuCI status-include widget (view/status/include/15_pon.js, rendered
  between the system and memory sections) that adds
  a compact PON optical module card to Status -> Overview: Rx/Tx power, module
  temperature, Tx bias and supply voltage in a headline card, per-device
  upstream/downstream throughput, and a conntrack footer showing TCP/UDP flow
  counts including flowtable-offloaded flows. The card also enriches the stock
  system table's CPU usage row with USR/SYS and per-core breakdown.

  Data comes from the same sources as luci-app-pon's own status page
  (ponctl --device <dev> status --json), and the exec permissions are already
  covered by the luci-app-pon rpcd ACL. The card hides itself when no PON
  lines are configured.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-pon-overview/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DATA) ./files/15_pon.js \
		$(1)/www/luci-static/resources/view/status/include/15_pon.js
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/root/usr/libexec/pon-overview-stats \
		$(1)/usr/libexec/pon-overview-stats
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/root/usr/share/rpcd/acl.d/luci-app-pon-overview.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-pon-overview.json
endef

define Package/luci-app-pon-overview/postinst
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-pon-overview))
