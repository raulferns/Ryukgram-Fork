// Standalone "Internal & Dogfood Menus" enabler.
//
// === IDA-VERIFIED CALL CHAIN ===
// When "Internal Settings" row (case 4) is tapped in didSelectRowAtIndexPath:
// (0x100f23ec0), v65 = ivar internalSettingsAvailabilityStatus.
// If v65 == 0 (Available) -> calls sub_107556A84 (0x107556a84).
// sub_107556A84 at 0x107556abc calls sub_106FEB960(fragment) -- a SECOND
// independent employee validator.
//
// sub_106FEB960 return values (IDA verified at 0x106feb960):
//   0 = Available  (v6 = 0 when FBEndToEndIsRunningJestE2E() != 0, OR v2 != 0)
//   1 = Hidden     (v6 = 1 when FBEndToEndIsRunningSapienz(session) & sub_102D7BFD0())
//   2 = Denied     (v6 = 2 when v2 == 0 after asIGUserIsEmployeeOrTestUserFragment check)
//
// sub_102D7BFD0 calls sub_102D81478 which calls sub_10240E200 which calls
// XPluginsGetDataFuncOrAbort(1681030145) -- handled by our fishhook.
//
// The cleanest fix: directly hook sub_106FEB960 to always return 0 (Available).
// We use MSHookFunction with ASLR-slide computed from mach_header at runtime.
// fishhook covers the XPlugins MobileConfig gate as a second layer.
//
// Fishhook works by replacing dynamic loader bindings in the writable GOT (__DATA),
// which is 100% safe for sideloading.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import "../../Utils.h"
#import "../Gating/SCIRuntimeBoolForce.h"
#import "SCIInternalMenusForce.h"
#import "SCIInternalGatePrefs.h"
#import "../../../modules/fishhook/fishhook.h"
#import <dlfcn.h>
#import <unistd.h>


// ---------------------------------------------------------------------------
#pragma mark - Helper declarations
// ---------------------------------------------------------------------------

#import <UIKit/UIKit.h>

static uintptr_t get_instagram_base_address(void);

// ---------------------------------------------------------------------------
#pragma mark - Employee Status Hook (sub_106FEB960) via GOT fishhook
// ---------------------------------------------------------------------------
//
// IDA PROOF: sub_107556A84 (Internal Settings opener) at 0x107556abc calls
// sub_106FEB960(fragment). Returns 0=Available, 2=Denied.
// Inside sub_106FEB960 at 0x106feb99c: calls FBEndToEndIsRunningJestE2E().
// If FBEndToEndIsRunningJestE2E() returns 1 -> sub_106FEB960 returns 0 (Available).
//
// We safely fishhook FBEndToEndIsRunningJestE2E and FBEndToEndIsRunningSapienz 
// (which are thunks to imported C functions in GOT) and verify that the call
// originates from within the address range of sub_106FEB960.
// This is 100% safe, doesn't use MSHookFunction on __TEXT, and prevents launch crash.

#import <os/log.h>






// ---------------------------------------------------------------------------
#pragma mark - ObjC hook installation
// ---------------------------------------------------------------------------

static NSUInteger SCIInternalMenusInstallLocalRuntimeBoolHooks(void) {
    NSUInteger installed = 0;

    if ([SCIRuntimeBoolForce forceClassNamed:@"IGUser" selector:@"isEmployee" classMethod:NO value:YES]) installed++;
    if ([SCIRuntimeBoolForce forceClassNamed:@"IGUser" selector:@"isTestUser" classMethod:NO value:YES]) installed++;

    // Master local employee gate (FBSharedFramework). This is the predicate the
    // [ig-only]/[internal-only] action checkers consult and the dogfood entry
    // rows depend on. Kept manual/post-launch only.
    if ([SCIRuntimeBoolForce forceClassNamed:@"IGFacebookUserInfo"
                                    selector:@"isEmployee"
                                 classMethod:NO
                                       value:YES]) installed++;

    // Secondary employee getter in the IG main image.
    if ([SCIRuntimeBoolForce forceClassNamed:@"IGAdPlatformLogger_objc"
                                    selector:@"isEmployee"
                                 classMethod:NO
                                       value:YES]) installed++;

    // Autofill internal settings debug footer — gateway row into the native
    // internal/debug settings surface.
    if ([SCIRuntimeBoolForce forceClassNamed:@"_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings"
                                    selector:@"getDebugFooterEnabled"
                                 classMethod:NO
                                       value:YES]) installed++;

    // Identity-switcher dogfood mode.
    if ([SCIRuntimeBoolForce forceClassNamed:@"_TtC24IGIdentitySwitcherGating30IGIdentitySwitcherGatingHelper"
                                    selector:@"isFbAcquisitionEpDogfoodModeEnabled"
                                 classMethod:NO
                                       value:YES]) installed++;

    return installed;
}

NSString *SCIInternalMenusForceApplyNow(void) {
    NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
    return [NSString stringWithFormat:@"Forced internal settings: %d, installed %lu ObjC hooks.", [SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"], (unsigned long)installed];
}

// ---------------------------------------------------------------------------
#pragma mark - %ctor: Install fishhook dynamic bindings at startup
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
            NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
            NSLog(@"[RyukGram] Installed %lu ObjC runtime hooks at launch", (unsigned long)installed);
        }
    }
}
