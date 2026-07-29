#import "SCIAdvancedHooks.h"
#import "SCIInternalMenusForce.h"
#import "../../Utils.h"
#import <Foundation/Foundation.h>

// On-toggle apply for the Dev hooks that are genuinely safe to install live.
//
// Employee/Internal for the new IG is a coordinated launch-time chain:
// SCIEmployeeInternal -> SCIInternalGlobalSafe (MobileConfig + Bug Reporter
// payload preflight + validated Dogfood openers).
// Installing only one layer after a live preference change could expose a stale
// Assistant row before its XPlugins payload guard is installed. Therefore those
// keys intentionally require an app restart; their method bodies read prefs live
// once the complete chain has been installed.

void SCIIGDSEnsureHooksInstalled(void);

static BOOL SCIKeyEqualsAny(NSString *key, NSArray<NSString *> *keys) {
    if (!key.length) return NO;
    for (NSString *candidate in keys) if ([key isEqualToString:candidate]) return YES;
    return NO;
}

static NSArray<NSString *> *SCIInternalSettingsKeys(void) {
    return @[@"sci_employee_internal",
             @"sci_force_ig_internal_employee",
             @"sci_force_ig_is_employee",
             @"sci_force_internal_settings_menu",
             @"sci_force_internal_settings_loggedout",
             @"sci_force_internal_settings_availability",
             @"sci_apply_internal_native",
             @"sci_apply_force_bloks",
             @"sci_apply_bloks_prefetch"];
}

static NSArray<NSString *> *SCIIGDSKeys(void) {
    return @[@"sci_igds_launcher_all",
             @"sci_igds_liquidglass",
             @"sci_apply_liquidglass",
             @"sci_igds_prism",
             @"sci_igds_lg_inappnotif",
             @"sci_igds_lg_toast",
             @"sci_igds_lg_toastpeek",
             @"sci_igds_lg_iconbarbtn",
             @"sci_igds_lg_navstylepin",
             @"sci_igds_lg_easeinout",
             @"sci_igds_lg_cgblur",
             @"sci_igds_lg_glyphopt",
             @"sci_igds_lg_debugger",
             @"sci_igds_nav_ctxmenu",
             @"sci_igds_nav_rounded",
             @"sci_igds_nav_tzoom",
             @"sci_igds_nav_bottomsheet",
             @"sci_igds_animated_waveform",
             @"sci_igds_async_font",
             @"sci_igds_direct_channels",
             @"sci_igds_pagevc_fix",
             @"sci_igds_wordmark_isIGWordmark1aEnabled",
             @"sci_igds_wordmark_isIGWordmark1aAltEnabled",
             @"sci_igds_wordmark_isIGWordmark1bEnabled",
             @"sci_igds_wordmark_isIGWordmark1bAltEnabled"];
}

void SCIAdvancedHooksApplyForChangedKey(NSString *key, BOOL isOn) {
    if (!isOn || !key.length) return;
    @autoreleasepool {
        if ([key isEqualToString:@"sci_internal_menus"]) {
            (void)SCIInternalMenusForceApplyNow();
        }
        if (SCIKeyEqualsAny(key, SCIInternalSettingsKeys())) {
            // Deliberately no partial live install. The complete safe chain is
            // installed from its constructors on the next app launch.
            return;
        }
        if (SCIKeyEqualsAny(key, SCIIGDSKeys())) SCIIGDSEnsureHooksInstalled();
    }
}
