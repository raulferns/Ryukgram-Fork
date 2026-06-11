// ============================================================================
// SCIIGConsumerSubsHook.x
// ============================================================================
// Instagram Plus (IGPlus) CLIENT benefit unlock.
//
// IGConsumerSubsService is the single client source-of-truth the feature code
// asks "is benefit X enabled?". Every getter is a plain @objc BOOL (B@:), so
// MSHookMessageEx is the correct, reliable primitive (confirmed via FLEX:
// "runtime hook: forced TRUE"). Forcing these makes the app behave as a
// subscriber for everything the client renders/decides locally. The server
// eligibility QUERY stays server-side, but features read THESE getters.
//
// TIMING: one known class, ~20 selectors, installed once after
// UIApplicationDidBecomeActive. No blind dispatch_after retry ladder, no class
// enumeration, no main-thread scanning -> no launch slowness.
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

// selector <-> pref table (no-arg BOOL getters)
typedef struct { const char *sel; NSString *key; } SCIBenefit;
static NSArray<NSString *> *benefitKeys(void){ return @[
    @"sci_igplus_has_access", @"sci_igplus_any_active",
    @"sci_igplus_custom_lists", @"sci_igplus_story_superlikes", @"sci_igplus_search_story_viewers",
    @"sci_igplus_story_extend", @"sci_igplus_story_rewatch", @"sci_igplus_story_peeks",
    @"sci_igplus_story_spotlight", @"sci_igplus_silent_post_highlights", @"sci_igplus_dm_peek",
    @"sci_igplus_custom_app_icon", @"sci_igplus_branded_threads", @"sci_igplus_timestamp_viewers",
    @"sci_igplus_custom_bio_font", @"sci_igplus_silent_post_profile", @"sci_igplus_pinned_posts_limit",
    @"sci_igplus_story_peek_active" ]; }

static const char *benefitSels[] = {
    "hasAccessToIGPlus", "hasAnyActiveBenefit",
    "isCustomListsBenefitEnabled", "isStorySuperlikesBenefitEnabled", "isSearchStoryViewersBenefitEnabled",
    "isStoryExtendBenefitEnabled", "isStoryRewatchBenefitEnabled", "isStoryPeeksBenefitEnabled",
    "isStorySpotlightBenefitEnabled", "isSilentPostToHighlightsBenefitEnabled", "isDirectMessagePeekBenefitEnabled",
    "isCustomAppIconBenefitEnabled", "isBrandedThreadsBenefitEnabled", "isTimestampViewersListBenefitEnabled",
    "isCustomBioFontInProfileBenefitEnabled", "isSilentPostToProfileBenefitEnabled", "isPinnedPostsIncreasedLimitEnabled",
    NULL };

#define MAXH 40
static IMP   gOrig[MAXH];
static SEL   gSel[MAXH];
static NSString *gKey[MAXH];
static int   gN = 0;
static IMP   gOrigActive; static SEL gSelActive;
static NSMutableSet<NSString *> *gDone;

static void hookGetter(Class cls, SEL sel, NSString *prefKey) {
    if (gN>=MAXH || !cls || !class_getInstanceMethod(cls, sel)) return;
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

static void hookIsBenefitActive(Class cls) {
    SEL sel=NSSelectorFromString(@"isBenefitActive:");
    if (gOrigActive || !cls || !class_getInstanceMethod(cls, sel)) return;
    gSelActive=sel;
    IMP newImp=imp_implementationWithBlock(^BOOL(id self, id benefit){
        if (ON(@"sci_igplus_any_active")) return YES;
        BOOL(*o)(id,SEL,id)=(BOOL(*)(id,SEL,id))gOrigActive;
        return o?o(self,gSelActive,benefit):NO;
    });
    MSHookMessageEx(cls,sel,newImp,&gOrigActive);
    SCILOG("isBenefitActive: %{public}s", gOrigActive?"HOOKED":"FAILED");
}


static BOOL SCIAnyIGPlusPrefEnabled(void) {
    if ([SCIInternalGatePrefs individualGateEnabledForKey:kMaster]) return YES;
    for (NSString *key in benefitKeys()) {
        if ([SCIInternalGatePrefs individualGateEnabledForKey:key]) return YES;
    }
    return NO;
}

static void install(void) {
    if (!gDone) gDone=[NSMutableSet set];
    Class svc = NSClassFromString(@"IGConsumerSubsService");
    if (!svc) svc = NSClassFromString(@"_TtC21IGConsumerSubsService21IGConsumerSubsService");
    if (svc) {
        NSArray<NSString *> *keys = benefitKeys();
        for (int i=0; benefitSels[i]; i++)
            hookGetter(svc, NSSelectorFromString(@(benefitSels[i])), keys[i]);
        hookIsBenefitActive(svc);
    } else {
        SCILOG("IGConsumerSubsService not loaded yet");
    }
    // StoryPeek coordinator (isPeekActive)
    Class peek = NSClassFromString(@"_TtC23IGConsumerSubsStoryPeek34IGConsumerSubsStoryPeekCoordinator");
    if (peek) hookGetter(peek, NSSelectorFromString(@"isPeekActive"), @"sci_igplus_story_peek_active");
}

%ctor {
    @autoreleasepool {
        if (!SCIAnyIGPlusPrefEnabled()) return;
        [SCIInternalGatePrefs installCrashGuardIfNeeded];
        // SCI-FIX 2026-06-11: single deterministic install at DidBecomeActive,
        // replacing static-init install() + 1s/3s/6s dispatch_after ladder.
        SCIInstallOnceOnActive(^{ install(); });
    }
}
