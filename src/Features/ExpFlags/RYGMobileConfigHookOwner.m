#import "RYGMobileConfig.h"
#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <string.h>

// The Developer MobileConfig browser can create real overrides even when the
// legacy ryg_metaconfig_enabled preference is off. On relaunch the old %ctor
// returned before constructing RYGMobileConfig or installing its getter hooks.
// This owner activates whenever a persisted mc_overrides.plist exists and owns
// the exact getter IMPs after UIApplication becomes active.

static BOOL gRYGMCHookOwnerScheduled;
static BOOL gRYGMCHookOwnerActive;

static IMP gRYGMCUpBool;
static IMP gRYGMCUpBoolDef;
static IMP gRYGMCUpBoolOpts;
static IMP gRYGMCUpBoolOptsDef;
static IMP gRYGMCUpInt;
static IMP gRYGMCUpIntDef;
static IMP gRYGMCUpIntOpts;
static IMP gRYGMCUpIntOptsDef;
static IMP gRYGMCUpDouble;
static IMP gRYGMCUpDoubleDef;
static IMP gRYGMCUpDoubleOpts;
static IMP gRYGMCUpDoubleOptsDef;
static IMP gRYGMCUpString;
static IMP gRYGMCUpStringDef;
static IMP gRYGMCUpStringOpts;
static IMP gRYGMCUpStringOptsDef;

static unsigned long long RYGMCForceCanonicalPID(unsigned long long pid) {
    if (!pid) return 0;
    unsigned long long type = (pid >> 48) & 0x0fULL;
    return (pid & 0x0000FFFFFFFFFFFFULL) | ((0x40ULL | type) << 48);
}

static NSDictionary<NSNumber *, id> *RYGMCOwnedOverrideDictionary(void) {
    RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
    Ivar ivar = class_getInstanceVariable(RYGMobileConfig.class, "_overrides");
    id value = ivar ? object_getIvar(mobileConfig, ivar) : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static id RYGMCOwnedOverride(unsigned long long pid) {
    NSDictionary *overrides = RYGMCOwnedOverrideDictionary();
    if (!overrides.count || !pid) return nil;
    id value = overrides[@(RYGMCForceCanonicalPID(pid))];
    if (value) return value;
    return overrides[@(pid)];
}

static NSString *RYGMCOverridesStorePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"RyukGram"] stringByAppendingPathComponent:@"mc_overrides.plist"];
}

static BOOL RYGMCHasPersistedOverrides(void) {
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:RYGMCOverridesStorePath()];
    return disk.count > 0;
}

static BOOL RYGMCOwnerShouldRun(void) {
    return [RYGUtils getBoolPref:@"ryg_metaconfig_enabled"] || RYGMCHasPersistedOverrides();
}

