#import "RYGRuntimeHookManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

// Generic Runtime Browser persistence must never install method hooks from a
// constructor. Dedicated Developer owners are separate; this gate only delays
// the generic persisted replay until Instagram has finished launching.
static atomic_bool gRYGRuntimeLaunchReady = false;
static atomic_bool gRYGRuntimePostLaunchScheduled = false;

@interface RYGRuntimeHookManager (RYGRuntimePostLaunchRestore)
+ (void)ryg_postLaunch_restorePersistedOverrides;
@end

@implementation RYGRuntimeHookManager (RYGRuntimePostLaunchRestore)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getClassMethod(self, @selector(restorePersistedOverrides));
        Method replacement = class_getClassMethod(self, @selector(ryg_postLaunch_restorePersistedOverrides));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

+ (void)ryg_postLaunch_restorePersistedOverrides {
    if (!atomic_load_explicit(&gRYGRuntimeLaunchReady, memory_order_acquire)) return;
    // After exchange this selector is the RuntimeHookManager's real replay.
    [self ryg_postLaunch_restorePersistedOverrides];
}

@end

static void RYGRuntimeSchedulePostLaunchRestore(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&gRYGRuntimePostLaunchScheduled,
                                                  &expected,
                                                  true,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(750 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [RYGRuntimeHookManager restorePersistedOverrides];
    });
}

static void RYGRuntimeMarkLaunchReady(void) {
    atomic_store_explicit(&gRYGRuntimeLaunchReady, true, memory_order_release);
    RYGRuntimeSchedulePostLaunchRestore();
}

__attribute__((constructor(190))) static void RYGInstallRuntimePostLaunchRestoreGate(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGRuntimeMarkLaunchReady();
        }];
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateInactive) {
            RYGRuntimeMarkLaunchReady();
        }
    });
}
