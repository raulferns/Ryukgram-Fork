#import "SCIInternalGatePrefs.h"
#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <limits.h>
#import <stdint.h>
#import <stdio.h>

static NSString *const kSCIInternalGateCrashGuardEnabledKey = @"sci_internal_gate_crash_guard_enabled";
static NSString *const kSCIInternalGateCrashPendingKeysKey = @"sci_internal_gate_crash_pending_keys";
static NSString *const kSCIInternalGateCrashPendingRuntimePlansKey = @"sci_internal_gate_crash_pending_runtime_plans";
static NSString *const kSCIInternalGateCrashDisabledKeysKey = @"sci_internal_gate_crash_disabled_keys";
static NSString *const kSCIInternalGateCrashDisabledRuntimePlansKey = @"sci_internal_gate_crash_disabled_runtime_plans";
static NSString *const kSCIInternalGateCrashLastSourceKey = @"sci_internal_gate_crash_last_source";
static NSString *const kSCIInternalGateCrashSessionKey = @"sci_internal_gate_crash_session_id";
static NSString *const kSCIInternalGateCrashStableKey = @"sci_internal_gate_crash_stable_session_id";
static NSString *const kSCIInternalGateCrashCleanExitKey = @"sci_internal_gate_crash_clean_exit_session_id";
static NSString *const kSCIRuntimePatchPlansKey = @"sci_runtime_patch_plans";
static const NSTimeInterval kSCIInternalGateCrashStableWindowSeconds = 4.0;

static NSString *const kSCIForceIGObjCMasterKey = @"sci_force_ig_internal_employee";
static NSString *const kSCIMobileConfigMasterKey = @"sci_force_mc_internal_use_all";
static NSString *const kSCIMobileConfigCustomOverridesKey = @"sci_mobileconfig_custom_overrides";

static char gSCICrashMarkerPath[PATH_MAX] = {0};
static struct sigaction gSCIOldSIGSEGV;
static struct sigaction gSCIOldSIGBUS;
static struct sigaction gSCIOldSIGABRT;
static struct sigaction gSCIOldSIGILL;
static struct sigaction gSCIOldSIGTRAP;

static size_t SCIAppendUnsigned(char *buf, size_t pos, size_t cap, unsigned value) {
    char tmp[16];
    size_t n = 0;
    do {
        tmp[n++] = (char)('0' + (value % 10));
        value /= 10;
    } while (value && n < sizeof(tmp));
    while (n && pos < cap) buf[pos++] = tmp[--n];
    return pos;
}

static void SCIWriteCrashMarker(int signo) {
    if (!gSCICrashMarkerPath[0]) return;
    int fd = open(gSCICrashMarkerPath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    char buf[32];
    size_t pos = 0;
    const char prefix[] = "signal:";
    for (size_t i = 0; i < sizeof(prefix) - 1 && pos < sizeof(buf); i++) buf[pos++] = prefix[i];
    pos = SCIAppendUnsigned(buf, pos, sizeof(buf), (unsigned)signo);
    if (pos < sizeof(buf)) buf[pos++] = '\n';
    if (pos) write(fd, buf, pos);
    close(fd);
}

static void SCICrashSignalHandler(int signo, siginfo_t *info, void *uctx) {
    (void)info; (void)uctx;
    SCIWriteCrashMarker(signo);
    struct sigaction *old = NULL;
    if (signo == SIGSEGV) old = &gSCIOldSIGSEGV;
    else if (signo == SIGBUS) old = &gSCIOldSIGBUS;
    else if (signo == SIGABRT) old = &gSCIOldSIGABRT;
    else if (signo == SIGILL) old = &gSCIOldSIGILL;
    else if (signo == SIGTRAP) old = &gSCIOldSIGTRAP;
    if (old && old->sa_sigaction && old->sa_sigaction != SCICrashSignalHandler && (old->sa_flags & SA_SIGINFO)) {
        old->sa_sigaction(signo, info, uctx);
        return;
    }
    if (old && old->sa_handler && old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN && old->sa_handler != (void (*)(int))SCICrashSignalHandler) {
        old->sa_handler(signo);
        return;
    }
    signal(signo, SIG_DFL);
    raise(signo);
}

static void SCIUncaughtExceptionHandler(NSException *exception) {
    (void)exception;
    SCIWriteCrashMarker(SIGABRT);
}

static BOOL SCISigactionIsOurHandler(const struct sigaction *sa) {
    if (!sa) return NO;
    if ((sa->sa_flags & SA_SIGINFO) && sa->sa_sigaction == SCICrashSignalHandler) return YES;
    return sa->sa_handler == (void (*)(int))SCICrashSignalHandler;
}

static void SCIInstallCrashHandlerForSignal(int signo, struct sigaction *oldStore) {
    struct sigaction current;
    memset(&current, 0, sizeof(current));
    if (sigaction(signo, NULL, &current) == 0 && !SCISigactionIsOurHandler(&current) && oldStore) {
        *oldStore = current;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SCICrashSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(signo, &sa, NULL);
}

static void SCIReinstallCrashSignalHandlers(void) {
    SCIInstallCrashHandlerForSignal(SIGSEGV, &gSCIOldSIGSEGV);
    SCIInstallCrashHandlerForSignal(SIGBUS, &gSCIOldSIGBUS);
    SCIInstallCrashHandlerForSignal(SIGABRT, &gSCIOldSIGABRT);
    SCIInstallCrashHandlerForSignal(SIGILL, &gSCIOldSIGILL);
    SCIInstallCrashHandlerForSignal(SIGTRAP, &gSCIOldSIGTRAP);
}

static void SCIInstallCrashSignalHandlers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"ryukgram_internal_gate_crash.marker"];
        const char *fs = path.fileSystemRepresentation;
        if (fs) strncpy(gSCICrashMarkerPath, fs, sizeof(gSCICrashMarkerPath) - 1);
        SCIReinstallCrashSignalHandlers();
        NSSetUncaughtExceptionHandler(&SCIUncaughtExceptionHandler);
    });
}

