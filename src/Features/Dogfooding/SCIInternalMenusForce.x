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
#import "../../../modules/fishhook/fishhook.h"
#import <dlfcn.h>
#import <unistd.h>

// ---------------------------------------------------------------------------
#pragma mark - XPlugins / fishhook Gating Hook
// ---------------------------------------------------------------------------

typedef void *(*XPluginsGetDataFuncOrAbortFn)(int paramID);
typedef void *(*XPluginsGetFunctionPtrFromIDFn)(int socketID, int arg2);

static XPluginsGetDataFuncOrAbortFn orig_XPluginsGetDataFuncOrAbort = NULL;
static XPluginsGetFunctionPtrFromIDFn orig_XPluginsGetFunctionPtrFromID = NULL;

static void dummy_socket_func(void *a __unused, void *b __unused, void *c __unused, void *d __unused) {
    // No-op to prevent crashes if a socket resolves to NULL
}

static uint64_t mock_true_func(void) {
    return 1;
}

static BOOL cached_force_internal = NO;

static void *custom_XPluginsGetDataFunc(int paramID) {
    // 1681030145 is the MobileConfig gate (paramID for internal settings availability check)
    if (paramID == 1681030145 && cached_force_internal) {
        return (void *)mock_true_func;
    }
    if (orig_XPluginsGetDataFuncOrAbort) {
        return orig_XPluginsGetDataFuncOrAbort(paramID);
    }
    return NULL;
}

static void *custom_XPluginsGetFunctionPtrFromID(int socketID, int arg2) {
    void *res = NULL;
    if (orig_XPluginsGetFunctionPtrFromID) {
        res = orig_XPluginsGetFunctionPtrFromID(socketID, arg2);
    }
    if (!res) {
        return (void *)dummy_socket_func;
    }
    return res;
}

// ---------------------------------------------------------------------------
#pragma mark - Employee Status Hook (sub_106FEB960)
// ---------------------------------------------------------------------------
//
// IDA PROOF: sub_107556A84 (Internal Settings opener) at 0x107556abc calls
// sub_106FEB960(fragment). Returns 0=Available, 2=Denied.
// We hook it at its ASLR-slid address to always return 0.
// Using MSHookFunction via Substrate which handles __TEXT correctly on arm64.
//
// The static offset from mach-o load address is: 0x106FEB960 - 0x100000000 = 0x6FEB960

#define kEmployeeCheckOffset 0x6FEB960UL

typedef long (*EmployeeCheckFn)(void *a1, void *a2);
static EmployeeCheckFn orig_employeeCheck = NULL;

static long replacement_employeeCheck(void *a1, void *a2) {
    // IDA: return 0 = Available. The caller (sub_107556A84) proceeds to open
    // Internal Settings VC when this returns 0.
    NSLog(@"[RyukGram] employee check intercepted -> returning 0 (Available)");
    return 0;
}

static void SCIInstallEmployeeCheckHook(void) {
    // Compute the ASLR slide: get the slide of the main Instagram executable.
    // Instagram is always image index 0 in the dyld image list (the main binary).
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void *targetAddr = (void *)(slide + kEmployeeCheckOffset);
    NSLog(@"[RyukGram] Hooking employee check at %p (slide=0x%lx)", targetAddr, slide);
    MSHookFunction(targetAddr, (void *)replacement_employeeCheck, (void **)&orig_employeeCheck);
    if (orig_employeeCheck) {
        NSLog(@"[RyukGram] Employee check hook installed successfully");
    } else {
        NSLog(@"[RyukGram] WARN: MSHookFunction did not set orig for employee check");
    }
}


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
    cached_force_internal = [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"];
    // Install the IDA-verified employee check hook (sub_106FEB960) if not already installed
    if (!orig_employeeCheck) {
        SCIInstallEmployeeCheckHook();
    }
    NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
    return [NSString stringWithFormat:@"Installed employee hook + %lu ObjC hooks.", (unsigned long)installed];
}

// ---------------------------------------------------------------------------
#pragma mark - %ctor: Install fishhook dynamic bindings at startup
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        struct rebinding rebs[2];
        rebs[0].name = "XPluginsGetDataFuncOrAbort";
        rebs[0].replacement = (void *)custom_XPluginsGetDataFunc;
        rebs[0].replaced = (void **)&orig_XPluginsGetDataFuncOrAbort;

        rebs[1].name = "XPluginsGetFunctionPtrFromID";
        rebs[1].replacement = (void *)custom_XPluginsGetFunctionPtrFromID;
        rebs[1].replaced = (void **)&orig_XPluginsGetFunctionPtrFromID;

        int rc = rebind_symbols(rebs, 2);
        NSLog(@"[RyukGram] fishhook resolved bindings for XPlugins, rc = %d", rc);
        
        cached_force_internal = [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"];
        
        if (cached_force_internal) {
            // IDA-verified: hook sub_106FEB960 (employee validator called at tap time in
            // sub_107556A84 at 0x107556abc). Must be installed at launch before any tap.
            SCIInstallEmployeeCheckHook();
            NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
            NSLog(@"[RyukGram] Installed employee hook + %lu ObjC runtime hooks at launch", (unsigned long)installed);
        }
    }
}
