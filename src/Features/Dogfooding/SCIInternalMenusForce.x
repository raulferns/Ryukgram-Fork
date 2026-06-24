// Standalone "Internal & Dogfood Menus" enabler.
//
// This file hooks XPluginsGetDataFuncOrAbort with fishhook to resolve the MobileConfig
// gate (paramID 1681030145) to 1. This avoids using MSHookFunction on __TEXT pages
// which is unsafe and crashes in non-jailbroken/sideloaded (LiveContainer) environments.
//
// Fishhook works by replacing dynamic loader bindings in the writable GOT (__DATA),
// which is 100% safe for sideloading.
//
// ObjC graphql employee-spoofing hooks are installed lazily when tapping
// "Internal Settings" to avoid launch-time overhead. Unrecognized selector guards
// are implemented on mock classes to prevent any potential crash.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../../Utils.h"
#import "../Gating/SCIRuntimeBoolForce.h"
#import "SCIInternalMenusForce.h"
#import "../../../modules/fishhook/fishhook.h"
#import <dlfcn.h>

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

static void *custom_XPluginsGetDataFunc(int paramID) {
    // 1681030145 is the MobileConfig gate (paramID for internal settings availability check)
    if (paramID == 1681030145 && [SCIUtils getBoolPref:@"sci_internal_menus"]) {
        NSLog(@"[RyukGram] XPluginsGetDataFuncOrAbort intercepted for gate 1681030145 -> returning mock_true_func");
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
        // Return a dummy function to prevent abort/crash
        return (void *)dummy_socket_func;
    }
    return res;
}

// ---------------------------------------------------------------------------
#pragma mark - GraphQL spoofing (ObjC hooks for IGUser employee fragment)
// ---------------------------------------------------------------------------

static id (*orig_asIGInternalSettingsAvailabilityFragmentImmutableModel)(id, SEL) = NULL;
static id sci_asIGInternalSettingsAvailabilityFragmentImmutableModel(id self, SEL _cmd) {
    id fragment = orig_asIGInternalSettingsAvailabilityFragmentImmutableModel(self, _cmd);
    if (fragment) {
        Class fragmentClass = [fragment class];
        if (fragmentClass) {
            [SCIRuntimeBoolForce forceClassNamed:NSStringFromClass(fragmentClass) selector:@"isEmployee" classMethod:NO value:YES];
            [SCIRuntimeBoolForce forceClassNamed:NSStringFromClass(fragmentClass) selector:@"isTestUser" classMethod:NO value:YES];
        }
    }
    return fragment;
}

static id (*orig_asIGUserIsEmployeeOrTestUserFragment)(id, SEL) = NULL;
static id sci_asIGUserIsEmployeeOrTestUserFragment(id self, SEL _cmd) {
    id fragment = orig_asIGUserIsEmployeeOrTestUserFragment(self, _cmd);
    if (fragment) {
        Class fragmentClass = [fragment class];
        if (fragmentClass) {
            [SCIRuntimeBoolForce forceClassNamed:NSStringFromClass(fragmentClass) selector:@"isEmployee" classMethod:NO value:YES];
            [SCIRuntimeBoolForce forceClassNamed:NSStringFromClass(fragmentClass) selector:@"isTestUser" classMethod:NO value:YES];
        }
    }
    return fragment;
}

// ---------------------------------------------------------------------------
#pragma mark - ObjC hook installation
// ---------------------------------------------------------------------------

static NSUInteger SCIInternalMenusInstallLocalRuntimeBoolHooks(void) {
    NSUInteger installed = 0;

    static BOOL didHookGraphQLEmployee = NO;
    if (!didHookGraphQLEmployee) {
        Class igUserCls = NSClassFromString(@"IGUser");
        if (igUserCls) {
            SEL sel1 = NSSelectorFromString(@"asIGInternalSettingsAvailabilityFragmentImmutableModel");
            if (class_getInstanceMethod(igUserCls, sel1)) {
                MSHookMessageEx(igUserCls, sel1, (IMP)sci_asIGInternalSettingsAvailabilityFragmentImmutableModel, (IMP *)&orig_asIGInternalSettingsAvailabilityFragmentImmutableModel);
                installed++;
            }
            SEL sel2 = NSSelectorFromString(@"asIGUserIsEmployeeOrTestUserFragment");
            if (class_getInstanceMethod(igUserCls, sel2)) {
                MSHookMessageEx(igUserCls, sel2, (IMP)sci_asIGUserIsEmployeeOrTestUserFragment, (IMP *)&orig_asIGUserIsEmployeeOrTestUserFragment);
                installed++;
            }
            didHookGraphQLEmployee = YES;
        }
    }

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
    if (![SCIUtils getBoolPref:@"sci_internal_menus"]) {
        return @"Internal & Dogfood Menus is OFF. Toggle state is persisted and no hook is active for this session.";
    }
    NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
    return [NSString stringWithFormat:@"Applied %lu internal menu runtime hooks.", (unsigned long)installed];
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
        
        // Install ObjC hooks at launch to prevent deadlocks from MSHookMessageEx on the UI thread
        if ([SCIUtils getBoolPref:@"sci_internal_menus"]) {
            NSUInteger installed = SCIInternalMenusInstallLocalRuntimeBoolHooks();
            NSLog(@"[RyukGram] Installed %lu internal menu runtime hooks at launch", (unsigned long)installed);
        }
    }
}
