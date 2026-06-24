// Standalone "Internal & Dogfood Menus" enabler.
//
// This file hooks the native MobileConfig gate (sub_102D81478) and the employee
// check (sub_106FEB960) directly using MSHookFunction. This avoids the previous
// approach of hooking XPluginsGetDataFuncOrAbort with fishhook, which caused UI
// freezes because:
//   1. rebind_symbols was called on the main thread during a tap handler
//   2. The mock function pointer chain didn't account for all callers
//
// The direct function hooks are installed at %ctor (safe: they only replace the
// return value of tiny leaf functions) and the ObjC hooks are applied lazily
// when the user taps the Internal Settings row (since the classes must be loaded).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../../Utils.h"
#import "../Gating/SCIRuntimeBoolForce.h"
#import "SCIInternalMenusForce.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

// ---------------------------------------------------------------------------
#pragma mark - Direct function hooks (MSHookFunction on sub_102D81478 & sub_106FEB960)
// ---------------------------------------------------------------------------

// sub_102D81478: the MobileConfig gate.
// Original: calls sub_10240E200(1681030145) → XPluginsGetDataFuncOrAbort → func() → bool.
// We replace it to always return 1 (truthy = gate passes).
typedef uint64_t (*MobileConfigGateFn)(uint64_t);
static MobileConfigGateFn sOrig_MobileConfigGate = NULL;

static uint64_t hooked_MobileConfigGate(uint64_t a1) {
    NSLog(@"[RyukGram] MobileConfigGate(0x%llx) → forced truthy", (unsigned long long)a1);
    return 1;
}

// sub_106FEB960: the employee check.
// Returns: 0 = not employee, 1 = running Sapienz (bypass), 2 = IS employee.
// We force it to return 2 (is employee) so content builders always populate.
typedef uint64_t (*EmployeeCheckFn)(void *, void *);
static EmployeeCheckFn sOrig_EmployeeCheck = NULL;

static uint64_t hooked_EmployeeCheck(void *a1, void *a2) {
    NSLog(@"[RyukGram] EmployeeCheck → forced 2 (is employee)");
    return 2;
}

// sub_10753CC1C: the DogfoodingSessionsViewControllerSocketWrapper check.
// This is called for "Logged Out Internal Settings" and can hang when the socket
// resolution fails. We hook it to always return 1 (socket available).
typedef uint64_t (*SocketWrapperCheckFn)(uint64_t, uint64_t, uint64_t);
static SocketWrapperCheckFn sOrig_SocketWrapperCheck = NULL;

static uint64_t hooked_SocketWrapperCheck(uint64_t a1, uint64_t a2, uint64_t a3) {
    NSLog(@"[RyukGram] SocketWrapperCheck → forced 1 (available)");
    return 1;
}

// ---------------------------------------------------------------------------
#pragma mark - ASLR helpers
// ---------------------------------------------------------------------------

// Instagram may be loaded as a dylib inside LiveContainer (not image index 0).
// We find the correct image by looking for the one whose Mach-O header is at
// the expected preferred base address (0x100000000 for arm64) after accounting
// for the slide.
static intptr_t SCIGetInstagramSlide(void) {
    static intptr_t slide = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;
            // Match the Instagram binary by name. In LiveContainer it may be
            // named "Instagram" or end with "/Instagram.app/Instagram".
            NSString *imageName = [NSString stringWithUTF8String:name];
            if ([imageName hasSuffix:@"/Instagram"] ||
                [imageName hasSuffix:@"/Instagram.app/Instagram"] ||
                [imageName containsString:@"Instagram"]) {
                slide = _dyld_get_image_vmaddr_slide(i);
                NSLog(@"[RyukGram] Found Instagram at image %u (%s), slide: 0x%lx", i, name, (long)slide);
                return;
            }
        }
        // Fallback: try image 0 (standalone jailbreak).
        slide = _dyld_get_image_vmaddr_slide(0);
        NSLog(@"[RyukGram] Instagram image not found by name, using image 0 slide: 0x%lx", (long)slide);
    });
    return slide;
}

// Resolve a virtual address from IDA (unslid) to the runtime address.
static void *SCIResolve(uintptr_t ida_addr) {
    return (void *)(ida_addr + SCIGetInstagramSlide());
}


// ---------------------------------------------------------------------------
#pragma mark - GraphQL spoofing (ObjC hooks for IGUser employee fragment)
// ---------------------------------------------------------------------------

@interface SCIMockEmployeeFragment : NSObject
- (NSString *)graphQLID;
- (NSArray *)accountBadges;
@end

