# Instagram 439 — Employee, Dogfood and Internal Settings revalidation

## Audited binaries

- `Instagram(16)` SHA-256: `fa19f499c560b188d2802e3a1a36642209ee6e42d7639c1ebe010f14b2c4cd9b`
- `FBSharedFramework(14)` SHA-256: `a79c110c59e7c16e5608227e12807583c1afcf80cb2a2e38302f147dbf99c12b`
- Both Mach-O images are decrypted (`cryptid = 0`).

The Apple `otool` binary was unavailable on the Linux analysis host. Load commands, Objective-C metadata and Mach-O structures were checked with LLVM tooling; ARM64 control flow, chained fixups, symbols and raw data were independently inspected. No old offset was reused without revalidation.

## Removed legacy names

The following literal names have zero ASCII and UTF-16 occurrences in both new binaries and are absent from symbols, imports, exports and chained bindings:

- `ig_is_employee`
- `ig_is_employee_or_test_user`
- `is_employee_or_test_user`
- `is_employee_or_employee_test_account`
- `ig_dogfooding_first_client`

The remaining `is_employee` strings belong to fields, ivars, selectors and telemetry. `_IGDeviceReportFBUserIsEmployeeKey`, `_is_employee`, `_is_employee_value_set` and `IGApplicationStateLogger ... isEmployee:` are not the Internal Settings authorization path in this build.

## Availability resolver

The Swift type is `IGInternalSettingsAvailabilityStatus`.

- resolver: `Instagram + 0x09E5D194`
- VA: `0x109E5D194`
- direct callers:
  - `0x104F54944`
  - `0x1059599F0`
  - `0x10633E3D0`
  - `0x10643E038`

Recovered decision flow:

```text
FBEndToEndIsRunningSapienz == true  -> 1
internal_only unavailable          -> 1
FBEndToEndIsRunningJestE2E == true -> 0
employeeOrTestUser == true         -> 0
employeeOrTestUser == false        -> 2
```

Raw values:

- `0`: allowed
- `1`: unavailable because the internal plugin/rollout is absent
- `2`: denied by employee/test-account identity

The consolidated outer Bug Reporter hook supplies status `0` and `showInternalSettings = YES` without pretending that removed XPlugins data exists.

## Canonical employee/test-user path

The generated fragment is obtained through `asIGUserIsEmployeeOrTestUserFragment`.

- Objective-C stub: `0x10A55FA5C`
- shared helper: `0x104177F3C`
- direct callers: 10

The helper accepts an account through three routes:

1. `accountBadges` contains internal badge value `0`;
2. `graphQLID.integerValue` belongs to either reserved range:
   - `90,010,000,000,000 <= ID < 90,020,000,000,000`
   - `15,812,502,200,005,009 <= ID < 15,852,502,200,005,009`
3. fallback MobileConfig boolean.

The fallback uses `_MC(context)`, `FBMobileConfigOptions.withoutLogging` and `-[FBMobileConfigContextManager getBool:withOptions:]` with packed parameter:

```text
0x008100A700000134
```

Decoded fields:

- type: `0x81` (boolean)
- config: `0x00A7` (`167`)
- parameter: `0x00000134` (`308`)

The verified framework implementation is `FBSharedFramework + 0x47F070`, encoding:

```text
B32@0:8{mc_bool_param_t=Q}16@24
```

`SCIInternalGlobalSafe.x` hooks every present boolean getter variant after validating its runtime ABI and forces only this exact employee/test-user parameter while the Employee/Internal master is enabled. It does not patch `__TEXT` and does not force unrelated MobileConfig values.

## Dogfooding Assistant and MAISA

Dogfooding Assistant presentation parameter:

```text
0x00810A8A000139D6
```

Decoded:

- type: `0x81`
- config: `0x0A8A` (`2698`)
- parameter: `0x000139D6` (`80342`)

MAISA UX variant:

```text
0x0082139D00001B09
```

Decoded:

- type: `0x82` (int64)
- config: `0x139D` (`5021`)
- parameter: `0x00001B09` (`6921`)

The caller normalizes raw value `4` to `0`. No MAISA value is forced. The Dogfooding Assistant boolean is forced only if its native XPlugins socket provider returns a real non-empty payload.

## Bug Reporter menu ABI

Class:

```text
_TtC17IGBugReporterMenu29IGBugReportMenuViewController
```

Current initializer:

```text
initWithDeviceSession:
userSession:
reliabilityLogging:
navChain:
endpoint:
entryPoint:
style:
internalSettingsAvailabilityStatus:
showInternalSettings:
showLoggedOutInternalSettings:
showShakeToReportPreferenceToggle:
showDogfoodingAssistant:
maisaUXVariantRawValue:
```

Verified Objective-C encoding:

```text
@104@0:8@16@24@32@40@48@56q64q72B80B84B88B92q96
```

`entryPoint` is an object at `@56`; the earlier preliminary `q56` assumption was incorrect.

- Swift initializer address: `0x104F8C954`
- direct callers:
  - `0x1001A2854`
  - `0x1011574A4`
  - `0x104B5D6A8`
  - `0x104F54A44`

Recovered scalar layout:

- `+0xC0`: `internalSettingsAvailabilityStatus`
- `+0xC8`: `showInternalSettings`
- `+0xC9`: `showLoggedOutInternalSettings`
- `+0xCA`: `showShakeToReportPreferenceToggle`
- `+0xCB`: `showDogfoodingAssistant`
- `+0xCC`: `maisaUXVariant`

Original `showInternalSettings` expression:

```text
internal_only && !hide-internal-settings-in-bug-report-menu
```

The safe outer hook validates both current and legacy initializer ABIs, suppresses the older menu mutation while forwarding to the original hook, then enforces Internal Settings state before native lifecycle code observes the object.

## Critical XPlugins ABI correction

The former proposal to rebind `_XPluginsGetDataFuncOrAbort(0x64327C01)` to a function returning `x0 = 1` was invalid and must never be implemented.

### `internal_only`

- hash: `0x64327C01`
- wrapper: `0x10410D7E4`
- XPlugins data table: `0x10EA1BCA0`
- table index: `1788` of `2305`
- entry: `0x10EA22C60`
- provider: `0x102BD80E4`
- result: `{ NULL, 0 }`

The provider ABI is a pair `(data pointer, count)` in `x0/x1`, not a boolean:

```c
struct XPluginsDataPair {
    const void *data;   // x0
    uintptr_t count;    // x1
};
```

Confirmed consumers include:

```text
0x104F8CB24: ldr w20, [x0, #8]
0x105959A1C: ldr x8, [x0]
0x105959A1C: ldr w1, [x0, #8]
```

The descriptor element contains three 32-bit XPlugins function IDs at offsets `+0`, `+4` and `+8`. The ID at `+8` is resolved through `XPluginsGetFunctionPtrFromID`, receives a `SocketThreadLocalScope`, and participates in building the typed plugin collection.

Swift reflection identifies the nested item type as `IGPinnedInternalSettingsSocket.Plugin`, with fields:

- `cell_text`
- `description_text`
- `imageID`
- `pinnedByDefaultID`

A second provider, hash `0x253F21CF`, should supply the actual plugin row array. It also resolves to the null `{ NULL, 0 }` provider. The subsystem is absent in two layers:

1. no descriptor containing the three function IDs;
2. no collection of `Plugin` rows.

The action `ig.action.navigation.OpenInternalSettings` and function ID `0x20AA` remain registered, but the handler reaches the same null provider through `0x10643E000`; it is not a provider-independent opener.

### Dogfooding Assistant socket

- hash: `0x7FBC8058`
- provider: `0x102BD80E4`
- result: `{ NULL, 0 }`

The two empty providers remain untouched. The implementation never returns a sentinel pointer, never inline-hooks the wrapper and never fabricates incomplete plugin data.

## Applied safe implementation

`src/Features/Dogfooding/SCIInternalGlobalSafe.x` is the single authoritative new-build layer. Its split `.inc` files compile into one Logos translation unit and static scope.

It:

- probes both XPlugins hashes through their real pair-return ABI;
- forces employee/test-user MobileConfig only for `0x008100A700000134`;
- forces Dogfooding Assistant MobileConfig only when `0x7FBC8058` has real data and count;
- hooks all six present `getBool*` variants with exact encodings;
- validates current and legacy Bug Reporter initializer encodings;
- sets status `0` and `showInternalSettings = YES`;
- keeps `showDogfoodingAssistant = NO` while the socket payload is empty;
- clears stale Assistant state before `viewDidLoad` and `viewDidAppear`;
- intercepts a stale Assistant row before Instagram's native handler;
- opens Dogfooding Settings only through the validated factory `openWithConfig:onViewController:userSession:` with a captured native config/session;
- never calls the unavailable initializer that terminates with `brk #1`;
- retries idempotently as late frameworks load through the existing coalesced GraphQL/dyld bridge.

Internal settings whose controllers have independent validated entry points remain usable. Surfaces whose only route is the absent pinned socket remain unavailable until the complete native descriptor and row producer are present.

## Verified mapping

`src/BundleAssets/id_name_mapping_internal439.json` contains analyst-recovered aliases:

```text
167:308    is_employee_or_test_user_fallback
2698:80342 show_dogfooding_assistant
5021:6921  maisa_ux_variant
```

The full Mapping-V8 catalogue is reconstructed from the retained baseline and `Resources/mobileconfig/id_name_mapping_v8_delta.parts/part00...part08` by `tools/apply-idmap-v8.py`.

Validation requirements:

- baseline entries: `5581`
- target entries: `5584`
- target SHA-256: `06b7bd08ba4e21f8f54aaa01163847438b9a398e193a663d6f1b8befc8a43eb2`
- contiguous part names
- complete target ID coverage
- no duplicate target IDs

The generated JSON is embedded in `__DATA,__idmap`; the 439 aliases are embedded in `__DATA,__idmap439`.

## Scope

This patch restores the verified client-side employee fallback and Bug Reporter Internal Settings path. It does not impersonate backend authorization, invent server responses or claim to reconstruct the removed pinned plugin collection. Dogfooding Assistant remains hidden and blocked in the audited build because its socket provider is genuinely empty.
