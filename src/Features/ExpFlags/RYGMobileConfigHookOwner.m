#import "RYGMobileConfig.h"
#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import <dlfcn.h>
#include <string.h>

// Persistent MobileConfig getter owner.
//
// Critical runtime rule: Instagram evaluates MobileConfig getters thousands of
// times while launching. The getter path therefore MUST be RAM-only. It must not
// touch NSUserDefaults, disk, RYGMobileConfig.shared, Objective-C ivar lookup,
// backtraces, or native override-table writes.
//
// This owner keeps a tiny canonical PID -> value snapshot in memory. Explicit
// user mutations update that snapshot. The on-disk plist is read once when the
// tweak loads; dyld callbacks only attempt exact hook installation and never
// parse files or reapply the entire native table.

static os_unfair_lock gRYGMCCacheLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSNumber *, id> *gRYGMCCachedOverrides;
static BOOL gRYGMCHookOwnerScheduled;
static BOOL gRYGMCHookOwnerActive;
static BOOL gRYGMCHookOwnerShouldRun;

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

static NSString *RYGMCOverridesStorePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [[support stringByAppendingPathComponent:@"RyukGram"] stringByAppendingPathComponent:@"mc_overrides.plist"];
}

static NSDictionary<NSNumber *, id> *RYGMCLoadDiskSnapshot(void) {
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:RYGMCOverridesStorePath()];
    if (![disk isKindOfClass:NSDictionary.class] || !disk.count) return @{};
    NSMutableDictionary<NSNumber *, id> *snapshot = [NSMutableDictionary dictionaryWithCapacity:disk.count];
    [disk enumerateKeysAndObjectsUsingBlock:^(id rawKey, id value, BOOL *stop) {
        (void)stop;
        if (![rawKey isKindOfClass:NSString.class]) return;
        const char *digits = [(NSString *)rawKey UTF8String];
        if (!digits || !*digits) return;
        char *end = NULL;
        unsigned long long pid = strtoull(digits, &end, 10);
        if (!pid || end == digits || *end != '\0') return;
        unsigned long long canonical = RYGMCForceCanonicalPID(pid);
        unsigned int type = (unsigned int)((canonical >> 48) & 0x0fULL);
        BOOL valid = type == 3 ? [value isKindOfClass:NSString.class] : [value isKindOfClass:NSNumber.class];
        if (valid) snapshot[@(canonical)] = value;
    }];
    return snapshot.copy;
}

static void RYGMCPublishSnapshot(NSDictionary<NSNumber *, id> *snapshot) {
    os_unfair_lock_lock(&gRYGMCCacheLock);
    gRYGMCCachedOverrides = snapshot.copy ?: @{};
    gRYGMCHookOwnerShouldRun = gRYGMCCachedOverrides.count > 0 || [RYGUtils getBoolPref:@"ryg_metaconfig_enabled"];
    os_unfair_lock_unlock(&gRYGMCCacheLock);
}

static void RYGMCCacheSet(unsigned long long pid, id value) {
    if (!pid) return;
    unsigned long long canonical = RYGMCForceCanonicalPID(pid);
    os_unfair_lock_lock(&gRYGMCCacheLock);
    NSMutableDictionary *next = [gRYGMCCachedOverrides mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) next[@(canonical)] = value;
    else [next removeObjectForKey:@(canonical)];
    gRYGMCCachedOverrides = next.copy;
    gRYGMCHookOwnerShouldRun = gRYGMCCachedOverrides.count > 0 || [RYGUtils getBoolPref:@"ryg_metaconfig_enabled"];
    os_unfair_lock_unlock(&gRYGMCCacheLock);
}

static void RYGMCCacheClear(void) {
    os_unfair_lock_lock(&gRYGMCCacheLock);
    gRYGMCCachedOverrides = @{};
    gRYGMCHookOwnerShouldRun = [RYGUtils getBoolPref:@"ryg_metaconfig_enabled"];
    os_unfair_lock_unlock(&gRYGMCCacheLock);
}

static id RYGMCOwnedOverride(unsigned long long pid) {
    if (!pid) return nil;
    NSNumber *key = @(RYGMCForceCanonicalPID(pid));
    os_unfair_lock_lock(&gRYGMCCacheLock);
    id value = gRYGMCCachedOverrides[key];
    os_unfair_lock_unlock(&gRYGMCCacheLock);
    return value;
}

