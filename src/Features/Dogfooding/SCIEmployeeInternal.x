// SCIEmployeeInternal.x
// Canonical employee identity layer for the sideload build.
//
// This file owns only Objective-C identity surfaces. Bug Reporter/Internal
// Settings presentation is owned exclusively by SCIInternalGlobalSafe.x.
// Keeping those responsibilities separate prevents two MSHookMessageEx chains
// from competing for the same initializer/lifecycle selectors.
//
// _ig_is_employee and _ig_is_employee_or_test_user are data descriptors in the
// audited build, not callable BOOL functions. They are never passed to an
// inline-function hook API.

#import "../../Utils.h"
#import "SCIInternalGatePrefs.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <stdlib.h>
#import <string.h>

#define EILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeIdentity " fmt, ##__VA_ARGS__)

void SCIRequestInternalGlobalHooksInstall(void);

static inline BOOL EIMasterOn(void) {
    return [SCIInternalGatePrefs employeeInternalMasterEnabled] ||
           [SCIUtils getBoolPref:@"sci_internal_menus"];
}

// MARK: - Known Objective-C identity propagation

%group SCIEmployeeKnownObjCGroup

%hook IGFacebookUserInfo
- (BOOL)isEmployee {
    return EIMasterOn() ? YES : %orig;
}
%end

%hook IGAdPlatformLogger_objc
- (BOOL)isEmployee {
    return EIMasterOn() ? YES : %orig;
}
- (void)setIsEmployee:(BOOL)value {
    %orig(EIMasterOn() ? YES : value);
}
%end

%hook FBWKWebView
- (void)setIsEmployee:(BOOL)value {
    %orig(EIMasterOn() ? YES : value);
}
%end

%hook FBWKWebViewDelegateAdaptor
- (void)setIsEmployee:(BOOL)value {
    %orig(EIMasterOn() ? YES : value);
}
%end

%end

// MARK: - Exact Swift @objc identity surface

static BOOL (*orig_EIAdLoggerSwiftIsEmployee)(id, SEL) = NULL;
static void (*orig_EIAdLoggerSwiftSetIsEmployee)(id, SEL, BOOL) = NULL;

static BOOL EIAdLoggerSwiftIsEmployee(id self, SEL _cmd) {
    if (EIMasterOn()) return YES;
    return orig_EIAdLoggerSwiftIsEmployee
        ? orig_EIAdLoggerSwiftIsEmployee(self, _cmd)
        : NO;
}

static void EIAdLoggerSwiftSetIsEmployee(id self, SEL _cmd, BOOL value) {
    if (orig_EIAdLoggerSwiftSetIsEmployee) {
        orig_EIAdLoggerSwiftSetIsEmployee(
            self, _cmd, EIMasterOn() ? YES : value);
    }
}

static BOOL EITypeEncodingMatches(Method method, const char *expected) {
    if (!method || !expected) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding && strcmp(encoding, expected) == 0;
}

static BOOL EIInstallSwiftIdentityHooks(void) {
    Class cls = objc_getClass(
        "_TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift");
    if (!cls) return NO;

    SEL getter = sel_registerName("isEmployee");
    Method getterMethod = class_getInstanceMethod(cls, getter);
    if (!orig_EIAdLoggerSwiftIsEmployee &&
        EITypeEncodingMatches(getterMethod, "B16@0:8")) {
        MSHookMessageEx(
            cls, getter, (IMP)EIAdLoggerSwiftIsEmployee,
            (IMP *)&orig_EIAdLoggerSwiftIsEmployee);
    }

    SEL setter = sel_registerName("setIsEmployee:");
    Method setterMethod = class_getInstanceMethod(cls, setter);
    if (!orig_EIAdLoggerSwiftSetIsEmployee &&
        EITypeEncodingMatches(setterMethod, "v20@0:8B16")) {
        MSHookMessageEx(
            cls, setter, (IMP)EIAdLoggerSwiftSetIsEmployee,
            (IMP *)&orig_EIAdLoggerSwiftSetIsEmployee);
    }

    return orig_EIAdLoggerSwiftIsEmployee != NULL ||
           orig_EIAdLoggerSwiftSetIsEmployee != NULL;
}

// MARK: - Exact runtime BOOL getters

static NSMutableDictionary<NSString *, NSValue *> *EIIdentityOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [NSMutableDictionary dictionary];
    });
    return store;
}

static NSString *EIIdentityKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@#%@",
            NSStringFromClass(cls) ?: @"<nil>",
            NSStringFromSelector(selector) ?: @"<nil>"];
}

static BOOL EIIsZeroArgumentBoolGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding &&
        (strcmp(encoding, "B16@0:8") == 0 ||
         strcmp(encoding, "c16@0:8") == 0 ||
         strcmp(encoding, "C16@0:8") == 0);
}

