// Standalone "Internal & Dogfood Menus" enabler.
//
// Startup-safe persistent-toggle version.
//
// The previous version executed these hooks from %ctor when the persisted
// sci_internal_menus pref was ON. That made a persisted UI toggle execute during
// Instagram scene-create, before the app finished booting. On the tested build,
// that drove IG into XPlugins/FBAnalytics while FBAnalyticsCurrentSerializedAppIdentity
// was still inside pthread_once, producing a 0x8BADF00D watchdog deadlock.
//
// This file now keeps persistence but removes launch-time execution. The toggle
// remains ON across restarts, but the hooks are applied only when the user
// changes the toggle to ON inside Settings during the current session. There is
// no separate manual Apply button and nothing runs automatically at launch.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../../Utils.h"
#import "../Gating/SCIRuntimeBoolForce.h"
#import "SCIInternalMenusForce.h"
#import "../../../modules/fishhook/fishhook.h"
#import <dlfcn.h>

typedef void *(*XPluginsDataFunc)(int paramID, ...);
typedef void *(*XPluginsGetDataFuncOrAbortFn)(int paramID);
typedef void *(*XPluginsGetFunctionPtrFromIDFn)(int socketID, int arg2);

static XPluginsGetDataFuncOrAbortFn orig_XPluginsGetDataFuncOrAbort = NULL;
static XPluginsGetFunctionPtrFromIDFn orig_XPluginsGetFunctionPtrFromID = NULL;

static void dummy_socket_func(void *a __unused, void *b __unused, void *c __unused, void *d __unused) {
    // No-op to prevent crashes if a socket resolves to NULL
}

static uint32_t mock_socket_config[2] = { 0, 117 };

static void *mock_data_func_impl(void) {
    return &mock_socket_config;
}

static void *custom_XPluginsGetDataFunc(int paramID) {
    // 1681030145 is 0x64327C01
    if (paramID == 1681030145) {
        return (void *)mock_data_func_impl;
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

    static BOOL didHookXPlugins = NO;
    if (!didHookXPlugins) {
        struct rebinding rebs[2];
        rebs[0].name = "XPluginsGetDataFuncOrAbort";
        rebs[0].replacement = (void *)custom_XPluginsGetDataFunc;
        rebs[0].replaced = (void **)&orig_XPluginsGetDataFuncOrAbort;

        rebs[1].name = "XPluginsGetFunctionPtrFromID";
        rebs[1].replacement = (void *)custom_XPluginsGetFunctionPtrFromID;
        rebs[1].replaced = (void **)&orig_XPluginsGetFunctionPtrFromID;

        rebind_symbols(rebs, 2);
        didHookXPlugins = YES;
        installed++;
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

%ctor {
    @autoreleasepool {
        // Deliberately no-op. Persistence stays in NSUserDefaults, but a persisted
        // ON state must not execute during Instagram scene-create. Execution occurs
        // only when the settings toggle is changed to ON in the current session.
    }
}
