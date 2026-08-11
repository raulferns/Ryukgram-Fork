# SCIEmployeeConsumers swap + real-time browser filter removal

Two changes, both verified with LIEF 1.0.0 + Capstone 5.0.9 against the
shipped `Instagram` (43429 classes) and resident `FBSharedFramework`
(5348 classes).

## 1. SCIEmployeeInternal.x → SCIEmployeeConsumers.x (swap)

`SCIEmployeeInternal.x` is **removed** and replaced by
`SCIEmployeeConsumers.x`, which keeps the exact three exported entry points
the tree depends on so nothing else has to change:

* `SCIInstallEmployeeIdentityHooksIfNeeded` — called from part03/part04 and
  `SCIInternalMenusForce.x`.
* `SCIInstallEmployeeIdentityHooksForObject` — called from part02 for the live
  `deviceSession` / `userSession` objects (the generic per-object installer is
  ported over intact).
* `SCIInstallEmployeeInternalHooksIfNeeded` — the compat entry the Settings /
  launcher / actions callers use; still defers to
  `SCIRequestInternalGlobalHooksInstall`.

What the new file adds over the old one:

* The four **initializer-argument consumers** that cache the identity flag and
  expose no getter afterwards — `IGSeenStateStore`, `IGSeenStateLogger`,
  `IGLeadGenAnalyticsLogger`, `IGFeedRequestQPLogger` (exact ABIs verified).
  These were hooked nowhere in the tree.
* An encoding check that treats `{B,c,C}` as one BOOL class, so the Swift
  `IGAdPlatformLogger_swift` and generic identity hooks still install if the
  runtime reports the getter as `c`/`C` (the old strict `strcmp` would skip).

Ownership is unchanged: this file touches only ObjC identity. It does **not**
hook `IGBugReportMenuViewController` or `FBMobileConfigContextManager` — those
stay owned by `SCIInternalGlobalSafe.x`, so no two MSHookMessageEx chains fight
over one selector. Gate is the existing master
(`[SCIInternalGatePrefs employeeInternalMasterEnabled] || sci_internal_menus`);
`IGFeedRequestQPLogger.isTestUser` also honours `sci_force_ig_is_test_user`.

## 2. Unified Runtime Browser — remove the pre-baked filter

`SCISymbolBrowserEngine classesForImage:` was already a **live** runtime sweep
(`objc_copyClassList` + `class_copyMethodList`, filtered to Instagram /
FBSharedFramework, keeping BOOL getters with 0 or 1 argument). The reason
almost nothing showed was the **display** gate in
`SCISymbolsBrowserViewController rebuildSections`: with no search query it only
kept entries whose name/abi contained a hardcoded token from
`SCICDefaultFiltersForMode` (`MobileConfig`, `Gating`, `Employee`, … and, for
DATA params, `ig_is_employee` — a descriptor that no longer exists in this
build).

Change: `rebuildSections` no longer calls that curated allow-list. With an
empty query every entry that passes the current mode (live ObjC BOOL getters,
C functions, DATA params, Swift) for both images is shown in real time; the
image/kind segments and the search box narrow it. The no-query cap is raised
(420 → 20000) so the full boolean surface is reachable.

Safety preserved: the group-force switch still uses
`controllableEntriesInGroup:` (based on `inlineToggleSafe`), not the curated
list, so removing the display filter does not widen what "Force group" applies
to. `entryMatchesDefaultFilters:` / `SCICDefaultFiltersForMode` are left
defined (unused) so `SCIUnifiedRuntimeBrowserCompat.m`, which hooks that
selector reflectively, still resolves — its widening simply becomes moot.

## Build fix — Logos colon-counting bug with inline ternary bodies

First submission failed CI: `SCIEmployeeConsumers.x:77: error: Invalid argument
structure in %orig`. Root cause, confirmed by running the actual
`theos/vendor/logos` preprocessor (not guessed): when a method's signature and
body are on the **same line** and the body contains a ternary (`cond ? a : b`),
Logos' colon-counting selector-arity parser picks up the ternary's `:` as an
extra selector argument separator, so the argument count it expects for
`%orig(...)` no longer matches the real selector. Reproduced in isolation with
a 3-line file:

```objc
%hook FBWKWebView
- (void)setIsEmployee:(BOOL)value { %orig(value ? YES : value); }
%end
```

→ identical error. Moving the body onto its own line fixes it:

```objc
%hook FBWKWebView
- (void)setIsEmployee:(BOOL)value {
    %orig(value ? YES : value);
}
%end
```

The four `SCIEmployeeConsumersInitArgs` hooks were already written this way and
were never affected; only the four single-line `SCIEmployeeConsumersKnownObjC`
bodies (`IGFacebookUserInfo`, `IGAdPlatformLogger_objc` ×2,
`FBWKWebView`, `FBWKWebViewDelegateAdaptor`) needed reformatting. The fixed
file was verified by running it through the real Logos preprocessor end to
end: zero errors, and every expected `MSHookMessageEx(...)` call site
(`isEmployee`, `setIsEmployee:`, and all four init selectors) appears in the
generated output with the correct argument count.

Worth a project-wide sweep: any other `.x` file with a `%hook`/method body
sharing one line with a ternary inside `%orig(...)` (or inside the return
expression before a bare `%orig`) is exposed to the same failure the moment
its content changes enough to re-trigger Logos' parse path.

## MobileConfig param IDs (still open)

Unchanged from the prior note: the two hardcoded IDs in `part00.inc`
(`0x008100A700000134`, `0x00810A8A000139D6`) do not appear statically in this
build (0 hits in the constant pool and in movz/movk). They are runtime-assigned
and need the in-app `getBool:` probe to confirm; left as-is.
