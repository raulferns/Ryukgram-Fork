# New Instagram internal/employee implementation

## Audited binaries

- Instagram SHA-256: `fa19f499c560b188d2802e3a1a36642209ee6e42d7639c1ebe010f14b2c4cd9b`
- FBSharedFramework SHA-256: `a79c110c59e7c16e5608227e12807583c1afcf80cb2a2e38302f147dbf99c12b`
- Both Mach-O images are decrypted (`cryptid = 0`).

## Employee/test-user path

The old named descriptors `_ig_is_employee` and `_ig_is_employee_or_test_user` are absent from this build. The canonical fallback is inline through `FBMobileConfigContextManager`:

- selector family: `getBool:`, `getBool:withOptions:` and default/no-logging variants;
- encoded parameter: `0x008100A700000134`;
- low parameter index: `0x134` (`308`);
- consumer helper: Instagram `0x104177F3C`;
- generated fragment selector: `asIGUserIsEmployeeOrTestUserFragment`.

The runtime hook forces only this exact parameter while the Employee/Internal master is enabled. It does not force all MobileConfig booleans.

## Internal Settings availability

`IGInternalSettingsAvailabilityStatus` is an enum:

- `0`: allowed;
- `1`: unavailable because the internal rollout/plugin is absent (or Sapienz);
- `2`: denied because the account is not employee/test-user.

The current and legacy Bug Reporter initializers are hooked through their validated Objective-C ABIs. `SCIInternalGlobalSafe.x` is the single authoritative implementation: it forwards through the older Employee/Internal hook under a thread-local menu-mutation suppression, then enforces status `0`, `showInternalSettings = YES` and provider-aware Assistant visibility before native lifecycle code observes the object. The GraphQL/dyld bridge calls the same idempotent exported installer as late frameworks load.

## XPlugins ABI correction

`XPluginsGetDataFuncOrAbort` returns a function pointer. Executing that provider returns a two-register data pair:

```c
struct XPluginsDataPair {
    const void *data;   // x0
    uintptr_t count;    // x1
};
```

It is not a BOOL provider.

### `internal_only`

- hash: `0x64327C01`;
- table index: `1788` of `2305`;
- provider: Instagram `0x102BD80E4`;
- result: `{ NULL, 0 }`.

Consumers include code that dereferences the returned data pointer, including `ldr w20, [x0, #8]`. Returning `x0 = 1` would therefore create a false row followed by an invalid dereference. No fishhook/rebinding or sentinel bridge is installed.

### Dogfooding Assistant socket

- hash: `0x7FBC8058`;
- provider: the same empty provider at Instagram `0x102BD80E4`;
- result: `{ NULL, 0 }`.

The Dogfooding Assistant MobileConfig parameter is `0x00810A8A000139D6`, but it is not forced when the native socket payload is absent.

## Safe surface behavior

When the employee/internal master is enabled:

- the exact employee/test-user MobileConfig parameter is forced to `YES`;
- the native Internal Settings row/status path remains enabled through the validated Bug Reporter initializer;
- the current and legacy Bug Reporter initializers receive `showDogfoodingAssistant = NO` when the XPlugins socket payload is empty;
- the Assistant scalar is cleared before native `viewDidLoad` / `viewDidAppear`, not merely after the table is built;
- tapping a stale Assistant row is intercepted before Instagram's native handler;
- `SCIDogfoodObjectRuntime` opens Dogfooding Settings only through the validated class factory `openWithConfig:onViewController:userSession:` and only with a captured native config/session;
- the unavailable `initWithConfig:userSession:` fallback is never called;
- `SCIInternalMenusLauncher.openDogfoodingSettingsVC` is routed through the same safe factory path.

The implementation deliberately does not claim a global XPlugins bridge. Internal surfaces that require missing plugin payload/function IDs remain unavailable until a real compatible provider is present in the app.

## Mapping V8

The build reconstructs the exact uploaded `Mapping-V8.json` from the repository baseline plus the checked split delta in `Resources/mobileconfig/id_name_mapping_v8_delta.parts/`:

- baseline entries: `5581`;
- V8 entries: `5584`;
- target SHA-256: `06b7bd08ba4e21f8f54aaa01163847438b9a398e193a663d6f1b8befc8a43eb2`.

`tools/apply-idmap-v8.py` requires contiguous `part00...partNN` files, refuses a stale baseline, checks full ID coverage and verifies the final SHA before the generated JSON is embedded in the dylib's `__DATA,__idmap` section.