static BOOL SCICrashMarkerExists(void) {
    return gSCICrashMarkerPath[0] && access(gSCICrashMarkerPath, F_OK) == 0;
}

static void SCIClearCrashMarker(void) {
    if (gSCICrashMarkerPath[0]) unlink(gSCICrashMarkerPath);
}

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

+ (BOOL)boolForKey:(NSString *)key { return [SCIUtils getBoolPref:key]; }
+ (BOOL)objCGateEnabledForKey:(NSString *)key { return [self boolForKey:kSCIForceIGObjCMasterKey] || (key.length && [self boolForKey:key]); }
+ (BOOL)mobileConfigBoolGateEnabledForKey:(NSString *)key { return [self boolForKey:kSCIMobileConfigMasterKey] || (key.length && [self boolForKey:key]); }
+ (BOOL)individualGateEnabledForKey:(NSString *)key { return key.length && [self boolForKey:key]; }
+ (NSDictionary *)mobileConfigCustomOverrides { NSDictionary *d = [SCIUtils getDictPref:kSCIMobileConfigCustomOverridesKey]; return [d isKindOfClass:NSDictionary.class] ? d : @{}; }

+ (NSArray<NSString *> *)activeGateKeys {
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSString *key in [self allGateKeys]) if ([SCIUtils getBoolPref:key]) [active addObject:key];
    return active.copy;
}

+ (NSDictionary *)activeRuntimePatchPlans {
    NSDictionary *plans = [SCIUtils getDictPref:kSCIRuntimePatchPlansKey];
    return [plans isKindOfClass:NSDictionary.class] ? plans : @{};
}

+ (void)markCrashGuardCleanExitForSession:(NSString *)session reason:(NSString *)reason {
    if (!session.length) return;
    [SCIUtils setPref:session forKey:kSCIInternalGateCrashCleanExitKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
    [SCIUtils setPref:reason ?: @"clean exit" forKey:kSCIInternalGateCrashLastSourceKey];
}

+ (void)installCrashGuardLifecycleForSession:(NSString *)session activeKeys:(NSArray<NSString *> *)activeKeys runtimePlans:(NSDictionary *)runtimePlans {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            SCIReinstallCrashSignalHandlers();
            NSString *sid = [SCIUtils getStringPref:kSCIInternalGateCrashSessionKey];
            if (!sid.length) return;
            [SCIUtils setPref:sid forKey:kSCIInternalGateCrashStableKey];
            [SCIUtils setPref:@"foreground active; still armed until 4s stable window completes" forKey:kSCIInternalGateCrashLastSourceKey];
            [NSUserDefaults.standardUserDefaults synchronize];

            // Do not clear pending immediately on foreground-active. The crash in
            // Instagram-2026-06-19-023942.ips aborts from an async FBShared queue
            // after launch/foreground, so clearing here makes the next launch see
            // a crash marker with no pending keys and therefore nothing to disable.
            // User exits are handled by background/terminate notifications and
            // previous short sessions without a signal marker are ignored on next
            // launch, so this stable timer does not recreate the old false positive.
            // This timer only clears pending state; it never disables gates by time.
            [NSTimer scheduledTimerWithTimeInterval:kSCIInternalGateCrashStableWindowSeconds repeats:NO block:^(__unused NSTimer *timer) {
                NSString *current = [SCIUtils getStringPref:kSCIInternalGateCrashSessionKey];
                if (!current.length || ![current isEqualToString:sid]) return;
                [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
                [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
                [SCIUtils setPref:@"4s stable window completed" forKey:kSCIInternalGateCrashLastSourceKey];
                [NSUserDefaults.standardUserDefaults synchronize];
            }];
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [self markCrashGuardCleanExitForSession:[SCIUtils getStringPref:kSCIInternalGateCrashSessionKey] reason:@"entered background / user exit"];
        }];
        [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            [self markCrashGuardCleanExitForSession:[SCIUtils getStringPref:kSCIInternalGateCrashSessionKey] reason:@"will terminate / user exit"];
        }];
    });
    (void)session; (void)activeKeys; (void)runtimePlans;
}

