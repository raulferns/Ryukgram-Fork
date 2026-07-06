#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../../Utils.h"
#import "SCIInternalGatePrefs.h"
#import "SCIInternalMenusForce.h"
#import "SCIInternalMenusLauncher.h"
#import "SCIDogfoodObjectRuntime.h"
#import <os/log.h>

#define ILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] InternalMenu " fmt, ##__VA_ARGS__)

static inline BOOL SCIMenuGateOn(void) {
    return [SCIUtils getBoolPref:@"sci_employee_internal"] ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"];
}

// Write a raw long value directly into an instance ivar by name.
// Returns YES if the ivar was found and patched.
static BOOL SCIPatchIvarToLong(id obj, const char *ivarName, long long value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *(long long *)((uint8_t *)(__bridge void *)obj + offset) = value;
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

- (id)initWithDeviceSession:(id)deviceSession
                userSession:(id)userSession
         reliabilityLogging:(id)reliabilityLogging
                   navChain:(id)navChain
                   endpoint:(id)endpoint
                 entryPoint:(id)entryPoint
                      style:(long long)style
internalSettingsAvailabilityStatus:(long long)availabilityStatus
       showInternalSettings:(BOOL)showInternalSettings
showLoggedOutInternalSettings:(BOOL)showLoggedOut
showShakeToReportPreferenceToggle:(BOOL)showShake {

    if (SCIMenuGateOn()) {
        showInternalSettings = YES;
        showShake = YES;
        if (userSession) {
            [SCIDogfoodObjectRuntime noteLiveUserSession:userSession source:@"IGBugReportMenuViewController.initWithDeviceSession"];
        }
    }
    if ([SCIUtils getBoolPref:@"sci_employee_internal"] ||
        [SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
        showLoggedOut = YES;
    }

    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
        availabilityStatus = (long long)[SCIUtils getDoublePref:@"sci_internal_settings_availability_value"];
    } else if (SCIMenuGateOn()) {
        availabilityStatus = 0;
    }

    return %orig(deviceSession, userSession, reliabilityLogging, navChain, endpoint, entryPoint, style, availabilityStatus, showInternalSettings, showLoggedOut, showShake);
}

- (BOOL)showInternalSettings {
    if (SCIMenuGateOn()) return YES;
    return %orig;
}

- (BOOL)showLoggedOutInternalSettings {
    if ([SCIUtils getBoolPref:@"sci_employee_internal"] ||
        [SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
        return YES;
    }
    return %orig;
}

- (BOOL)showShakeToReportPreferenceToggle {
    if (SCIMenuGateOn()) return YES;
    return %orig;
}

- (BOOL)showDogfoodingAssistant {
    if (SCIMenuGateOn()) return YES;
    return %orig;
}

// Getter fallback — some code paths may still call the getter.
- (long long)internalSettingsAvailabilityStatus {
    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
        return (long long)[SCIUtils getDoublePref:@"sci_internal_settings_availability_value"];
    } else if (SCIMenuGateOn()) {
        return 0;
    }
    return %orig;
}

// The binary reads internalSettingsAvailabilityStatus, showInternalSettings, etc.
// as raw ivars (LDR from ivar offset), bypassing ObjC getters entirely.
// Patch them directly once the view is loaded so that didSelectRowAtIndexPath:
// and the subtitle builder both see the correct values.
- (void)viewDidLoad {
    if (SCIMenuGateOn() || [SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
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

        long long availabilityVal = 0;
        if ([SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
            availabilityVal = (long long)[SCIUtils getDoublePref:@"sci_internal_settings_availability_value"];
        } else if (SCIMenuGateOn()) {
            availabilityVal = 0;
        }

        BOOL patched = NO;
        if (currentSession || [SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
            patched = SCIPatchIvarToLong(self, "internalSettingsAvailabilityStatus", availabilityVal);
            SCIPatchIvarToBool(self, "showInternalSettings", YES);
            SCIPatchIvarToBool(self, "showDogfoodingAssistant", YES);
        } else {
            patched = SCIPatchIvarToLong(self, "internalSettingsAvailabilityStatus", 2); // Denied
            SCIPatchIvarToBool(self, "showInternalSettings", NO);
            SCIPatchIvarToBool(self, "showDogfoodingAssistant", NO);
        }
        SCIPatchIvarToBool(self, "showShakeToReportPreferenceToggle", YES);
        if ([SCIUtils getBoolPref:@"sci_employee_internal"] || [SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
            SCIPatchIvarToBool(self, "showLoggedOutInternalSettings", YES);
        }
        ILOG("viewDidLoad: patched ivars directly before orig (patched=%s, status=%lld, loggedIn=%s)", patched ? "YES" : "NO", availabilityVal, currentSession ? "YES" : "NO");
    }
    %orig;
    if (SCIMenuGateOn()) {
        NSString *res = SCIInternalMenusForceApplyNow();
        ILOG("viewDidLoad: applied employee hooks: %s", res.UTF8String);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (SCIMenuGateOn()) {
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
    Class C = objc_getClass("_TtC17IGBugReporterMenu29IGBugReportMenuViewController");
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
    if (!SCIMenuGateOn() && ![SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) return;
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
                if (objc_getClass("_TtC17IGBugReporterMenu29IGBugReportMenuViewController")) {
                    SCIInstallInternalMenuHook();
                    [timer invalidate];
                }
            }];
        });
    }
}
