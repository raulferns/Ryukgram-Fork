# RyukGram — new Instagram(35) / FBSharedFramework(113) analysis

This patch is based on a fresh binary scan of the uploaded main executable and FBSharedFramework.

## Binary observations

- `Instagram(35)` still contains/imports `_IGMobileConfigBooleanValueForInternalUse`, EasyGating, MSGCSessioned, MCIExperiment/MCIExtension and `_XPluginsGetListLookupDataPair`.
- `FBSharedFramework(113)` still contains `IGFacebookUserInfo`, `IGDSLauncherConfig`, LiquidGlass helper/tabbar names and MobileConfig/EasyGating C symbol names.
- `IGFacebookUserInfo` was not present as an app-main class string, but it is present in FBSharedFramework; forcing it via runtime lookup can still be valid only after the framework class is loaded.
- `IGAdPlatformLogger_objc`, `AutofillInternalSettingsInstagram.IGAutofillInternalSettings`, `_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings`, and `_TtC24IGIdentitySwitcherGating30IGIdentitySwitcherGatingHelper` are present in the new main executable.

## Repo diagnosis

The Advanced section persisted `sci_internal_menus`, but `switchChanged:` did not call `SCIInternalMenusForceApplyNow()` when that switch changed. Result: the switch could show ON while no current-session runtime hook was installed.

This patch only changes that behavior:

- state still persists in NSUserDefaults;
- nothing is applied from `%ctor`/launch just because the pref is persisted;
- when the user toggles `Internal & Dogfood Menus` ON inside Settings, the existing `SCIInternalMenusForceApplyNow()` function is called once for the current session;
- no fan-out to `sci_force_mc_internal_use_all`, `sci_force_internal_settings_menu`, or other launch-dangerous prefs is restored.

## XPlugins

`SCIXPluginsLookupHook.txt` is still documentation-only and not compiled. That is intentional here: the prior watchdog stack went through `XPluginsGetListLookupDataPair` / `XPluginsGetDataPair` / `ASEventPublishInternal`. Do not re-enable XPlugins in this same patch.
