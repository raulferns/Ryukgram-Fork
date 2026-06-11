// SCILauncherClientHook.x
//
// Hooks IGDogfoodingAssistantLauncherClient.overrideLauncherWithUserSession:
// launcherName:parametersToValues: in FBSharedFramework. Every call (whether
// from IG's own dogfood flow, Notes settings, our SCILauncherOverride engine,
// or anything else) is mirrored into our persistent store before being
// forwarded to the original implementation.
//
// This is the missing piece for capturing whatever Notes Dogfood writes when
// the user toggles a switch. If Notes calls this method, we record it; on
// next launch our replay re-applies it through the same client.
//
// Class confirmed live via FLEX at runtime (instance at 0x1559e95c0 in the
// user's session; symbol present in FBSharedFramework's __objc_classlist).
// Method signature confirmed: B40@0:8@16@24@32 (BOOL return, 3 id args).

#import "SCILauncherOverride.h"
#import "SCIInstallOnce.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static BOOL (*orig_overrideLauncher)(id, SEL, id, id, id) = NULL;

static BOOL new_overrideLauncher(id self, SEL _cmd,
                                  id session, id name, id params) {
	// Forward FIRST so a crash in our mirror code can't break IG's behavior.
	BOOL ok = orig_overrideLauncher ? orig_overrideLauncher(self, _cmd, session, name, params) : NO;

	// Mirror to our persistent store. Idempotent — re-persisting the same
	// (launcher, param, value) tuple just overwrites with identical data.
	@try {
		if ([name isKindOfClass:[NSString class]] &&
		    [params isKindOfClass:[NSDictionary class]]) {
			for (id k in (NSDictionary *)params) {
				if (![k isKindOfClass:[NSString class]]) continue;
				id v = ((NSDictionary *)params)[k];
				if (v) [SCILauncherOverride persistLauncher:name parameter:k value:v];
			}
		}
	} @catch (__unused id e) {}
	return ok;
}

static void sciInstallLauncherClientHook(void) {
	Class cls = NSClassFromString(@"IGDogfoodingAssistantLauncherClient.IGDogfoodingAssistantLauncherClient");
	if (!cls) cls = NSClassFromString(@"_TtC35IGDogfoodingAssistantLauncherClient35IGDogfoodingAssistantLauncherClient");
	if (!cls) return;
	SEL sel = @selector(overrideLauncherWithUserSession:launcherName:parametersToValues:);
	if (![cls instancesRespondToSelector:sel]) return;
	@try {
		MSHookMessageEx(cls, sel, (IMP)new_overrideLauncher, (IMP *)&orig_overrideLauncher);
	} @catch (__unused id e) {}
}

%ctor {
	@autoreleasepool {
		// Try at ctor time; if the Swift class isn't initialized yet,
		// retry after a beat on the main queue (FBSharedFramework loads
		// before our dylib so this is usually unnecessary, but it's cheap).
		sciInstallLauncherClientHook();
		// SCI-FIX 2026-06-11: deterministic fallback instead of a +1s timer.
		if (!orig_overrideLauncher) {
			SCIInstallOnceOnActive(^{
				if (!orig_overrideLauncher) sciInstallLauncherClientHook();
			});
		}
	}
}