static const char *RYGMCUnqualified(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGMCOwnerTypeMatches(const char *raw, char expected) {
    const char *type = RYGMCUnqualified(raw);
    if (!type || !*type) return NO;
    switch (expected) {
        case 'P': return *type == 'Q' || *type == 'q' || (*type == '{' && (strstr(type, "=Q}") || strstr(type, "=q}")));
        case 'B': return *type == 'B' || *type == 'c' || *type == 'C';
        case 'Q': return *type == 'q' || *type == 'Q';
        case 'D': return *type == 'd';
        case '@': return *type == '@';
        default: return NO;
    }
}

static BOOL RYGMCOwnerMethodMatches(Method method, char returnType, const char *arguments) {
    if (!method || !arguments || method_getNumberOfArguments(method) != strlen(arguments) + 2) return NO;
    char encoded[128] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    if (!RYGMCOwnerTypeMatches(encoded, returnType)) return NO;
    for (unsigned int index = 0; arguments[index]; index++) {
        memset(encoded, 0, sizeof(encoded));
        method_getArgumentType(method, index + 2, encoded, sizeof(encoded));
        if (!RYGMCOwnerTypeMatches(encoded, arguments[index])) return NO;
    }
    return YES;
}

static BOOL RYGMCOwnerInstallOne(Class cls, NSString *selectorName, IMP replacement, IMP *upstream, char returnType, const char *arguments) {
    if (!cls || !selectorName.length || !replacement || !upstream) return NO;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    if (!RYGMCOwnerMethodMatches(method, returnType, arguments)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current == replacement) return YES;
    *upstream = current;
    (void)method_setImplementation(method, replacement);
    return method_getImplementation(method) == replacement;
}

static BOOL RYGMCOwnerBool(id self, SEL cmd, unsigned long long pid) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value boolValue] : (gRYGMCUpBool ? ((BOOL (*)(id,SEL,unsigned long long))gRYGMCUpBool)(self,cmd,pid) : NO);
}
static BOOL RYGMCOwnerBoolDef(id self, SEL cmd, unsigned long long pid, BOOL def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value boolValue] : (gRYGMCUpBoolDef ? ((BOOL (*)(id,SEL,unsigned long long,BOOL))gRYGMCUpBoolDef)(self,cmd,pid,def) : def);
}
static BOOL RYGMCOwnerBoolOpts(id self, SEL cmd, unsigned long long pid, id opts) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value boolValue] : (gRYGMCUpBoolOpts ? ((BOOL (*)(id,SEL,unsigned long long,id))gRYGMCUpBoolOpts)(self,cmd,pid,opts) : NO);
}
static BOOL RYGMCOwnerBoolOptsDef(id self, SEL cmd, unsigned long long pid, id opts, BOOL def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value boolValue] : (gRYGMCUpBoolOptsDef ? ((BOOL (*)(id,SEL,unsigned long long,id,BOOL))gRYGMCUpBoolOptsDef)(self,cmd,pid,opts,def) : def);
}
static long long RYGMCOwnerInt(id self, SEL cmd, unsigned long long pid) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value longLongValue] : (gRYGMCUpInt ? ((long long (*)(id,SEL,unsigned long long))gRYGMCUpInt)(self,cmd,pid) : 0);
}
static long long RYGMCOwnerIntDef(id self, SEL cmd, unsigned long long pid, long long def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value longLongValue] : (gRYGMCUpIntDef ? ((long long (*)(id,SEL,unsigned long long,long long))gRYGMCUpIntDef)(self,cmd,pid,def) : def);
}
static long long RYGMCOwnerIntOpts(id self, SEL cmd, unsigned long long pid, id opts) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value longLongValue] : (gRYGMCUpIntOpts ? ((long long (*)(id,SEL,unsigned long long,id))gRYGMCUpIntOpts)(self,cmd,pid,opts) : 0);
}
static long long RYGMCOwnerIntOptsDef(id self, SEL cmd, unsigned long long pid, id opts, long long def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value longLongValue] : (gRYGMCUpIntOptsDef ? ((long long (*)(id,SEL,unsigned long long,id,long long))gRYGMCUpIntOptsDef)(self,cmd,pid,opts,def) : def);
}
static double RYGMCOwnerDouble(id self, SEL cmd, unsigned long long pid) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value doubleValue] : (gRYGMCUpDouble ? ((double (*)(id,SEL,unsigned long long))gRYGMCUpDouble)(self,cmd,pid) : 0.0);
}
static double RYGMCOwnerDoubleDef(id self, SEL cmd, unsigned long long pid, double def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value doubleValue] : (gRYGMCUpDoubleDef ? ((double (*)(id,SEL,unsigned long long,double))gRYGMCUpDoubleDef)(self,cmd,pid,def) : def);
}
static double RYGMCOwnerDoubleOpts(id self, SEL cmd, unsigned long long pid, id opts) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value doubleValue] : (gRYGMCUpDoubleOpts ? ((double (*)(id,SEL,unsigned long long,id))gRYGMCUpDoubleOpts)(self,cmd,pid,opts) : 0.0);
}
static double RYGMCOwnerDoubleOptsDef(id self, SEL cmd, unsigned long long pid, id opts, double def) {
    id value = RYGMCOwnedOverride(pid);
    return value ? [value doubleValue] : (gRYGMCUpDoubleOptsDef ? ((double (*)(id,SEL,unsigned long long,id,double))gRYGMCUpDoubleOptsDef)(self,cmd,pid,opts,def) : def);
}
static id RYGMCOwnerString(id self, SEL cmd, unsigned long long pid) {
    id value = RYGMCOwnedOverride(pid);
    return [value isKindOfClass:NSString.class] ? value : (gRYGMCUpString ? ((id (*)(id,SEL,unsigned long long))gRYGMCUpString)(self,cmd,pid) : nil);
}
static id RYGMCOwnerStringDef(id self, SEL cmd, unsigned long long pid, id def) {
    id value = RYGMCOwnedOverride(pid);
    return [value isKindOfClass:NSString.class] ? value : (gRYGMCUpStringDef ? ((id (*)(id,SEL,unsigned long long,id))gRYGMCUpStringDef)(self,cmd,pid,def) : def);
}
static id RYGMCOwnerStringOpts(id self, SEL cmd, unsigned long long pid, id opts) {
    id value = RYGMCOwnedOverride(pid);
    return [value isKindOfClass:NSString.class] ? value : (gRYGMCUpStringOpts ? ((id (*)(id,SEL,unsigned long long,id))gRYGMCUpStringOpts)(self,cmd,pid,opts) : nil);
}
static id RYGMCOwnerStringOptsDef(id self, SEL cmd, unsigned long long pid, id opts, id def) {
    id value = RYGMCOwnedOverride(pid);
    return [value isKindOfClass:NSString.class] ? value : (gRYGMCUpStringOptsDef ? ((id (*)(id,SEL,unsigned long long,id,id))gRYGMCUpStringOptsDef)(self,cmd,pid,opts,def) : def);
}

static NSUInteger RYGMCOwnerScore(Class cls) {
    NSUInteger score = 0;
    for (NSString *selector in @[@"getBool:", @"getInt64:", @"getDouble:", @"getString:"])
        if (class_getInstanceMethod(cls, NSSelectorFromString(selector))) score++;
    return score;
}