+ (void)disablePendingKeys:(NSArray<NSString *> *)pending runtimePlans:(NSDictionary *)pendingPlans source:(NSString *)source {
    NSMutableOrderedSet<NSString *> *disabled = [NSMutableOrderedSet orderedSetWithArray:pending ?: @[]];
    for (NSString *key in [self activeGateKeys]) [disabled addObject:key];
    for (NSString *key in disabled) [SCIUtils setPref:@NO forKey:key];
    [SCIUtils setPref:disabled.array forKey:kSCIInternalGateCrashDisabledKeysKey];

    NSDictionary *livePlans = [self activeRuntimePatchPlans];
    NSMutableDictionary *disabledPlans = [NSMutableDictionary dictionary];
    if ([pendingPlans isKindOfClass:NSDictionary.class]) [disabledPlans addEntriesFromDictionary:pendingPlans];
    if (livePlans.count) [disabledPlans addEntriesFromDictionary:livePlans];
    if (disabledPlans.count) {
        [SCIUtils setPref:disabledPlans.copy forKey:kSCIInternalGateCrashDisabledRuntimePlansKey];
        [SCIUtils setPref:@{} forKey:kSCIRuntimePatchPlansKey];
    }

    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
    [SCIUtils setPref:source ?: @"confirmed crash marker" forKey:kSCIInternalGateCrashLastSourceKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

+ (void)installCrashGuardIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (![SCIUtils getBoolPref:kSCIInternalGateCrashGuardEnabledKey]) return;
        SCIInstallCrashSignalHandlers();

        NSArray<NSString *> *pending = [SCIUtils getArrayPref:kSCIInternalGateCrashPendingKeysKey];
        NSDictionary *pendingPlans = [SCIUtils getDictPref:kSCIInternalGateCrashPendingRuntimePlansKey];
        NSArray<NSString *> *active = [self activeGateKeys];
        NSDictionary *runtimePlans = [self activeRuntimePatchPlans];

        BOOL hadPending = pending.count > 0 || pendingPlans.count > 0;
        BOOL hadCrashMarker = SCICrashMarkerExists();
        if (hadCrashMarker && (hadPending || active.count || runtimePlans.count)) {
            NSArray<NSString *> *keysToDisable = pending.count ? pending : active;
            NSDictionary *plansToDisable = pendingPlans.count ? pendingPlans : runtimePlans;
            NSString *source = hadPending ? @"confirmed SIGSEGV/SIGBUS/SIGABRT crash marker from previous run" : @"confirmed crash marker with no pending state; disabling currently active gates";
            [self disablePendingKeys:keysToDisable runtimePlans:plansToDisable source:source];
            SCIClearCrashMarker();
            return;
        }
        if (hadPending) {
            // Old logic treated every launch that failed to survive 15s as a crash.
            // That creates false positives when the user simply closes the app.
            // Without the marker written by our signal/exception handler, clear the
            // pending state and keep the toggles intact.
            [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
            [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
            [SCIUtils setPref:@"previous short session had no crash marker; ignored" forKey:kSCIInternalGateCrashLastSourceKey];
            [NSUserDefaults.standardUserDefaults synchronize];
        }
        SCIClearCrashMarker();

        if (!active.count && !runtimePlans.count) return;

        NSString *session = [NSString stringWithFormat:@"%.0f-%u", NSDate.date.timeIntervalSince1970 * 1000.0, arc4random_uniform(UINT32_MAX)];
        [SCIUtils setPref:session forKey:kSCIInternalGateCrashSessionKey];
        if (active.count) [SCIUtils setPref:active forKey:kSCIInternalGateCrashPendingKeysKey];
        if (runtimePlans.count) [SCIUtils setPref:runtimePlans forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
        [SCIUtils setPref:@"armed; waiting for foreground-active or crash marker" forKey:kSCIInternalGateCrashLastSourceKey];
        [NSUserDefaults.standardUserDefaults synchronize];
        [self installCrashGuardLifecycleForSession:session activeKeys:active runtimePlans:runtimePlans];
    });
}

+ (NSArray<NSString *> *)crashDisabledKeys {
    NSArray *d = [SCIUtils getArrayPref:kSCIInternalGateCrashDisabledKeysKey];
    return [d isKindOfClass:NSArray.class] ? d : @[];
}

+ (void)resetCrashGuard {
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingKeysKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashPendingRuntimePlansKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashDisabledKeysKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashDisabledRuntimePlansKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashLastSourceKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashSessionKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashStableKey];
    [SCIUtils setPref:nil forKey:kSCIInternalGateCrashCleanExitKey];
    SCIClearCrashMarker();
}

+ (void)resetCrashGuardAndRestoreKeys {
    NSArray<NSString *> *disabled = [self crashDisabledKeys];
    for (NSString *key in disabled) [SCIUtils setPref:@YES forKey:key];
    NSDictionary *plans = [SCIUtils getDictPref:kSCIInternalGateCrashDisabledRuntimePlansKey];
    if (plans.count) [SCIUtils setPref:plans forKey:kSCIRuntimePatchPlansKey];
    [self resetCrashGuard];
}

@end
