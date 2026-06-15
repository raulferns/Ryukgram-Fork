// SCIIGPlusUnlock.x — Instagram Plus (IGPlus) unlock.
//
// Authoritative binary analysis (Instagram 433, decrypted, full Swift metadata,
// cross-checked with otool -Iv + capstone): the whole IGPlus gate surface is
// @objc on one Swift class, every getter `B16@0:8` (BOOL, no args), so it is
// hookable exactly as baseline §4 prescribes — MSHookMessageEx on the runtime-
// resolved Swift class, one orig per selector, ABI-compatible replacement,
// install gated by a cheap pref in %ctor. Keys match the existing Dev submenu.
//
//   _TtC21IGConsumerSubsService21IGConsumerSubsService
//       hasAccessToIGPlus, hasAnyActiveBenefit, + 15 is*BenefitEnabled getters
//   _TtC23IGConsumerSubsStoryPeek34IGConsumerSubsStoryPeekCoordinator
//       isPeekActive
//
// FBSharedFramework carries no IGPlus/ConsumerSubs classes; gate is in the exec.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

static NSString *const kIGPlusAll = @"sci_force_igplus_all";
static NSString *const kIGPlusElig = @"sci_igplus_eligibility";

// Forced when the master is on OR this benefit's own switch is on. Read live so
// toggling in the submenu is immediate once the group is installed.
static inline BOOL SCIIGPlusOn(NSString *key) {
	return [SCIUtils getBoolPref:kIGPlusAll] || [SCIUtils getBoolPref:key];
}
// Access/eligibility getters also honor the "eligibility/data-provider" switch.
static inline BOOL SCIIGPlusElig(NSString *key) {
	return SCIIGPlusOn(key) || [SCIUtils getBoolPref:kIGPlusElig];
}

// Instrumentation: prove whether these @objc getters are actually dispatched
// through objc_msgSend. If this counter stays 0 after exercising IGPlus screens,
// the gating runs through Swift direct/vtable dispatch and MSHookMessageEx is
// bypassed — which means forcing the @objc entry cannot unlock the feature and a
// different strategy (Swift function patch / eligibility-helper hook) is required.
#import <os/log.h>
#import <objc/runtime.h>
#include <stdatomic.h>
static atomic_int g_igplus_hits = 0;

// The macro now wraps every hook body in real_##fn and routes calls through a thin
// hook_##fn that ticks the counter + os_logs the first hit per getter, then runs
// the original body unchanged.
#define IGPLUS_HOOK(fn) \
	static BOOL (*orig_##fn)(id, SEL) = NULL; \
	static BOOL real_##fn(id self, SEL _cmd); \
	static BOOL hook_##fn(id self, SEL _cmd) { \
		if (atomic_fetch_add_explicit(&g_igplus_hits, 1, memory_order_relaxed) == 0) \
			os_log(OS_LOG_DEFAULT, "[SCI] IGPlus @objc getter dispatched via objc_msgSend (first hit): %{public}s", sel_getName(_cmd)); \
		return real_##fn(self, _cmd); \
	} \
	static BOOL real_##fn(id self, SEL _cmd)

