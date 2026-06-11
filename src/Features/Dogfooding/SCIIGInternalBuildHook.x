// SCIIGInternalBuildHook.x
//
// Startup-safe internal build helpers.
//
// Previous version installed broad ObjC hooks from %ctor and also hooked session
// lifecycle methods with incompatible block signatures. That can stall/crash the
// Instagram launch path when stale prefs are present. This file now does nothing
// on a clean install and only installs a small fixed selector set when the user
// explicitly enabled sci_force_ig_internal_employee before launch.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <os/log.h>
#import "SCIInternalGatePrefs.h"

#define HLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIIntBuild] " fmt,##__VA_ARGS__)

static NSString *const kPref = @"sci_force_ig_internal_employee";

static inline BOOL SCIInternalBuildStartupEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:kPref];
}

static inline BOOL SCIInternalBuildEnabled(void) {
    return [SCIInternalGatePrefs objCGateEnabledForKey:kPref];
}

static NSMutableSet<NSString *> *gHooked;

static void SCIHookBoolGetter(NSString *clsName, SEL sel) {
    if (!SCIInternalBuildEnabled()) return;
    Class cls = NSClassFromString(clsName) ?: objc_getClass(clsName.UTF8String);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    char ret[8] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (!(ret[0] == 'B' || ret[0] == 'c' || ret[0] == 'C')) return;
    if (method_getNumberOfArguments(m) != 2) return;

    NSString *tag = [NSString stringWithFormat:@"%@#%s", clsName, sel_getName(sel)];
    if ([gHooked containsObject:tag]) return;

    IMP newIMP = imp_implementationWithBlock(^BOOL(__unused id _self){ return YES; });
    IMP orig = NULL;
    MSHookMessageEx(cls, sel, newIMP, &orig);
    [gHooked addObject:tag];
    HLOG("Hooked %{public}@", tag);
}

static void SCIApplyAutofillInternalSettings(id session) {
    if (!SCIInternalBuildEnabled()) return;
    SEL sel = NSSelectorFromString(@"autofillInternalSettings");
    if (!session || ![session respondsToSelector:sel]) return;

    id (*getSettings)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id settings = getSettings(session, sel);
    if (!settings) return;

    SEL setDebug = NSSelectorFromString(@"setDebugFooterEnabledWithEnabled:");
    if ([settings respondsToSelector:setDebug]) {
        void (*fn)(id,SEL,BOOL) = (void (*)(id,SEL,BOOL))objc_msgSend;
        fn(settings, setDebug, YES);
        HLOG("setDebugFooterEnabledWithEnabled:YES applied");
    }

    SEL setBloks = NSSelectorFromString(@"setForceBloksExperienceOn");
    if ([settings respondsToSelector:setBloks]) {
        void (*setBloksFn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        setBloksFn(settings, setBloks);
    }
}

void SCIInstallInternalBuildHooksIfNeeded(void) {
    static BOOL installed = NO;
    if (installed) return;
    if (!SCIInternalBuildEnabled()) return;
    installed = YES;

    if (!gHooked) gHooked = [NSMutableSet set];

    SEL sels[] = {
        @selector(isEmployee),
        NSSelectorFromString(@"isInternal"),
        NSSelectorFromString(@"ig_isInternal"),
        NSSelectorFromString(@"isInternalOnly"),
        NSSelectorFromString(@"isInternalToggleOn"),
        NSSelectorFromString(@"getDebugFooterEnabled"),
    };
    NSArray<NSString *> *classes = @[
        @"IGFacebookUserInfo",
        @"_TtC17IGBugReporterMenu29IGBugReportMenuViewController",
        @"_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings",
    ];

    for (NSString *cn in classes) {
        for (NSUInteger i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
            SCIHookBoolGetter(cn, sels[i]);
        }
    }

    // No broad objc_copyClassList scan and no session lifecycle swizzling here.
    // Session-backed setters are applied by explicit UI/native action paths.
}

%ctor {
    @autoreleasepool {
        SCIInstallInternalBuildHooksIfNeeded();
    }
}
