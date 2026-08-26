#import "RYGRuntimeHookManager.h"
#import "RYGRuntimeBrowserEngine.h"
#import <UIKit/UIKit.h>
#import <stdatomic.h>

// Persisted hooks can be installed correctly during construction and then be
// replaced by Instagram's own late swizzles.  Reassert the exact persisted
// identities after launch/activation without involving Runtime Browser or any
// class/image scan.  setSessionOverride reuses the persisted value in RAM and
// deliberately does not rewrite NSUserDefaults for every row.

static NSString *const kRYGRuntimePersistedSpecsV7Key = @"ryg_runtime_bool_hook_specs_v7";
static const NSUInteger kRYGRuntimeReassertLimit = 128;
static atomic_uint_fast64_t gRYGRuntimeReassertGeneration = 0;

static dispatch_queue_t RYGRuntimeReassertQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.runtime-hook-reassert", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void RYGRuntimeReassertPersisted(uint64_t generation) {
    @autoreleasepool {
        if (generation != atomic_load_explicit(&gRYGRuntimeReassertGeneration, memory_order_acquire)) return;
        NSDictionary *specs = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRYGRuntimePersistedSpecsV7Key];
        if (!specs.count) return;
        NSArray *keys = [specs.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        NSUInteger limit = MIN(keys.count, kRYGRuntimeReassertLimit);
        for (NSUInteger index = 0; index < limit; index++) {
            if (generation != atomic_load_explicit(&gRYGRuntimeReassertGeneration, memory_order_acquire)) return;
            id raw = specs[keys[index]];
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *spec = raw;
            NSString *className = [spec[@"class"] isKindOfClass:NSString.class] ? spec[@"class"] : nil;
            NSString *selectorName = [spec[@"selector"] isKindOfClass:NSString.class] ? spec[@"selector"] : nil;
            NSNumber *meta = [spec[@"meta"] isKindOfClass:NSNumber.class] ? spec[@"meta"] : nil;
            NSNumber *kind = [spec[@"kind"] isKindOfClass:NSNumber.class] ? spec[@"kind"] : nil;
            NSNumber *value = [spec[@"value"] isKindOfClass:NSNumber.class] ? spec[@"value"] : nil;
            if (!className.length || !selectorName.length || !meta || !kind || !value) continue;
            NSInteger argumentKind = kind.integerValue;
            if (argumentKind < RYGRuntimeArgumentNone || argumentKind > RYGRuntimeArgumentInteger) continue;

            RYGRuntimeBoolMethod *method = [RYGRuntimeBoolMethod new];
            method.className = className;
            method.selectorName = selectorName;
            method.classMethod = meta.boolValue;
            method.argumentKind = (RYGRuntimeArgumentKind)argumentKind;
            (void)[RYGRuntimeHookManager setSessionOverride:@(value.boolValue) forMethod:method];
        }
    }
}

static void RYGScheduleRuntimeReassert(NSTimeInterval delay) {
    NSDictionary *specs = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRYGRuntimePersistedSpecsV7Key];
    if (!specs.count) return;
    uint64_t generation = atomic_fetch_add_explicit(&gRYGRuntimeReassertGeneration, 1, memory_order_acq_rel) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), RYGRuntimeReassertQueue(), ^{
        RYGRuntimeReassertPersisted(generation);
    });
}

__attribute__((constructor(220))) static void RYGInstallRuntimePersistedReassertOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGScheduleRuntimeReassert(0.15);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            RYGScheduleRuntimeReassert(0.25);
        }];
    });
}
