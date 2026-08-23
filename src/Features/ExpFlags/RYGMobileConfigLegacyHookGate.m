#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

// RYGMobileConfigHookOwner installs the RAM-only getter owner from +load, before
// C/Logos constructors run. The older RYGMobileConfig.xm %ctor is still kept as
// a compatibility fallback, but when ryg_metaconfig_enabled is true it would
// otherwise wrap the same sixteen getters again during cold launch.
//
// Do not mutate the user's preference. For the constructor window only, make
// RYGUtils report this one legacy bootstrap key as disabled. The fast owner has
// already captured the real preference from +load. Once launch completes the
// method exchange is removed entirely, so there is no steady-state read cost.

static atomic_bool gRYGMCLegacyGateInstalled = false;
static atomic_bool gRYGMCLegacyGateOpen = false;

@interface RYGUtils (RYGMobileConfigLegacyHookGate)
+ (BOOL)ryg_mcLegacyGate_getBoolPref:(NSString *)key;
@end

@implementation RYGUtils (RYGMobileConfigLegacyHookGate)

+ (BOOL)ryg_mcLegacyGate_getBoolPref:(NSString *)key {
    if (!atomic_load_explicit(&gRYGMCLegacyGateOpen, memory_order_acquire) &&
        [key isEqualToString:@"ryg_metaconfig_enabled"]) {
        return NO;
    }
    // After exchange this selector points at RYGUtils' original implementation.
    return [self ryg_mcLegacyGate_getBoolPref:key];
}

@end

static void RYGMCLegacyGateRemove(void) {
    bool expected = true;
    if (!atomic_compare_exchange_strong_explicit(&gRYGMCLegacyGateInstalled,
                                                  &expected,
                                                  false,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) return;
    Class meta = object_getClass(RYGUtils.class);
    Method original = class_getInstanceMethod(meta, @selector(getBoolPref:));
    Method gated = class_getInstanceMethod(meta, @selector(ryg_mcLegacyGate_getBoolPref:));
    if (original && gated) method_exchangeImplementations(original, gated);
    atomic_store_explicit(&gRYGMCLegacyGateOpen, true, memory_order_release);
}

__attribute__((constructor(90))) static void RYGInstallMobileConfigLegacyHookGate(void) {
    Class meta = object_getClass(RYGUtils.class);
    Method original = class_getInstanceMethod(meta, @selector(getBoolPref:));
    Method gated = class_getInstanceMethod(meta, @selector(ryg_mcLegacyGate_getBoolPref:));
    if (!original || !gated) {
        atomic_store_explicit(&gRYGMCLegacyGateOpen, true, memory_order_release);
        return;
    }
    method_exchangeImplementations(original, gated);
    atomic_store_explicit(&gRYGMCLegacyGateInstalled, true, memory_order_release);

    dispatch_async(dispatch_get_main_queue(), ^{
        // didFinishLaunching fires once. Keeping this inert observer for the
        // remainder of the process is cheaper and safer than a self-retaining
        // observer token just to unregister it from inside its own block.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGMCLegacyGateRemove();
        }];

        // If injection happens after didFinishLaunching, remove the gate on the
        // first main-queue turn rather than waiting for a lifecycle notification.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateInactive) {
            RYGMCLegacyGateRemove();
        }
    });
}
