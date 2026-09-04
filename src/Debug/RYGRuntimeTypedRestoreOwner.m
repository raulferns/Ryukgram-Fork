#import "RYGRuntimeValueStore.h"
#import <UIKit/UIKit.h>
#import <stdatomic.h>

// Typed runtime overrides are authoritative for the WATweaks-style browser.
// Retry after Instagram has finished loading/swizzling its runtime. Failed
// installs remain persisted and can be retried by Apply or a later activation.
static atomic_uint_fast64_t gRYGTypedRestoreGeneration = 0;

static dispatch_queue_t RYGTypedRestoreQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.ryukgram.runtime-typed-restore", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void RYGTypedRestore(uint64_t generation) {
    @autoreleasepool {
        if (generation != atomic_load_explicit(&gRYGTypedRestoreGeneration, memory_order_acquire)) return;
        (void)RYGRuntimeValueReinstallPersistedHooks();
    }
}

static void RYGScheduleTypedRestore(NSTimeInterval delay) {
    if (!RYGRuntimeValueAllOverrideSpecs().count) return;
    uint64_t generation = atomic_fetch_add_explicit(&gRYGTypedRestoreGeneration, 1, memory_order_acq_rel) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), RYGTypedRestoreQueue(), ^{
        RYGTypedRestore(generation);
    });
}

__attribute__((constructor(230))) static void RYGInstallTypedRuntimeRestoreOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            // Delay until Instagram's normal late runtime registration settles.
            RYGScheduleTypedRestore(1.25);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGScheduleTypedRestore(0.35);
        }];
    });
}
