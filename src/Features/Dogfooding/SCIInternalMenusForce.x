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
#import "../../Utils.h"
#import "../Gating/SCIRuntimeBoolForce.h"
#import "SCIInternalMenusForce.h"

static NSUInteger SCIInternalMenusInstallLocalRuntimeBoolHooks(void) {
    NSUInteger installed = 0;

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
