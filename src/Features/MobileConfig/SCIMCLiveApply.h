// SCIMCLiveApply.h — RyukGram-Fork
//
// Applies MobileConfig overrides LIVE, in-process, via the exact C++ overrides
// table API that Instagram's own FBShared exports (the same path the Facebook
// Debug UI VCs drive under the hood). No network fetch, no params-list call, no
// relaunch — so it never hits the abort() precondition in
// _IGMobileConfigTryUpdateConfigsWithCompletion.
//
// Confirmed ABI (FBSharedFramework, disassembled with radare2):
//   mobileconfig::FBMobileConfigManager::getOrCreateOverridesTable(bool)
//     symbol: _ZN12mobileconfig21FBMobileConfigManager25getOrCreateOverridesTableEb
//     x0 = FBMobileConfigManager* (raw), w1 = bool, x8 = sret -> shared_ptr (16B)
//   mobileconfig::FBMobileConfigOverridesTable::updateOverrideForParam(unsigned long long, bool, bool)
//     symbol: _ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEybb
//     x0 = OverridesTable* (raw), x1 = paramID (u64), w2 = value, w3 = persist
//   removeOverrideForParam(unsigned long long, bool)
//     symbol: _ZN12mobileconfig28FBMobileConfigOverridesTable22removeOverrideForParamEyb
//
// paramID note: this is the 64-bit MobileConfig param hash (the SAME identifier
// the EasyGating evaluators read), e.g. ig_is_employee param0 == 0x8102c800010921
// as encoded in the IG binary's _ig_is_employee descriptor. It is NOT the local
// build ordinal from params_map.txt.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCIMCLiveResult) {
    SCIMCLiveOK = 0,
    SCIMCLiveNoManager,      // could not resolve the live FBMobileConfigManager
    SCIMCLiveNoTable,        // getOrCreateOverridesTable returned null
    SCIMCLiveNoSymbol,       // a required C++ symbol was not found
};

@interface SCIMCLiveApply : NSObject

/// One-line status for a settings-row accessory: "ready", "no manager",
/// "no symbols". Cheap; safe to call on every cell render.
+ (NSString *)wiringStatus;

/// Set (value) or clear (remove) a single override live. paramID is the 64-bit
/// MobileConfig param hash. Returns SCIMCLiveOK on success.
+ (SCIMCLiveResult)setOverrideForParamID:(uint64_t)paramID value:(BOOL)value;
+ (SCIMCLiveResult)clearOverrideForParamID:(uint64_t)paramID;

/// Validation entry point: forces ig_is_employee (config 56474, param 0,
/// paramID 0x8102c800010921 — read directly from the IG binary descriptor) to
/// true, live. If internal gating flips without relaunch, the 64-bit paramID
/// space is confirmed and every other config can be driven the same way.
+ (NSString *)applyIsEmployeeProbe;

@end

NS_ASSUME_NONNULL_END
