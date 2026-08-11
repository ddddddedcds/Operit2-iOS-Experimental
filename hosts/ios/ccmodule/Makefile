# OperitCC —— Control Center module (CCSupport). Rootless bundle.
TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OperitCC
OperitCC_FILES = operit_cc.m
# 安装到 /Library/CCSupport/（rootless 自动加 /var/jb 前缀），CCSupport 扫描加载。
# 不链接 ControlCenterUIKit（私有框架运行时类，动态派发）。
OperitCC_INSTALL_PATH = /Library/CCSupport
OperitCC_FRAMEWORKS = UIKit ControlCenterUIKit

include $(THEOS_MAKE_PATH)/bundle.mk
