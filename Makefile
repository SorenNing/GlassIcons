ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlassIcons
GlassIcons_FILES = GlassIcons.m
GlassIcons_CFLAGS = -fobjc-arc -Wall
GlassIcons_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/GlassIconsPrefs.bundle"
	install -m 644 prefs/Info.plist prefs/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/GlassIconsPrefs.bundle/"
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	install -m 644 prefs/GlassIcons.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/GlassIcons.plist"
