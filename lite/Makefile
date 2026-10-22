TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RealBGLite

RealBGLite_FILES = main.m
RealBGLite_FRAMEWORKS = UIKit Foundation
RealBGLite_CFLAGS = -fobjc-arc
RealBGLite_CODESIGN_FLAGS = -Sentitlements.plist
RealBGLite_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