static Class EIIdentityDeclaringClass(Class cls, SEL selector) {
    for (Class current = cls; current;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL declares = NO;
        for (unsigned int index = 0; methods && index < count; index++) {
            if (method_getName(methods[index]) == selector) {
                declares = YES;
                break;
            }
        }
        if (methods) free(methods);
        if (declares) return current;
    }
    return Nil;
}

static BOOL EIIdentityBoolGetter(id self, SEL _cmd) {
    if (EIMasterOn()) return YES;

    IMP original = NULL;
    NSMutableDictionary<NSString *, NSValue *> *store =
        EIIdentityOriginals();
    @synchronized (store) {
        for (Class cls = object_getClass(self); cls;
             cls = class_getSuperclass(cls)) {
            NSValue *value = store[EIIdentityKey(cls, _cmd)];
            if (value) {
                original = value.pointerValue;
                break;
            }
        }
    }
    return original
        ? ((BOOL (*)(id, SEL))original)(self, _cmd)
        : NO;
}

static BOOL EIInstallIdentitySelectorOnClass(Class cls, SEL selector) {
    if (!cls || !selector) return NO;

    cls = EIIdentityDeclaringClass(cls, selector);
    if (!cls) return NO;

    if (cls == objc_getClass("IGFacebookUserInfo") &&
        selector == sel_registerName("isEmployee")) {
        return YES; // Owned by SCIEmployeeKnownObjCGroup.
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!EIIsZeroArgumentBoolGetter(method)) {
        if (method) {
            EILOG("skip identity %{public}s.%{public}s ABI=%{public}s",
                  class_getName(cls), sel_getName(selector),
                  method_getTypeEncoding(method) ?: "<nil>");
        }
        return NO;
    }

    NSString *key = EIIdentityKey(cls, selector);
    NSMutableDictionary<NSString *, NSValue *> *store =
        EIIdentityOriginals();
    @synchronized (store) {
        if (store[key]) return YES;
    }

    IMP original = NULL;
    MSHookMessageEx(
        cls, selector, (IMP)EIIdentityBoolGetter, &original);
    if (!original) return NO;

    @synchronized (store) {
        store[key] = [NSValue valueWithPointer:original];
    }
    EILOG("identity hook %{public}s.%{public}s",
          class_getName(cls), sel_getName(selector));
    return YES;
}

static NSUInteger EIInstallIdentityHooksOnClass(
    Class cls, BOOL includeIsEmployee
) {
    if (!cls || !includeIsEmployee) return 0;
    return EIInstallIdentitySelectorOnClass(
        cls, sel_registerName("isEmployee")) ? 1 : 0;
}

void SCIInstallEmployeeIdentityHooksForObject(id object) {
    if (!EIMasterOn() || !object) return;
    Class cls = object_getClass(object);
    BOOL includeIsEmployee =
        cls != objc_getClass("IGFacebookUserInfo");
    EIInstallIdentityHooksOnClass(cls, includeIsEmployee);
}

static NSUInteger EIInstallKnownIdentityHooks(void) {
    NSArray<NSString *> *classNames = @[
        @"IGFacebookUserInfo",
        @"IGBaseUser",
        @"IGUserSession",
        @"IGSessionContext",
        @"IGUserSessionContext",
        @"IGDeviceSession",
        @"IGDogfooderProd"
    ];

    NSUInteger installed = 0;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        BOOL includeIsEmployee =
            ![className isEqualToString:@"IGFacebookUserInfo"];
        installed += EIInstallIdentityHooksOnClass(
            cls, includeIsEmployee);
    }
    return installed;
}

// MARK: - Public installers

void SCIInstallEmployeeIdentityHooksIfNeeded(void) {
    static BOOL knownObjCInstalled = NO;

    if (!EIMasterOn()) return;

    if (!knownObjCInstalled) {
        knownObjCInstalled = YES;
        %init(SCIEmployeeKnownObjCGroup);
    }

    NSUInteger runtimeCount = EIInstallKnownIdentityHooks();
    BOOL swiftInstalled = EIInstallSwiftIdentityHooks();
    EILOG("installed master=%d runtime=%lu swift=%d",
          EIMasterOn(), (unsigned long)runtimeCount,
          swiftInstalled);
}

void SCIInstallEmployeeInternalHooksIfNeeded(void) {
    // Compatibility entry point retained for older Settings callers. The
    // authoritative global installer owns identity + MobileConfig + Bug Reporter
    // ordering and remains idempotent.
    SCIRequestInternalGlobalHooksInstall();
}

%ctor {
    @autoreleasepool {
        // Identity is safe to install synchronously for launch-linked classes.
        // The separate Internal Global constructor owns menu/MC installation.
        if (EIMasterOn()) {
            SCIInstallEmployeeIdentityHooksIfNeeded();
        }
    }
}
