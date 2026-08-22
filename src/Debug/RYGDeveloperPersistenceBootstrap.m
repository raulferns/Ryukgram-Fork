#import "RYGDeveloperTopicViewController.h"
#import "RYGEasyGatingRuntime.h"
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>

static NSString *const kRYGPersistedEasyGatingOverridesKey = @"ryg_easy_gating_platform_bool_overrides_v2";
static BOOL gRYGDeveloperRestoreScheduled;

static void RYGRestorePersistedDeveloperModes(void) {
    [RYGDeveloperTopicViewController activatePersistedNativeFeatures];
    NSDictionary *easyGating = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRYGPersistedEasyGatingOverridesKey];
    if (easyGating.count) [RYGEasyGatingRuntime.shared installIfNeeded];
}

static void RYGScheduleDeveloperRestore(void) {
    @synchronized(RYGDeveloperTopicViewController.class) {
        if (gRYGDeveloperRestoreScheduled) return;
        gRYGDeveloperRestoreScheduled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized(RYGDeveloperTopicViewController.class) { gRYGDeveloperRestoreScheduled = NO; }
        RYGRestorePersistedDeveloperModes();
    });
}

static void RYGDeveloperPersistenceImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    RYGScheduleDeveloperRestore();
}

__attribute__((constructor)) static void RYGInstallDeveloperPersistenceBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            RYGScheduleDeveloperRestore();
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            RYGScheduleDeveloperRestore();
        }];
        RYGScheduleDeveloperRestore();
    });
    _dyld_register_func_for_add_image(RYGDeveloperPersistenceImageDidLoad);
}
