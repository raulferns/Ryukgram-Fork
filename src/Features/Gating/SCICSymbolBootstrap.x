// SCICSymbolBootstrap.x
// Installs persisted C-symbol observe/force hooks once at launch. Cheap early
// return; no import enumeration unless there is persisted C-symbol state.

#import "../Gating/SCICSymbolEngine.h"

%ctor {
    @autoreleasepool {
        if (![SCICSymbolEngine hasPersistedHooks]) return;
        [SCICSymbolEngine reinstallPersistedHooks];
    }
}
