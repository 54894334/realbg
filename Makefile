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

# 这里原来写着 -Wl,-undefined,dynamic_lookup，是个致命错误：
# 它让链接器不再检查任何一个符号是否存在，全部推到运行时由 dyld 解析。
# 只要 iOS 上少一个符号，dyld 就在 main 之前直接杀进程 ——
# 表现正是「点开就闪退、日志一个字节都没有」。
# 现在改回正常链接：符号有问题在 CI 阶段就报错，不会流到手机上。
# 私有框架本来就不用（全部走 NSClassFromString），不需要 dynamic_lookup。
RealBG_LDFLAGS =

RealBG_CODESIGN_FLAGS = -Sentitlements.plist
RealBG_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
