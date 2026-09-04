#import "RYGMobileConfig.h"
#import <UIKit/UIKit.h>
#import <stdatomic.h>

static atomic_uint_fast64_t gRYGMCNativeFileGeneration = 0;

static dispatch_queue_t RYGMCNativeFileQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.mobileconfig.native-file", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void RYGMCNativeFileRestore(uint64_t generation) {
    @autoreleasepool {
        if (atomic_load_explicit(&gRYGMCNativeFileGeneration, memory_order_acquire) != generation) return;
        RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
        // mc_overrides.plist is the only durable authority for RyukGram-owned
        // values. RYGMobileConfig and the hot getter owner both load that exact
        // typed store. Canonical/native JSON is export/import material only and
        // must never be promoted implicitly when the app enters foreground.
        if (mobileConfig.overrideCount) [mobileConfig reapplyOverridesToNativeTable];
    }
}

static void RYGMCNativeFileSchedule(void) {
    uint64_t generation = atomic_fetch_add_explicit(&gRYGMCNativeFileGeneration, 1, memory_order_acq_rel) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
                   RYGMCNativeFileQueue(), ^{
        RYGMCNativeFileRestore(generation);
    });
}

__attribute__((constructor(230))) static void RYGInstallMobileConfigNativeFileOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGMCNativeFileSchedule();
        }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) RYGMCNativeFileSchedule();
    });
}
