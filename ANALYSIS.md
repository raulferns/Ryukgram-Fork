# Instagram / FBShared binary validation

This branch was revalidated against the binaries supplied for the current
Developer-menu revamp. Runtime-dependent code must fail closed when an ABI or
instruction shape changes; names alone are never treated as proof that a call is
safe.

## Inputs

- `Instagram(1)`
  - SHA-256: `081dc7dd77e29f834b2b2b85606857a811df965a67d0a70f65d54dd4c613f9d0`
  - UUID: `4c4c44ae-5555-3144-a12c-ea6364602eb8`
  - arm64 Mach-O executable, image base `0x100000000`
  - 56 sections, 37,899 symbols in the LIEF inventory
- `FBSharedFramework(2)`
  - SHA-256: `2fe29f46c48827cafd55e13a5a9abc2052aca855c50f95a1c2a4028c8f0792d6`
  - UUID: `4c4c447b-5555-3144-a1ea-03f1c30a2679`
  - arm64 Mach-O dylib, image base `0x0`
  - 56 sections, 33,720 symbols in the LIEF inventory

The files were inspected with LIEF 1.0.0 and Capstone 5.0.9. The Objective-C
inventory parser also classified method bodies so a real implementation could be
distinguished from a `ret`, constant-return stub or branch thunk.

## Native Developer / Bug Report menu

The current Instagram binary still contains the real native entry point:

| Owner | Selector | ABI | VM address | Body |
|---|---|---:|---:|---|
| `IGWindow` | `showDebugMenu` | `v16@0:8` | `0x1064e2b1c` | implemented |
| `IGWindow` | `showDebugMenuWithEntryPoint:` | `v24@0:8q16` | `0x1091022d0` | implemented |

`IGBugReportMenuViewController` is also fully implemented. Both initializer
forms are present, including the current form with separate visibility inputs
for Internal Settings, Logged-out Internal Settings, Shake to Report and
Dogfooding Assistant:

```text
initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:
entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:
showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:
showDogfoodingAssistant:maisaUXVariantRawValue:
```

The table datasource, selection handlers and action-cell handlers all have real
bodies. The release binary did not remove this menu.

The previous RyukGram failure was self-inflicted: `RYGDebugBlockGroup` replaced
`-[IGWindow showDebugMenu]` with an empty method and made an
`IGBugReportUploader` initializer return `nil`. Both hooks are removed. RyukGram
now asks the active `IGWindow` to open the menu, allowing Instagram to build its
real device session, user session, logging, endpoint and uploader graph. The
initializer hook changes only the four proven visibility arguments when the
user enables Internal/Dogfood mode.

## Native Dogfooding surfaces

The following are implemented in the supplied executable:

| Surface | Proven entry point | ABI / address |
|---|---|---|
| Dogfooding Settings | `+[IGDogfoodingSettings openWithConfig:onViewController:userSession:]` | `v40@0:8@16@24@32`, `0x109994c78` |
| Dogfooding Settings VC | `-initWithConfig:userSession:` | `@32@0:8@16@24`, `0x1053b9d7c` |
| Direct Notes Dogfood | `+notesDogfoodingSettingsOpenOnViewController:userSession:` | `v32@0:8@16@24`, `0x106002b74` |

The settings controller has real section/row builders, selection handlers,
toggle handling and restart behavior. Config and user-session objects are
captured only from these native flows; they are never fabricated.

`IGDogfoodingAssistantLauncherClient.sessionBrowserViewController(userSession:)`
exists only as a Swift symbol in this build. There is no Objective-C selector
that can be safely sent or hooked. The Developer menu therefore routes
Dogfooding Assistant through `IGWindow`'s native Bug Report provider/socket row
instead of inventing `sessionBrowserViewController:userSession:` or
`overrideLauncherWithUserSession:...` selectors.

## EasyGating

In `FBSharedFramework(2)`:

- `_EasyGatingGetBoolean_Internal_DoNotUseOrMock`: `0x528a48`
- `_EasyGatingPlatformGetBoolean`: `0x528df0`
- mapper reached by the wrapper's first direct `BL`: `0x528f14`

The current wrapper calls the mapper at `0x528a68`; the mapper is not located at
the old hard-coded `wrapper + 0x34`. Its validated dispatch shape begins:

```asm
mov   w11, w0
stp   x29, x30, [sp, #-0x10]!
mov   x29, sp
adrp  x9, ...
add   x9, x9, ...
adr   x10, ...
ldrh  w8, [x9, x11, lsl #1]
add   x10, x10, x8, lsl #2
br    x10
```

RyukGram now scans direct `B`/`BL` targets in the wrapper prologue and accepts a
mapper only when this complete ARM64 shape matches. It reads the mapper to
recover the final gate ID, but never modifies signed FBShared `__TEXT`; the
wrapper import is intercepted through fishhook.

## ABProps / MobileConfig runtime authority

