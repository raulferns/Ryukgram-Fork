// SCIIGPlusEligibilityHooks.x — aggressive IGPlus unlock via the eligibility
// HELPERS, not the service getters.
//
// Why this exists (binary-proven, Instagram 433):
//   The IGPlus benefit getters live on _TtC21IGConsumerSubsService and are @objc
//   B16@0:8, but Instagram evaluates gating through Swift direct/vtable dispatch,
//   so MSHookMessageEx on the service is frequently BYPASSED (the g_igplus_hits
//   counter in SCIIGPlusUnlock.x stays 0 on those paths). That is why forcing the
//   service getters alone does not unlock the features.
//
//   The real decision points are the static eligibility helpers that take the
//   consumerSubsService as a PARAMETER. These are @objc class methods, validated
//   in the binary with their exact signatures. Forcing THESE to YES flips the
//   actual gate the surfaces consult:
//
//     +[IGProfileGatingService isAuraQuietPostingEnabledWithConsumerSubsService:]                         B24@0:8@16
//     +[IGConsumerSubsUpsellAlertHelper shouldShowViewerListUpsellButtonWithConsumerSubsService:launcherSet:] B32@0:8@16@24
//     +[IGConsumerSubsPinnedPostsUpsellHelperObjC isUpsellEligibleWithConsumerSubsService:launcherSet:sessionUserDefaults:]         B40@0:8@16@24@32
//     +[IGConsumerSubsPinnedPostsUpsellHelperObjC isOverflowPostMenuUpsellEligibleWithConsumerSubsService:launcherSet:sessionUserDefaults:] B40@0:8@16@24@32
//     +[IGStoryViewersListExperimentHelpers isViewersListMetricRedesignEnabledWithConsumerSubsService:]   B24@0:8@16
//     +[IGConsumerSubsDirectChatPeekEligibility isChatPeekFeatureEligibleWithLauncherSet:consumerSubsService:] B32@0:8@16@24
//     +[IGConsumerSubsDirectChatPeekEligibility isUpsellEligibleWithLauncherSet:consumerSubsService:]      B32@0:8@16@24
//
//   These are CLASS methods, so MSHookMessageEx on the metaclass intercepts every
//   objc_msgSend dispatch to them. Combined with the MobileConfig reader forcing
//   in SCICSymbolEngine (IG_PLUS_AVAILABLE / AURA_* params), this is the
//   aggressive two-pronged unlock baseline §4 allows for class-method gates.
//
// Timing/persistence: install gated by a cheap pref in %ctor; one orig per
// selector; ABI-compatible replacements; classes resolved at install time.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <os/log.h>
#import <stdatomic.h>

static NSString *const kIGPlusAll  = @"sci_force_igplus_all";
static NSString *const kIGPlusElig = @"sci_igplus_eligibility";
static NSString *const kIGPlusHelpers = @"sci_igplus_force_eligibility_helpers";

// Master for this file: the dedicated helpers switch, the IGPlus master, or the
// eligibility switch all enable it.
static inline BOOL SCIHelpersOn(void) {
	return [SCIUtils getBoolPref:kIGPlusHelpers]
		|| [SCIUtils getBoolPref:kIGPlusAll]
		|| [SCIUtils getBoolPref:kIGPlusElig];
}

static atomic_int g_helper_hits = 0;
static void tick(const char *what, SEL _cmd) {
	if (atomic_fetch_add_explicit(&g_helper_hits, 1, memory_order_relaxed) == 0)
		os_log(OS_LOG_DEFAULT, "[SCI] IGPlus eligibility helper dispatched: %{public}s %{public}s",
			what, sel_getName(_cmd));
}

