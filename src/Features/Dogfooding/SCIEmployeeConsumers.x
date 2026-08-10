// SCIEmployeeConsumers.x
//
// Canonical Objective-C employee/test-user identity layer for the sideload
// build. Replaces the former SCIEmployeeInternal.x: same responsibilities and
// the same three exported entry points (so the ~14 existing callers keep
// linking), plus the initializer-argument consumers that the old file did not
// cover, and an encoding check that tolerates the runtime reporting BOOL as
// 'c'/'C' instead of 'B'.
//
// Ownership boundary (unchanged): this file owns ONLY ObjC identity surfaces.
// Bug Reporter / Internal Settings presentation and the MobileConfig getBool:
// readers stay owned exclusively by SCIInternalGlobalSafe.x. Nothing here
// hooks IGBugReportMenuViewController or FBMobileConfigContextManager, so no
// two MSHookMessageEx chains compete for the same selector.
//
// Every class/selector/ABI below was dumped from the shipped Instagram exec
// (43429 classes) and the resident FBSharedFramework (5348 classes) and matched
// before inclusion. These rewrite client-side identity only; nothing mints or
// replaces a server-side internal token. The C-level is_employee thunk is
// intentionally not hooked (its descriptor is absent in this build).

#import "../../Utils.h"
#import "SCIInternalGatePrefs.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <string.h>

#define ECLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeConsumers " fmt, ##__VA_ARGS__)

// Defined in SCIInternalGlobalSafe.x — the authoritative installer that owns
// identity + MobileConfig + Bug Reporter ordering.
void SCIRequestInternalGlobalHooksInstall(void);

// Same master switch the rest of the Dogfooding tree uses, so every Dev-menu
// toggle keeps driving this file.
static inline BOOL ECMasterOn(void) {
    return [SCIInternalGatePrefs employeeInternalMasterEnabled] ||
           [SCIUtils getBoolPref:@"sci_internal_menus"];
}
// isTestUser is a superset of employee: forced with employee, or via its pref.
static inline BOOL ECTestUserOn(void) {
    return ECMasterOn() || [SCIUtils getBoolPref:@"sci_force_ig_is_test_user"];
}

// Encoding compare that treats {'B','c','C'} as one BOOL class, so a hook is
// still installed if the runtime normalises the getter's return/arg encoding.
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
//  Known ObjC identity surface (plain classes) — %hook
// ===================================================================
%group SCIEmployeeConsumersKnownObjC

%hook IGFacebookUserInfo   // isEmployee : B16@0:8 (ivar accessor, FBSharedFramework)
- (BOOL)isEmployee { return ECMasterOn() ? YES : %orig; }
%end

%hook IGAdPlatformLogger_objc   // isEmployee B16@0:8 ; setIsEmployee: v20@0:8B16
- (BOOL)isEmployee { return ECMasterOn() ? YES : %orig; }
- (void)setIsEmployee:(BOOL)value { %orig(ECMasterOn() ? YES : value); }
%end

%hook FBWKWebView   // setIsEmployee: v20@0:8B16
- (void)setIsEmployee:(BOOL)value { %orig(ECMasterOn() ? YES : value); }
%end

%hook FBWKWebViewDelegateAdaptor   // setIsEmployee: v20@0:8B16
- (void)setIsEmployee:(BOOL)value { %orig(ECMasterOn() ? YES : value); }
%end

%end // group SCIEmployeeConsumersKnownObjC

// ===================================================================
//  Identity carried as an INITIALIZER ARGUMENT (cached by the callee;
//  no hookable getter afterwards). IG analog of the FB tweak's
//  RCDMobileConfigParams.init / FBLoom argument rewriting. Not covered
//  by any getter hook and not hooked anywhere else in the tree.
// ===================================================================
%group SCIEmployeeConsumersInitArgs

%hook IGSeenStateStore   // initWithDependencies:isEmployee: @28@0:8@16B24
- (id)initWithDependencies:(id)dependencies isEmployee:(BOOL)isEmployee {
    return %orig(dependencies, ECMasterOn() ? YES : isEmployee);
}
%end