static BOOL RYGMCOwnerShouldRunFast(void) {
    os_unfair_lock_lock(&gRYGMCCacheLock);
    BOOL value = gRYGMCHookOwnerShouldRun;
    os_unfair_lock_unlock(&gRYGMCCacheLock);
    return value;
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

static BOOL RYGMCIMPBelongsToRyukGram(IMP imp) {
    if (!imp) return NO;
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return NO;
    NSString *name = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent].lowercaseString ?: @"";
    return [name containsString:@"ryukgram"];
}

static BOOL RYGMCOwnerInstallOne(Class cls, NSString *selectorName, IMP replacement, IMP *upstream, char returnType, const char *arguments) {
    if (!cls || !selectorName.length || !replacement || !upstream) return NO;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
    if (!RYGMCOwnerMethodMatches(method, returnType, arguments)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current == replacement) return YES;

    // Preserve the first non-RyukGram implementation as the real upstream. If
    // an older RyukGram MobileConfig trampoline installs after us, put this
    // owner back on top without chaining through that expensive legacy path.
    if (!*upstream || !RYGMCIMPBelongsToRyukGram(current)) *upstream = current;
    if (!*upstream) return NO;
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
    if (!RYGMCOwnerShouldRunFast()) return;
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
}

static void RYGMCOwnerSchedule(void) {
    @synchronized(RYGMobileConfig.class) {
        if (gRYGMCHookOwnerScheduled) return;
        gRYGMCHookOwnerScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(RYGMobileConfig.class) { gRYGMCHookOwnerScheduled = NO; }
        if (!gRYGMCHookOwnerActive || !RYGMCOwnerShouldRunFast()) return;
        RYGMCOwnerInstallHooks();
    });
}

static void RYGMCOwnerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (gRYGMCHookOwnerActive && RYGMCOwnerShouldRunFast()) RYGMCOwnerSchedule();
}

@implementation RYGMobileConfig (RYGMobileConfigHookOwner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RYGMCPublishSnapshot(RYGMCLoadDiskSnapshot());
        // Capture the native upstream as early as possible, before the legacy
        // Logos MobileConfig constructor gets a chance to wrap the same getter.
        if (RYGMCOwnerShouldRunFast()) RYGMCOwnerInstallHooks();

        Method setOriginal = class_getInstanceMethod(self, @selector(setOverride:for:));
        Method setOwned = class_getInstanceMethod(self, @selector(ryg_owner_setOverride:for:));
        if (setOriginal && setOwned) method_exchangeImplementations(setOriginal, setOwned);
        Method clearOriginal = class_getInstanceMethod(self, @selector(clearOverrideFor:));
        Method clearOwned = class_getInstanceMethod(self, @selector(ryg_owner_clearOverrideFor:));
        if (clearOriginal && clearOwned) method_exchangeImplementations(clearOriginal, clearOwned);
        Method resetOriginal = class_getInstanceMethod(self, @selector(resetAllOverrides));
        Method resetOwned = class_getInstanceMethod(self, @selector(ryg_owner_resetAllOverrides));
        if (resetOriginal && resetOwned) method_exchangeImplementations(resetOriginal, resetOwned);
    });
}

- (BOOL)ryg_owner_setOverride:(id)value for:(RYGMCParam *)param {
    BOOL success = [self ryg_owner_setOverride:value for:param];
    if (success && param.paramID) {
        RYGMCCacheSet(param.paramID, value);
        gRYGMCHookOwnerActive = YES;
        RYGMCOwnerSchedule();
    }
    return success;
}

- (void)ryg_owner_clearOverrideFor:(RYGMCParam *)param {
    unsigned long long pid = param.paramID;
    [self ryg_owner_clearOverrideFor:param];
    if (pid) RYGMCCacheSet(pid, nil);
}

- (void)ryg_owner_resetAllOverrides {
    [self ryg_owner_resetAllOverrides];
    RYGMCCacheClear();
}

@end

__attribute__((constructor(110))) static void RYGInstallMobileConfigHookOwner(void) {
    @autoreleasepool {
        if (!gRYGMCCachedOverrides) RYGMCPublishSnapshot(RYGMCLoadDiskSnapshot());
        gRYGMCHookOwnerActive = YES;
        if (RYGMCOwnerShouldRunFast()) RYGMCOwnerInstallHooks();
    }

    _dyld_register_func_for_add_image(RYGMCOwnerImageDidLoad);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGMCHookOwnerActive = YES;
            if (RYGMCOwnerShouldRunFast()) RYGMCOwnerSchedule();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGMCHookOwnerActive = NO;
        }];
        // Run once after all constructors. If the legacy Logos hook installed
        // after our early capture, this puts the RAM-only owner back on top.
        if (RYGMCOwnerShouldRunFast()) RYGMCOwnerSchedule();
    });
}
