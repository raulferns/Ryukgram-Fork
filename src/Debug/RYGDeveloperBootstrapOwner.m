#import "RYGDeveloperTopicViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGEasyGatingRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>

// Persisted Developer state must be owned by startup/lifecycle code, not by the
// Developer UI. Opening Runtime Browser is never a prerequisite for restoring a
// method, C import, EasyGating gate, Prism/Story override or dogfood mode.

static os_unfair_lock gRYGDeveloperBootstrapLock = OS_UNFAIR_LOCK_INIT;
static BOOL gRYGDeveloperBootstrapActive;
static BOOL gRYGDeveloperBootstrapScheduled;
static char kRYGDeveloperBootstrapQueueSpecific;

@interface RYGDeveloperTopicViewController (RYGBackgroundPersistedActivation)
+ (void)ryg_background_activatePersistedNativeFeatures;
@end

static dispatch_queue_t RYGDeveloperBootstrapQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.developer-bootstrap", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue,
                                    &kRYGDeveloperBootstrapQueueSpecific,
                                    &kRYGDeveloperBootstrapQueueSpecific,
                                    NULL);
    });
    return queue;
}

static BOOL RYGDeveloperIsOnBootstrapQueue(void) {
    return dispatch_get_specific(&kRYGDeveloperBootstrapQueueSpecific) == &kRYGDeveloperBootstrapQueueSpecific;
}

static BOOL RYGDeveloperHasPersistedEasyGating(void) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:@"ryg_easy_gating_platform_bool_overrides_v2"];
    return [raw isKindOfClass:NSDictionary.class] && [(NSDictionary *)raw count] > 0;
}

static BOOL RYGDeveloperHasPersistedNativeState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"ryg_dev_internal_menu_enabled"] ||
        [defaults boolForKey:@"ryg_dev_dogfood_mode_enabled"]) return YES;
    for (NSString *key in @[@"ryg_dev_prism_setter_mode", @"ryg_dev_redesign_setter_mode", @"ryg_dev_story_tray_override"]) {
        if ([defaults objectForKey:key] != nil) return YES;
    }
    return NO;
}

static BOOL RYGDeveloperHasPersistedRuntimeState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *methods = [defaults dictionaryForKey:@"ryg_runtime_method_overrides_v5"];
    NSDictionary *legacyMethods = [defaults dictionaryForKey:@"ryg_runtime_method_overrides_v4"];
    NSDictionary *c = [defaults dictionaryForKey:@"ryg_runtime_c_overrides_v5"];
    NSDictionary *legacyC = [defaults dictionaryForKey:@"ryg_runtime_c_overrides_v4"];
    return methods.count || legacyMethods.count || c.count || legacyC.count;
}

// After the class-method exchange below, this alias invokes the original
// activatePersistedNativeFeatures implementation. Calling the public selector
// from UI code only schedules this work; it never blocks viewDidLoad.
static void RYGDeveloperRunOriginalNativeActivation(void) {
    [RYGDeveloperTopicViewController ryg_background_activatePersistedNativeFeatures];
}

static void RYGDeveloperBootstrapRun(void) {
    @autoreleasepool {
        if (RYGDeveloperHasPersistedRuntimeState()) {
            [RYGRuntimeBrowserEngine reinstallPersistedOverrides];
        }
        if (RYGDeveloperHasPersistedEasyGating()) {
            [RYGEasyGatingRuntime.shared installIfNeeded];
        }
        if (RYGDeveloperHasPersistedNativeState()) {
            RYGDeveloperRunOriginalNativeActivation();
        }
    }
}

static void RYGDeveloperBootstrapSchedule(void) {
    os_unfair_lock_lock(&gRYGDeveloperBootstrapLock);
    if (!gRYGDeveloperBootstrapActive || gRYGDeveloperBootstrapScheduled) {
        os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);
        return;
    }
    gRYGDeveloperBootstrapScheduled = YES;
    os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), RYGDeveloperBootstrapQueue(), ^{
        RYGDeveloperBootstrapRun();
        os_unfair_lock_lock(&gRYGDeveloperBootstrapLock);
        gRYGDeveloperBootstrapScheduled = NO;
        os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);
    });
}

static void RYGDeveloperBootstrapImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    // The callback is intentionally O(1). It only coalesces a targeted restore;
    // no Objective-C class/method catalogue is built here.
    RYGDeveloperBootstrapSchedule();
}

@implementation RYGDeveloperTopicViewController (RYGBackgroundPersistedActivation)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getClassMethod(self, @selector(activatePersistedNativeFeatures));
        Method replacement = class_getClassMethod(self, @selector(ryg_background_activatePersistedNativeFeatures));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

+ (void)ryg_background_activatePersistedNativeFeatures {
    if (RYGDeveloperIsOnBootstrapQueue()) {
        // After exchange, the alias points at the original implementation.
        [self ryg_background_activatePersistedNativeFeatures];
        return;
    }
    dispatch_async(RYGDeveloperBootstrapQueue(), ^{
        [self ryg_background_activatePersistedNativeFeatures];
    });
}

@end

__attribute__((constructor)) static void RYGInstallDeveloperBootstrapOwner(void) {
    (void)RYGDeveloperBootstrapQueue();
    _dyld_register_func_for_add_image(RYGDeveloperBootstrapImageDidLoad);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            os_unfair_lock_lock(&gRYGDeveloperBootstrapLock);
            gRYGDeveloperBootstrapActive = YES;
            os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);
            RYGDeveloperBootstrapSchedule();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            os_unfair_lock_lock(&gRYGDeveloperBootstrapLock);
            gRYGDeveloperBootstrapActive = NO;
            os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);
        }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            os_unfair_lock_lock(&gRYGDeveloperBootstrapLock);
            gRYGDeveloperBootstrapActive = YES;
            os_unfair_lock_unlock(&gRYGDeveloperBootstrapLock);
            RYGDeveloperBootstrapSchedule();
        }
    });
}
