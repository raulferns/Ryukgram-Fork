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

static void SCIForceBugReportMenuIvars(id vc) {
    if (!vc) return;
    Class cls = [vc class];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    ILOG("checking %u bug-report-menu ivars for class %{public}s", count, class_getName(cls));

    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];
        const char *name = ivar_getName(ivar);
        const char *type = ivar_getTypeEncoding(ivar);
        if (!name) continue;

        ptrdiff_t offset = ivar_getOffset(ivar);
        NSString *ivarName = [NSString stringWithUTF8String:name];

        if ([ivarName containsString:@"showInternalSettings"]) {
            *((uint8_t *)((char *)(__bridge void *)vc + offset)) = 1;
            ILOG("forced ivar %{public}s (type: %s) to 1", name, type ? type : "unknown");
        } else if ([ivarName containsString:@"showLoggedOutInternalSettings"]) {
            *((uint8_t *)((char *)(__bridge void *)vc + offset)) = 1;
            ILOG("forced ivar %{public}s (type: %s) to 1", name, type ? type : "unknown");
        } else if ([ivarName containsString:@"showShakeToReportPreferenceToggle"]) {
            *((uint8_t *)((char *)(__bridge void *)vc + offset)) = 1;
            ILOG("forced ivar %{public}s (type: %s) to 1", name, type ? type : "unknown");
        } else if ([ivarName containsString:@"internalSettingsAvailabilityStatus"]) {
            if (type && (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L')) {
                *((long *)((char *)(__bridge void *)vc + offset)) = 0;
            } else if (type && (type[0] == 'i' || type[0] == 'I')) {
                *((int *)((char *)(__bridge void *)vc + offset)) = 0;
            } else {
                // Default to 1-byte write if type is unknown (common for Swift enums). 
                // Since memory is usually zero-initialized, writing 1 byte of 0 is safe.
                *((uint8_t *)((char *)(__bridge void *)vc + offset)) = 0;
            }
            ILOG("forced ivar %{public}s (type: %s) to 0", name, type ? type : "unknown");
        }
    }

    free(ivars);
}



static void (*sOrigViewDidLoad)(id, SEL) = NULL;
static void sci_viewDidLoad(id self, SEL _cmd) {
    ILOG("viewDidLoad");
    if (sOrigViewDidLoad) sOrigViewDidLoad(self, _cmd);
    if (SCIInternalMenuEnabled()) {
        SCIForceBugReportMenuIvars(self);
    }
}

static BOOL (*sOrigShowInternal)(id, SEL) = NULL;
static BOOL sci_showInternal(id self, SEL _cmd) {
    if (SCIInternalMenuEnabled()) return YES;
    return sOrigShowInternal ? sOrigShowInternal(self, _cmd) : NO;
}

static BOOL (*sOrigShowLoggedOut)(id, SEL) = NULL;
static BOOL sci_showLoggedOut(id self, SEL _cmd) {
    if (SCIInternalMenuLoggedOutEnabled()) return YES;
    return sOrigShowLoggedOut ? sOrigShowLoggedOut(self, _cmd) : NO;
}

static BOOL (*sOrigShowShake)(id, SEL) = NULL;
static BOOL sci_showShake(id self, SEL _cmd) {
    if (SCIInternalMenuEnabled()) return YES;
    return sOrigShowShake ? sOrigShowShake(self, _cmd) : NO;
}

static BOOL (*sOrigShowAssistant)(id, SEL) = NULL;
static BOOL sci_showAssistant(id self, SEL _cmd) {
    if (SCIInternalMenuEnabled()) return YES;
    return sOrigShowAssistant ? sOrigShowAssistant(self, _cmd) : NO;
}

static long (*sOrigAvailabilityStatus)(id, SEL) = NULL;
static long sci_availabilityStatus(id self, SEL _cmd) {
    if (SCIInternalMenuEnabled()) return 0;
    return sOrigAvailabilityStatus ? sOrigAvailabilityStatus(self, _cmd) : 2;
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
    static BOOL didViewDidLoadHook = NO;
    Class C = SCIInternalMenuClass();
    if (!C) { ILOG("IGBugReportMenuViewController not loaded"); return; }

    if (!didViewDidLoadHook) {
        SEL viewDidLoadSel = @selector(viewDidLoad);
        if (class_getInstanceMethod(C, viewDidLoadSel)) {
            IMP orig = NULL;
            MSHookMessageEx(C, viewDidLoadSel, (IMP)sci_viewDidLoad, &orig);
            sOrigViewDidLoad = (void (*)(id, SEL))orig;
            didViewDidLoadHook = (orig != NULL);
            ILOG("viewDidLoad hook %{public}s", didViewDidLoadHook ? "hooked" : "failed");
        }
    }

    SCIHookBoolGetter(C, @selector(showInternalSettings), (IMP)sci_showInternal, (IMP *)&sOrigShowInternal);
    SCIHookBoolGetter(C, @selector(showLoggedOutInternalSettings), (IMP)sci_showLoggedOut, (IMP *)&sOrigShowLoggedOut);
    SCIHookBoolGetter(C, @selector(showShakeToReportPreferenceToggle), (IMP)sci_showShake, (IMP *)&sOrigShowShake);
    SCIHookBoolGetter(C, @selector(showDogfoodingAssistant), (IMP)sci_showAssistant, (IMP *)&sOrigShowAssistant);

    SEL statusSel = NSSelectorFromString(@"internalSettingsAvailabilityStatus");
    if (class_getInstanceMethod(C, statusSel) && !sOrigAvailabilityStatus) {
        IMP orig = NULL;
        MSHookMessageEx(C, statusSel, (IMP)sci_availabilityStatus, &orig);
        sOrigAvailabilityStatus = (long (*)(id, SEL))orig;
        ILOG("availability status hook %s", sOrigAvailabilityStatus ? "hooked" : "failed");
    }

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
