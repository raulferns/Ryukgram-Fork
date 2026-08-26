#import "RYGDeveloperTopicViewController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
#include <string.h>

// Exact Developer controls must own their hooks independently of discovery UI.
// Revalidate only the selectors proven in the current Instagram/FBShared build.

static NSString *const kPrismPref = @"ryg_dev_prism_setter_mode";
static NSString *const kRedesignPref = @"ryg_dev_redesign_setter_mode";
static NSString *const kGlassSwizzlePref = @"ryg_dev_glass_swizzle_enabled";
static NSString *const kGlassThrowbackPref = @"ryg_dev_glass_throwback_enabled";
static NSString *const kGlassNavigationPref = @"ryg_dev_glass_navigation_enabled";

static IMP gPrismUpstream;
static IMP gRedesignUpstream;
static atomic_uint_fast64_t gDeveloperReassertGeneration = 0;

static const char *RYGDevOwnerSkip(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGDevOwnerSetterABI(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char ret[32] = {0}, arg[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    method_getArgumentType(method, 2, arg, sizeof(arg));
    const char *r = RYGDevOwnerSkip(ret), *a = RYGDevOwnerSkip(arg);
    return r && *r == 'v' && a && strchr("BcC", *a) != NULL;
}

static BOOL RYGDevOwnerIMPIsOurs(IMP imp) {
    if (!imp) return NO;
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return NO;
    NSString *leaf = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent].lowercaseString ?: @"";
    return [leaf containsString:@"ryukgram"];
}

static NSInteger RYGDevOwnerMode(NSString *key) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [raw isKindOfClass:NSNumber.class] ? [raw integerValue] : -1;
}

static void RYGDevOwnerPrism(id self, SEL cmd, BOOL enabled) {
    NSInteger mode = RYGDevOwnerMode(kPrismPref);
    BOOL output = mode < 0 ? enabled : mode != 0;
    if (gPrismUpstream) ((void (*)(id,SEL,BOOL))gPrismUpstream)(self,cmd,output);
}

static void RYGDevOwnerRedesign(id self, SEL cmd, BOOL enabled) {
    NSInteger mode = RYGDevOwnerMode(kRedesignPref);
    BOOL output = mode < 0 ? enabled : mode != 0;
    if (gRedesignUpstream) ((void (*)(id,SEL,BOOL))gRedesignUpstream)(self,cmd,output);
}

static BOOL RYGDevOwnerInstallSetter(const char *className, const char *selectorName, IMP replacement, IMP *upstream) {
    Class cls = objc_lookUpClass(className);
    SEL selector = sel_registerName(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!RYGDevOwnerSetterABI(method)) return NO;
    IMP current = method_getImplementation(method);
    if (current == replacement) return YES;
    if (!current) return NO;

    // If another current RyukGram owner is still installed, it already owns the
    // exact selector.  Do not create a wrapper chain.  If Instagram replaced it,
    // current points outside RyukGram and becomes the new upstream.
    if (RYGDevOwnerIMPIsOurs(current)) return YES;
    *upstream = current;
    (void)method_setImplementation(method, replacement);
    return method_getImplementation(method) == replacement;
}

static id RYGDevOwnerShared(const char *className) {
    Class cls = objc_lookUpClass(className);
    SEL selector = sel_registerName("shared");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char ret[16] = {0}; method_getReturnType(method, ret, sizeof(ret));
    const char *r = RYGDevOwnerSkip(ret);
    return r && *r == '@' ? ((id (*)(id,SEL))objc_msgSend)((id)cls,selector) : nil;
}

static void RYGDevOwnerApplyHelperPref(NSString *pref, const char *className, const char *selectorName) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:pref];
    if (![raw isKindOfClass:NSNumber.class]) return;
    id helper = RYGDevOwnerShared(className);
    SEL selector = sel_registerName(selectorName);
    Method method = helper ? class_getInstanceMethod([helper class], selector) : NULL;
    if (!RYGDevOwnerSetterABI(method)) return;
    ((void (*)(id,SEL,BOOL))objc_msgSend)(helper,selector,[raw boolValue]);
}

static void RYGDevOwnerReassert(void) {
    @autoreleasepool {
        if (RYGDevOwnerMode(kPrismPref) >= 0)
            (void)RYGDevOwnerInstallSetter("IGBloksFollowButtonView", "setPrismEnabled:", (IMP)RYGDevOwnerPrism, &gPrismUpstream);
        if (RYGDevOwnerMode(kRedesignPref) >= 0)
            (void)RYGDevOwnerInstallSetter("IGTableViewCell", "setListRedesignOn:", (IMP)RYGDevOwnerRedesign, &gRedesignUpstream);

        RYGDevOwnerApplyHelperPref(kGlassSwizzlePref, "_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle", "setIsEnabled:");
        RYGDevOwnerApplyHelperPref(kGlassThrowbackPref, "_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper", "overrideIsEnabled:");
        RYGDevOwnerApplyHelperPref(kGlassNavigationPref, "_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper", "overrideIsEnabled:");

        // Existing DeveloperTopic owns the exact BugReport/Dogfood capture ABIs.
        // Calling its bounded activation again is cheap and lets it install once
        // those classes have actually loaded; it never prepares MobileConfig.
        [RYGDeveloperTopicViewController activatePersistedNativeFeatures];
    }
}

static dispatch_queue_t RYGDeveloperReassertQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.developer-exact-reassert", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static BOOL RYGDeveloperHasPersistedState(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:kPrismPref] || [d objectForKey:kRedesignPref] ||
           [d objectForKey:kGlassSwizzlePref] || [d objectForKey:kGlassThrowbackPref] ||
           [d objectForKey:kGlassNavigationPref] ||
           [d boolForKey:@"ryg_dev_internal_menu_enabled"] || [d boolForKey:@"ryg_dev_dogfood_mode_enabled"] ||
           [d dictionaryForKey:@"ryg_easy_gating_platform_bool_overrides_v2"].count > 0;
}

static void RYGScheduleDeveloperReassert(NSTimeInterval delay) {
    if (!RYGDeveloperHasPersistedState()) return;
    uint64_t generation = atomic_fetch_add_explicit(&gDeveloperReassertGeneration, 1, memory_order_acq_rel) + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), RYGDeveloperReassertQueue(), ^{
        if (generation != atomic_load_explicit(&gDeveloperReassertGeneration, memory_order_acquire)) return;
        RYGDevOwnerReassert();
    });
}

__attribute__((constructor(225))) static void RYGInstallDeveloperSetterOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            RYGScheduleDeveloperReassert(0.25);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            RYGScheduleDeveloperReassert(0.35);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            RYGScheduleDeveloperReassert(0.05);
        }];
    });
}