%hook IGSeenStateLogger   // initWithIsEmployee:analyticsLogger: @28@0:8B16@20
- (id)initWithIsEmployee:(BOOL)isEmployee analyticsLogger:(id)analyticsLogger {
    return %orig(ECMasterOn() ? YES : isEmployee, analyticsLogger);
}
%end

%hook IGLeadGenAnalyticsLogger  // initWithAnalyticsLogger:userFbidV2:isEmployee: @36@0:8@16q24B32
- (id)initWithAnalyticsLogger:(id)analyticsLogger
                   userFbidV2:(long long)userFbidV2
                   isEmployee:(BOOL)isEmployee {
    return %orig(analyticsLogger, userFbidV2, ECMasterOn() ? YES : isEmployee);
}
%end

%hook IGFeedRequestQPLogger  // ...isCacheLoadEnabled:isEmployee:isTestUser: @52@0:8B16@20@28B36B40B44B48
- (id)initWithShouldIncludeRequestId:(BOOL)shouldIncludeRequestId
                    instancesManager:(id)instancesManager
            persistentFailureTracker:(id)persistentFailureTracker
             isDeferredNppTapEnabled:(BOOL)isDeferredNppTapEnabled
                  isCacheLoadEnabled:(BOOL)isCacheLoadEnabled
                          isEmployee:(BOOL)isEmployee
                          isTestUser:(BOOL)isTestUser {
    return %orig(shouldIncludeRequestId, instancesManager, persistentFailureTracker,
                 isDeferredNppTapEnabled, isCacheLoadEnabled,
                 ECMasterOn() ? YES : isEmployee,
                 ECTestUserOn() ? YES : isTestUser);
}
%end

%end // group SCIEmployeeConsumersInitArgs

// ===================================================================
//  Swift @objc identity (IGAdPlatformLogger_swift) — MSHookMessageEx
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
//  Generic per-object isEmployee installer (ported from the previous
//  file — part02 of SCIInternalGlobalSafe calls this for the live
//  deviceSession / userSession objects). Records one original IMP per
//  class#selector and forces YES under master.
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
    return enc && (ECEncodingEquiv(enc, "B16@0:8"));
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
    if (cls == objc_getClass("IGFacebookUserInfo") &&
        selector == sel_registerName("isEmployee")) return YES; // owned by %group
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

// ---- Public entry points (names preserved from SCIEmployeeInternal.x) ----

void SCIInstallEmployeeIdentityHooksForObject(id object) {
    if (!ECMasterOn() || !object) return;
    Class cls = object_getClass(object);
    if (cls == objc_getClass("IGFacebookUserInfo")) return;
    ECInstallIdentitySelector(cls, sel_registerName("isEmployee"));
}

void SCIInstallEmployeeIdentityHooksIfNeeded(void) {
    static BOOL knownInstalled = NO;
    if (!ECMasterOn()) return;
    if (!knownInstalled) {
        knownInstalled = YES;
        %init(SCIEmployeeConsumersKnownObjC);
        %init(SCIEmployeeConsumersInitArgs);
    }
    static NSArray<NSString *> *classNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classNames = @[ @"IGBaseUser", @"IGUserSession", @"IGSessionContext",
                        @"IGUserSessionContext", @"IGDeviceSession", @"IGDogfooderProd" ];
    });
    NSUInteger runtime = 0;
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (cls && ECInstallIdentitySelector(cls, sel_registerName("isEmployee"))) runtime++;
    }
    ECInstallSwiftIdentityHooks();
    ECLOG("identity installed master=%d runtime=%lu", ECMasterOn(), (unsigned long)runtime);
}

void SCIInstallEmployeeInternalHooksIfNeeded(void) {
    // Compat entry retained for older Settings callers: defer to the global
    // installer that owns identity + MobileConfig + Bug Reporter ordering.
    SCIRequestInternalGlobalHooksInstall();
}

%ctor {
    @autoreleasepool {
        if (ECMasterOn()) SCIInstallEmployeeIdentityHooksIfNeeded();
    }
}
