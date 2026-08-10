# Employee init-arg consumers — analysis & delta

Verified with LIEF 1.0.0 + Capstone 5.0.9 against the shipped
`Instagram` executable (imagebase `0x100000000`, 43429 ObjC classes,
DYLD_CHAINED_PTR_64) and the resident `FBSharedFramework`
(imagebase `0x0`, 5348 classes).

## Framework coverage

The Instagram image links 153 dylibs. The **only** Meta-owned embedded
(`@rpath`) framework is `FBSharedFramework.framework` — fully swept
(5348 classes). There is **no** `FBSharedDynamicFramework` or
`FBRarelyUsedFramework` in this build (those exist in the Facebook app,
not here). The other embedded frameworks are third-party
(`SpotifyiOS`, `libavcodec`, `libavutil`, `GoogleCast`) or the sideload
injectors (`Regram.dylib`, `RegramExtension.dylib`,
`_ipa_by_iosdecrypted_[sideloadKeychainFix].dylib`) — none carry
employee/internal ObjC surface. So the two binaries analysed cover the
entire Meta-owned identity/gating class surface for this build.

## What is already correct in the tree (independently confirmed)

* **Identity getters/setters** — `SCIEmployeeInternal.x` already forces
  `IGFacebookUserInfo.isEmployee`, `IGAdPlatformLogger_objc`
  `isEmployee`/`setIsEmployee:`, `IGAdPlatformLogger_swift` (Swift @objc,
  encoding-validated), `FBWKWebView`/`FBWKWebViewDelegateAdaptor`
  `setIsEmployee:`. Encodings match this build.
* **Bug Reporter menu** — `SCIInternalGlobalSafeParts/part02-03` hooks both
  `IGBugReportMenuViewController` initializers, including the current
  overload ending `showDogfoodingAssistant:maisaUXVariantRawValue:`. The
  selectors match the shipped binary character-for-character.
* **MobileConfig force** — `-[FBMobileConfigContextManager getBool:]` and
  its five siblings. `FBMobileConfigContextManager` lives in
  `FBSharedFramework`; all six encodings
  (`B24@0:8{mc_bool_param_t=Q}16`, …) match this build exactly.

No changes were made to any of the above — they are correct as shipped.

## The gap this delta fills

Four IG classes take the identity flag **as an initializer argument** and
cache it; they never expose a hookable `isEmployee` getter afterwards, so
the getter-forcing layer does not reach them. None of them is hooked
anywhere in the tree. Verified selectors/ABI:

| class | selector | encoding |
|---|---|---|
| `IGSeenStateStore` | `initWithDependencies:isEmployee:` | `@28@0:8@16B24` |
| `IGSeenStateLogger` | `initWithIsEmployee:analyticsLogger:` | `@28@0:8B16@20` |
| `IGLeadGenAnalyticsLogger` | `initWithAnalyticsLogger:userFbidV2:isEmployee:` | `@36@0:8@16q24B32` |
| `IGFeedRequestQPLogger` | `initWith…isCacheLoadEnabled:isEmployee:isTestUser:` | `@52@0:8B16@20@28B36B40B44B48` |

`src/Features/Dogfooding/SCIEmployeeInitConsumers.x` `%hook`s these four
initializers and rewrites the argument, riding the existing master switch
(`[SCIInternalGatePrefs employeeInternalMasterEnabled] || sci_internal_menus`).
`IGFeedRequestQPLogger`'s `isTestUser` arg additionally honours a
`sci_force_ig_is_test_user` sub-toggle. Plain-ObjC classes → `%hook`, gated
`%init` in `%ctor`; no new MSHookMessageEx chain, no new Settings row.

## Open item — MobileConfig param IDs need a runtime probe

The two hardcoded IDs in `part00.inc`:

```
kSCIEmployeeOrTestUserMC  = 0x008100A700000134
kSCIDogfoodingAssistantMC = 0x00810A8A000139D6
```

do **not** appear anywhere in this build — not as an 8-byte literal in
the constant pool (0 hits in `Instagram` and `FBSharedFramework`) and not
as a movz/movk immediate in `__text`. MobileConfig `mc_bool_param_t` IDs
are assigned at runtime, so they cannot be validated statically; the
values here were presumably captured from a runtime session and may drift
between builds. This matches the in-progress "validate 64-bit paramID
space" work: log `param.raw` inside the `getBool:` hook for a known
is_employee_or_test_user read and compare. Left unchanged pending that
probe.
