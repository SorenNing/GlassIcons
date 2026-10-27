ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlassIconsPrefs
GlassIconsPrefs_FILES = RootListController.m
GlassIconsPrefs_CFLAGS = -fobjc-arc -Wall
GlassIconsPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
GlassIconsPrefs_PRIVATE_FRAMEWORKS = Preferences
GlassIconsPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
