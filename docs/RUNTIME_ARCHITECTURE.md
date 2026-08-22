# Dogfood Runtime Architecture

The `dogfood` runtime architecture follows three strict ownership rules:

1. **Discovery is UI-only.** Runtime Browser enumerates loaded images, class names, and then class methods only after an explicit Developer action. No Runtime Browser index or global Objective-C catalogue is built during app launch.
2. **Persistence replays exact identities.** `RYGRuntimeHookManager` persists `{class, selector, meta, ABI, value}` specs and keeps forced values in memory for hot-path reads. Relaunch restores only those exact specs. Legacy v4/v5 stores are migrated once and oversized legacy stores are quarantined instead of replayed blindly.
3. **Native Developer state has one bootstrap.** Prism/list setters, Liquid Glass helper state, Bug Report visibility, Dogfooding capture and EasyGating are restored once after application launch. MobileConfig catalogue resolution is never part of startup; dogfood MobileConfig is resolved only from an explicit user action.

The following competing implementations are intentionally removed and must not return: `RYGDeveloperBootstrapOwner`, `RYGDeveloperPersistenceBootstrap`, `RYGDeveloperSurfaceFastPath`, `RYGRuntimeFastPath`, `RYGRuntimeOverrideOwner`, and `RYGRuntimeIndex`.

C-symbol overrides remain limited to rebindable imports and explicit integer/pointer BOOL ABIs. No signed `__TEXT` patching is used.
