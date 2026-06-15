// SCICSymbolBootstrap.x
//
// Installs persisted C-symbol fishhook overrides once at launch. Per THEOS.md
// baseline §5 (C imported symbol → fishhook, flag latched): the %ctor only does
// a cheap pref read and early-returns when the master switch is off. All real
// rebinding happens inside reinstallPersistedHooks, and only for symbols that
// have a persisted override (or when the diagnostic-all flag is on).

#import "../Gating/SCICSymbolEngine.h"
#import "../../Utils.h"

%ctor {
	@autoreleasepool {
		if (![SCIUtils getBoolPref:@"sci_c_symbol_force_enabled"]) return;
		[SCICSymbolEngine reinstallPersistedHooks];
	}
}
