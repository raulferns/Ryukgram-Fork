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

static uintptr_t get_instagram_base_address(void);


#import <UIKit/UIKit.h>
#import "SCIInternalMenusLauncher.h"
#import "SCIDogfoodObjectRuntime.h"

@interface SCIDummyViewController : UIViewController
@property (nonatomic, strong) NSString *targetURL;
@property (nonatomic, assign) BOOL isDogfooding;
@end

@implementation SCIDummyViewController
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    UIViewController *presenter = self.presentingViewController;
    UINavigationController *nav = self.navigationController;
    
    if (self.isDogfooding) {
        if (nav) {
            NSMutableArray *vcs = [nav.viewControllers mutableCopy];
            [vcs removeObject:self];
            [nav setViewControllers:vcs animated:NO];
            [SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings];
        } else if (presenter) {
            [self dismissViewControllerAnimated:NO completion:^{
                [SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings];
            }];
        }
    } else if (self.targetURL) {
        if (nav) {
            NSMutableArray *vcs = [nav.viewControllers mutableCopy];
            [vcs removeObject:self];
            [nav setViewControllers:vcs animated:NO];
            [SCIInternalMenusLauncher openInternalURLString:self.targetURL controller:nav];
        } else if (presenter) {
            [self dismissViewControllerAnimated:NO completion:^{
                [SCIInternalMenusLauncher openInternalURLString:self.targetURL controller:presenter];
            }];
        }
    }
}
@end

static void *create_dummy_vc(int type) {
    SCIDummyViewController *vc = [[SCIDummyViewController alloc] init];
    if (type == 1) {
        vc.targetURL = @"instagram://internal_settings";
        vc.isDogfooding = NO;
    } else {
        vc.targetURL = nil;
        vc.isDogfooding = YES;
    }
    return (__bridge_retained void *)vc;
}

__attribute__((naked))
static void *custom_initializer_internal_settings(void) {
    __asm__ __volatile__(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "mov w0, #1\n"
        "bl _create_dummy_vc\n"
        "ldp x29, x30, [sp], #16\n"
        "mov x19, #0\n"
        "ret\n"
    );
}

__attribute__((naked))
static void *custom_initializer_dogfooding_assistant(void) {
    __asm__ __volatile__(
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "mov w0, #2\n"
        "bl _create_dummy_vc\n"
        "ldp x29, x30, [sp], #16\n"
        "mov x19, #0\n"
        "ret\n"
    );
}

static void *dummy_socket_func(void *a __unused, void *b __unused, void *c __unused, void *d __unused) {
    return NULL;
}

static uint32_t cached_desc_1681030145[32] = {1, 1681030145};
static uint32_t cached_desc_760840931[32] = {1, 760840931};

static const void *mock_func_1681030145(void) {
    return &cached_desc_1681030145;
}

static const void *mock_func_760840931(void) {
    return &cached_desc_760840931;
}

static void *custom_XPluginsGetDataFunc(int paramID) {
    if (orig_XPluginsGetDataFuncOrAbort) {
        void *res = orig_XPluginsGetDataFuncOrAbort(paramID);
        if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
            if (paramID == 1681030145) {
                static BOOL copied = NO;
                if (!copied) {
                    cached_desc_1681030145[0] = 1; // force enabled
                    cached_desc_1681030145[1] = 1681030145; // force socket ID
                    if (res) {
                        typedef const void *(*DescriptorFunc)(void);
                        const void *real_desc = ((DescriptorFunc)res)();
                        if (real_desc) {
                            memcpy(cached_desc_1681030145, real_desc, 128);
                            cached_desc_1681030145[0] = 1; // force enabled
                            cached_desc_1681030145[1] = 1681030145; // force socket ID
                        }
                    }
                    copied = YES;
                    os_log(OS_LOG_DEFAULT, "[SCIGate] Hooked XPluginsGetDataFunc: paramID %d, initialized descriptor", paramID);
                }
                return (void *)mock_func_1681030145;
            }
            if (paramID == 760840931) {
                static BOOL copied = NO;
                if (!copied) {
                    cached_desc_760840931[0] = 1; // force enabled
                    cached_desc_760840931[1] = 760840931; // force socket ID
                    if (res) {
                        typedef const void *(*DescriptorFunc)(void);
                        const void *real_desc = ((DescriptorFunc)res)();
                        if (real_desc) {
                            memcpy(cached_desc_760840931, real_desc, 128);
                            cached_desc_760840931[0] = 1; // force enabled
                            cached_desc_760840931[1] = 760840931; // force socket ID
                        }
                    }
                    copied = YES;
                    os_log(OS_LOG_DEFAULT, "[SCIGate] Hooked XPluginsGetDataFunc: paramID %d, initialized descriptor", paramID);
                }
                return (void *)mock_func_760840931;
            }
        }
        return res;
    }
    return NULL;
}

static void *custom_XPluginsGetFunctionPtrFromID(int socketID, int arg2) {
    if ([SCIInternalGatePrefs objCGateEnabledForKey:@"sci_force_internal_settings_menu"]) {
        if (socketID == 1681030145) {
            return (void *)custom_initializer_internal_settings;
        }
        if (socketID == 760840931) {
            return (void *)custom_initializer_dogfooding_assistant;
        }
    }
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

static BOOL gSCIDuringBugReportMenuTapHandler = NO;

void SCISetDuringBugReportMenuTapHandler(BOOL during) {
    gSCIDuringBugReportMenuTapHandler = during;
}

BOOL SCIIsDuringBugReportMenuTapHandler(void) {
    return gSCIDuringBugReportMenuTapHandler;
}

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
        if (gSCIDuringBugReportMenuTapHandler) {
            os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningJestE2E MATCH tap time (via flag) -> returning 1");
            return 1;
        }
        
        void *ret_addr = __builtin_return_address(0);
        uintptr_t base = get_instagram_base_address();
        if (base != 0) {
            uintptr_t ip = (uintptr_t)ret_addr;
            uintptr_t start = base + 0x6FEB960;
            uintptr_t end = start + 0x9c;
            if (ip >= start && ip <= end) {
                os_log(OS_LOG_DEFAULT, "[SCIGate] FBEndToEndIsRunningJestE2E builder time -> returning 0 to bypass initializer crash");
                return 0;
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
