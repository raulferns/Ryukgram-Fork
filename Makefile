TARGET := iphone:clang:26.2:16.3
INSTALL_TARGET_PROCESSES = Instagram
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RyukGram

$(TWEAK_NAME)_FILES = $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \)) modules/fishhook/fishhook.c

# SideStore-only: legacy sideload compat patch (keychain, app groups, CloudKit).
ifdef SIDESTORE
	$(TWEAK_NAME)_FILES += modules/SideloadPatch/SideloadPatch.xm
endif

$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics UserNotifications Photos PhotosUI CoreServices SystemConfiguration SafariServices Security QuartzCore AVFoundation AVKit UniformTypeIdentifiers CoreLocation MapKit LocalAuthentication Accelerate CoreData CoreMedia CoreVideo CoreImage ImageIO QuickLook
$(TWEAK_NAME)_PRIVATE_FRAMEWORKS = Preferences
$(TWEAK_NAME)_USE_MODULES = 0

# TARGET_OS_* defines so the iPhoneOS26.2 SDK headers resolve correctly under Theos.
SCI_TARGET_FLAGS = -DTARGET_OS_MAC=1 -DTARGET_OS_OSX=0 -DTARGET_OS_IPHONE=1 -DTARGET_OS_IOS=1 -DTARGET_OS_EMBEDDED=1 -DTARGET_OS_SIMULATOR=0 -DTARGET_OS_MACCATALYST=0 -DTARGET_OS_UIKITFORMAC=0 -DTARGET_OS_TV=0 -DTARGET_OS_WATCH=0 -DTARGET_OS_VISION=0 -DTARGET_OS_BRIDGE=0 -DTARGET_OS_DRIVERKIT=0

# File logger master switch. Build with SCI_FILELOG=0 for production: the
# logger, its NSLog tee, and the Settings row compile out to nothing.
SCI_FILELOG ?= 1

$(TWEAK_NAME)_CFLAGS = -fobjc-arc -F$(THEOS)/sdks/iPhoneOS26.2.sdk/System/Library/SubFrameworks -F$(THEOS)/sdks/iPhoneOS26.2.sdk/System/Library/Frameworks/Accelerate.framework/Frameworks $(SCI_TARGET_FLAGS) -Wno-unsupported-availability-guard -Wno-unused-value -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-unused-function -Wno-incompatible-pointer-types -DSCI_FILELOG=$(SCI_FILELOG) -include src/SCIPrefix.h
$(TWEAK_NAME)_LOGOSFLAGS = --c warnings=none
$(TWEAK_NAME)_LDFLAGS += -lcompression

ifeq ($(FINALPACKAGE),1)
	$(TWEAK_NAME)_LDFLAGS += -Wl,-x
	$(TWEAK_NAME)_LDFLAGS += -Wl,-unexported_symbol,_SCI*
	$(TWEAK_NAME)_LDFLAGS += -Wl,-unexported_symbol,_sci*
	$(TWEAK_NAME)_LDFLAGS += -Wl,-unexported_symbol,_kSCI*
	$(TWEAK_NAME)_LDFLAGS += -Wl,-unexported_symbol,_dm*
	$(TWEAK_NAME)_LDFLAGS += -Wl,-unexported_symbol,__Z*
endif

CCFLAGS += -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk
RyukGram_FILES += src/Features/Dogfooding/SCIIGInternalSettingsMenuGate.x
