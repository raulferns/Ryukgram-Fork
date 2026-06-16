// SCIMobileConfigDiag.x — UNIFIED into SCICSymbolEngine.
//
// The standalone CSV diagnostic used its own fishhook on the same readers as
// SCICSymbolEngine / SCIMobileConfigForce, which is the double-rebind hazard.
//
// Diagnostics now live in the engine: turn on "Diagnostic capture (all readers)"
// in the C Symbols Browser. The engine hooks every curated reader observe-only
// (calls orig, records call counts + captured gating IDs + observed values) and
// the browser surfaces them live. That replaces the CSV file with an in-app,
// real-time view and removes the conflicting second rebind.
//


%ctor {
	// Intentionally no-op. Single source of truth is SCICSymbolEngine.
}
