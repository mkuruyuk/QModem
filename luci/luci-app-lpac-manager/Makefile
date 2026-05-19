include $(TOPDIR)/rules.mk

# Include unified version
include ../../version.mk

PKG_NAME:=luci-app-lpac-manager
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=$(QMODEM_RELEASE)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  PKGARCH:=all
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI eSIM Profile Manager (lpac)
  DEPENDS:=+luci-base +luci-compat +lpac +jq +libmbim
  URL:=https://github.com/mkuruyuk/QModem
endef

define Package/$(PKG_NAME)/description
  LuCI web interface for eSIM/eUICC profile management via lpac.
  Supports QMI, MBIM, and AT backends.
  Patched for Fibocom L850-GL and Foxconn T99W175 removable eSIM.
  Integrates with QModem via mbim-proxy for conflict-free operation.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/lpac-esim
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	# Backend script
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./src/usr/bin/lpac-esim $(1)/usr/bin/lpac-esim

	# LuCI controller (use src/ version - newer v1.3.5)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./src/usr/lib/lua/luci/controller/lpac_esim.lua $(1)/usr/lib/lua/luci/controller/lpac_esim.lua

	# LuCI views (use src/ version - newer with diagnostics tab)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/lpac_esim
	$(CP) ./src/usr/lib/lua/luci/view/lpac_esim/*.htm $(1)/usr/lib/lua/luci/view/lpac_esim/

	# Static web assets (JS, CSS)
	$(INSTALL_DIR) $(1)/www/luci-static/resources/lpac-esim
	$(CP) ./htdocs/luci-static/resources/lpac-esim/* $(1)/www/luci-static/resources/lpac-esim/

	# UCI config
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./etc/config/lpac-esim $(1)/etc/config/lpac-esim

	# Menu and ACL
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	if [ -d ./root/usr/share/luci/menu.d ]; then \
		$(CP) ./root/usr/share/luci/menu.d/*.json $(1)/usr/share/luci/menu.d/ 2>/dev/null || true; \
	fi
	if [ -d ./root/usr/share/rpcd/acl.d ]; then \
		$(CP) ./root/usr/share/rpcd/acl.d/*.json $(1)/usr/share/rpcd/acl.d/ 2>/dev/null || true; \
	fi
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-modulecache /tmp/luci-indexcache*
	/etc/init.d/rpcd reload 2>/dev/null
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
