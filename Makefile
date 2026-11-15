# AtriaZoomGuard — Theos Makefile
# roothide 环境；如需 rootless，把 THEOS_PACKAGE_SCHEME 改成 rootless 即可。
# SDK 版本可按本机实际修改（例如 iphone:clang:16.5:15.0）。

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AtriaZoomGuard
AtriaZoomGuard_FILES = Tweak.x
AtriaZoomGuard_CFLAGS = -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk
