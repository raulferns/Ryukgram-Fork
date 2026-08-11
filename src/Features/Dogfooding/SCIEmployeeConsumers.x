// SCIEmployeeConsumers.x
//
// Canonical Objective-C employee/test-user identity layer. Same three
// exported entry points as the file this replaced (SCIEmployeeInternal.x),
// so every existing caller (part02/part03/part04, SCIInternalMenusForce.x,
// the Settings/Actions call sites, Tier-2) keeps linking and working.
//
// SCI-FIX 2026-08-10 (employee identity silently never applying): the
// previous revision of this file called SCIInstallEmployeeIdentityHooksIfNeeded()
// directly from a raw %ctor, and gated its ONE Logos %init(group) call behind
// a `static BOOL knownInstalled` flag that was set to YES unconditionally
// before the %init ran — not after confirming it succeeded. %ctor runs before
// UIApplicationMain; per SCIInstallOnce.h (see its header comment for the
// full crash history — SCI-FIX 2026-06-11, crash 433.0.283) touching ObjC
// class realization that early is unsafe project-wide, and every other
// Dogfooding hook file in this tree defers object/class hooking to
// UIApplicationDidBecomeActiveNotification via SCIInstallOnceOnActive for
// exactly that reason. Logos' %init(group) has no partial-failure signal —
// it either fully wires a group or (silently, if objc_getClass returns nil
// for a class that isn't realized yet) does nothing for it — so calling it
// too early and then latching "done" permanently disabled every identity
// swizzle in this file for the rest of the process, on every launch,
// regardless of what the user later toggled in the Dev menu. This revision:
//   (1) moves the automatic launch-time trigger into SCIInstallOnceOnActive
//       (app fully active, UI built, classes realized — matches
//       SCIDogfoodObjectRuntimeHooks.x / SCIIGUserSessionHook.x exactly);
//   (2) replaces the two Logos %hook groups with individually-guarded plain
//       MSHookMessageEx installers (one static "already installed" IMP
//       pointer per selector, matching FBTInstallBoolObjectHook /
//       FBTInstallBoolVoidHook / SCIInstallInternalMenusBoolGetter's own
//       established pattern in this codebase). Each install is now cheap,
//       idempotent and safe to attempt on every call — from the %ctor, from
//       part02/03/04, from SCIInternalMenusForce's manual "Apply Now", from
//       Tier-2 — so an early miss no longer blocks a later, correct retry.
//   (3) removes the speculative classNames list (IGBaseUser, IGUserSession,
//       IGUserSessionContext, IGDeviceSession, IGDogfooderProd) that was
//       never checked against the shipped binary: 4 of the 6 names do not
//       exist in this build at all, IGSessionContext exists but exposes only
//       .cxx_destruct (no isEmployee), and IGDogfooderProd is the app-update/
//       build-status checker (checkBuildStatusForBuild:/triggerUpdateWithMode:)
//       — an unrelated false friend, not an identity/dogfooding surface. It
//       hooked nothing, ever; removed rather than left as dead weight.
//
// Ownership boundary (unchanged): this file owns ONLY ObjC identity surfaces.
// Bug Reporter / Internal Settings presentation and the MobileConfig getBool:
// readers stay owned exclusively by SCIInternalGlobalSafe.x. Nothing here
// hooks IGBugReportMenuViewController or FBMobileConfigContextManager.
//
// Every class/selector/ABI below was re-verified against BOTH the build this
// file originally shipped against and the current uploaded Instagram/
// FBSharedFramework pair (imagebase and class-count differ between the two —
// 43429->43736 classes / 5348->5383 — confirming an app update landed between
// sessions); all nine encodings below are byte-identical across both builds.
// Scope: every hook here rewrites a client-side identity argument or getter
// only; nothing mints or replaces a server-side internal token.

#import "../../Utils.h"
#import "SCIInternalGatePrefs.h"
#import "SCIInstallOnce.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <string.h>

#define ECLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeConsumers " fmt, ##__VA_ARGS__)

// Defined in SCIInternalGlobalSafe.x — the authoritative installer that owns
// identity + MobileConfig + Bug Reporter ordering.
void SCIRequestInternalGlobalHooksInstall(void);

static inline BOOL ECMasterOn(void) {
    return [SCIInternalGatePrefs employeeInternalMasterEnabled] ||
           [SCIUtils getBoolPref:@"sci_internal_menus"];
}
static inline BOOL ECTestUserOn(void) {
    return ECMasterOn() || [SCIUtils getBoolPref:@"sci_force_ig_is_test_user"];
}

// Encoding compare that treats {'B','c','C'} as one BOOL class.
static BOOL ECEncodingEquiv(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    while (*actual && *expected) {
        char a = *actual, e = *expected;
        BOOL ab = (a == 'B' || a == 'c' || a == 'C');
        BOOL eb = (e == 'B' || e == 'c' || e == 'C');
        if (a != e && !(ab && eb)) return NO;
        actual++; expected++;
    }
    return *actual == 0 && *expected == 0;
}
static BOOL ECInstMatches(Class cls, SEL sel, const char *enc) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    return ECEncodingEquiv(t, enc);
}

// ===================================================================
//  Retry-safe installer helpers. Each hook gets its own static "original
//  IMP" pointer: *original != NULL means already installed (instant
//  no-op on every later call); class not yet realized or ABI mismatch
//  means NO for THIS call only — never a permanent latch. Mirrors
//  FBTInstallBoolObjectHook/FBTInstallBoolVoidHook (turn 1 of this
//  project) and SCIInternalMenusForce.x's SCIInstallInternalMenusBoolGetter.
// ===================================================================
static BOOL ECInstallHook(const char *className, const char *selName, const char *enc, IMP repl, IMP *orig) {
    if (*orig) return YES;
    Class cls = objc_getClass(className);
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    if (!ECInstMatches(cls, sel, enc)) return NO;
    MSHookMessageEx(cls, sel, repl, orig);
    return *orig != NULL;
}

// --- IGFacebookUserInfo.isEmployee (FBSharedFramework) --- B16@0:8
// imp = ldrb w0,[x0,#8]; ret — real ivar accessor, no setter exists.
typedef BOOL (*ECGetterFn)(id, SEL);
static IMP ec_orig_FBUserInfo_isEmployee = NULL;
static BOOL ec_repl_FBUserInfo_isEmployee(id self, SEL _cmd) {
    if (ECMasterOn()) return YES;
    return ec_orig_FBUserInfo_isEmployee ? ((ECGetterFn)ec_orig_FBUserInfo_isEmployee)(self, _cmd) : NO;
}

// --- IGAdPlatformLogger_objc.isEmployee --- B16@0:8
static IMP ec_orig_AdPlatform_isEmployee = NULL;
static BOOL ec_repl_AdPlatform_isEmployee(id self, SEL _cmd) {
    if (ECMasterOn()) return YES;
    return ec_orig_AdPlatform_isEmployee ? ((ECGetterFn)ec_orig_AdPlatform_isEmployee)(self, _cmd) : NO;
}

// --- IGAdPlatformLogger_objc.setIsEmployee: --- v20@0:8B16
typedef void (*ECSetterFn)(id, SEL, BOOL);
static IMP ec_orig_AdPlatform_setIsEmployee = NULL;
static void ec_repl_AdPlatform_setIsEmployee(id self, SEL _cmd, BOOL value) {
    if (ec_orig_AdPlatform_setIsEmployee) ((ECSetterFn)ec_orig_AdPlatform_setIsEmployee)(self, _cmd, ECMasterOn() ? YES : value);
}

