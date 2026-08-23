#import "RYGMobileConfig.h"
#import "../../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import <dlfcn.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Persistent MobileConfig getter owner.
//
// Instagram evaluates these getters at very high frequency during cold launch.
// The getter path therefore contains only integer arithmetic, atomic loads and
// the original call. No Objective-C dictionary lookup, NSNumber creation, lock,
// disk access, NSUserDefaults, backtrace, dladdr or native-table write is allowed
// on the hot read path.

#define RYG_MC_HOT_CAPACITY 16384u

typedef struct {
    atomic_uint_fast64_t pid;
    atomic_uintptr_t value;
} RYGMCHotSlot;

static RYGMCHotSlot gRYGMCHotSlots[RYG_MC_HOT_CAPACITY];
static os_unfair_lock gRYGMCHotMutationLock = OS_UNFAIR_LOCK_INIT;
static atomic_uint_fast32_t gRYGMCHotCount = 0;
static atomic_bool gRYGMCHookOwnerShouldRun = false;
static atomic_bool gRYGMCHooksInstalled = false;
static BOOL gRYGMCPreferenceEnabledAtLoad = NO;

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

static NSUInteger RYGMCHotIndex(unsigned long long pid) {
    uint64_t x = pid;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return (NSUInteger)(x & (RYG_MC_HOT_CAPACITY - 1u));
}

static RYGMCHotSlot *RYGMCHotFindSlot(unsigned long long canonical, BOOL create) {
    if (!canonical) return NULL;
    NSUInteger start = RYGMCHotIndex(canonical);
    for (NSUInteger probe = 0; probe < RYG_MC_HOT_CAPACITY; probe++) {
        RYGMCHotSlot *slot = &gRYGMCHotSlots[(start + probe) & (RYG_MC_HOT_CAPACITY - 1u)];
        uint64_t existing = atomic_load_explicit(&slot->pid, memory_order_acquire);
        if (existing == canonical) return slot;
        if (existing == 0) {
            if (!create) return NULL;
            atomic_store_explicit(&slot->pid, canonical, memory_order_release);
            return slot;
        }
    }
    return NULL;
}

static void RYGMCHotRefreshShouldRun(void) {
    BOOL hasOverrides = atomic_load_explicit(&gRYGMCHotCount, memory_order_acquire) > 0;
    atomic_store_explicit(&gRYGMCHookOwnerShouldRun,
                          hasOverrides || gRYGMCPreferenceEnabledAtLoad,
                          memory_order_release);
}

static void RYGMCHotSet(unsigned long long pid, id value) {
    unsigned long long canonical = RYGMCForceCanonicalPID(pid);
    if (!canonical) return;

    // Mutation is rare and serialized. Readers never take this lock.
    os_unfair_lock_lock(&gRYGMCHotMutationLock);
    RYGMCHotSlot *slot = RYGMCHotFindSlot(canonical, value != nil);
    if (slot) {
        uintptr_t previous = atomic_load_explicit(&slot->value, memory_order_acquire);
        uintptr_t next = value ? (uintptr_t)(__bridge_retained void *)value : 0;
        atomic_store_explicit(&slot->value, next, memory_order_release);
        if (!previous && next) atomic_fetch_add_explicit(&gRYGMCHotCount, 1, memory_order_acq_rel);
        else if (previous && !next) atomic_fetch_sub_explicit(&gRYGMCHotCount, 1, memory_order_acq_rel);
        // Previous values are intentionally retained until process exit. This
        // avoids a reader/use-after-free race without putting reclamation on the
        // getter path; one object is retained per explicit user mutation only.
    }
    RYGMCHotRefreshShouldRun();
    os_unfair_lock_unlock(&gRYGMCHotMutationLock);
}

static void RYGMCHotClear(void) {
    os_unfair_lock_lock(&gRYGMCHotMutationLock);
    for (NSUInteger index = 0; index < RYG_MC_HOT_CAPACITY; index++) {
        if (atomic_load_explicit(&gRYGMCHotSlots[index].pid, memory_order_relaxed) != 0)
            atomic_store_explicit(&gRYGMCHotSlots[index].value, 0, memory_order_release);
    }
    atomic_store_explicit(&gRYGMCHotCount, 0, memory_order_release);
    RYGMCHotRefreshShouldRun();
    os_unfair_lock_unlock(&gRYGMCHotMutationLock);
}

static id RYGMCOwnedOverride(unsigned long long pid) {
    unsigned long long canonical = RYGMCForceCanonicalPID(pid);
    if (!canonical) return nil;
    RYGMCHotSlot *slot = RYGMCHotFindSlot(canonical, NO);
    if (!slot) return nil;
    uintptr_t raw = atomic_load_explicit(&slot->value, memory_order_acquire);
    return raw ? (__bridge id)((void *)raw) : nil;
}

static BOOL RYGMCOwnerShouldRunFast(void) {
    return atomic_load_explicit(&gRYGMCHookOwnerShouldRun, memory_order_acquire);
}

static NSString *RYGMCOverridesStorePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [[support stringByAppendingPathComponent:@"RyukGram"] stringByAppendingPathComponent:@"mc_overrides.plist"];
}

