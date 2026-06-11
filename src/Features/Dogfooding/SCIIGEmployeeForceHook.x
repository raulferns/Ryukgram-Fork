// ============================================================================
// SCIIGEmployeeForceHook.x
// ============================================================================
//
// Hooks ObjC metadata-confirmed employee/internal BOOL getters. These getters
// drive internal badges / labels / debug overlays, not the dogfood/QE menus
// (those are gated by the MobileConfig C gate in SCIInternalUseGateHook.x).
//
// Hardening:
//   * RETRY: install at %ctor and again at +1s/+3s/+6s, because several of
//     these classes, especially Swift VCs, are not registered yet at load time.
//   * VERIFICATION: each attempt logs whether the class was found and whether
//     the hook installed, so we have evidence of what actually took effect.
//   * Swift name fallback: tries the plain ObjC name and common mangled forms.
//
// These are objc_msgSend-dispatched BOOL getters (B@:) so MSHookMessageEx is
// the correct primitive. Swift direct-dispatch properties would need a different
// approach.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"
#import "SCIEmployeeDefaults.h"

static NSString *const kSCIForceEmployeeKey = @"sci_force_ig_internal_employee";
static NSString *const kSCIForceIsEmployeeKey = @"sci_force_ig_is_employee";
static NSString *const kSCIForceFeaturedBadgeKey = @"sci_force_ig_featured_internal_badge";
static NSString *const kSCIForceInboxBadgeKey = @"sci_force_ig_inbox_internal_badge";
static NSString *const kSCIForceCreationLabelKey = @"sci_force_ig_creation_internal_label";
static NSString *const kSCIForceLaunchDebugKey = @"sci_force_ig_launch_debug_info";
static NSString *const kSCIForceLaunchDebugV2Key = @"sci_force_ig_launch_debug_info_v2";
static NSString *const kSCIForceStoryUnderlayKey = @"sci_force_ig_story_debug_underlay";

#define SCILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] " fmt, ##__VA_ARGS__)

static inline BOOL SCIForceGateOn(NSString *key) {
    return [SCIInternalGatePrefs objCGateEnabledForKey:kSCIForceEmployeeKey] ||
           [SCIInternalGatePrefs objCGateEnabledForKey:key];
}

#define SCI_BOOL_HOOK(NAME, KEY) \
    static BOOL (*orig_##NAME)(id, SEL) = NULL; \
    static BOOL new_##NAME(id self, SEL _cmd) { \
        if (SCIForceGateOn(KEY)) return YES; \
        return orig_##NAME ? orig_##NAME(self, _cmd) : NO; \
    }

SCI_BOOL_HOOK(isEmployee, kSCIForceIsEmployeeKey)
SCI_BOOL_HOOK(featuredBadge, kSCIForceFeaturedBadgeKey)
SCI_BOOL_HOOK(inboxBadge, kSCIForceInboxBadgeKey)
SCI_BOOL_HOOK(creationLabel, kSCIForceCreationLabelKey)
SCI_BOOL_HOOK(launchDebug, kSCIForceLaunchDebugKey)
SCI_BOOL_HOOK(launchDebugV2, kSCIForceLaunchDebugV2Key)
SCI_BOOL_HOOK(storyUnderlay, kSCIForceStoryUnderlayKey)

static Class SCIResolveClass(NSString *plain, NSArray<NSString *> *alts) {
    Class c = NSClassFromString(plain);
    if (c) return c;
    for (NSString *a in alts) {
        c = NSClassFromString(a);
        if (c) return c;
    }
    NSMutableArray<NSString *> *needles = [NSMutableArray array];
    if (plain.length) [needles addObject:plain];
    for (NSString *a in alts) {
        if (a.length) [needles addObject:a];
    }
    if (!needles.count) return Nil;

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return Nil;

    Class found = Nil;
    for (unsigned int i = 0; i < count && !found; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];
        for (NSString *needle in needles) {
            if ([className containsString:needle]) {
                found = classes[i];
                SCILOG("SCIResolveClass: found %{public}@ for %{public}@", className, needle);
                break;
            }
        }
    }
    free(classes);
    if (found) return found;
    return Nil;
}

