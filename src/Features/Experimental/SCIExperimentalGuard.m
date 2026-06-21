#import "SCIExperimentalGuard.h"
#import "../../Utils.h"

static NSString *const kCounterKey = @"sci_exp_unstable_launches";
static NSInteger  const kThreshold = 3;
static BOOL gDidReset = NO;

@implementation SCIExperimentalGuard

+ (NSArray<NSString *> *)allPrefKeys {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"igt_homecoming",
            @"igt_prism",
            @"igt_directnotes_friendmap",
            @"sci_story_tray",
            @"sci_ig_wordmark_variant",
            @"sci_statusbar_oldschool",
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
            // Legacy Direct Notes reply prefs: kept only so reset clears old installs.
            @"igt_quicksnap",
            @"igt_directnotes_audio_reply",
            @"igt_directnotes_avatar_reply",
            @"igt_directnotes_gifs_reply",
            @"igt_directnotes_photo_reply",
        ];
    });
    return keys;
}

+ (BOOL)anyEnabled {
    for (NSString *k in [self allPrefKeys]) {
        if ([k isEqualToString:@"sci_ig_wordmark_variant"]) {
            NSString *v = [SCIUtils getStringPref:k];
            if (v.length && ![v isEqualToString:@"off"]) return YES;
            continue;
        }
        if ([SCIUtils getBoolPref:k]) return YES;
    }
    return NO;
}

+ (void)resetAll {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in [self allPrefKeys]) {
        if ([k isEqualToString:@"sci_ig_wordmark_variant"]) [ud setObject:@"off" forKey:k];
        else [ud setBool:NO forKey:k];
    }
}

+ (BOOL)didResetThisLaunch { return gDidReset; }

+ (void)load {
    if (![self anyEnabled]) return;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger c = [ud integerForKey:kCounterKey] + 1;

    if (c >= kThreshold) {
        [self resetAll];
        [ud removeObjectForKey:kCounterKey];
        gDidReset = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SCINotifyWarning(SCI_NOTIF_EXPERIMENTAL_WARN,
                             SCILocalized(@"Experimental flags reset"),
                             SCILocalized(@"Disabled after repeated crashes."));
        });
        return;
    }

    [ud setInteger:c forKey:kCounterKey];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCounterKey];
    });
}

@end
