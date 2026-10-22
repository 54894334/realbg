TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RealBG

RealBG_FILES = src/main.m src/RBRootVC.m src/RBStore.m src/RBProcesses.m \
               src/RBBackstage.m src/RBBooster.m
RealBG_CFLAGS = -fobjc-arc -I src \
	-Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable \
	-Wno-objc-method-access -Wno-undeclared-selector -Wno-format \
	-Wno-nullability-completeness -Wno-incompatible-pointer-types \
	-Wno-objc-property-no-attribute -Wno-protocol -Wno-unused-but-set-variable
RealBG_FRAMEWORKS = UIKit Foundation
# 私有框架一律 NSClassFromString 动态取，不在链接期引用符号；
# dynamic_lookup 兜底，避免 CI 上的 SDK 缺 PrivateFrameworks .tbd 时链接失败
RealBG_LDFLAGS = -Wl,-undefined,dynamic_lookup
RealBG_CODESIGN_FLAGS = -Sentitlements.plist
RealBG_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