@implementation SCIMockEmployeeFragment
- (NSString *)graphQLID {
    return @"90010000000001";
}
- (NSArray *)accountBadges {
    return @[];
}
@end

@interface SCIMockAvailabilityModel : NSObject
- (id)asIGUserIsEmployeeOrTestUserFragment;
@end

@implementation SCIMockAvailabilityModel
- (id)asIGUserIsEmployeeOrTestUserFragment {
    return [SCIMockEmployeeFragment new];
}
@end

static id new_asIGInternalSettingsAvailabilityFragmentImmutableModel(id self, SEL _cmd) {
    return [SCIMockAvailabilityModel new];
}

static id new_asIGUserIsEmployeeOrTestUserFragment(id self, SEL _cmd) {
    return [SCIMockEmployeeFragment new];
}

// ---------------------------------------------------------------------------
#pragma mark - ObjC hook installation (called lazily, not at %ctor)
// ---------------------------------------------------------------------------

static NSUInteger SCIInternalMenusInstallLocalRuntimeBoolHooks(void) {
    NSUInteger installed = 0;

    static BOOL didHookGraphQLEmployee = NO;
    if (!didHookGraphQLEmployee) {
        Class igUserCls = NSClassFromString(@"IGUser");
        if (igUserCls) {
            SEL sel1 = NSSelectorFromString(@"asIGInternalSettingsAvailabilityFragmentImmutableModel");
            if (class_getInstanceMethod(igUserCls, sel1)) {
                IMP orig = NULL;
                MSHookMessageEx(igUserCls, sel1, (IMP)new_asIGInternalSettingsAvailabilityFragmentImmutableModel, &orig);
                installed++;
            }
            SEL sel2 = NSSelectorFromString(@"asIGUserIsEmployeeOrTestUserFragment");
            if (class_getInstanceMethod(igUserCls, sel2)) {
                IMP orig = NULL;
                MSHookMessageEx(igUserCls, sel2, (IMP)new_asIGUserIsEmployeeOrTestUserFragment, &orig);
                installed++;
            }
            didHookGraphQLEmployee = YES;
        }
    }

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
    if (![SCIUtils getBoolPref:@"sci_internal_menus"]) {
        return @"Internal & Dogfood Menus is OFF. Toggle state is persisted and no hook is active for this session.";
    }

    NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
    if (installed == 0) {
        return @"No internal menu hooks were installed. The target classes may not be loaded yet in this Instagram surface. Toggle remains persisted; flip it ON again after opening the relevant surface.";
    }

    return [NSString stringWithFormat:@"Applied %lu internal menu runtime hook%@ for this session from the toggle change. Nothing was executed during launch.",
            (unsigned long)installed,
            installed == 1 ? @"" : @"s"];
}

// ---------------------------------------------------------------------------
#pragma mark - %ctor: Install direct function hooks at load time
// ---------------------------------------------------------------------------
// These three function hooks are safe at %ctor because they only change the
// return value of small, self-contained functions. They do not call into the
// ObjC runtime, XPlugins, or FBAnalytics — avoiding the deadlock that the
// previous fishhook-based approach caused.

%ctor {
    @autoreleasepool {
        // Hook sub_102D81478 (MobileConfig gate: calls XPluginsGetDataFuncOrAbort(1681030145))
        void *mobileConfigGateAddr = SCIResolve(0x102D81478);
        if (mobileConfigGateAddr) {
            MSHookFunction(mobileConfigGateAddr, (void *)hooked_MobileConfigGate, (void **)&sOrig_MobileConfigGate);
            NSLog(@"[RyukGram] Hooked MobileConfigGate at %p", mobileConfigGateAddr);
        }

        // Hook sub_106FEB960 (Employee check: queries GraphQL + MobileConfig)
        void *employeeCheckAddr = SCIResolve(0x106FEB960);
        if (employeeCheckAddr) {
            MSHookFunction(employeeCheckAddr, (void *)hooked_EmployeeCheck, (void **)&sOrig_EmployeeCheck);
            NSLog(@"[RyukGram] Hooked EmployeeCheck at %p", employeeCheckAddr);
        }

        // Hook sub_10753CC1C (DogfoodingSessionsViewControllerSocketWrapper check)
        void *socketWrapperCheckAddr = SCIResolve(0x10753CC1C);
        if (socketWrapperCheckAddr) {
            MSHookFunction(socketWrapperCheckAddr, (void *)hooked_SocketWrapperCheck, (void **)&sOrig_SocketWrapperCheck);
            NSLog(@"[RyukGram] Hooked SocketWrapperCheck at %p", socketWrapperCheckAddr);
        }
    }
}
