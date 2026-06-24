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

static void (*sOrigDidSelectRow)(id, SEL, id, id) = NULL;
static void sci_didSelectRow(id self, SEL _cmd, id tableView, id indexPath) {
    UITableViewCell *cell = nil;
    @try {
        if ([tableView respondsToSelector:@selector(cellForRowAtIndexPath:)]) {
            cell = [tableView cellForRowAtIndexPath:indexPath];
        }
    } @catch (__unused id e) {}
    
    if (cell && SCICellContainsText(cell, @"Internal Settings")) {
        ILOG("intercepted Internal Settings tap — applying ObjC employee hooks");
        // Apply the ObjC employee-spoofing hooks lazily (lightweight, no fishhook).
        // The heavy function hooks (MobileConfigGate, EmployeeCheck, SocketWrapper)
        // are already installed at %ctor in SCIInternalMenusForce.x.
        (void)SCIInternalMenusForceApplyNow();
    }
    if (sOrigDidSelectRow) sOrigDidSelectRow(self, _cmd, tableView, indexPath);
}


static void SCIHookBoolGetter(Class C, SEL sel, IMP replacement, IMP *orig) {
    if (!C || !sel || *orig) return;
    if (!class_getInstanceMethod(C, sel)) return;
    MSHookMessageEx(C, sel, replacement, orig);
    ILOG("getter %{public}s %{public}s", sel_getName(sel), *orig ? "hooked" : "failed");
}

static void SCIInstallInternalMenuHook(void) {
    Class C = SCIInternalMenuClass();
    if (!C) { ILOG("IGBugReportMenuViewController not loaded"); return; }

    SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
    if (class_getInstanceMethod(C, selectSel) && !sOrigDidSelectRow) {
        IMP orig = NULL;
        MSHookMessageEx(C, selectSel, (IMP)sci_didSelectRow, &orig);
        sOrigDidSelectRow = (void (*)(id, SEL, id, id))orig;
        ILOG("didSelectRow hook registered");
    }
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
