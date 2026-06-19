// ============================================================================
// SCIIGPlusEligibilityHook.x
// ============================================================================
// Lower-level IGPlus eligibility/data-provider forcing, validated against the
// Instagram executable. These sit UNDER the benefit getters and are consulted by
// several IGConsumer paths.
//
// Hook primitive: MSHookMessageEx, because all targets are Swift ObjC-exposed
// classes/selectors. No dispatch_after retry ladder. Hooks install only when a
// persisted IGPlus pref is active at launch; first enable from all-off requires
// relaunch.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"
#import "SCIInternalSettingsApplier.h"
#import "SCIInstallOnce.h"

#define ELOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] IGPlusElig " fmt, ##__VA_ARGS__)
static inline BOOL ON(NSString *k){ return [SCIInternalGatePrefs individualGateEnabledForKey:@"sci_force_igplus_all"] || [SCIInternalGatePrefs individualGateEnabledForKey:k]; }

static NSMutableSet<NSString *> *gDone;

static BOOL sciForceYes1(__unused id self, __unused SEL _cmd, __unused id a) { return YES; }
static BOOL sciForceYes2(__unused id self, __unused SEL _cmd, __unused id a, __unused id b) { return YES; }
static BOOL sciForceYes4(__unused id self, __unused SEL _cmd, __unused NSInteger a, __unused NSInteger b, __unused id c, __unused id d) { return YES; }

static void hookKnown(NSString *clsName, NSString *selName, BOOL instance, IMP replacement) {
	Class cls = NSClassFromString(clsName);
	if (!cls) return;
	SEL sel = NSSelectorFromString(selName);
	Method m = instance ? class_getInstanceMethod(cls, sel) : class_getClassMethod(cls, sel);
	if (!m) return;
	Class target = instance ? cls : object_getClass(cls);
	NSString *tag = [NSString stringWithFormat:@"%@%@#%@", instance ? @"-" : @"+", clsName, selName];
	if ([gDone containsObject:tag]) return;
	IMP orig = NULL;
	MSHookMessageEx(target, sel, replacement, &orig);
	[gDone addObject:tag];
	ELOG("%{public}@ -> YES (%{public}s)", tag, orig ? "ok" : "noorig");
}

static void install(void) {
	if (!gDone) gDone = [NSMutableSet set];
	if (!ON(@"sci_igplus_eligibility")) return;

	// Instance: B24@0:8@16
	hookKnown(@"_TtC23SUBSBenefitDataProvider23SUBSBenefitDataProvider",
			  @"isBenefitActiveWithBenefitType:", YES, (IMP)sciForceYes1);

	// Class methods: B48@0:8q16q24@32@40
	NSString *peek = @"_TtC34IGConsumerSubsStoryPeekEligibility34IGConsumerSubsStoryPeekEligibility";
	hookKnown(peek, @"isPeekEligibleForEntryPoint:viewModelType:consumerSubsService:launcherSet:", NO, (IMP)sciForceYes4);
	hookKnown(peek, @"isUpsellPeekEligibleForEntryPoint:viewModelType:consumerSubsService:launcherSet:", NO, (IMP)sciForceYes4);
	hookKnown(peek, @"isAnyPeekEligibleForEntryPoint:viewModelType:consumerSubsService:launcherSet:", NO, (IMP)sciForceYes4);

	// Class method: B32@0:8@16@24
	hookKnown(@"_TtC29IGConsumerSubsDirectChatPeeks39IGConsumerSubsDirectChatPeekEligibility",
			  @"isChatPeekFeatureEligibleWithLauncherSet:consumerSubsService:", NO, (IMP)sciForceYes2);

	// Class method: B24@0:8@16
	hookKnown(@"_TtC27IGConsumerSubsCustomAppIcon33IGConsumerSubsCustomAppIconHelper",
			  @"isCustomAppIconAvailableWithUserSession:", NO, (IMP)sciForceYes1);
}

%ctor {
	@autoreleasepool {
		if (!ON(@"sci_igplus_eligibility")) return;
		[SCIInternalGatePrefs installCrashGuardIfNeeded];
		install();
		SCIInstallOnceOnActive(^{ install(); });
		[SCIInternalSettingsApplier scheduleAutoApplyIfEnabled];
	}
}
