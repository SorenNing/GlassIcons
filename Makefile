ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlassIcons
GlassIcons_FILES = GlassIcons.m
GlassIcons_CFLAGS = -fobjc-arc -Wall
GlassIcons_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
