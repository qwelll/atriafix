export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AtriaScaleNoAnim
AtriaScaleNoAnim_FILES = Tweak.x
AtriaScaleNoAnim_FRAMEWORKS = UIKit QuartzCore Foundation
AtriaScaleNoAnim_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