IGPLUS_HOOK(hasAccessToIGPlus)                  { return SCIIGPlusElig(@"sci_igplus_has_access") ? YES : (orig_hasAccessToIGPlus ? orig_hasAccessToIGPlus(self,_cmd) : NO); }
IGPLUS_HOOK(hasAnyActiveBenefit)               { return SCIIGPlusElig(@"sci_igplus_any_active") ? YES : (orig_hasAnyActiveBenefit ? orig_hasAnyActiveBenefit(self,_cmd) : NO); }
IGPLUS_HOOK(isCustomListsBenefitEnabled)       { return SCIIGPlusOn(@"sci_igplus_custom_lists") ? YES : (orig_isCustomListsBenefitEnabled ? orig_isCustomListsBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isStorySuperlikesBenefitEnabled)   { return SCIIGPlusOn(@"sci_igplus_story_superlikes") ? YES : (orig_isStorySuperlikesBenefitEnabled ? orig_isStorySuperlikesBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isSearchStoryViewersBenefitEnabled){ return SCIIGPlusOn(@"sci_igplus_search_story_viewers") ? YES : (orig_isSearchStoryViewersBenefitEnabled ? orig_isSearchStoryViewersBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isStoryExtendBenefitEnabled)       { return SCIIGPlusOn(@"sci_igplus_story_extend") ? YES : (orig_isStoryExtendBenefitEnabled ? orig_isStoryExtendBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isStoryRewatchBenefitEnabled)      { return SCIIGPlusOn(@"sci_igplus_story_rewatch") ? YES : (orig_isStoryRewatchBenefitEnabled ? orig_isStoryRewatchBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isStoryPeeksBenefitEnabled)        { return SCIIGPlusOn(@"sci_igplus_story_peeks") ? YES : (orig_isStoryPeeksBenefitEnabled ? orig_isStoryPeeksBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isStorySpotlightBenefitEnabled)    { return SCIIGPlusOn(@"sci_igplus_story_spotlight") ? YES : (orig_isStorySpotlightBenefitEnabled ? orig_isStorySpotlightBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isSilentPostToHighlightsBenefitEnabled) { return SCIIGPlusOn(@"sci_igplus_silent_post_highlights") ? YES : (orig_isSilentPostToHighlightsBenefitEnabled ? orig_isSilentPostToHighlightsBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isDirectMessagePeekBenefitEnabled) { return SCIIGPlusOn(@"sci_igplus_dm_peek") ? YES : (orig_isDirectMessagePeekBenefitEnabled ? orig_isDirectMessagePeekBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isCustomAppIconBenefitEnabled)     { return SCIIGPlusOn(@"sci_igplus_custom_app_icon") ? YES : (orig_isCustomAppIconBenefitEnabled ? orig_isCustomAppIconBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isBrandedThreadsBenefitEnabled)    { return SCIIGPlusOn(@"sci_igplus_branded_threads") ? YES : (orig_isBrandedThreadsBenefitEnabled ? orig_isBrandedThreadsBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isTimestampViewersListBenefitEnabled) { return SCIIGPlusOn(@"sci_igplus_timestamp_viewers") ? YES : (orig_isTimestampViewersListBenefitEnabled ? orig_isTimestampViewersListBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isCustomBioFontInProfileBenefitEnabled) { return SCIIGPlusOn(@"sci_igplus_custom_bio_font") ? YES : (orig_isCustomBioFontInProfileBenefitEnabled ? orig_isCustomBioFontInProfileBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isSilentPostToProfileBenefitEnabled) { return SCIIGPlusOn(@"sci_igplus_silent_post_profile") ? YES : (orig_isSilentPostToProfileBenefitEnabled ? orig_isSilentPostToProfileBenefitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isPinnedPostsIncreasedLimitEnabled){ return SCIIGPlusOn(@"sci_igplus_pinned_posts_limit") ? YES : (orig_isPinnedPostsIncreasedLimitEnabled ? orig_isPinnedPostsIncreasedLimitEnabled(self,_cmd) : NO); }
IGPLUS_HOOK(isPeekActive)                      { return SCIIGPlusElig(@"sci_igplus_story_peek_active") ? YES : (orig_isPeekActive ? orig_isPeekActive(self,_cmd) : NO); }

static void SCIHook(Class cls, NSString *sel, IMP repl, IMP *orig) {
	if (!cls) return;
	SEL s = NSSelectorFromString(sel);
	if (!class_getInstanceMethod(cls, s)) return;
	MSHookMessageEx(cls, s, repl, orig);
}

static void SCIInstallIGPlusHooks(void) {
	Class svc = objc_getClass("_TtC21IGConsumerSubsService21IGConsumerSubsService");
	SCIHook(svc, @"hasAccessToIGPlus",                  (IMP)hook_hasAccessToIGPlus,                  (IMP *)&orig_hasAccessToIGPlus);
	SCIHook(svc, @"hasAnyActiveBenefit",                (IMP)hook_hasAnyActiveBenefit,                (IMP *)&orig_hasAnyActiveBenefit);
	SCIHook(svc, @"isCustomListsBenefitEnabled",        (IMP)hook_isCustomListsBenefitEnabled,        (IMP *)&orig_isCustomListsBenefitEnabled);
	SCIHook(svc, @"isStorySuperlikesBenefitEnabled",    (IMP)hook_isStorySuperlikesBenefitEnabled,    (IMP *)&orig_isStorySuperlikesBenefitEnabled);
	SCIHook(svc, @"isSearchStoryViewersBenefitEnabled", (IMP)hook_isSearchStoryViewersBenefitEnabled, (IMP *)&orig_isSearchStoryViewersBenefitEnabled);
	SCIHook(svc, @"isStoryExtendBenefitEnabled",        (IMP)hook_isStoryExtendBenefitEnabled,        (IMP *)&orig_isStoryExtendBenefitEnabled);
	SCIHook(svc, @"isStoryRewatchBenefitEnabled",       (IMP)hook_isStoryRewatchBenefitEnabled,       (IMP *)&orig_isStoryRewatchBenefitEnabled);
	SCIHook(svc, @"isStoryPeeksBenefitEnabled",         (IMP)hook_isStoryPeeksBenefitEnabled,         (IMP *)&orig_isStoryPeeksBenefitEnabled);
	SCIHook(svc, @"isStorySpotlightBenefitEnabled",     (IMP)hook_isStorySpotlightBenefitEnabled,     (IMP *)&orig_isStorySpotlightBenefitEnabled);
	SCIHook(svc, @"isSilentPostToHighlightsBenefitEnabled", (IMP)hook_isSilentPostToHighlightsBenefitEnabled, (IMP *)&orig_isSilentPostToHighlightsBenefitEnabled);
	SCIHook(svc, @"isDirectMessagePeekBenefitEnabled",  (IMP)hook_isDirectMessagePeekBenefitEnabled,  (IMP *)&orig_isDirectMessagePeekBenefitEnabled);
	SCIHook(svc, @"isCustomAppIconBenefitEnabled",      (IMP)hook_isCustomAppIconBenefitEnabled,      (IMP *)&orig_isCustomAppIconBenefitEnabled);
	SCIHook(svc, @"isBrandedThreadsBenefitEnabled",     (IMP)hook_isBrandedThreadsBenefitEnabled,     (IMP *)&orig_isBrandedThreadsBenefitEnabled);
	SCIHook(svc, @"isTimestampViewersListBenefitEnabled", (IMP)hook_isTimestampViewersListBenefitEnabled, (IMP *)&orig_isTimestampViewersListBenefitEnabled);
	SCIHook(svc, @"isCustomBioFontInProfileBenefitEnabled", (IMP)hook_isCustomBioFontInProfileBenefitEnabled, (IMP *)&orig_isCustomBioFontInProfileBenefitEnabled);
	SCIHook(svc, @"isSilentPostToProfileBenefitEnabled", (IMP)hook_isSilentPostToProfileBenefitEnabled, (IMP *)&orig_isSilentPostToProfileBenefitEnabled);
	SCIHook(svc, @"isPinnedPostsIncreasedLimitEnabled", (IMP)hook_isPinnedPostsIncreasedLimitEnabled, (IMP *)&orig_isPinnedPostsIncreasedLimitEnabled);

	Class peek = objc_getClass("_TtC23IGConsumerSubsStoryPeek34IGConsumerSubsStoryPeekCoordinator");
	SCIHook(peek, @"isPeekActive", (IMP)hook_isPeekActive, (IMP *)&orig_isPeekActive);
}

static BOOL SCIAnyIGPlusOn(void) {
	for (NSString *k in @[kIGPlusAll, kIGPlusElig, @"sci_igplus_has_access", @"sci_igplus_any_active",
			@"sci_igplus_custom_lists", @"sci_igplus_story_superlikes", @"sci_igplus_search_story_viewers",
			@"sci_igplus_story_extend", @"sci_igplus_story_rewatch", @"sci_igplus_story_peeks",
			@"sci_igplus_story_spotlight", @"sci_igplus_silent_post_highlights", @"sci_igplus_dm_peek",
			@"sci_igplus_custom_app_icon", @"sci_igplus_branded_threads", @"sci_igplus_timestamp_viewers",
			@"sci_igplus_custom_bio_font", @"sci_igplus_silent_post_profile", @"sci_igplus_pinned_posts_limit",
			@"sci_igplus_story_peek_active"]) {
		if ([SCIUtils getBoolPref:k]) return YES;
	}
	return NO;
}

%ctor {
	@autoreleasepool {
		if (!SCIAnyIGPlusOn()) return;
		SCIInstallIGPlusHooks();
	}
}