// --- FBWKWebView.setIsEmployee: --- v20@0:8B16
static IMP ec_orig_FBWKWebView_setIsEmployee = NULL;
static void ec_repl_FBWKWebView_setIsEmployee(id self, SEL _cmd, BOOL value) {
    if (ec_orig_FBWKWebView_setIsEmployee) ((ECSetterFn)ec_orig_FBWKWebView_setIsEmployee)(self, _cmd, ECMasterOn() ? YES : value);
}

// --- FBWKWebViewDelegateAdaptor.setIsEmployee: --- v20@0:8B16
static IMP ec_orig_FBWKWebViewDA_setIsEmployee = NULL;
static void ec_repl_FBWKWebViewDA_setIsEmployee(id self, SEL _cmd, BOOL value) {
    if (ec_orig_FBWKWebViewDA_setIsEmployee) ((ECSetterFn)ec_orig_FBWKWebViewDA_setIsEmployee)(self, _cmd, ECMasterOn() ? YES : value);
}

// --- IGSeenStateStore.initWithDependencies:isEmployee: --- @28@0:8@16B24
typedef id (*ECInitDepEmpFn)(id, SEL, id, BOOL);
static IMP ec_orig_SeenStateStore_init = NULL;
static id ec_repl_SeenStateStore_init(id self, SEL _cmd, id dependencies, BOOL isEmployee) {
    return ec_orig_SeenStateStore_init ? ((ECInitDepEmpFn)ec_orig_SeenStateStore_init)(self, _cmd, dependencies, ECMasterOn() ? YES : isEmployee) : nil;
}

// --- IGSeenStateLogger.initWithIsEmployee:analyticsLogger: --- @28@0:8B16@20
typedef id (*ECInitEmpLoggerFn)(id, SEL, BOOL, id);
static IMP ec_orig_SeenStateLogger_init = NULL;
static id ec_repl_SeenStateLogger_init(id self, SEL _cmd, BOOL isEmployee, id analyticsLogger) {
    return ec_orig_SeenStateLogger_init ? ((ECInitEmpLoggerFn)ec_orig_SeenStateLogger_init)(self, _cmd, ECMasterOn() ? YES : isEmployee, analyticsLogger) : nil;
}

// --- IGLeadGenAnalyticsLogger.initWithAnalyticsLogger:userFbidV2:isEmployee: --- @36@0:8@16q24B32
typedef id (*ECInitLeadGenFn)(id, SEL, id, long long, BOOL);
static IMP ec_orig_LeadGenLogger_init = NULL;
static id ec_repl_LeadGenLogger_init(id self, SEL _cmd, id analyticsLogger, long long userFbidV2, BOOL isEmployee) {
    return ec_orig_LeadGenLogger_init ? ((ECInitLeadGenFn)ec_orig_LeadGenLogger_init)(self, _cmd, analyticsLogger, userFbidV2, ECMasterOn() ? YES : isEmployee) : nil;
}

// --- IGFeedRequestQPLogger.initWith...isCacheLoadEnabled:isEmployee:isTestUser: --- @52@0:8B16@20@28B36B40B44B48
typedef id (*ECInitFeedQPFn)(id, SEL, BOOL, id, id, BOOL, BOOL, BOOL, BOOL);
static IMP ec_orig_FeedQPLogger_init = NULL;
static id ec_repl_FeedQPLogger_init(id self, SEL _cmd,
                                    BOOL shouldIncludeRequestId, id instancesManager, id persistentFailureTracker,
                                    BOOL isDeferredNppTapEnabled, BOOL isCacheLoadEnabled,
                                    BOOL isEmployee, BOOL isTestUser) {
    return ec_orig_FeedQPLogger_init
        ? ((ECInitFeedQPFn)ec_orig_FeedQPLogger_init)(self, _cmd,
              shouldIncludeRequestId, instancesManager, persistentFailureTracker,
              isDeferredNppTapEnabled, isCacheLoadEnabled,
              ECMasterOn() ? YES : isEmployee,
              ECTestUserOn() ? YES : isTestUser)
        : nil;
}