Instagram does not expose WhatsApp's `WAABProperties` class. The equivalent
typed experiment surface in this app is FBShared MobileConfig's exported native
parameter table. Consequently, the ABProps Runtime Browser is built from the
live table, not from `id_name_mapping.json`. A mapping can decorate a row with a
name only when that exact config/parameter already exists in the binary; it can
never create a row, type or PID.

Current FBShared exports:

- `mobileconfig::typeFromParameter(unsigned long long)`: `0x923d88`
- `mobileconfig::kMobileConfigParamsSize`: `0x1f29b68`
- `mobileconfig::kMobileConfigParamsList`: `0x2abbbb8`

`typeFromParameter` is exactly:

```asm
ubfx x0, x0, #48, #6
ret
```

`kMobileConfigParamsSize` contains `0x897d`, or **35,197** rows. The chained
pointer resolves to `0x226bea0`; the validated row stride is 40 bytes:

- `+16`: parameter index (`uint32_t`)
- `+20`: ordinal mix; low 16 bits are the ordinal
- `+24`: type/serial; high 16 bits are the native type
- `+36`: config number (`uint32_t`)

All 35,197 rows have one of the four supported types:

| Native type | Meaning | Rows |
|---:|---|---:|
| 1 | bool | 24,423 |
| 2 | int64 | 7,169 |
| 3 | string | 1,501 |
| 4 | double | 2,104 |

### Live manager wiring

The supplied Instagram binary contains the active-session chain:

```text
+[FBMobileConfigFBTGlobalSessionManager sharedInstance]
  -> currentSessionContextManagerHolder
  -> mcFbtManager
  -> mobileconfig
  -> FBMobileConfigContextManager / IGMobileConfigContextManager
```

The previous browser captured a manager in one translation unit while
`liveValueFor:` read a different static `gManager`, so the UI commonly returned
`nil`. `managerForPid:` now resolves the active-session manager through the chain
above and stores it in the same manager authority used by typed reads.

The current context-manager getter families have concrete ABIs for bool, int64,
string and double, including their options/default variants. RyukGram's getter
owner validates each encoding before installation and keeps its hot path to
integer arithmetic plus atomic loads.

### StartupConfigs writer ABI

The current `FBMobileConfigStartupConfigs` methods are:

```text
+getInstance                         @16@0:8
-setOverrideForParam:andValue:       B32@0:8Q16@24
-removeOverrideForParam:             v24@0:8Q16
```

The old RyukGram code required `setOverrideForParam:andValue:` to return `void`,
so it rejected the current `BOOL` ABI and never called the native writer.
The implementation now follows WATweaks: it accepts the current Boolean return,
uses the returned acceptance result, and supports `void` only as a validated
legacy compatibility form.

### Persistence and native-file boundary

The runtime model follows the WATweaks separation of responsibilities:

- typed PID/value overrides persist in RyukGram's own store;
- exact getter hooks provide immediate effective behavior;
- `FBMobileConfigStartupConfigs` receives typed native overrides;
- the complete effective configuration can be exported with PID, type, names,
  effective value and override state;
- importing that snapshot restores only explicit overrides, never all server
  values;
- Instagram's `mc_overrides.json` and `id_name_mapping.json` remain read-only.

The old delayed writer that regenerated `mc_overrides.json` after every edit has
been removed. `mc_overrides.plist` is the single RyukGram persistence authority.
Local canonical JSON is portable import/export material only and is never
promoted implicitly when Instagram returns to the foreground.

## Generic typed Runtime Browser

The Objective-C browser enumerates classes only in the selected loaded Mach-O
image and indexes methods on demand. A method is editable only when runtime
metadata proves a no-argument getter with one of these return classes:

```text
BOOL/char, signed and unsigned integers, float, double, Foundation object
```

Persistence stores exact class name, selector, method kind, return type and a
Foundation-safe encoded value. Hooks use the correctly typed function ABI.
Lifecycle/ownership selectors are blocked. Applying persisted generic hooks is
explicit, matching WATweaks' cold-start policy; there is no constructor-wide
runtime scan or automatic generic hook replay.

## Meta / Family Local Experiments

The current native path is also complete:

- `+[FDIDExperimentGenerator generateConfigs]` — `0x109645e54`
- `-[FDIDExperimentGenerator initWithFamilyDeviceID:logger:]` — `0x1053c239c`
- `+[OdinFamilyDeviceIDSignalProvider currentFamilyDeviceID]` — `0x103246700`
- `-[MetaLocalExperimentListViewController initWithExperimentConfigs:experimentGenerator:]` — `0x10551c750`

RyukGram now pairs FDID configs with the current Odin family-device ID and the
FDID generator. It no longer initializes an unrelated LID generator with a nil
device ID.

## Validation policy

`scripts/validate-source.py` now rejects the regressions responsible for the
broken menu: empty `IGWindow` hooks, nil Bug Report uploader hooks, fabricated
Swift-only Dogfood selectors, fixed EasyGating mapper offsets, void-only
StartupConfigs ABI checks, mapping-created MobileConfig rows, native JSON
writers and automatic constructor replay of generic typed runtime hooks.
