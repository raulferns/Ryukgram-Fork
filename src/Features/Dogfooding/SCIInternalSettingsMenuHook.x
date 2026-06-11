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

typedef id (*SCIBugMenuInitIMP)(id, SEL, id, id, id, id, id, id, long, long, BOOL, BOOL, BOOL);
static SCIBugMenuInitIMP sOrigBugMenuInit = NULL;

static id sci_bugMenuInitHook(id self, SEL _cmd,
    id deviceSession, id userSession, id reliabilityLogging,
    id navChain, id endpoint, id entryPoint,
    long style, long status,
    BOOL showInternal, BOOL showLoggedOut, BOOL showShake)
{
    if (SCIInternalMenuEnabled()) {
        showInternal = YES;
        showShake = YES;
        if (SCIInternalMenuLoggedOutEnabled()) showLoggedOut = YES;
    }
    return sOrigBugMenuInit ? sOrigBugMenuInit(self, _cmd, deviceSession, userSession, reliabilityLogging, navChain, endpoint, entryPoint, style, status, showInternal, showLoggedOut, showShake) : self;
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

static void SCIHookBoolGetter(Class C, SEL sel, IMP replacement, IMP *orig) {
    if (!C || !sel || *orig) return;
    if (!class_getInstanceMethod(C, sel)) return;
    MSHookMessageEx(C, sel, replacement, orig);
    ILOG("getter %{public}s %{public}s", sel_getName(sel), *orig ? "hooked" : "failed");
}

static void SCIInstallInternalMenuHook(void) {
    static BOOL didInitHook = NO;
    Class C = SCIInternalMenuClass();
    if (!C) { ILOG("IGBugReportMenuViewController not loaded"); return; }

    SEL initSel = NSSelectorFromString(@"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:");
    if (!didInitHook && class_getInstanceMethod(C, initSel)) {
        IMP orig = NULL;
        MSHookMessageEx(C, initSel, (IMP)sci_bugMenuInitHook, &orig);
        sOrigBugMenuInit = (SCIBugMenuInitIMP)orig;
        didInitHook = (orig != NULL);
        ILOG("init hook %{public}s", didInitHook ? "hooked" : "failed");
    }

    SCIHookBoolGetter(C, @selector(showInternalSettings), (IMP)sci_showInternal, (IMP *)&sOrigShowInternal);
    SCIHookBoolGetter(C, @selector(showLoggedOutInternalSettings), (IMP)sci_showLoggedOut, (IMP *)&sOrigShowLoggedOut);
    SCIHookBoolGetter(C, @selector(showShakeToReportPreferenceToggle), (IMP)sci_showShake, (IMP *)&sOrigShowShake);
    SCIHookBoolGetter(C, @selector(showDogfoodingAssistant), (IMP)sci_showAssistant, (IMP *)&sOrigShowAssistant);
}


void SCIInstallInternalSettingsMenuHookIfNeeded(void) {
    if (!SCIInternalMenuEnabled()) return;
    [SCIInternalGatePrefs installCrashGuardIfNeeded];
    SCIInstallInternalMenuHook();
}

%ctor {
    @autoreleasepool {
        SCIInstallInternalSettingsMenuHookIfNeeded();
    }
}
