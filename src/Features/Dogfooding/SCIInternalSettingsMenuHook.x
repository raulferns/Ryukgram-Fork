// SCIInternalSettingsMenuHook.x
// Stable ABI hooks for Instagram's own internal settings entry in the bug reporter menu.
// Validated against Instagram(32): IGBugReporterMenu.IGBugReportMenuViewController
// exposes initWithDeviceSession:...showInternalSettings:showLoggedOutInternalSettings:showShake...
// and getters showInternalSettings/showLoggedOutInternalSettings/showShakeToReportPreferenceToggle/showDogfoodingAssistant.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"
#import "../../Utils.h"
#import "SCIInternalMenusForce.h"

#define ILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] InternalMenu " fmt, ##__VA_ARGS__)

static NSString *const kForce = @"sci_force_internal_settings_menu";
static NSString *const kLogged = @"sci_force_internal_settings_loggedout";

static inline BOOL SCIInternalMenuEnabled(void) { return [SCIInternalGatePrefs objCGateEnabledForKey:kForce]; }
static inline BOOL SCIInternalMenuLoggedOutEnabled(void) { return SCIInternalMenuEnabled() && [SCIInternalGatePrefs individualGateEnabledForKey:kLogged]; }

static Class SCIInternalMenuClass(void) {
    Class C = NSClassFromString(@"_TtC17IGBugReporterMenu29IGBugReportMenuViewController");
    if (!C) C = NSClassFromString(@"IGBugReporterMenu.IGBugReportMenuViewController");
    if (!C) C = NSClassFromString(@"IGBugReportMenuViewController");
    return C;
}


static BOOL SCICellContainsText(UIView *view, NSString *text) {
    if ([view isKindOfClass:NSClassFromString(@"UILabel")]) {
        UILabel *lbl = (UILabel *)view;
        if ([lbl.text containsString:text]) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (SCICellContainsText(sub, text)) return YES;
    }
    return NO;
}

%group SCIInternalMenuHooks

%hook IGBugReportMenuViewController

- (BOOL)showInternalSettings {
    if (SCIInternalMenuEnabled()) return YES;
    return %orig;
}

- (BOOL)showLoggedOutInternalSettings {
    if (SCIInternalMenuLoggedOutEnabled()) return YES;
    return %orig;
}

- (BOOL)showShakeToReportPreferenceToggle {
    if (SCIInternalMenuEnabled()) return YES;
    return %orig;
}

- (BOOL)showDogfoodingAssistant {
    if (SCIInternalMenuEnabled()) return YES;
    return %orig;
}

- (long)internalSettingsAvailabilityStatus {
    if (SCIInternalMenuEnabled()) return 0;
    return %orig;
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    UITableViewCell *cell = nil;
    @try {
        if ([tableView respondsToSelector:@selector(cellForRowAtIndexPath:)]) {
            cell = [tableView cellForRowAtIndexPath:indexPath];
        }
    } @catch (__unused id e) {}
    
    if (cell && SCICellContainsText(cell, @"Internal Settings")) {
        ILOG("intercepted Internal Settings tap — applying ObjC employee hooks");
        (void)SCIInternalMenusForceApplyNow();
    }
    %orig;
}

%end

%end

static void SCIInstallInternalMenuHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class C = SCIInternalMenuClass();
        if (C) {
            %init(SCIInternalMenuHooks, IGBugReportMenuViewController = C);
            ILOG("IGBugReportMenuViewController hooked successfully via Logos.");
        } else {
            ILOG("IGBugReportMenuViewController not loaded yet.");
        }
    });
}

void SCIInstallInternalSettingsMenuHookIfNeeded(void) {
    if (!SCIInternalMenuEnabled()) return;
    [SCIInternalGatePrefs installCrashGuardIfNeeded];
    SCIInstallInternalMenuHook();
}

%ctor {
    @autoreleasepool {
        [SCIInternalGatePrefs installCrashGuardIfNeeded];
        SCIInstallInternalMenuHook();
        double delays[] = {1.0, 3.0, 6.0, 10.0};
        for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SCIInstallInternalMenuHook();
            });
        }
    }
}
