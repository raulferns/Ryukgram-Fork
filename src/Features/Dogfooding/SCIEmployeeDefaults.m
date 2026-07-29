#import "SCIEmployeeDefaults.h"
#import "SCIInternalGatePrefs.h"
#import "SCIDogfoodObjectRuntime.h"
#import "../MobileConfig/SCITier2EmployeeGate.h"
#import "../../Utils.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>

#define EDLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeDefaults " fmt, ##__VA_ARGS__)

static NSString *const kSCIForceEmployeeDefaultsKey = @"sci_force_employee_defaults_persist";

static BOOL sSCIEmployeeDefaultsNSHooksInstalled = NO;
static BOOL sSCIEmployeeDefaultsIGHooksInstalled = NO;
static BOOL sSCIEmployeeDefaultsApplying = NO;

// CRASH FIX: calling NSUserDefaults inside an NSUserDefaults hook → infinite recursion.
// Hook calls SCIEmployeeDefaultsEnabled → getBoolPref → boolForKey → hook → ∞
// Cache the state as a plain C BOOL set BEFORE hooks install.
static volatile BOOL sSCIEmployeeEnabledCache = NO;

static void SCIUpdateEmployeeEnabledCache(void) {
    // Legacy global-default rewriting is intentionally separate from the
    // Employee/Internal identity master. It runs only when explicitly opted in.
    sSCIEmployeeEnabledCache =
        ![SCIUtils getBoolPref:@"sci_tier2_employee_internal"] &&
        [SCIInternalGatePrefs individualGateEnabledForKey:kSCIForceEmployeeDefaultsKey];
}

static BOOL SCIEmployeeDefaultsEnabled(void) {
    // Pure C hot path: Tier-2 suppresses an already-installed legacy hook even
    // if constructor ordering populated the old cache first.
    return sSCIEmployeeEnabledCache && !SCITier2EmployeeGateEnabled();
}

static BOOL SCIEmployeeKeyMatches(id keyObj) {
    if (![keyObj isKindOfClass:NSString.class]) return NO;
    NSString *key = (NSString *)keyObj;
    static NSSet<NSString *> *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithArray:@[
            @"ig_is_employee",
            @"ig_is_employee_or_test_user",
            @"is_employee",
            @"_ig_is_employee",
            @"_ig_is_employee_or_test_user",
            @"IGDeviceReportFBUserIsEmployeeKey",
            @"kIGDeviceReportFBUserIsEmployeeKey",
            @"FBUserIsEmployeeKey",
            @"IGFacebookUserInfo.isEmployee",
        ]];
    });
    return [exact containsObject:key];
}