static void RYGMCOwnerInstallHooks(void) {
    if (!RYGMCOwnerShouldRun()) return;
    (void)RYGMobileConfig.shared; // loads persisted mc_overrides.plist before hooks read it
    Class fb = objc_lookUpClass("FBMobileConfigContextManager");
    Class ig = objc_lookUpClass("IGMobileConfigContextManager");
    Class cls = RYGMCOwnerScore(fb) >= RYGMCOwnerScore(ig) ? fb : ig;
    if (!cls) return;

    RYGMCOwnerInstallOne(cls,@"getBool:",(IMP)RYGMCOwnerBool,&gRYGMCUpBool,'B',"P");
    RYGMCOwnerInstallOne(cls,@"getBool:withDefault:",(IMP)RYGMCOwnerBoolDef,&gRYGMCUpBoolDef,'B',"PB");
    RYGMCOwnerInstallOne(cls,@"getBool:withOptions:",(IMP)RYGMCOwnerBoolOpts,&gRYGMCUpBoolOpts,'B',"P@");
    RYGMCOwnerInstallOne(cls,@"getBool:withOptions:withDefault:",(IMP)RYGMCOwnerBoolOptsDef,&gRYGMCUpBoolOptsDef,'B',"P@B");
    RYGMCOwnerInstallOne(cls,@"getInt64:",(IMP)RYGMCOwnerInt,&gRYGMCUpInt,'Q',"P");
    RYGMCOwnerInstallOne(cls,@"getInt64:withDefault:",(IMP)RYGMCOwnerIntDef,&gRYGMCUpIntDef,'Q',"PQ");
    RYGMCOwnerInstallOne(cls,@"getInt64:withOptions:",(IMP)RYGMCOwnerIntOpts,&gRYGMCUpIntOpts,'Q',"P@");
    RYGMCOwnerInstallOne(cls,@"getInt64:withOptions:withDefault:",(IMP)RYGMCOwnerIntOptsDef,&gRYGMCUpIntOptsDef,'Q',"P@Q");
    RYGMCOwnerInstallOne(cls,@"getDouble:",(IMP)RYGMCOwnerDouble,&gRYGMCUpDouble,'D',"P");
    RYGMCOwnerInstallOne(cls,@"getDouble:withDefault:",(IMP)RYGMCOwnerDoubleDef,&gRYGMCUpDoubleDef,'D',"PD");
    RYGMCOwnerInstallOne(cls,@"getDouble:withOptions:",(IMP)RYGMCOwnerDoubleOpts,&gRYGMCUpDoubleOpts,'D',"P@");
    RYGMCOwnerInstallOne(cls,@"getDouble:withOptions:withDefault:",(IMP)RYGMCOwnerDoubleOptsDef,&gRYGMCUpDoubleOptsDef,'D',"P@D");
    RYGMCOwnerInstallOne(cls,@"getString:",(IMP)RYGMCOwnerString,&gRYGMCUpString,'@',"P");
    RYGMCOwnerInstallOne(cls,@"getString:withDefault:",(IMP)RYGMCOwnerStringDef,&gRYGMCUpStringDef,'@',"P@");
    RYGMCOwnerInstallOne(cls,@"getString:withOptions:",(IMP)RYGMCOwnerStringOpts,&gRYGMCUpStringOpts,'@',"P@");
    RYGMCOwnerInstallOne(cls,@"getString:withOptions:withDefault:",(IMP)RYGMCOwnerStringOptsDef,&gRYGMCUpStringOptsDef,'@',"P@@");

    if (RYGMobileConfig.shared.overrideCount) [RYGMobileConfig.shared reapplyOverridesToNativeTable];
}

static void RYGMCOwnerSchedule(void) {
    @synchronized(RYGMobileConfig.class) {
        if (gRYGMCHookOwnerScheduled) return;
        gRYGMCHookOwnerScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(RYGMobileConfig.class) { gRYGMCHookOwnerScheduled = NO; }
        if (!gRYGMCHookOwnerActive) return;
        RYGMCOwnerInstallHooks();
    });
}

static void RYGMCOwnerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (gRYGMCHookOwnerActive && RYGMCOwnerShouldRun()) RYGMCOwnerSchedule();
}

@implementation RYGMobileConfig (RYGMobileConfigHookOwner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(setOverride:for:));
        Method owned = class_getInstanceMethod(self, @selector(ryg_owner_setOverride:for:));
        if (original && owned) method_exchangeImplementations(original, owned);
    });
}

- (BOOL)ryg_owner_setOverride:(id)value for:(RYGMCParam *)param {
    BOOL success = [self ryg_owner_setOverride:value for:param];
    if (success) {
        gRYGMCHookOwnerActive = YES;
        RYGMCOwnerSchedule();
    }
    return success;
}

@end

__attribute__((constructor)) static void RYGInstallMobileConfigHookOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGMCHookOwnerActive = YES;
            if (RYGMCOwnerShouldRun()) RYGMCOwnerSchedule();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGMCHookOwnerActive = NO;
        }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            gRYGMCHookOwnerActive = YES;
            if (RYGMCOwnerShouldRun()) RYGMCOwnerSchedule();
        }
    });
    _dyld_register_func_for_add_image(RYGMCOwnerImageDidLoad);
}
