ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlassIcons
GlassIcons_FILES = GlassIcons.m BadgeGlass.m
GlassIcons_CFLAGS = -fobjc-arc -Wall
GlassIcons_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore CoreGraphics CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	install -m 644 prefs/GlassIcons.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/GlassIcons.plist"
	ldid -S -Cadhoc "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/GlassIconsPrefs.bundle/GlassIconsPrefs" && echo "signed prefs bundle"
