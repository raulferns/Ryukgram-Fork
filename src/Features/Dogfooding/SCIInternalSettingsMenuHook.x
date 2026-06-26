// SCIInternalSettingsMenuHook.x
// Stable ABI hooks for Instagram's own internal settings entry in the bug reporter menu.
// Validated against Instagram(32): IGBugReporterMenu.IGBugReportMenuViewController
//
// IMPORTANT: The binary reads `internalSettingsAvailabilityStatus` as a raw ivar
// (LDR from _OBJC_IVAR_$_...internalSettingsAvailabilityStatus offset), bypassing
// any ObjC getter. The getter hooks are kept as fallbacks, but the real fix is
// the viewDidLoad hook that writes 0 directly into the ivar via ivar_getOffset.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"
#import "../../Utils.h"
#import "SCIInternalMenusForce.h"
#import "SCIInternalMenusLauncher.h"
#import "SCIDogfoodObjectRuntime.h"

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

// Write a raw long value directly into an instance ivar by name.
// Returns YES if the ivar was found and patched.
static BOOL SCIPatchIvarToLong(id obj, const char *ivarName, long value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *(long *)((uint8_t *)(__bridge void *)obj + offset) = value;
    return YES;
}

// Write a raw BOOL (1 byte) directly into an instance ivar by name.
static BOOL SCIPatchIvarToBool(id obj, const char *ivarName, BOOL value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *(BOOL *)((uint8_t *)(__bridge void *)obj + offset) = value;
    return YES;
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

- (id)initWithDeviceSession:(id)arg1
                userSession:(id)arg2
         reliabilityLogging:(id)arg3
                   navChain:(id)arg4
                   endpoint:(id)arg5
                 entryPoint:(long)arg6
                      style:(long)arg7
internalSettingsAvailabilityStatus:(long)arg8
       showInternalSettings:(BOOL)arg9
showLoggedOutInternalSettings:(BOOL)arg10
showShakeToReportPreferenceToggle:(BOOL)arg11 {
    if (SCIInternalMenuEnabled()) {
        ILOG("initWithDeviceSession: forcing internalSettingsAvailabilityStatus=2 to bypass MobileConfig socket call");
        if (arg2) {
            [SCIDogfoodObjectRuntime noteLiveUserSession:arg2 source:@"IGBugReportMenuViewController.initWithDeviceSession"];
        }
        return %orig(arg1, arg2, arg3, arg4, arg5, arg6, arg7, 2, YES, YES, YES);
    }
    return %orig;
}

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

// Getter fallback — some code paths may still call the getter.
- (long)internalSettingsAvailabilityStatus {
    if (SCIInternalMenuEnabled()) return 0;
    return %orig;
}

// The binary reads internalSettingsAvailabilityStatus, showInternalSettings, etc.
// as raw ivars (LDR from ivar offset), bypassing ObjC getters entirely.
// Patch them directly once the view is loaded so that didSelectRowAtIndexPath:
// and the subtitle builder both see the correct values.
- (void)viewDidLoad {
    if (SCIInternalMenuEnabled()) {
        Ivar sessionIvar = class_getInstanceVariable(object_getClass(self), "userSession");
        id currentSession = nil;
        if (sessionIvar) {
            currentSession = object_getIvar(self, sessionIvar);
        }
        if (!currentSession) {
            currentSession = [SCIDogfoodObjectRuntime activeUserSession];
            if (currentSession && sessionIvar) {
                object_setIvar(self, sessionIvar, currentSession);
                ILOG("viewDidLoad: userSession was nil, patched with activeUserSession");
            }
        }

        BOOL patched = NO;
        if (currentSession) {
            patched = SCIPatchIvarToLong(self, "internalSettingsAvailabilityStatus", 0);
            SCIPatchIvarToBool(self, "showInternalSettings", YES);
            SCIPatchIvarToBool(self, "showDogfoodingAssistant", YES);
        } else {
            patched = SCIPatchIvarToLong(self, "internalSettingsAvailabilityStatus", 2); // Denied
            SCIPatchIvarToBool(self, "showInternalSettings", NO);
            SCIPatchIvarToBool(self, "showDogfoodingAssistant", NO);
        }
        SCIPatchIvarToBool(self, "showShakeToReportPreferenceToggle", YES);
        if (SCIInternalMenuLoggedOutEnabled()) {
            SCIPatchIvarToBool(self, "showLoggedOutInternalSettings", YES);
        }
        ILOG("viewDidLoad: patched ivars directly before orig (status=%s, loggedIn=%s)", patched ? "OK" : "MISS", currentSession ? "YES" : "NO");
    }
    %orig;
    if (SCIInternalMenuEnabled()) {
        NSString *res = SCIInternalMenusForceApplyNow();
        ILOG("viewDidLoad: applied employee hooks: %s", res.UTF8String);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (SCIInternalMenuEnabled()) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell && SCICellContainsText(cell, @"Internal Settings")) {
            ILOG("Tapped Internal Settings cell. Triggering custom open sequence with fallback URIs...");
            NSString *res = [SCIInternalMenusLauncher openInternalURLString:nil controller:self];
            ILOG("Open internal settings URL sequence result: %@", res);
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
    }
    %orig;
}

%end

%end

static void SCIInstallInternalMenuHook(void) {
    Class C = SCIInternalMenuClass();
    if (C) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            %init(SCIInternalMenuHooks, IGBugReportMenuViewController = C);
            ILOG("IGBugReportMenuViewController hooked successfully via Logos.");
        });
    } else {
        ILOG("IGBugReportMenuViewController not loaded yet.");
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
        
        // Continuously poll in the background until the framework is loaded
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
                if (SCIInternalMenuClass()) {
                    SCIInstallInternalMenuHook();
                    [timer invalidate];
                }
            }];
        });
    }
}
