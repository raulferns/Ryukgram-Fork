// SCIMCParamAutoResolve.h
//
// Build-independent replacement for the two hardcoded MobileConfig param IDs
// (kSCIEmployeeOrTestUserMC / kSCIDogfoodingAssistantMC in part00.inc).
//
// Why this exists: mc_bool_param_t is an opaque 64-bit value. There is no
// name-keyed MobileConfig API to resolve it from (every getBool* variant on
// FB/IGMobileConfigContextManager and the UserSession/Sessionless managers
// takes {mc_bool_param_t=Q} — verified across both shipped images), and the
// per-key descriptor symbols the older tweak used (_ig_is_employee,
// _ig_is_employee_or_test_user, _ig_dogfooding_assistant,
// _ig_dogfooding_first_client) are gone from this build entirely: 0 hits as
// exported symbol, imported symbol, or raw string in Instagram AND FBSharedFramework. The two
// literal IDs also do not appear anywhere statically — not as an 8-byte
// constant-pool value, not as a movz/movk immediate — because they are
// assigned at runtime. So they cannot be validated ahead of time and silently
// stop matching whenever Instagram reshuffles them, which turns the entire
// MobileConfig force layer into a no-op with no visible error.
//
// The approach here removes the hardcoding instead of refreshing it:
//
//   LEARN  — the Bug Reporter / internal-settings code path is already hooked
//            (part02/part03 wrap the two IGBugReportMenuViewController
//            initializers plus viewDidLoad/viewDidAppear/didSelect). While
//            execution is inside that path, every mc_bool_param_t passed to
//            getBool* is recorded, per thread. Those are, by construction, the
//            parameters the internal-settings surface actually consults on
//            THIS build.
//   FORCE  — outside that window nothing is forced by observation; only IDs
//            already learned (or a still-valid hardcoded seed) are forced.
//
// This self-heals across app updates: after one visit to the shake/bug menu
// with the master ON, the correct IDs for the running build are persisted and
// used from then on, including at next launch.
//
// Scope note: learning observes; it does not change any value. Forcing is
// limited to the learned ID set, so this is narrower than "force every
// MobileConfig boolean", which would flip thousands of unrelated experiments.

#ifndef SCI_MC_PARAM_AUTO_RESOLVE_H
#define SCI_MC_PARAM_AUTO_RESOLVE_H

#import <Foundation/Foundation.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Marks entry/exit of a known internal-settings / bug-report code path.
/// Re-entrant and per-thread: nested calls are counted, so wrapping both an
/// initializer and a viewDidLoad that runs inside it is safe.
void SCIMCLearnScopeEnter(void);
void SCIMCLearnScopeExit(void);

/// Called from the getBool* wrappers for every observed parameter.
/// Records the ID when inside a learn scope; otherwise a cheap no-op.
void SCIMCNoteObservedParam(uint64_t raw);

/// YES when this param should be forced: it is in the learned set, or it
/// matches a seed ID that is still valid on this build.
BOOL SCIMCShouldForceLearnedParam(uint64_t raw);

/// Seed IDs from a previous build. Used only until something is learned, and
/// never treated as authoritative.
void SCIMCRegisterSeedParam(uint64_t raw, BOOL requiresDogfoodPayload);

/// Diagnostics for the Dev menu: how many IDs are known and where from.
NSString *SCIMCAutoResolveStatusSummary(void);

/// Clears everything learned (Dev menu "recalibrate").
void SCIMCAutoResolveReset(void);

/// YES if the param must additionally pass the XPlugins dogfood payload check
/// (mirrors the old kSCIDogfoodingAssistantMC special case).
BOOL SCIMCLearnedParamRequiresDogfoodPayload(uint64_t raw);

#ifdef __cplusplus
}
#endif

#endif /* SCI_MC_PARAM_AUTO_RESOLVE_H */
