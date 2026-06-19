// SCICSymbolStubBootstrap.x
// Relaunch-safe bootstrap for the v34 runtime patch resolver.
// Startup stays cheap: only a small persisted dictionary is read; no symbol scan.
#import "../../Utils.h"
#import "SCICRuntimePatchResolver.h"

%ctor {
    @autoreleasepool {
        [SCICRuntimePatchResolver reinstallPersistedPatchPlans];
        if ([SCIUtils getBoolPref:@"sci_csym_stub_install_at_launch"]) {
            [SCIUtils setPref:@NO forKey:@"sci_csym_stub_install_at_launch"];
        }
    }
}
