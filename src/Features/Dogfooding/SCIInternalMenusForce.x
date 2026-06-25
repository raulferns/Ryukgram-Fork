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
#pragma mark - XPlugins / fishhook Gating Hook
// ---------------------------------------------------------------------------

typedef void *(*XPluginsGetDataFuncOrAbortFn)(int paramID);
typedef void *(*XPluginsGetFunctionPtrFromIDFn)(int socketID, int arg2);

static XPluginsGetDataFuncOrAbortFn orig_XPluginsGetDataFuncOrAbort = NULL;
static XPluginsGetFunctionPtrFromIDFn orig_XPluginsGetFunctionPtrFromID = NULL;

static void dummy_socket_func(void *a __unused, void *b __unused, void *c __unused, void *d __unused) {
    // No-op to prevent crashes if a socket resolves to NULL
}

static const uint32_t mock_val_true = 1;
static const void *mock_true_func(void) {
    return &mock_val_true;
}

static void *custom_XPluginsGetDataFunc(int paramID) {
    // 1681030145 is the MobileConfig gate (paramID for internal settings availability check)
    if (paramID == 1681030145 && [SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
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

typedef int (*FBEndToEndIsRunningJestE2EFn)(void);
typedef int (*FBEndToEndIsRunningSapienzFn)(void *a1);

static FBEndToEndIsRunningJestE2EFn orig_FBEndToEndIsRunningJestE2E = NULL;
static FBEndToEndIsRunningSapienzFn orig_FBEndToEndIsRunningSapienz = NULL;

static uintptr_t get_instagram_base_address(void) {
    static uintptr_t cached_base = 0;
    if (cached_base != 0) return cached_base;
    
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            size_t len = strlen(name);
            if ((len >= 10 && strcmp(name + len - 10, "/Instagram") == 0) || strcmp(name, "Instagram") == 0) {
                cached_base = (uintptr_t)_dyld_get_image_header(i);
                os_log(OS_LOG_DEFAULT, "[SCIGate] Found Instagram binary at index %u, base = %p", i, (void *)cached_base);
                break;
            }
        }
    }
    
    if (cached_base == 0) {
        cached_base = (uintptr_t)_dyld_get_image_header(0);
        os_log(OS_LOG_DEFAULT, "[SCIGate] WARNING: Instagram binary not found by name, falling back to index 0: %p", (void *)cached_base);
    }
    return cached_base;
}

static int custom_FBEndToEndIsRunningJestE2E(void) {
    if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
        void *ret_addr = __builtin_return_address(0);
        uintptr_t base = get_instagram_base_address();
        os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningJestE2E called, base=%p, ret_addr=%p, offset=0x%lx", (void *)base, ret_addr, (unsigned long)((uintptr_t)ret_addr - base));
        if (base != 0) {
            uintptr_t start = base + 0x6FEB960;
            uintptr_t end = start + 0x9c;
            uintptr_t ip = (uintptr_t)ret_addr;
            if (ip >= start && ip <= end) {
                os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningJestE2E MATCH -> returning 1");
                return 1;
            }
        }
    }
    if (orig_FBEndToEndIsRunningJestE2E) {
        return orig_FBEndToEndIsRunningJestE2E();
    }
    return 0;
}

static int custom_FBEndToEndIsRunningSapienz(void *a1) {
    if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
        void *ret_addr = __builtin_return_address(0);
        uintptr_t base = get_instagram_base_address();
        os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningSapienz called, base=%p, ret_addr=%p, offset=0x%lx", (void *)base, ret_addr, (unsigned long)((uintptr_t)ret_addr - base));
        if (base != 0) {
            uintptr_t start = base + 0x6FEB960;
            uintptr_t end = start + 0x9c;
            uintptr_t ip = (uintptr_t)ret_addr;
            if (ip >= start && ip <= end) {
                os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningSapienz MATCH -> returning 0");
                return 0;
            }
        }
    }
    if (orig_FBEndToEndIsRunningSapienz) {
        return orig_FBEndToEndIsRunningSapienz(a1);
    }
    return 0;
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
    NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
    return [NSString stringWithFormat:@"Forced internal settings: %d, installed %lu ObjC hooks.", [SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"], (unsigned long)installed];
}

// ---------------------------------------------------------------------------
#pragma mark - %ctor: Install fishhook dynamic bindings at startup
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        struct rebinding rebs[4];
        rebs[0].name = "XPluginsGetDataFuncOrAbort";
        rebs[0].replacement = (void *)custom_XPluginsGetDataFunc;
        rebs[0].replaced = (void **)&orig_XPluginsGetDataFuncOrAbort;

        rebs[1].name = "XPluginsGetFunctionPtrFromID";
        rebs[1].replacement = (void *)custom_XPluginsGetFunctionPtrFromID;
        rebs[1].replaced = (void **)&orig_XPluginsGetFunctionPtrFromID;

        rebs[2].name = "FBEndToEndIsRunningJestE2E";
        rebs[2].replacement = (void *)custom_FBEndToEndIsRunningJestE2E;
        rebs[2].replaced = (void **)&orig_FBEndToEndIsRunningJestE2E;

        rebs[3].name = "FBEndToEndIsRunningSapienz";
        rebs[3].replacement = (void *)custom_FBEndToEndIsRunningSapienz;
        rebs[3].replaced = (void **)&orig_FBEndToEndIsRunningSapienz;

        int rc = rebind_symbols(rebs, 4);
        NSLog(@"[RyukGram] fishhook resolved bindings, rc = %d", rc);
        
        if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
            NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
            NSLog(@"[RyukGram] Installed %lu ObjC runtime hooks at launch", (unsigned long)installed);
        }
    }
}