static NSUInteger ECInstallKnownObjC(void) {
    NSUInteger n = 0;
    n += ECInstallHook("IGFacebookUserInfo", "isEmployee", "B16@0:8",
                       (IMP)ec_repl_FBUserInfo_isEmployee, &ec_orig_FBUserInfo_isEmployee);
    n += ECInstallHook("IGAdPlatformLogger_objc", "isEmployee", "B16@0:8",
                       (IMP)ec_repl_AdPlatform_isEmployee, &ec_orig_AdPlatform_isEmployee);
    n += ECInstallHook("IGAdPlatformLogger_objc", "setIsEmployee:", "v20@0:8B16",
                       (IMP)ec_repl_AdPlatform_setIsEmployee, &ec_orig_AdPlatform_setIsEmployee);
    n += ECInstallHook("FBWKWebView", "setIsEmployee:", "v20@0:8B16",
                       (IMP)ec_repl_FBWKWebView_setIsEmployee, &ec_orig_FBWKWebView_setIsEmployee);
    n += ECInstallHook("FBWKWebViewDelegateAdaptor", "setIsEmployee:", "v20@0:8B16",
                       (IMP)ec_repl_FBWKWebViewDA_setIsEmployee, &ec_orig_FBWKWebViewDA_setIsEmployee);
    n += ECInstallHook("IGSeenStateStore", "initWithDependencies:isEmployee:", "@28@0:8@16B24",
                       (IMP)ec_repl_SeenStateStore_init, &ec_orig_SeenStateStore_init);
    n += ECInstallHook("IGSeenStateLogger", "initWithIsEmployee:analyticsLogger:", "@28@0:8B16@20",
                       (IMP)ec_repl_SeenStateLogger_init, &ec_orig_SeenStateLogger_init);
    n += ECInstallHook("IGLeadGenAnalyticsLogger", "initWithAnalyticsLogger:userFbidV2:isEmployee:", "@36@0:8@16q24B32",
                       (IMP)ec_repl_LeadGenLogger_init, &ec_orig_LeadGenLogger_init);
    n += ECInstallHook("IGFeedRequestQPLogger",
                       "initWithShouldIncludeRequestId:instancesManager:persistentFailureTracker:isDeferredNppTapEnabled:isCacheLoadEnabled:isEmployee:isTestUser:",
                       "@52@0:8B16@20@28B36B40B44B48",
                       (IMP)ec_repl_FeedQPLogger_init, &ec_orig_FeedQPLogger_init);
    return n;
}

// ===================================================================
//  Swift @objc identity (IGAdPlatformLogger_swift) — already retry-safe.
// ===================================================================
static BOOL (*orig_ECAdSwiftIsEmployee)(id, SEL) = NULL;
static void (*orig_ECAdSwiftSetIsEmployee)(id, SEL, BOOL) = NULL;

static BOOL ECAdSwiftIsEmployee(id self, SEL _cmd) {
    if (ECMasterOn()) return YES;
    return orig_ECAdSwiftIsEmployee ? orig_ECAdSwiftIsEmployee(self, _cmd) : NO;
}
static void ECAdSwiftSetIsEmployee(id self, SEL _cmd, BOOL value) {
    if (orig_ECAdSwiftSetIsEmployee)
        orig_ECAdSwiftSetIsEmployee(self, _cmd, ECMasterOn() ? YES : value);
}
static void ECInstallSwiftIdentityHooks(void) {
    Class cls = objc_getClass("_TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift");
    if (!cls) return;
    SEL getter = sel_registerName("isEmployee");
    if (!orig_ECAdSwiftIsEmployee && ECInstMatches(cls, getter, "B16@0:8"))
        MSHookMessageEx(cls, getter, (IMP)ECAdSwiftIsEmployee, (IMP *)&orig_ECAdSwiftIsEmployee);
    SEL setter = sel_registerName("setIsEmployee:");
    if (!orig_ECAdSwiftSetIsEmployee && ECInstMatches(cls, setter, "v20@0:8B16"))
        MSHookMessageEx(cls, setter, (IMP)ECAdSwiftSetIsEmployee, (IMP *)&orig_ECAdSwiftSetIsEmployee);
}

