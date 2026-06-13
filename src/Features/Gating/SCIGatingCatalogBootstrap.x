#import "SCIGatingCatalog.h"

// Startup-safe bootstrap for SCIGatingCatalog.
//
// reconcileCrashGuardOnLaunch: must run synchronously at %ctor so the blacklist
// is updated before any getter evaluation could be attempted later.
//
// installPersistedDirectOverrideHooks: intentionally deferred to main queue.
//   • Needs NSUserDefaults (safe after IG app init, unsafe if MC fishhook fires first)
//   • Most gating getters are read lazily, not during pre-application init
//   • The deferred approach means overrides are active before the first UI render
//     cycle (dispatch_async runs before the first runloop iteration with UI)
//
// SCIBulkGatingPresetsBootstrap.x handles the truly launch-path-critical features
// (StatusBarOldSchool, StoryTray, IGDS LiquidGlass/Prism) via SCIRuntimeBoolForce
// which is always safe at %ctor time.

%ctor {
    @autoreleasepool {
        // 1. Reconcile crash guard — must be synchronous and early
        [SCIGatingCatalog reconcileCrashGuardOnLaunch];
    }
}
