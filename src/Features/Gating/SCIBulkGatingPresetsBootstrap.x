// SCIBulkGatingPresetsBootstrap.x
//
// Startup restoration of persisted getter overrides for features that MUST
// take effect during the IG launch path (before the main UI is built).
//
// SAFETY CONTRACT:
//   1. Pref reads via CFPreferences (CF-only, zero ObjC → zero MC-recursion risk).
//   2. SCIRuntimeBoolForce.forceClassNamed:… uses class_replaceMethod with a
//      constant-returning block — no ObjC inside the block, no self recursion.
//   3. All class lookups via objc_getClass: returns nil if absent → silent no-op.
//   4. SCIBulkGatingPresets calls (wordmark, gating-catalog restore) are deferred
//      to main queue after IG completes application init to avoid NSUserDefaults
//      touching MobileConfig before IG's own %ctor chain finishes.
//
// REASON THESE FILES WERE REMOVED PREVIOUSLY (SCILaunchAutoForceHooks.removed.txt):
//   They used SCIBulkGatingPresets/SCIGatingCatalog which call NSUserDefaults.
//   Replaced here by SCIRuntimeBoolForce (safe) + dispatch_async for the catalog.

#import "SCIRuntimeBoolForce.h"
#import "SCIBulkGatingPresets.h"
#import "SCIGatingCatalog.h"
#import <CoreFoundation/CoreFoundation.h>

static BOOL sci_cfpref(const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!k) return NO;
    Boolean exists = false;
    Boolean v = CFPreferencesGetAppBooleanValue(k, kCFPreferencesCurrentApplication, &exists);
    CFRelease(k);
    return exists ? (BOOL)v : NO;
}