// ===================================================================
//  Generic per-object isEmployee installer — unchanged from before.
//  part02 of SCIInternalGlobalSafe.x calls this for the live
//  deviceSession / userSession objects it holds.
// ===================================================================
static NSMutableDictionary<NSString *, NSValue *> *ECIdentityOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}
static NSString *ECIdentityKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@#%@",
            NSStringFromClass(cls) ?: @"<nil>", NSStringFromSelector(selector) ?: @"<nil>"];
}
static BOOL ECIsZeroArgBoolGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    const char *enc = method_getTypeEncoding(method);
    return enc && ECEncodingEquiv(enc, "B16@0:8");
}
static Class ECDeclaringClass(Class cls, SEL selector) {
    for (Class cur = cls; cur; cur = class_getSuperclass(cur)) {
        unsigned int count = 0; Method *methods = class_copyMethodList(cur, &count);
        BOOL declares = NO;
        for (unsigned int i = 0; methods && i < count; i++)
            if (method_getName(methods[i]) == selector) { declares = YES; break; }
        if (methods) free(methods);
        if (declares) return cur;
    }
    return Nil;
}
static BOOL ECIdentityBoolGetter(id self, SEL _cmd) {
    if (ECMasterOn()) return YES;
    IMP original = NULL;
    NSMutableDictionary<NSString *, NSValue *> *store = ECIdentityOriginals();
    @synchronized (store) {
        for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
            NSValue *v = store[ECIdentityKey(cls, _cmd)];
            if (v) { original = v.pointerValue; break; }
        }
    }
    return original ? ((BOOL (*)(id, SEL))original)(self, _cmd) : NO;
}
static BOOL ECInstallIdentitySelector(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    cls = ECDeclaringClass(cls, selector);
    if (!cls) return NO;
    // Owned by ECInstallKnownObjC() above — avoid a second, competing swizzle.
    if (cls == objc_getClass("IGFacebookUserInfo") &&
        selector == sel_registerName("isEmployee")) return YES;
    Method method = class_getInstanceMethod(cls, selector);
    if (!ECIsZeroArgBoolGetter(method)) return NO;
    NSString *key = ECIdentityKey(cls, selector);
    NSMutableDictionary<NSString *, NSValue *> *store = ECIdentityOriginals();
    @synchronized (store) { if (store[key]) return YES; }
    IMP original = NULL;
    MSHookMessageEx(cls, selector, (IMP)ECIdentityBoolGetter, &original);
    if (!original) return NO;
    @synchronized (store) { store[key] = [NSValue valueWithPointer:original]; }
    return YES;
}

// ---- Public entry points (unchanged names/signatures) ----

void SCIInstallEmployeeIdentityHooksForObject(id object) {
    if (!ECMasterOn() || !object) return;
    Class cls = object_getClass(object);
    if (cls == objc_getClass("IGFacebookUserInfo")) return;
    ECInstallIdentitySelector(cls, sel_registerName("isEmployee"));
}

void SCIInstallEmployeeIdentityHooksIfNeeded(void) {
    if (!ECMasterOn()) return;
    NSUInteger known = ECInstallKnownObjC();
    ECInstallSwiftIdentityHooks();
    ECLOG("identity install attempt: %lu/9 known-ObjC hooks now installed (idempotent; safe to call again)",
          (unsigned long)known);
}

void SCIInstallEmployeeInternalHooksIfNeeded(void) {
    // Compat entry retained for older Settings callers: defer to the global
    // installer that owns identity + MobileConfig + Bug Reporter ordering.
    SCIRequestInternalGlobalHooksInstall();
}

%ctor {
    @autoreleasepool {
        SCIInstallOnceOnActive(^{
            if (ECMasterOn()) SCIInstallEmployeeIdentityHooksIfNeeded();
        });
    }
}
