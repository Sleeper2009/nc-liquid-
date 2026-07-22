ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassNC
LiquidGlassNC_FILES = Tweak.xm
LiquidGlassNC_CFLAGS = -fobjc-arc
LiquidGlassNC_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
