# RyukGram v34.24 — iOS 26 UIKit/Liquid Glass menu chrome corrective

Base: `Ryukgram-Fork-v34.23-popover-morph-menu-corrective.zip`.

## What changed

- Added a reusable iOS 26 navigation title bubble (`SCIUIKit26TitleBubbleView`) backed by `UIGlassEffect` through the existing `SCIUIKit26GlassEffect` resolver.
- Installed/refreshed the title bubble from the common Liquid Glass view-controller chrome path, so settings pages and other tweak-owned navigation screens get the same pill-style title surface instead of a plain floating title.
- Increased the menu/page title font to a 19pt bold Dynamic Type-scaled font, both inside the title bubble and in fallback navigation bar title attributes.
- Removed the negative top insets from the main settings list, base settings list, app-icon picker, lock settings lists, and chat-background per-image sheet so rows no longer slide under the transparent nav/title area.
- Converted settings cells toward native `UITableViewStyleInsetGrouped` behavior with `UIListContentConfiguration`, `UIBackgroundConfiguration listGroupedCellConfiguration`, compact margins, native separators, and lighter panel alpha for better Liquid Glass translucency.
- Reworked `SCIOptionSheet` away from a fake blur container/popup body and into a native inset-grouped popover table, still anchored through `UIPopoverPresentationController` for UIKit morphing.
- Enlarged the wordmark popover width/row height so it no longer looks like the tiny custom font selector from the screenshot.
- Updated full-screen popup chrome to reapply common Liquid Glass table/collection styling instead of forcing solid table backgrounds.

## Files touched

- `src/UI/SCIUIKit26LiquidGlass.h`
- `src/UI/SCIUIKit26LiquidGlass.m`
- `src/UI/SCIPopupChrome.m`
- `src/UI/SCIOptionSheet.m`
- `src/Settings/SCISettingsViewController.m`
- `src/Settings/SCIBaseSettingsListViewController.m`
- `src/Settings/SCIAppIconPickerViewController.m`
- `src/Lock/UI/SCILockGroupDetailViewController.m`
- `src/Lock/UI/SCILockPasscodeRootViewController.m`
- `src/Lock/UI/SCILockTimeoutPickerViewController.m`
- `src/Features/ChatBackground/SCIChatBgPerImageSheet.m`

## Validation performed here

- `git diff --no-index --check` between the original unzip and patched tree: no whitespace errors.
- Checked that the remaining negative top content insets in the touched settings/menu surfaces were removed.

Full Theos build was not run in this container because `$THEOS`/the iPhoneOS26.2 SDK is not installed here.
