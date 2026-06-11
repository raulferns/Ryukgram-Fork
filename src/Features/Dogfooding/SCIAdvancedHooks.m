#import "SCIAdvancedHooks.h"
#import "SCIInternalMenusForce.h"
#import "../../Utils.h"
#import <Foundation/Foundation.h>

void SCIInstallMobileConfigInternalUseGateIfNeeded(void);
void SCIInstallEasyGatingHooksIfNeeded(void);
void SCIInstallSessionedMCGateHooksIfNeeded(void);
void SCIInstallIGEmployeeForceHooksIfNeeded(void);
void SCIInstallInternalBuildHooksIfNeeded(void);
void SCIInstallInternalSettingsMenuHookIfNeeded(void);
void SCIIGDSEnsureHooksInstalled(void);

static BOOL SCIKeyEqualsAny(NSString *key, NSArray<NSString *> *keys) {
    if (!key.length) return NO;
    for (NSString *candidate in keys) if ([key isEqualToString:candidate]) return YES;
    return NO;
}


static NSArray<NSString *> *SCIMobileConfigKeys(void) {
    return @[@"sci_force_all_mc_gates",
             @"sci_force_mc_internal_use_all",
             @"sci_force_mc_internal_use_boolean",
             @"sci_force_ig_internal_apps_installed_after_ios18",
             @"sci_force_minos_dogfood_mek_encryption"];
}

static NSArray<NSString *> *SCIEasyGatingKeys(void) {
    return @[@"sci_force_all_mc_gates",
             @"sci_force_easy_gating_all",
             @"sci_force_easy_gating_internal",
             @"sci_force_easy_gating_platform",
             @"sci_force_easy_gating_auth",
             @"sci_force_easy_gating_mcq"];
}

static NSArray<NSString *> *SCISessionedMCKeys(void) {
    return @[@"sci_force_all_mc_gates",
             @"sci_force_sessioned_mc_all",
             @"sci_force_msgc_sessioned_boolean",
             @"sci_force_mci_extension_boolean",
             @"sci_force_mci_experiment_boolean"];
}

static NSArray<NSString *> *SCIEmployeeObjCKeys(void) {
    return @[@"sci_internal_menus",
             @"sci_force_ig_internal_employee",
             @"sci_force_ig_is_employee",
             @"sci_force_employee_defaults_persist",
             @"sci_force_ig_featured_internal_badge",
             @"sci_force_ig_inbox_internal_badge",
             @"sci_force_ig_creation_internal_label",
             @"sci_force_ig_launch_debug_info",
             @"sci_force_ig_launch_debug_info_v2",
             @"sci_force_ig_story_debug_underlay"];
}

static NSArray<NSString *> *SCIInternalSettingsKeys(void) {
    return @[@"sci_force_internal_settings_menu",
             @"sci_force_internal_settings_loggedout",
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
        if (SCIKeyEqualsAny(key, SCIMobileConfigKeys())) SCIInstallMobileConfigInternalUseGateIfNeeded();
        if (SCIKeyEqualsAny(key, SCIEasyGatingKeys())) SCIInstallEasyGatingHooksIfNeeded();
        if (SCIKeyEqualsAny(key, SCISessionedMCKeys())) SCIInstallSessionedMCGateHooksIfNeeded();

        if ([key isEqualToString:@"sci_internal_menus"]) (void)SCIInternalMenusForceApplyNow();
        if (SCIKeyEqualsAny(key, SCIEmployeeObjCKeys())) {
            SCIInstallIGEmployeeForceHooksIfNeeded();
            SCIInstallInternalBuildHooksIfNeeded();
        }
        if (SCIKeyEqualsAny(key, SCIInternalSettingsKeys())) SCIInstallInternalSettingsMenuHookIfNeeded();
        if (SCIKeyEqualsAny(key, SCIIGDSKeys())) SCIIGDSEnsureHooksInstalled();
    }
}
