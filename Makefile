ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

# Plan B test: do not restore SpringBoard injection after the recovery build.
TWEAK_NAME = GIIconService
GIIconService_FILES = GIIconService.m
GIIconService_CFLAGS = -fobjc-arc -Wall -Wextra
GIIconService_FRAMEWORKS = Foundation CoreFoundation CoreGraphics ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	install -d "$(THEOS_STAGING_DIR)/DEBIAN"
	install -m 0755 pkg-deb/postinst "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	install -m 644 prefs/GlassIcons.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/GlassIcons.plist"
	ldid -S -Cadhoc "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/GlassIconsPrefs.bundle/GlassIconsPrefs" && echo "signed prefs bundle"
	install -d "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	install -m 644 GIIconService.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/GIIconService.plist"