static void RYGMCHotLoadDiskSnapshotOnce(void) {
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:RYGMCOverridesStorePath()];
    if (![disk isKindOfClass:NSDictionary.class] || !disk.count) {
        RYGMCHotRefreshShouldRun();
        return;
    }
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
        if (valid) RYGMCHotSet(canonical, value);
    }];
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

    // Preserve the first non-RyukGram implementation as the native upstream.
    // Never chain through the older telemetry/capture trampoline.
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

    BOOL installed = NO;
    installed |= RYGMCOwnerInstallOne(cls,@"getBool:",(IMP)RYGMCOwnerBool,&gRYGMCUpBool,'B',"P");
    installed |= RYGMCOwnerInstallOne(cls,@"getBool:withDefault:",(IMP)RYGMCOwnerBoolDef,&gRYGMCUpBoolDef,'B',"PB");
    installed |= RYGMCOwnerInstallOne(cls,@"getBool:withOptions:",(IMP)RYGMCOwnerBoolOpts,&gRYGMCUpBoolOpts,'B',"P@");
    installed |= RYGMCOwnerInstallOne(cls,@"getBool:withOptions:withDefault:",(IMP)RYGMCOwnerBoolOptsDef,&gRYGMCUpBoolOptsDef,'B',"P@B");
    installed |= RYGMCOwnerInstallOne(cls,@"getInt64:",(IMP)RYGMCOwnerInt,&gRYGMCUpInt,'Q',"P");
    installed |= RYGMCOwnerInstallOne(cls,@"getInt64:withDefault:",(IMP)RYGMCOwnerIntDef,&gRYGMCUpIntDef,'Q',"PQ");
    installed |= RYGMCOwnerInstallOne(cls,@"getInt64:withOptions:",(IMP)RYGMCOwnerIntOpts,&gRYGMCUpIntOpts,'Q',"P@");
    installed |= RYGMCOwnerInstallOne(cls,@"getInt64:withOptions:withDefault:",(IMP)RYGMCOwnerIntOptsDef,&gRYGMCUpIntOptsDef,'Q',"P@Q");
    installed |= RYGMCOwnerInstallOne(cls,@"getDouble:",(IMP)RYGMCOwnerDouble,&gRYGMCUpDouble,'D',"P");
    installed |= RYGMCOwnerInstallOne(cls,@"getDouble:withDefault:",(IMP)RYGMCOwnerDoubleDef,&gRYGMCUpDoubleDef,'D',"PD");
    installed |= RYGMCOwnerInstallOne(cls,@"getDouble:withOptions:",(IMP)RYGMCOwnerDoubleOpts,&gRYGMCUpDoubleOpts,'D',"P@");
    installed |= RYGMCOwnerInstallOne(cls,@"getDouble:withOptions:withDefault:",(IMP)RYGMCOwnerDoubleOptsDef,&gRYGMCUpDoubleOptsDef,'D',"P@D");
    installed |= RYGMCOwnerInstallOne(cls,@"getString:",(IMP)RYGMCOwnerString,&gRYGMCUpString,'@',"P");
    installed |= RYGMCOwnerInstallOne(cls,@"getString:withDefault:",(IMP)RYGMCOwnerStringDef,&gRYGMCUpStringDef,'@',"P@");
    installed |= RYGMCOwnerInstallOne(cls,@"getString:withOptions:",(IMP)RYGMCOwnerStringOpts,&gRYGMCUpStringOpts,'@',"P@");
    installed |= RYGMCOwnerInstallOne(cls,@"getString:withOptions:withDefault:",(IMP)RYGMCOwnerStringOptsDef,&gRYGMCUpStringOptsDef,'@',"P@@");
    if (installed) atomic_store_explicit(&gRYGMCHooksInstalled, true, memory_order_release);
}

static void RYGMCOwnerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (!RYGMCOwnerShouldRunFast() || atomic_load_explicit(&gRYGMCHooksInstalled, memory_order_acquire)) return;
    // O(1) late-load check. No disk parsing and no main-queue fan-out.
    if (objc_lookUpClass("FBMobileConfigContextManager") || objc_lookUpClass("IGMobileConfigContextManager"))
        RYGMCOwnerInstallHooks();
}

@implementation RYGMobileConfig (RYGMobileConfigHookOwner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gRYGMCPreferenceEnabledAtLoad = [RYGUtils getBoolPref:@"ryg_metaconfig_enabled"];
        RYGMCHotLoadDiskSnapshotOnce();
        RYGMCHotRefreshShouldRun();
        // Capture native IMPs before the legacy Logos constructor. The legacy
        // constructor is gated separately during bootstrap so it cannot stack.
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
        RYGMCHotSet(param.paramID, value);
        RYGMCOwnerInstallHooks();
    }
    return success;
}

- (void)ryg_owner_clearOverrideFor:(RYGMCParam *)param {
    unsigned long long pid = param.paramID;
    [self ryg_owner_clearOverrideFor:param];
    if (pid) RYGMCHotSet(pid, nil);
}

- (void)ryg_owner_resetAllOverrides {
    [self ryg_owner_resetAllOverrides];
    RYGMCHotClear();
}

@end

__attribute__((constructor(110))) static void RYGInstallMobileConfigHookOwner(void) {
    if (!RYGMCOwnerShouldRunFast()) return;
    if (!atomic_load_explicit(&gRYGMCHooksInstalled, memory_order_acquire)) RYGMCOwnerInstallHooks();
    if (!atomic_load_explicit(&gRYGMCHooksInstalled, memory_order_acquire))
        _dyld_register_func_for_add_image(RYGMCOwnerImageDidLoad);

    // One post-constructor reassertion only. It is cheap and protects against a
    // third-party/late tweak wrapping these exact getters after +load.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RYGMCOwnerShouldRunFast()) RYGMCOwnerInstallHooks();
    });
}