static void SCIHookInstance(NSString *plain, NSArray<NSString *> *alts, SEL sel, IMP newImp, IMP *origOut) {
    if (*origOut) return;
    Class cls = SCIResolveClass(plain, alts);
    if (!cls) {
        SCILOG("instance %{public}@ %{public}s: class NOT FOUND", plain, sel_getName(sel));
        return;
    }
    if (!class_getInstanceMethod(cls, sel)) {
        SCILOG("instance %{public}@ %{public}s: selector missing", plain, sel_getName(sel));
        return;
    }
    MSHookMessageEx(cls, sel, newImp, origOut);
    SCILOG("instance %{public}@ %{public}s: %{public}s", plain, sel_getName(sel), (*origOut ? "HOOKED" : "FAILED"));
}

static void SCIHookClass(NSString *plain, NSArray<NSString *> *alts, SEL sel, IMP newImp, IMP *origOut) {
    if (*origOut) return;
    Class cls = SCIResolveClass(plain, alts);
    if (!cls) {
        SCILOG("class %{public}@ %{public}s: class NOT FOUND", plain, sel_getName(sel));
        return;
    }
    if (!class_getClassMethod(cls, sel)) {
        SCILOG("class %{public}@ %{public}s: selector missing", plain, sel_getName(sel));
        return;
    }
    MSHookMessageEx(object_getClass(cls), sel, newImp, origOut);
    SCILOG("class %{public}@ %{public}s: %{public}s", plain, sel_getName(sel), (*origOut ? "HOOKED" : "FAILED"));
}


static BOOL SCIAnyEmployeeForcePrefEnabled(void) {
    return SCIForceGateOn(@"sci_force_ig_internal_employee") ||
           SCIForceGateOn(@"sci_force_ig_is_employee") ||
           SCIForceGateOn(@"sci_force_employee_defaults_persist") ||
           SCIForceGateOn(@"sci_force_ig_featured_internal_badge") ||
           SCIForceGateOn(@"sci_force_ig_inbox_internal_badge") ||
           SCIForceGateOn(@"sci_force_ig_creation_internal_label") ||
           SCIForceGateOn(@"sci_force_ig_launch_debug_info") ||
           SCIForceGateOn(@"sci_force_ig_launch_debug_info_v2") ||
           SCIForceGateOn(@"sci_force_ig_story_debug_underlay");
}

static void SCIInstallAllGates(void) {
    SCIHookInstance(@"IGFacebookUserInfo", @[], @selector(isEmployee),
                    (IMP)new_isEmployee, (IMP *)&orig_isEmployee);
    SCIHookInstance(@"IGFeaturedUserInfo", @[], @selector(shouldShowInternalBadge),
                    (IMP)new_featuredBadge, (IMP *)&orig_featuredBadge);
    SCIHookInstance(@"IGDirectInboxThreadCellViewModel", @[], @selector(shouldShowInternalBadge),
                    (IMP)new_inboxBadge, (IMP *)&orig_inboxBadge);
    SCIHookInstance(@"IGCreationActionBarButton", @[], @selector(shouldShowInternalLabel),
                    (IMP)new_creationLabel, (IMP *)&orig_creationLabel);
    SCIHookInstance(@"IGLaunchHorizonViewController", @[], @selector(shouldShowDebugInfo),
                    (IMP)new_launchDebug, (IMP *)&orig_launchDebug);
    SCIHookInstance(@"LaunchHorizonViewControllerV2",
                    @[@"_TtC16IGLaunchHorizon30LaunchHorizonViewControllerV2"],
                    @selector(shouldShowDebugInfo),
                    (IMP)new_launchDebugV2, (IMP *)&orig_launchDebugV2);
    SCIHookClass(@"_TtC20IGStoryDebugUnderlay37IGStoryOpaqueDebugUnderlayViewFactory",
                 @[@"IGStoryDebugUnderlay.IGStoryOpaqueDebugUnderlayViewFactory"],
                 @selector(shouldShowDebugUnderlay),
                 (IMP)new_storyUnderlay, (IMP *)&orig_storyUnderlay);
}

void SCIInstallIGEmployeeForceHooksIfNeeded(void) {
    if (!SCIAnyEmployeeForcePrefEnabled()) return;
    [SCIInternalGatePrefs installCrashGuardIfNeeded];
    [SCIEmployeeDefaults installHooksIfNeeded];
    SCIInstallAllGates();
}

%ctor {
    @autoreleasepool {
        SCIInstallIGEmployeeForceHooksIfNeeded();
    }
}
