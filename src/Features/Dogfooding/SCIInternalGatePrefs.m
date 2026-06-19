#import "SCIInternalGatePrefs.h"
#import "../../Utils.h"

static NSString *const kSCIInternalGateCrashGuardEnabledKey = @"sci_internal_gate_crash_guard_enabled";
static NSString *const kSCIInternalGateCrashPendingKeysKey = @"sci_internal_gate_crash_pending_keys";
static NSString *const kSCIInternalGateCrashDisabledKeysKey = @"sci_internal_gate_crash_disabled_keys";
static NSString *const kSCIInternalGateCrashLastSourceKey = @"sci_internal_gate_crash_last_source";

static NSString *const kSCIForceIGObjCMasterKey = @"sci_force_ig_internal_employee";
static NSString *const kSCIMobileConfigMasterKey = @"sci_force_mc_internal_use_all";
static NSString *const kSCIMobileConfigCustomOverridesKey = @"sci_mobileconfig_custom_overrides";

@implementation SCIInternalGatePrefs

+ (NSArray<NSString *> *)allGateKeys {
    return @[
        kSCIForceIGObjCMasterKey,
        @"sci_force_ig_is_employee",
        @"sci_force_employee_defaults_persist",
        @"sci_force_ig_featured_internal_badge",
        @"sci_force_ig_inbox_internal_badge",
        @"sci_force_ig_creation_internal_label",
        @"sci_force_ig_launch_debug_info",
        @"sci_force_ig_launch_debug_info_v2",
        @"sci_force_ig_story_debug_underlay",
        kSCIMobileConfigMasterKey,
        @"sci_force_all_mc_gates",
        @"sci_force_mc_internal_use_boolean",
        @"sci_force_ig_internal_apps_installed_after_ios18",
        @"sci_force_minos_dogfood_mek_encryption",
        @"sci_force_easy_gating_all",
        @"sci_force_easy_gating_internal",
        @"sci_force_easy_gating_auth",
        @"sci_force_easy_gating_mcq",
        @"sci_force_easy_gating_platform",
        @"sci_force_sessioned_mc_all",
        @"sci_force_msgc_sessioned_boolean",
        @"sci_force_mci_experiment_boolean",
        @"sci_force_mci_extension_boolean",
        @"sci_force_mobileconfig_overrides",
        @"sci_force_mobileconfig_try_update",
        @"sci_force_mobileconfig_force_update",
        @"sci_force_internal_settings_menu",
        @"sci_force_internal_settings_loggedout",
        @"sci_force_igplus_all",
        @"sci_igplus_eligibility",
        @"sci_igplus_has_access",
        @"sci_igplus_any_active",
        @"sci_igplus_custom_lists",
        @"sci_igplus_story_superlikes",
        @"sci_igplus_search_story_viewers",
        @"sci_igplus_story_extend",
        @"sci_igplus_story_rewatch",
        @"sci_igplus_story_peeks",
        @"sci_igplus_story_spotlight",
        @"sci_igplus_silent_post_highlights",
        @"sci_igplus_dm_peek",
        @"sci_igplus_custom_app_icon",
        @"sci_igplus_branded_threads",
        @"sci_igplus_timestamp_viewers",
        @"sci_igplus_custom_bio_font",
        @"sci_igplus_silent_post_profile",
        @"sci_igplus_pinned_posts_limit",
        @"sci_igplus_story_peek_active",
        @"sci_force_aura_igplus",
    ];
}

+ (BOOL)boolForKey:(NSString *)key {
    return [SCIUtils getBoolPref:key];
}

+ (BOOL)objCGateEnabledForKey:(NSString *)key {
    return [self boolForKey:kSCIForceIGObjCMasterKey] || (key.length && [self boolForKey:key]);
}

+ (BOOL)mobileConfigBoolGateEnabledForKey:(NSString *)key {
    return [self boolForKey:kSCIMobileConfigMasterKey] || (key.length && [self boolForKey:key]);
}

+ (BOOL)individualGateEnabledForKey:(NSString *)key {
    return key.length && [self boolForKey:key];
}

+ (NSDictionary *)mobileConfigCustomOverrides {
    NSDictionary *d = [SCIUtils getDictPref:kSCIMobileConfigCustomOverridesKey];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

+ (NSArray<NSString *> *)activeGateKeys {
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSString *key in [self allGateKeys]) {
        if ([SCIUtils getBoolPref:key]) [active addObject:key];
    }
    return active;
}

+ (void)installCrashGuardIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (![SCIUtils getBoolPref:kSCIInternalGateCrashGuardEnabledKey]) return;

        NSArray<NSString *> *pending = [SCIUtils getArrayPref:kSCIInternalGateCrashPendingKeysKey];
        if (pending.count) {
            NSMutableOrderedSet<NSString *> *disabled = [NSMutableOrderedSet orderedSetWithArray:pending];
            for (NSString *key in [self activeGateKeys]) [disabled addObject:key];
            for (NSString *key in disabled) [SCIUtils setPref:@NO forKey:key];
            [SCIUtils setPref:disabled.array forKey:kSCIInternalGateCrashDisabledKeysKey];
            [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
            [SCIUtils setPref:@"previous launch did not reach stable marker" forKey:kSCIInternalGateCrashLastSourceKey];
            [NSUserDefaults.standardUserDefaults synchronize];
            return;
        }

        NSArray<NSString *> *active = [self activeGateKeys];
        if (!active.count) return;

        [SCIUtils setPref:active forKey:kSCIInternalGateCrashPendingKeysKey];
        [SCIUtils setPref:@"armed" forKey:kSCIInternalGateCrashLastSourceKey];
        [NSUserDefaults.standardUserDefaults synchronize];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSArray<NSString *> *current = [SCIUtils getArrayPref:kSCIInternalGateCrashPendingKeysKey];
            if ([current isEqualToArray:active]) {
                [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
                [SCIUtils setPref:nil forKey:kSCIInternalGateCrashLastSourceKey];
            }
        });
    });
}

+ (NSArray<NSString *> *)crashDisabledKeys {
    NSArray *d = [SCIUtils getArrayPref:@"sci_internal_gate_crash_disabled_keys"];
    return [d isKindOfClass:NSArray.class] ? d : @[];
}

+ (void)resetCrashGuard {
    [SCIUtils setPref:nil forKey:@"sci_internal_gate_crash_pending_keys"];
    [SCIUtils setPref:nil forKey:@"sci_internal_gate_crash_disabled_keys"];
    [SCIUtils setPref:nil forKey:@"sci_internal_gate_crash_last_source"];
}

+ (void)resetCrashGuardAndRestoreKeys {
    NSArray<NSString *> *disabled = [self crashDisabledKeys];
    for (NSString *key in disabled) [SCIUtils setPref:@YES forKey:key];
    [self resetCrashGuard];
}

@end