// ── B24@0:8@16  (self, _cmd, service) ──────────────────────────────────────
#define HELPER_1ARG(fn) \
	static BOOL (*orig_##fn)(id,SEL,id) = NULL; \
	static BOOL hook_##fn(id self, SEL _cmd, id service) { \
		tick(#fn, _cmd); \
		if (SCIHelpersOn()) return YES; \
		return orig_##fn ? orig_##fn(self,_cmd,service) : NO; \
	}

// ── B32@0:8@16@24  (self, _cmd, a, b) ──────────────────────────────────────
#define HELPER_2ARG(fn) \
	static BOOL (*orig_##fn)(id,SEL,id,id) = NULL; \
	static BOOL hook_##fn(id self, SEL _cmd, id a, id b) { \
		tick(#fn, _cmd); \
		if (SCIHelpersOn()) return YES; \
		return orig_##fn ? orig_##fn(self,_cmd,a,b) : NO; \
	}

// ── B40@0:8@16@24@32  (self, _cmd, a, b, c) ────────────────────────────────
#define HELPER_3ARG(fn) \
	static BOOL (*orig_##fn)(id,SEL,id,id,id) = NULL; \
	static BOOL hook_##fn(id self, SEL _cmd, id a, id b, id c) { \
		tick(#fn, _cmd); \
		if (SCIHelpersOn()) return YES; \
		return orig_##fn ? orig_##fn(self,_cmd,a,b,c) : NO; \
	}

HELPER_1ARG(isAuraQuietPostingEnabled)
HELPER_1ARG(isViewersListMetricRedesignEnabled)
HELPER_2ARG(shouldShowViewerListUpsellButton)
HELPER_2ARG(isChatPeekFeatureEligible)
HELPER_2ARG(isUpsellEligibleLauncherFirst)
HELPER_3ARG(isUpsellEligibleServiceFirst)
HELPER_3ARG(isOverflowPostMenuUpsellEligible)

static void HookClassMethod(const char *clsName, NSString *sel, IMP repl, IMP *orig) {
	Class cls = objc_getClass(clsName);
	if (!cls) return;
	SEL s = NSSelectorFromString(sel);
	// class method → operate on the metaclass
	Class meta = object_getClass((id)cls);
	if (!class_getInstanceMethod(meta, s)) return;
	MSHookMessageEx(meta, s, repl, orig);
}

%ctor {
	@autoreleasepool {
		if (!SCIHelpersOn()) return;

		HookClassMethod("_TtC22IGProfileGatingService22IGProfileGatingService",
			@"isAuraQuietPostingEnabledWithConsumerSubsService:",
			(IMP)hook_isAuraQuietPostingEnabled, (IMP *)&orig_isAuraQuietPostingEnabled);

		HookClassMethod("_TtC20IGStoryOverviewSwift35IGStoryViewersListExperimentHelpers",
			@"isViewersListMetricRedesignEnabledWithConsumerSubsService:",
			(IMP)hook_isViewersListMetricRedesignEnabled, (IMP *)&orig_isViewersListMetricRedesignEnabled);

		HookClassMethod("_TtC16IGConsumerSubsUI31IGConsumerSubsUpsellAlertHelper",
			@"shouldShowViewerListUpsellButtonWithConsumerSubsService:launcherSet:",
			(IMP)hook_shouldShowViewerListUpsellButton, (IMP *)&orig_shouldShowViewerListUpsellButton);

		HookClassMethod("_TtC29IGConsumerSubsDirectChatPeeks39IGConsumerSubsDirectChatPeekEligibility",
			@"isChatPeekFeatureEligibleWithLauncherSet:consumerSubsService:",
			(IMP)hook_isChatPeekFeatureEligible, (IMP *)&orig_isChatPeekFeatureEligible);

		HookClassMethod("_TtC29IGConsumerSubsDirectChatPeeks39IGConsumerSubsDirectChatPeekEligibility",
			@"isUpsellEligibleWithLauncherSet:consumerSubsService:",
			(IMP)hook_isUpsellEligibleLauncherFirst, (IMP *)&orig_isUpsellEligibleLauncherFirst);

		HookClassMethod("_TtC40IGConsumerSubsOnboardingImpressionLogger41IGConsumerSubsPinnedPostsUpsellHelperObjC",
			@"isUpsellEligibleWithConsumerSubsService:launcherSet:sessionUserDefaults:",
			(IMP)hook_isUpsellEligibleServiceFirst, (IMP *)&orig_isUpsellEligibleServiceFirst);

		HookClassMethod("_TtC40IGConsumerSubsOnboardingImpressionLogger41IGConsumerSubsPinnedPostsUpsellHelperObjC",
			@"isOverflowPostMenuUpsellEligibleWithConsumerSubsService:launcherSet:sessionUserDefaults:",
			(IMP)hook_isOverflowPostMenuUpsellEligible, (IMP *)&orig_isOverflowPostMenuUpsellEligible);

		os_log(OS_LOG_DEFAULT, "[SCI] IGPlus eligibility-helper hooks installed");
	}
}
