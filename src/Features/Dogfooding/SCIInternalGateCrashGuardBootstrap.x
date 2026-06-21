// SCIInternalGateCrashGuardBootstrap.x
// Installs/reconciles the internal-gate crash guard independently from any
// specific hook family. This keeps the guard active for legacy gates, runtime
// patch plans, and async crashes that happen after the app becomes foreground.
#import "SCIInternalGatePrefs.h"

%ctor {
    @autoreleasepool {
        [SCIInternalGatePrefs installCrashGuardIfNeeded];
    }
}
