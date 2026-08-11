# Browser signal/noise + C-mode resolution + employee identity timing

## Correction: IGBaseUser / IGUserSession / IGDeviceSession DO exist

My previous note claimed these classes "do not exist in this build". That was
wrong, and the reason was a bad method: I searched only the Instagram
executable's `__objc_classlist` and reported absence. All three exist — in
**FBSharedFramework**, the resident dylib:

| class | Instagram exec | FBSharedFramework |
|---|---|---|
| `IGBaseUser` | no | **yes** (1076 instance methods) |
| `IGUserSession` | no | **yes** (12) |
| `IGDeviceSession` | no | **yes** (3) |
| `IGSessionContext` | yes (only `.cxx_destruct`) | no |
| `IGUserSessionContext` | no | no |
| `IGDogfooderProd` | yes | no |

What remains true is the *conclusion*, for a different reason: none of the
three exposes a zero-argument BOOL getter at all, and none has any
`employee`/`internal`/`dogfood`/`test` selector. `IGBaseUser`'s only
`isAllowedTo…`-style members return objects (`@16@0:8`), not BOOL. So the
hardcoded name list still hooked nothing — but it was removed for the correct
reason (no matching selector), not the false one (class absent).

Per-object installation via `SCIInstallEmployeeIdentityHooksForObject` (called
from part02 with the live `deviceSession` / `userSession`) remains the right
mechanism, because it resolves the actual runtime class of the instance rather
than guessing a name.

## `+` vs `-` in the browser

Standard Objective-C notation: `+` is a **class method** (hooked on the
metaclass, `object_getClass(cls)`), `-` is an **instance method**. Previously
only `+` was rendered and instance methods got no prefix at all, so the two
were visually identical. Both are explicit now.

The persisted override key format (`SCIOverrideKey`, `"+Class#sel"` /
`"Class#sel"`) is built separately in `objcOverrideKeyForEntry:` from the
`objcClassName`/`objcSelectorName`/`objcClassMethod` fields — not from the
display name — so existing saved overrides are unaffected.

## Browser filtering: exclude noise, don't allow-list topics

Correct objection: filtering by dogfood-ish keywords hides hookable gates that
matter but aren't dogfooding. The default view is now a **structural-noise
exclusion**, not a topic allow-list.

Measured over both images (BOOL-ish return, 0/1 argument, `set*`/`init*`
already excluded): 29,240 entries across 13,393 distinct selectors. The 40
most-repeated selectors account for **22.7%** of all entries and are all
mechanical:

| selector | classes implementing it |
|---|---|
| `isEqualToDiffableObject:` | 1490 |
| `isEqual:` | 931 |
| `quick_flexibilityFor:` | 734 |
| `canRespondToGesture:` | 417 |
| `prefersNavigationBarHidden` | 321 |
| `prefersNavigationBarDividerHidden` | 234 |
| `prefersStatusBarHidden` | 163 |
| `gestureRecognizerShouldBegin:` | 131 |
| `isAccessibilityElement` | 129 |

`quick_flexibilityFor:` — the one in the screenshot — is a synthesized layout
helper, `-(BOOL)quick_flexibilityFor:(BOOL)`, present on 734 unrelated view
classes. It is not a gate; it merely satisfies the crude "returns BOOL, takes
≤1 arg" rule.

`SCICStructuralNoiseSelectors()` drops equality/diffing, gesture and
text/search delegate callbacks, first-responder and accessibility plumbing,
plain UIKit view state (`isHidden`/`isSelected`/`isEnabled`/…), trivial media
state, and `__`-prefixed Swift thunks. **Everything else is shown**, including
gates with unfamiliar names and nothing to do with dogfooding. The segment is
now **Signal / All**: "All" disables even the noise exclusion, and any search
query bypasses both — nothing is ever permanently unreachable.

## C mode: why nothing resolved, and the fix

`SCICEnumerateImageSymbolsAtIndex` keeps only nlist entries with
`(n_type & N_TYPE) == N_SECT`, i.e. symbols **defined** in that image. Actual
symtab composition of the shipped pair:

| image | nlist symbols | defined (N_SECT) | imports (N_UNDF) |
|---|---|---|---|
| Instagram | 39,228 | **5** | 39,223 |
| FBSharedFramework | 35,113 | 24,136 | 10,977 |

So in C mode the executable contributed 5 rows; everything else it "knows"
about is an import with no address of its own — hence entries that look
unresolved and unhookable. Those imports are precisely the fishhook-able
surface (`_EasyGatingGetBoolean_Internal_DoNotUseOrMock`,
`_MCQEasyGatingGetBooleanInternalDoNotUseOrMock`,
`_EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock`,
`_EasyGatingPlatformGetBoolean`, MSGC/MCI readers …) that the Dev menu's
"Current C experiment gates" section already forces by name.

The file could already enumerate them (`SCICCollectImportedSymbolNamesForImage`
walks the lazy/non-lazy pointer sections plus the indirect symbol table) but
used the result only as a boolean `hasBindPointer` flag on defined symbols — so
an import with no defined counterpart never became a row.

`SCICEnumerateImportEntriesForImage` now emits imports as first-class entries:
the bound target is resolved live via `dlsym(RTLD_DEFAULT, …)` (which searches
every loaded image, so an import defined in another dylib resolves to a real
callable address), `resolvable` reflects that resolution, `hasBindPointer` is
YES by definition, and the row is labelled as GOT-rebindable rather than
swizzle-able. Results are de-duplicated against the defined-symbol pass.

## Text truncation

