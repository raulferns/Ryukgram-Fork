#import "RYGMobileConfig.h"
#import "RYGMobileConfigJSONIO.h"
#import "RYGMobileConfigNameMappingStore.h"
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

static NSString *RYGMCNativeFileCanonicalCachePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [[[support stringByAppendingPathComponent:@"RyukGram"] stringByStandardizingPath]
        stringByAppendingPathComponent:@"mc_overrides_canonical.json"];
}

static BOOL RYGMCNativeFileValidJSON(NSData *data) {
    if (!data.length) return NO;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class];
}

static BOOL RYGMCNativeFileWriteAndVerify(NSData *data, NSString *path) {
    if (!data.length || !path.length) return NO;
    NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if ([existing isEqualToData:data]) return YES;
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) return NO;
    NSData *roundTrip = [NSData dataWithContentsOfFile:path options:0 error:&error];
    return roundTrip.length && [roundTrip isEqualToData:data];
}

static void RYGMCNativeFileRestore(uint64_t generation) {
    @autoreleasepool {
        if (atomic_load_explicit(&gRYGMCNativeFileGeneration, memory_order_acquire) != generation) return;

        // The durable canonical document is the source of truth across process
        // launches. Do not require the in-memory override table to have already
        // been reconstructed: on a cold launch it is intentionally still empty.
        NSData *canonical = [NSData dataWithContentsOfFile:RYGMCNativeFileCanonicalCachePath()
                                                   options:NSDataReadingMappedIfSafe
                                                     error:nil];
        if (!RYGMCNativeFileValidJSON(canonical)) return;

        RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
        NSString *nativePath = [mobileConfig ryg_nativeOverridesJSONPath];
        if (!nativePath.length) return;
        if (!RYGMCNativeFileWriteAndVerify(canonical, nativePath)) return;

        NSData *mapping = RYGMCLoadCachedNameMappingData();
        NSString *mappingPath = [mobileConfig ryg_nativeNameMappingPath];
        if (mapping.length && mappingPath.length) (void)RYGMCNativeFileWriteAndVerify(mapping, mappingPath);

        // If the process restarted, hydrate the runtime override table from the
        // same canonical document before mirroring StartupConfigs. This runs on
        // the utility queue after the app became active and never on cold-start.
        if (!mobileConfig.overrideCount) {
            NSUInteger applied = 0;
            NSError *importError = nil;
            (void)[mobileConfig ryg_importAndApplyOverridesData:canonical
                                                   appliedCount:&applied
                                                          error:&importError];
        } else {
            [mobileConfig reapplyOverridesToNativeTable];
        }
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
