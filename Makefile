TARGET := iphone:clang:latest:14.0
# 只出 arm64 单切片。
# 原来出 arm64 + arm64e 两个切片，A12 以上设备会优先加载 arm64e。
# arm64e 带指针认证（PAC），而 TrollStore 的 ldid 伪签名不做指针签名覆盖 ——
# 一旦这里出问题就是「打开即闪退」，而且崩在 dyld，连崩溃日志都拿不到。
# A12+ 跑 arm64 是系统完整支持的（系统自己会降级），性能没有损失。
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RealBG

RealBG_FILES = src/main.m src/RBRootVC.m src/RBStore.m src/RBProcesses.m \
               src/RBBackstage.m src/RBBooster.m src/RBCrash.m
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