`cellForRowAtIndexPath:` hard-capped `numberOfLines` at 2 (title) / 3
(subtitle) even though the base list already uses
`UITableViewAutomaticDimension` — the row could grow but each label clipped
first. Class+selector names here routinely run 70–90+ characters and the
subtitle joins up to five `·`-separated clauses. Both caps are now 0
(unlimited); fonts nudged 12.5→13.0 / 10.5→11.0.

## Employee identity timing (why nothing applied)

`SCIEmployeeConsumers.x` called its installer directly from a raw `%ctor` and
latched a `static BOOL knownInstalled = YES` *before* confirming the Logos
`%init(group)` had bound anything. `%ctor` runs before `UIApplicationMain`;
`SCIInstallOnce.h` documents (SCI-FIX 2026-06-11, crash 433.0.283) why this
tree defers class hooking to `UIApplicationDidBecomeActive`, and `%init` has no
partial-failure signal — so an early miss latched "done" permanently and every
identity swizzle stayed off for the whole process, on every launch, whatever
the Dev menu said afterwards.

Now: the launch trigger goes through `SCIInstallOnceOnActive` (same as
`SCIDogfoodObjectRuntimeHooks.x` / `SCIIGUserSessionHook.x`), and the two Logos
groups are replaced by individually-guarded `MSHookMessageEx` installers with
one static original-IMP pointer per selector — idempotent, cheap to re-attempt,
and safe to call repeatedly from part02/03/04, from Tier-2, or from
"Apply now". An early miss no longer blocks a later correct retry.

All nine hooked selectors were re-verified against the newly uploaded
Instagram/FBSharedFramework pair (43,736 / 5,383 classes — an app update did
land between sessions) and every encoding is byte-identical to the previous
build. Both `IGBugReportMenuViewController` initializers and all six
`FBMobileConfigContextManager getBool*` encodings also still match exactly, so
`SCIInternalGlobalSafe.x` needs no change for this update.

Stale references to the removed `SCIEmployeeInternal.x` filename were corrected
in `SCISettings_Dev.m`, `SCIMobileConfigEmployeeGate.x`, `SCIAdvancedHooks.m`
and `SCIInternalMenusForce.x` (comments only).

## Still open

* The two hardcoded MobileConfig param IDs in `part00.inc`
  (`0x008100A700000134`, `0x00810A8A000139D6`) still do not appear anywhere in
  this build — not as an 8-byte constant-pool literal and not as a movz/movk
  immediate, in either image. They are runtime-assigned, so they cannot be
  validated statically and need the in-app `getBool:` probe.
* `SCISymbolBrowserViewController.m` (singular, 257 lines) is dead code — never
  instantiated anywhere. Left untouched; worth deleting separately.
* Liquid Glass in the Dev menu is driven by separate prefs in `Tweak.x`
  (`liquid_glass_buttons` / `liquid_glass_surfaces`) and by
  `src/UI/SCIUIKit26LiquidGlass.m`; nothing in these changes touches that
  subsystem.

## MobileConfig param IDs: auto-resolve instead of hardcoding

The two IDs in `part00.inc` cannot be validated statically (runtime-assigned;
0 static hits in either image) and silently stop matching on any build where
Instagram reshuffles them — turning the whole MobileConfig force layer into a
no-op with no error. Refreshing the constants by hand just restarts that clock,
so the hardcoding itself is now removed.

`SCIMCParamAutoResolve.{h,m}` learns the right IDs for the running build:

* **Learn** — `SCIMCLearnScopeEnter/Exit` bracket the already-hooked internal
  settings path: both `IGBugReportMenuViewController` initializers (part02) and
  `viewDidLoad` / `viewDidAppear` (part03). While inside, every
  `mc_bool_param_t` passed to any of the six `getBool*` wrappers is recorded.
  Those are by construction the parameters that surface actually consults.
  Scope depth is **thread-local** (getBool* is called from several queues, so a
  global counter would leak into concurrent unrelated work) and re-entrant.
* **Force** — outside the scope nothing is forced by observation. Only IDs
  already learned, or a seed that still matches, are forced. Learned IDs are
  persisted (`sci_mc_learned_internal_params`) and reload at next launch.
* **Bounded** — at most 24 IDs are ever learned, so a scope accidentally left
  open (early return / exception) cannot escalate into forcing a wide set. This
  stays far narrower than "force every MobileConfig boolean", which would flip
  thousands of unrelated experiments.
* The dogfooding-assistant precondition is preserved: that param (seeded, or
  any learned ID flagged as requiring it) still has to pass
  `SCIDogfoodAssistantPayloadAvailable()`, so the row cannot be forced visible
  without its XPlugins socket provider — the "blocked: XPlugins socket provider
  is empty" dead end stays guarded.

Calibration is one action: with the master ON, open the shake / bug-report menu
once. `SCIMCAutoResolveStatusSummary()` reports how many IDs are known and
where they came from, and `SCIMCAutoResolveReset()` clears them to recalibrate
after an app update. Both are ready to wire into a Dev-menu row.

Why not other approaches: there is no name-keyed MobileConfig API to resolve
against — every `getBool*` on `FBMobileConfigContextManager`,
`IGMobileConfigContextManager`, and the UserSession/Sessionless managers takes
an opaque `{mc_bool_param_t=Q}` (verified across both images); the only
name-keyed bool selectors in the app (`IGMobileConfigValueRevertCheckerCache
-boolForKey:`) belong to a revert-checker cache, not the read path. And the
per-key descriptor symbols the older tweak resolved via `dlsym` no longer exist
in this build.
