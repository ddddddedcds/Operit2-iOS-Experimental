THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 22

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MyTweak
MyTweak_FILES = Tweak.xm
MyTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
