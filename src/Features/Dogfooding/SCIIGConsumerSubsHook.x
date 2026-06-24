// ============================================================================
// SCIIGConsumerSubsHook.x  —  Instagram Plus (IGPlus) client benefit unlock
// ============================================================================
// IGConsumerSubsService is the single client source-of-truth the feature code
// asks "is benefit X enabled?". Each getter is a plain @objc BOOL (B@:), so
// MSHookMessageEx is the correct primitive. Forcing these makes the app behave
// as a subscriber for everything the client renders/decides LOCALLY. The server
// eligibility QUERY stays server-side; features read THESE getters.
//
// ONLY LIVE getters are hooked here. Each was verified against the shipping
// binary to (a) be a real instance method of the class AND (b) have an
// __objc_selref — i.e. there is a real objc_msgSend call site. Getters without
// a selref are reached only by Swift direct-dispatch (vtable), which a swizzle
// cannot intercept, so hooking them does nothing. Those dead getters were
// REMOVED to stop giving a false "applied" impression:
//   hasAccessToIGPlus, isStoryPeeksBenefitEnabled, isStorySpotlightBenefitEnabled,
//   isDirectMessagePeekBenefitEnabled, isCustomAppIconBenefitEnabled,
//   isBrandedThreadsBenefitEnabled, isTimestampViewersListBenefitEnabled,
//   isBenefitActive:
// (Note: the app likely gates the IG+ surface on hasAnyActiveBenefit — which IS
//  live and kept — rather than the dead hasAccessToIGPlus.)
//
// TIMING: one known class + StoryPeek coordinator, installed once on
// UIApplicationDidBecomeActive (see SCIInstallOnce.h). No %ctor hooking (avoids
// the static-init race), no dispatch_after retry ladder, no class enumeration.
// Gated on the master pref so users who never enable IG+ are not swizzled; the
// settings row is requiresRestart:YES, so first-enable applies on relaunch.
//
// Each getter is gated by its own pref OR the master `sci_force_igplus_all`.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"
#import "SCIInstallOnce.h"

#define SCILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] IGPlus " fmt, ##__VA_ARGS__)
static NSString *const kMaster = @"sci_force_igplus_all";
static inline BOOL ON(NSString *k){ return [SCIInternalGatePrefs individualGateEnabledForKey:kMaster] || [SCIInternalGatePrefs individualGateEnabledForKey:k]; }

// LIVE no-arg BOOL getters only (method + objc_msgSend selref verified). The key
// array is index-aligned with the selector array below.
static NSArray<NSString *> *benefitKeys(void){ return @[
    @"sci_igplus_any_active",
    @"sci_igplus_custom_lists", @"sci_igplus_story_superlikes", @"sci_igplus_search_story_viewers",
    @"sci_igplus_story_extend", @"sci_igplus_story_rewatch", @"sci_igplus_silent_post_highlights",
    @"sci_igplus_custom_bio_font", @"sci_igplus_silent_post_profile", @"sci_igplus_pinned_posts_limit" ]; }

static const char *benefitSels[] = {
    "hasAnyActiveBenefit",
    "isCustomListsBenefitEnabled", "isStorySuperlikesBenefitEnabled", "isSearchStoryViewersBenefitEnabled",
    "isStoryExtendBenefitEnabled", "isStoryRewatchBenefitEnabled", "isSilentPostToHighlightsBenefitEnabled",
    "isCustomBioFontInProfileBenefitEnabled", "isSilentPostToProfileBenefitEnabled", "isPinnedPostsIncreasedLimitEnabled",
    NULL };

#define MAXH 24
static IMP   gOrig[MAXH];
static SEL   gSel[MAXH];
static NSString *gKey[MAXH];
static int   gN = 0;
static NSMutableSet<NSString *> *gDone;

static void hookGetter(Class cls, SEL sel, NSString *prefKey) {
    if (gN>=MAXH || !cls || !sel || !class_getInstanceMethod(cls, sel)) return;
    NSString *tag=[NSString stringWithFormat:@"%s#%s",class_getName(cls),sel_getName(sel)];
    if ([gDone containsObject:tag]) return;
    int idx=gN++; gSel[idx]=sel; gKey[idx]=prefKey;
    IMP newImp=imp_implementationWithBlock(^BOOL(id self){
        if (ON(gKey[idx])) return YES;
        BOOL(*o)(id,SEL)=(BOOL(*)(id,SEL))gOrig[idx];
        return o?o(self,gSel[idx]):NO;
    });
    IMP orig=NULL; MSHookMessageEx(cls,sel,newImp,&orig); gOrig[idx]=orig;
    [gDone addObject:tag]; SCILOG("%{public}@: %{public}s", tag, orig?"HOOKED":"FAILED");
}

static void install(void) {
    if (!gDone) gDone=[NSMutableSet set];
    Class svc = NSClassFromString(@"IGConsumerSubsService") ?: NSClassFromString(@"_TtC21IGConsumerSubsService21IGConsumerSubsService");
    if (svc) {
        NSArray<NSString *> *keys = benefitKeys();
        for (int i=0; benefitSels[i]; i++)
            hookGetter(svc, NSSelectorFromString(@(benefitSels[i])), keys[i]);
    } else {
        SCILOG("IGConsumerSubsService not loaded yet");
    }
    // StoryPeek coordinator: isPeekActive is a real, live (selref) method on this
    // separate class — kept.
    Class peek = NSClassFromString(@"_TtC23IGConsumerSubsStoryPeek34IGConsumerSubsStoryPeekCoordinator");
    if (peek) hookGetter(peek, NSSelectorFromString(@"isPeekActive"), @"sci_igplus_story_peek_active");
}

%ctor {
    @autoreleasepool {
        if (![SCIInternalGatePrefs individualGateEnabledForKey:kMaster]) return;
        // On-active only: the Swift classes are realized by the time the UI is up,
        // and we avoid hooking during dyld static-init. Idempotent (gDone guard).
        SCIInstallOnceOnActive(^{
            [SCIInternalGatePrefs installCrashGuardIfNeeded];
            install();
        });
    }
}