%ctor {
    @autoreleasepool {

        // ── Status Bar Old School ─────────────────────────────────────────
        // IGThrowbackChromeExperimentHelper.isEnabled (Swift, instance method)
        // Classe: _TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper
        if (sci_cfpref("sci_statusbar_oldschool")) {
            [SCIRuntimeBoolForce
                forceClassNamed:@"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper"
                       selector:@"isEnabled"
                    classMethod:NO
                          value:YES];
        }

        // ── Story Tray ────────────────────────────────────────────────────
        // IGHomecomingConfiguration getters (Swift, instance methods)
        // Classe: _TtC18IGNavConfiguration25IGHomecomingConfiguration
        if (sci_cfpref("sci_story_tray")) {
            [SCIRuntimeBoolForce forceInstanceSelectors:@[
                @"isStoriesTrayOnAllTabsEnabled",
                @"showCinemaStoriesTrayOnSwipeUp",
                @"isDynamicTabStoryGridEnabled",
                @"isVerticalStoriesTray",
                @"isFeedCullingOnStoriesAccessEnabled",
                @"isHomecomingStoriesAccessFaceClusterEnabled",
            ] onClassNamed:@"_TtC18IGNavConfiguration25IGHomecomingConfiguration"
               value:YES];

            // IGNavConfiguration base: enableStoriesTabHeaderButton
            [SCIRuntimeBoolForce
                forceClassNamed:@"_TtC18IGNavConfiguration18IGNavConfiguration"
                       selector:@"enableStoriesTabHeaderButton"
                    classMethod:NO
                          value:YES];
        }

        // ── IGDS LauncherConfig — LiquidGlass master ──────────────────────
        // Confirmados via binary analysis do IG 433 + IGDSLauncherConfig_FULL_header.c
        if (sci_cfpref("sci_igds_liquidglass") || sci_cfpref("sci_igds_launcher_all")) {
            [SCIRuntimeBoolForce forceInstanceSelectors:@[
                @"canUseInternalLiquidGlassDebugger",
                @"isLiquidGlassCGContextBlurEnabled",
                @"isLiquidGlassEaseInOutBlurEnabled",
                @"isLiquidGlassIconBarButtonEnabled",
                @"isLiquidGlassInAppNotificationEnabled",
                @"isLiquidGlassNavigationContentStylePinningEnabled",
                @"isLiquidGlassToastEnabled",
                @"isLiquidGlassToastPeekEnabled",
                @"isContextMenuMigrationEnabled",
            ] onClassNamed:@"IGDSLauncherConfig" value:YES];
        }

        // ── IGDS LauncherConfig — Prism master ────────────────────────────
        if (sci_cfpref("sci_igds_prism") || sci_cfpref("sci_igds_launcher_all")) {
            [SCIRuntimeBoolForce forceInstanceSelectors:@[
                @"isPrismControlsEnabled", @"isPrismDefaultTooltipEnabled",
                @"isPrismToastsEnabled", @"isPrismAlertDialogEnabled",
                @"isPrismAvatarRingEnabled", @"isPrismContextMenuEnabled",
                @"isPrismContextMenuRefactorEnabled", @"isPrismIndigoButtonEnabled",
                @"isPrismIndigoButtonM1DirectEnabled", @"isIGBPrismEnabled",
                @"isPrismIndigoActionCellsEnabled", @"isPrismMediaButtonsEnabled",
                @"isPrismBottomSheetEnabled", @"isPrismAllUserAssetsEnabled",
                @"isPrismFollowRelatedUserAssetsEnabled", @"isPrismCreationIconsEnabled",
                @"isPrismCommentsEmptyStateEnabled", @"isPrismOverflowMenuEnabled",
                @"isPrismOverflowMenuStampWidthIncreased",
                @"isPrismDividersUpdateEnabled", @"isPrismDividersCommentsUpdateEnabled",
                @"isPrismDividersEditReelEnabled", @"isPrismDividersNotificationsUpdateEnabled",
                @"isPrismDividersProfileUpdateEnabled", @"isPrismDividersShareSheetUpdateEnabled",
            ] onClassNamed:@"IGDSLauncherConfig" value:YES];
        }

        // ── IGDS LauncherConfig — getters individuais do browser ──────────
        // Os overrides per-getter salvos pelo SCIIGDSLauncherConfigViewController
        // ficam em sci_igds_lg_* / sci_igds_prism_detail_* etc.
        // Aqui lemos apenas os master keys; os individuais são restaurados via
        // SCIGatingCatalog.installPersistedDirectOverrideHooks (dispatch abaixo).

        // ── Deferred: restaurar SCIGatingCatalog overrides + wordmark ─────
        // Executado no main queue após IG finalizar sua inicialização de app.
        // Seguro porque:
        //   - MSHookMessageEx em objetos ObjC é thread-safe (modifica vtable)
        //   - NSUserDefaults já está estável nesse ponto
        //   - IG não relê getters de config BOOL após este ponto (relê no próximo launch)
        dispatch_async(dispatch_get_main_queue(), ^{
            // Restaurar TODOS os overrides persistidos do Feature Gatings browser
            [SCIGatingCatalog installPersistedDirectOverrideHooks];

            // Restaurar wordmark (aplica e instala KVO observer)
            [SCIBulkGatingPresets installWordmarkPrefObserver];
            NSString *wv = [[NSUserDefaults standardUserDefaults]
                            stringForKey:@"sci_ig_wordmark_variant"];
            if (wv && ![wv isEqualToString:@"off"]) {
                [SCIBulkGatingPresets applyIGWordmarkMode:wv];
            }

            // Restaurar LiquidGlass (BulkGatingPresets path — classes Swift)
            // Verifica se há overrides persistidos para IGDSLauncherConfig.isLiquidGlassInAppNotificationEnabled
            NSNumber *lgState = [SCIGatingCatalog
                runtimeBoolOverrideStateForClass:@"IGDSLauncherConfig"
                                        selector:@"isLiquidGlassInAppNotificationEnabled"
                                     classMethod:NO];
            if (lgState != nil && lgState.boolValue) {
                [SCIBulkGatingPresets applyLiquidGlass:YES];
            }
        });
    }
}
