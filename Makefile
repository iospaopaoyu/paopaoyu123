ARCHS = arm64
TARGET = iphone:clang:16.5:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZhuTiTouSong

ZhuTiTouSong_FILES = $(wildcard *.xm) $(wildcard 功能/*.m)
ZhuTiTouSong_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-nonnull -Wno-nullability-completeness -I功能 -I.
ZhuTiTouSong_CCFLAGS = -I功能 -I.
ZhuTiTouSong_FRAMEWORKS = UIKit Foundation Security UserNotifications CoreGraphics
ZhuTiTouSong_PRIVATE_FRAMEWORKS = AppSupport
ZhuTiTouSong_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# Linux 交叉编译适配（macOS 下自动跳过，不影响 Xcode/Theos 原生编译）
ifeq ($(shell uname -s),Linux)
_THEOS_TARGET_LDFLAGS := $(filter-out -multiply_defined suppress,$(_THEOS_TARGET_LDFLAGS))
_THEOS_TARGET_LDFLAGS += -undefined dynamic_lookup -fuse-ld=lld
endif