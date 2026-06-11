# Advanced hooks local-pattern fix

This patch removes the global Advanced hooks replay observer.

## Reason

The previous implementation added a constructor that observed `UIApplicationDidBecomeActiveNotification`
and swept all persisted Advanced preferences through `SCIAdvancedHooksApplyForCurrentPrefs()`.
That created a new lifecycle-driven global replay path, unlike the rest of the tweak.

The correct local pattern is:

1. The hook file owns its installer.
2. The installer is idempotent.
3. The installer reads prefs once before installing and returns if every related pref is OFF.
4. The replacement functions use static/cache state or pref checks and return original when OFF.
5. The Settings switch persists the toggle and invokes only the changed hook installer for the current session.
6. No post-launch global sweep and no duplicate installer calls from `switchChanged:`.

## Files touched

- `SCIAdvancedHooks.h/m`: keep only changed-key dispatch; remove current-pref replay and constructor.
- `SCISettingsViewController.m`: remove duplicate MobileConfig/EasyGating/Sessioned installer calls.
- MobileConfig/EasyGating/Sessioned hooks: restore their own gated `%ctor` installers.
- Employee/InternalBuild/InternalSettings hooks: restore their own gated `%ctor` installers.

`SCIInternalMenusForce.x` is intentionally not changed by this patch because its previous launch-time path
was the one tied to the scene-create watchdog. It remains explicit-toggle/session-scoped.