static NSDictionary *SCIPatchedEmployeeDictionary(id original) {
    if (![original isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *m = [(NSDictionary *)original mutableCopy];
    m[@"isEmployee"] = @YES;
    m[@"_isEmployee"] = @YES;
    m[@"is_employee"] = @YES;
    m[@"ig_is_employee"] = @YES;
    m[@"ig_is_employee_or_test_user"] = @YES;
    return m;
}

static BOOL (*orig_NSUserDefaults_boolForKey)(id, SEL, NSString *) = NULL;
static BOOL new_NSUserDefaults_boolForKey(id self, SEL _cmd, NSString *key) {
    if (SCIEmployeeDefaultsEnabled() && SCIEmployeeKeyMatches(key)) return YES;
    return orig_NSUserDefaults_boolForKey ? orig_NSUserDefaults_boolForKey(self, _cmd, key) : NO;
}

static NSInteger (*orig_NSUserDefaults_integerForKey)(id, SEL, NSString *) = NULL;
static NSInteger new_NSUserDefaults_integerForKey(id self, SEL _cmd, NSString *key) {
    if (SCIEmployeeDefaultsEnabled() && SCIEmployeeKeyMatches(key)) return 1;
    return orig_NSUserDefaults_integerForKey ? orig_NSUserDefaults_integerForKey(self, _cmd, key) : 0;
}

static id (*orig_NSUserDefaults_objectForKey)(id, SEL, NSString *) = NULL;
static id new_NSUserDefaults_objectForKey(id self, SEL _cmd, NSString *key) {
    id v = orig_NSUserDefaults_objectForKey ? orig_NSUserDefaults_objectForKey(self, _cmd, key) : nil;
    if (!SCIEmployeeDefaultsEnabled()) return v;
    if (SCIEmployeeKeyMatches(key)) return @YES;
    if ([key isKindOfClass:NSString.class] && [key isEqualToString:@"IGFacebookCurrentUserInfoIGUserDefaultsKey"]) {
        NSDictionary *patched = SCIPatchedEmployeeDictionary(v);
        return patched ?: v;
    }
    return v;
}

static BOOL (*orig_generic_boolForKey)(id, SEL, NSString *) = NULL;
static BOOL new_generic_boolForKey(id self, SEL _cmd, NSString *key) {
    if (SCIEmployeeDefaultsEnabled() && SCIEmployeeKeyMatches(key)) return YES;
    return orig_generic_boolForKey ? orig_generic_boolForKey(self, _cmd, key) : NO;
}

static id (*orig_generic_objectForKey)(id, SEL, NSString *) = NULL;
static id new_generic_objectForKey(id self, SEL _cmd, NSString *key) {
    id v = orig_generic_objectForKey ? orig_generic_objectForKey(self, _cmd, key) : nil;
    if (!SCIEmployeeDefaultsEnabled()) return v;
    if (SCIEmployeeKeyMatches(key)) return @YES;
    if ([key isKindOfClass:NSString.class] && [key isEqualToString:@"IGFacebookCurrentUserInfoIGUserDefaultsKey"]) {
        NSDictionary *patched = SCIPatchedEmployeeDictionary(v);
        return patched ?: v;
    }
    return v;
}

@implementation SCIEmployeeDefaults

+ (BOOL)enabled { return SCIEmployeeDefaultsEnabled(); }

+ (NSArray<NSString *> *)employeeDefaultKeys {
    return @[
        @"ig_is_employee",
        @"ig_is_employee_or_test_user",
        @"is_employee",
        @"_ig_is_employee",
        @"_ig_is_employee_or_test_user",
        @"IGDeviceReportFBUserIsEmployeeKey",
        @"kIGDeviceReportFBUserIsEmployeeKey",
        @"FBUserIsEmployeeKey",
        @"IGFacebookUserInfo.isEmployee",
    ];
}

+ (void)installHooksIfNeeded {
    SCIUpdateEmployeeEnabledCache(); // populate cache before any hooks install
    if (!SCIEmployeeDefaultsEnabled()) return;
    if (!sSCIEmployeeDefaultsNSHooksInstalled) {
        sSCIEmployeeDefaultsNSHooksInstalled = YES;
        Class nsud = NSUserDefaults.class;
        if (class_getInstanceMethod(nsud, @selector(boolForKey:))) {
            MSHookMessageEx(nsud, @selector(boolForKey:), (IMP)new_NSUserDefaults_boolForKey, (IMP *)&orig_NSUserDefaults_boolForKey);
        }
        if (class_getInstanceMethod(nsud, @selector(integerForKey:))) {
            MSHookMessageEx(nsud, @selector(integerForKey:), (IMP)new_NSUserDefaults_integerForKey, (IMP *)&orig_NSUserDefaults_integerForKey);
        }
        if (class_getInstanceMethod(nsud, @selector(objectForKey:))) {
            MSHookMessageEx(nsud, @selector(objectForKey:), (IMP)new_NSUserDefaults_objectForKey, (IMP *)&orig_NSUserDefaults_objectForKey);
        }
        EDLOG("NSUserDefaults hooks installed");
    }

    // IGUserDefaults usually appears after session creation. Keep this retryable.
    if (!sSCIEmployeeDefaultsIGHooksInstalled) {
        Class igud = NSClassFromString(@"IGUserDefaults");
        if (igud) {
            BOOL hooked = NO;
            if (class_getInstanceMethod(igud, @selector(boolForKey:)) && !orig_generic_boolForKey) {
                MSHookMessageEx(igud, @selector(boolForKey:), (IMP)new_generic_boolForKey, (IMP *)&orig_generic_boolForKey);
                hooked = hooked || (orig_generic_boolForKey != NULL);
            }
            if (class_getInstanceMethod(igud, @selector(objectForKey:)) && !orig_generic_objectForKey) {
                MSHookMessageEx(igud, @selector(objectForKey:), (IMP)new_generic_objectForKey, (IMP *)&orig_generic_objectForKey);
                hooked = hooked || (orig_generic_objectForKey != NULL);
            }
            sSCIEmployeeDefaultsIGHooksInstalled = hooked;
            EDLOG("IGUserDefaults hooks %{public}s", hooked ? "installed" : "not-installed");
        }
    }

    [self applyToStandardDefaults];
}

+ (void)applyToStandardDefaults {
    if (!SCIEmployeeDefaultsEnabled() || sSCIEmployeeDefaultsApplying) return;
    sSCIEmployeeDefaultsApplying = YES;
    @try {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        for (NSString *key in [self employeeDefaultKeys]) {
            [d setObject:@YES forKey:key];
        }
        [d setObject:@YES forKey:@"IGDeviceReportFBUserIsEmployeeKey"];
        [d setObject:@YES forKey:@"ig_is_employee"];
        [d setObject:@YES forKey:@"ig_is_employee_or_test_user"];
        [d synchronize];
        EDLOG("standard defaults persisted");
    } @catch (id ex) {
        EDLOG("standard defaults exception: %{public}@", ex);
    }
    sSCIEmployeeDefaultsApplying = NO;
}

+ (void)applyToObject:(id)obj source:(NSString *)source {
    if (!obj || !SCIEmployeeDefaultsEnabled()) return;
    @try {
        for (NSString *key in [self employeeDefaultKeys]) {
            if ([obj respondsToSelector:@selector(setBool:forKey:)]) {
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(obj, @selector(setBool:forKey:), YES, key);
            } else if ([obj respondsToSelector:@selector(setObject:forKey:)]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(obj, @selector(setObject:forKey:), @YES, key);
            } else if ([obj respondsToSelector:@selector(setValue:forKey:)]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(obj, @selector(setValue:forKey:), @YES, key);
            }
        }
        if ([obj respondsToSelector:@selector(synchronize)]) {
            ((void (*)(id, SEL))objc_msgSend)(obj, @selector(synchronize));
        }
        [SCIDogfoodObjectRuntime noteAction:@"employee defaults" status:@"applied" detail:[NSString stringWithFormat:@"%@ %@", source ?: @"object", obj]];
        EDLOG("applied to %{public}@", source ?: @"object");
    } @catch (id ex) {
        EDLOG("apply object exception %{public}@", ex);
    }
}

+ (id)objectIvar:(id)obj named:(NSString *)name {
    if (!obj || !name.length) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name.UTF8String);
    if (!iv) iv = class_getInstanceVariable([obj class], name.UTF8String);
    if (!iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc || enc[0] != '@') return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused id e) { return nil; }
}

