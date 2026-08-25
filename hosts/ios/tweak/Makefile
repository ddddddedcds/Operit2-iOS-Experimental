# theos build for Operit iOS control tweak (Dopamine rootless, ElleKit)
# Loaded only into SpringBoard; exposes a Unix socket for device control.
TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
# Package scheme: rootless-only. This fork no longer ships a roothide build, and
# the tweak no longer carries any runtime roothide detection (the old
# roothide_compat.h path-resolution logic has been removed). THEOS_PACKAGE_SCHEME
# is fixed to rootless; do not reintroduce a roothide branch.
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := operit-sb operit-app

operit-sb_FILES := operit-sb.x
operit-sb_CFLAGS := -fobjc-arc -Wno-unused-function -Wno-arc-performSelector-leaks
operit-sb_FRAMEWORKS := CoreGraphics UIKit
operit-sb_LIBRARIES := sqlite3
# 尝试让 tweak 以可信 AX 客户端身份运行（旁白同款 entitlement）。
operit-sb_CODESIGN_FLAGS := -Sentitlements.plist

operit-app_FILES := operit-app.x
operit-app_CFLAGS := -fobjc-arc -Wno-unused-function -Wno-arc-performSelector-leaks
operit-app_FRAMEWORKS := CoreGraphics UIKit
# 与 operit-sb 同款私有 AX entitlement（进程内自读通常不需，但带上无害）。
operit-app_CODESIGN_FLAGS := -Sentitlements.plist

# 注：operit-axs（注入 backboardd）与 operit-ax.h（AX 树采集）均已移除——
# 真机验证 iOS 15.7 上跨进程 AX 不可用，纯视觉智能体（截屏 + VLM）已完全替代 uitree。
# 读屏改走 option B（_UICreateScreenUIImage 截屏 + VLM）。

include $(THEOS_MAKE_PATH)/tweak.mk
