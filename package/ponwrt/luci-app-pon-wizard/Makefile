# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2026 Kitsune2077

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pon-wizard
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Kitsune2077 <km2077@foxmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pon-wizard
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PON provisioning wizard (bridge, operator VLAN, management access)
  DEPENDS:=+luci-base +luci-app-pon
  PKGARCH:=all
endef

define Package/luci-app-pon-wizard/description
  Adds a "Wizard" tab under Network -> PON that consolidates the modem-side
  provisioning steps documented in docs/FLASHING.md:

  * bridging the 2.5G port for downstream PPPoE (section 6.2),
  * the operator VLAN tag <-> untag mapping (section 6.4),
  * the downstream management-access schemes A/B/C (sections 6.7.1-6.7.4),
    where B and C are applied by a single click.

  The frontend only stores the desired state in /etc/config/ponwizard;
  /usr/libexec/pon-wizard-apply reconciles the real network/firewall
  configuration towards it. Detection works from the actual configuration,
  so a modem already running scheme B (ponwrt-single-wire.sh) or scheme C
  (configured by hand per the docs) opens with the matching options checked.
  Generated sections reuse the documented names (mgmtdev/mgmtwan, the
  mgmtwan zone and Allow-mgmt-* rules), so manual configurations are
  adopted rather than duplicated. Applies arm a 10-minute automatic
  rollback unless confirmed.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-pon-wizard/conffiles
/etc/config/ponwizard
endef

define Package/luci-app-pon-wizard/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/pon-wizard-apply $(1)/usr/libexec/pon-wizard-apply
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/pon
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/pon/wizard.js \
		$(1)/www/luci-static/resources/view/pon/wizard.js
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ponwizard $(1)/etc/config/ponwizard
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-pon-wizard.json \
		$(1)/usr/share/luci/menu.d/luci-app-pon-wizard.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-pon-wizard.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-pon-wizard.json
endef

$(eval $(call BuildPackage,luci-app-pon-wizard))
