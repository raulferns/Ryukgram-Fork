// SCIMobileConfigForce.x — UNIFIED into SCICSymbolEngine.
//
// This file used to fishhook the MobileConfig/EasyGating boolean readers itself.
// That collided with SCICSymbolEngine and SCIMobileConfigDiag, which rebind the
// SAME imported symbols: whichever %ctor ran second captured the first's
// replacement as its "orig", breaking the call chain (the real fragility).
//
// Single source of truth is now SCICSymbolEngine. The legacy Dev switches
// (sci_force_mc_internal_use_boolean, sci_force_sessioned_mc_all, sci_force_
// msgc_sessioned_boolean, sci_force_mci_*_boolean, sci_force_all_mc_gates,
// sci_force_mc_internal_use_all) are read by the engine's reinstallPersistedHooks
// and mapped onto the same curated readers + the universal native adapter. So the
// old toggles keep working, but only ONE rebind happens.
//


%ctor {
	// Intentionally no-op. Single source of truth is SCICSymbolEngine.
}
