# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2026 Kitsune2077

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon-overview
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Kitsune2077 <km2077@foxmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pon-overview
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PON line status card for the LuCI overview page
  DEPENDS:=+luci-base +luci-app-pon
  PKGARCH:=all
endef

define Package/luci-app-pon-overview/description
  Ships a LuCI status-include widget (view/status/include/35_pon.js) that adds a
  compact PON card to Status -> Overview: line mode, lifecycle/ONU state,
  ONU-ID (or LLID), optical signal, Rx/Tx power, frontend temperature and basic
  OMCI information (channel online, OLT equipment, LOID authentication).

  Data comes from the same sources as luci-app-pon's own status page
  (ponctl --device <dev> status --json and pondctl status --line <line>), and
  the exec permissions are already covered by the luci-app-pon rpcd ACL, so no
  extra ACL file is needed. The card hides itself when no PON lines are
  configured.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-pon-overview/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DATA) ./files/35_pon.js \
		$(1)/www/luci-static/resources/view/status/include/35_pon.js
endef

$(eval $(call BuildPackage,luci-app-pon-overview))
