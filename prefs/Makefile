include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlassIconsPrefs
GlassIconsPrefs_FILES = RootListController.m
GlassIconsPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I.
GlassIconsPrefs_FRAMEWORKS = UIKit Foundation
GlassIconsPrefs_PRIVATE_FRAMEWORKS = Preferences
GlassIconsPrefs_INSTALL_PATH = /Library/PreferenceBundles
GlassIconsPrefs_RESOURCE_FILES = Resources/Root.plist Resources/icon.png Resources/icon@2x.png Resources/icon@3x.png

include $(THEOS_MAKE_PATH)/bundle.mk
