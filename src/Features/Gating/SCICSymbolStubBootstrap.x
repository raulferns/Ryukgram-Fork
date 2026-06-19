// SCICSymbolStubBootstrap.x
// Cold-launch reinstall for the unified runtime patch resolver.
//
// Timing: read one cheap persisted-plan dictionary first. If empty, return.
// The resolver reapplies only plans that were explicitly saved as safeAtLaunch
// and revalidates the backend before installing anything.
#import "../../Utils.h"
#import "SCICRuntimePatchResolver.h"

%ctor {
    @autoreleasepool {
        NSDictionary *plans = [SCIUtils getDictPref:[SCICRuntimePatchResolver persistedPlansKey]];
        if (![plans isKindOfClass:NSDictionary.class] || plans.count == 0) {
            if ([SCIUtils getBoolPref:@"sci_csym_stub_install_at_launch"]) {
                [SCIUtils setPref:@NO forKey:@"sci_csym_stub_install_at_launch"];
            }
            return;
        }
        [SCICRuntimePatchResolver reinstallSafePersistedPatchPlansAtLaunch];
        if ([SCIUtils getBoolPref:@"sci_csym_stub_install_at_launch"]) {
            [SCIUtils setPref:@NO forKey:@"sci_csym_stub_install_at_launch"];
        }
    }
}
