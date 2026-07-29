TARGET := iphone:clang:26.2:16.3
INSTALL_TARGET_PROCESSES = Instagram
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RyukGram

$(TWEAK_NAME)_FILES = $(shell find src -type f \( -iname \*.x -o -iname \*.xm -o -iname \*.m \)) modules/fishhook/fishhook.c

# The no-plugins sideload compat patch (keychain / app groups / CloudKit) is no
# longer baked in here — it ships as a standalone NoPluginsPatch.dylib
# (modules/SideloadPatch) injected by cyan for no-plugins builds.

$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics UserNotifications Photos PhotosUI CoreServices SystemConfiguration SafariServices Security QuartzCore AVFoundation AVKit UniformTypeIdentifiers CoreLocation MapKit LocalAuthentication Vision Accelerate CoreData CoreMedia CoreVideo CoreImage ImageIO QuickLook
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

# Rebuild the exact verified Mapping-V8 snapshot from the repository baseline
# plus a compact checked delta. THEOS_OBJ_DIR is architecture-sensitive: the
# outer make sees .theos/obj while the arm64 submake sees .theos/obj/arm64.
# Keep the generated catalogue in one architecture-independent absolute path.
SCI_IDMAP_BASE := src/BundleAssets/id_name_mapping.json
SCI_IDMAP_DELTA_DIR := Resources/mobileconfig/id_name_mapping_v8_delta.parts
SCI_IDMAP_DELTA_PARTS := $(sort $(wildcard $(SCI_IDMAP_DELTA_DIR)/part*))
SCI_IDMAP_TOOL := tools/apply-idmap-v8.py
SCI_IDMAP_GENERATED := $(CURDIR)/.theos/generated/id_name_mapping.v8.json
SCI_IDMAP_SECTION_SOURCE := src/BundleAssets/SCIIdMapSections.m

$(SCI_IDMAP_GENERATED): $(SCI_IDMAP_BASE) $(SCI_IDMAP_DELTA_PARTS) $(SCI_IDMAP_TOOL)
	@mkdir -p "$(dir $@)"
	@python3 "$(SCI_IDMAP_TOOL)" "$(SCI_IDMAP_BASE)" "$(SCI_IDMAP_DELTA_DIR)" "$@"

before-all:: $(SCI_IDMAP_GENERATED)

# SCIIdMapSections.m embeds both JSON files through assembler .incbin directives
# into a normal arm64 object containing __DATA,__idmap and __DATA,__idmap439.
# The raw JSON paths must not be placed in *_LDFLAGS: doing so can make the
# clang++ driver treat them as ordinary linker inputs and report "unknown file
# type". Runtime access through getsectiondata() remains unchanged.

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

# The object produced from SCIIdMapSections.m uses .incbin, so the generated
# Mapping-V8 file must exist before that one translation unit is compiled.
$(THEOS_OBJ_DIR)/$(SCI_IDMAP_SECTION_SOURCE).$(_THEOS_OBJ_FILE_TAG).o: $(SCI_IDMAP_GENERATED) src/BundleAssets/id_name_mapping_internal439.json

ifeq ($(FINALPACKAGE),1)
after-all::
	@python3 tools/obfuscate-classes.py "$(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib"
	@ldid -S "$(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib"
endif

# # Build FLEXing once for sideload builds, then reuse the compiled dylib.
# ifdef SIDELOAD

# FLEXING_DYLIB := modules/flexing/.theos/obj/arm64/FLEXing.dylib

# $(FLEXING_DYLIB):
# 	$(MAKE) -C modules/flexing FINALPACKAGE=1

# before-package:: $(FLEXING_DYLIB)

# clean-flexing::
# 	$(MAKE) -C modules/flexing clean
# endif