+ (id)objectViaSelector:(id)obj selector:(NSString *)selName {
    if (!obj || !selName.length) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); } @catch (__unused id e) { return nil; }
}

+ (void)applyToUserSession:(id)session source:(NSString *)source {
    if (!session || !SCIEmployeeDefaultsEnabled()) return;
    [self applyToStandardDefaults];
    [self applyToObject:[self objectIvar:session named:@"_userDefaults"] source:@"IGUserSession._userDefaults"];
    [self applyToObject:[self objectIvar:session named:@"_sessionUserDefaults"] source:@"IGUserSession._sessionUserDefaults"];
    [self applyToObject:[self objectIvar:session named:@"userDefaults"] source:@"IGUserSession.userDefaults ivar"];
    [self applyToObject:[self objectIvar:session named:@"sessionUserDefaults"] source:@"IGUserSession.sessionUserDefaults ivar"];
    [self applyToObject:[self objectViaSelector:session selector:@"userDefaults"] source:@"IGUserSession.userDefaults"];
    [self applyToObject:[self objectViaSelector:session selector:@"sessionUserDefaults"] source:@"IGUserSession.sessionUserDefaults"];
    [self applyToObject:[self objectViaSelector:session selector:@"preferences"] source:@"IGUserSession.preferences"];
    [SCIDogfoodObjectRuntime noteAction:@"employee defaults" status:@"session" detail:source ?: @"session"];
}

@end
