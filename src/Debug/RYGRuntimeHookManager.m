#import "RYGRuntimeHookManager.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeLiveObserver.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kRYGRuntimeSpecsV7Key = @"ryg_runtime_bool_hook_specs_v7";
static NSString *const kRYGRuntimeV6Key = @"ryg_runtime_bool_hook_specs_v6";
static NSString *const kRYGRuntimeLegacyV5Key = @"ryg_runtime_method_overrides_v5";
static NSString *const kRYGRuntimeLegacyV4Key = @"ryg_runtime_method_overrides_v4";
static NSString *const kRYGRuntimeQuarantineKey = @"ryg_runtime_override_quarantine_v7";
static NSString *const kRYGRuntimeLegacyBulkCleanupV8Key = @"ryg_runtime_legacy_bulk_cleanup_v8";
static NSString *const kRYGRuntimeCSpecsV7Key = @"ryg_runtime_c_hook_specs_v7";
static NSString *const kRYGRuntimeCV6Key = @"ryg_runtime_c_hook_specs_v6";
static NSString *const kRYGRuntimeCLegacyV5Key = @"ryg_runtime_c_overrides_v5";
static NSString *const kRYGRuntimeCLegacyV4Key = @"ryg_runtime_c_overrides_v4";

// Generic Runtime Browser persistence is bounded by design. Dedicated Developer
// features have their own exact owners and are not subject to this cap.
static const NSUInteger kRYGRuntimePersistentSpecLimit = 128;
static const NSUInteger kRYGRuntimeCPersistentSpecLimit = 8;

typedef struct {
    atomic_bool forcedSet;
    atomic_bool forcedValue;
    // -1 = never observed, 0 = false, 1 = true.
    atomic_int nativeValue;
} RYGRuntimeHotState;

@interface RYGRuntimeHookRecord : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) Class owner;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, assign) BOOL classMethod;
@property (nonatomic, assign) RYGRuntimeArgumentKind kind;
@property (nonatomic, assign) IMP upstream;
@property (nonatomic, assign) IMP replacement;
@property (nonatomic, assign) RYGRuntimeHotState *state;
@end
@implementation RYGRuntimeHookRecord @end

static os_unfair_lock gRYGRuntimeLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *gRYGRuntimeValues;
static NSMutableDictionary<NSString *, NSNumber *> *gRYGRuntimeObserved;
static NSMutableDictionary<NSString *, RYGRuntimeHookRecord *> *gRYGRuntimeHooks;
static NSMutableDictionary<NSString *, NSDictionary *> *gRYGRuntimeSpecs;
static NSMutableSet<NSString *> *gRYGRuntimePending;
static dispatch_once_t gRYGRuntimeStoreOnce;

static NSMutableDictionary<NSString *, NSDictionary *> *gRYGCRecords;
static NSMutableSet<NSString *> *gRYGCPending;
static dispatch_once_t gRYGCStoreOnce;

static os_unfair_lock gRYGRestoreLock = OS_UNFAIR_LOCK_INIT;
static BOOL gRYGRestoreScheduled;

static dispatch_queue_t RYGRuntimeRestoreQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.runtime-hook-restore", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static const char *RYGHookSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGHookBoolReturn(Method method) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGHookSkipQualifiers(encoded);
    return type && strchr("BcC", *type) != NULL;
}

static RYGRuntimeArgumentKind RYGHookArgumentKind(Method method) {
    if (!method || !RYGHookBoolReturn(method)) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[96] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    const char *type = RYGHookSkipQualifiers(encoded);
    if (!type || !*type) return (RYGRuntimeArgumentKind)-1;
    if (*type == '@') return RYGRuntimeArgumentObject;
    if (*type == 'q' || *type == 'Q') return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

// Direct lookup avoids +resolveInstanceMethod: and makes replay deterministic.
static Method RYGHookDirectMethod(Class owner, SEL selector) {
    if (!owner || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    Method found = NULL;
    for (unsigned int index = 0; methods && index < count; index++) {
        if (method_getName(methods[index]) == selector) { found = methods[index]; break; }
    }
    if (methods) free(methods);
    return found;
}

static BOOL RYGHookParseLegacyKey(NSString *key, NSString **className, NSString **selectorName, BOOL *classMethod) {
    if (![key isKindOfClass:NSString.class] || key.length < 4) return NO;
    unichar prefix = [key characterAtIndex:0];
    if (prefix != '+' && prefix != '-') return NO;
    NSString *body = [key substringFromIndex:1];
    NSRange separator = [body rangeOfString:@"#"];
    if (separator.location == NSNotFound || separator.location == 0 || NSMaxRange(separator) >= body.length) return NO;
    if (className) *className = [body substringToIndex:separator.location];
    if (selectorName) *selectorName = [body substringFromIndex:NSMaxRange(separator)];
    if (classMethod) *classMethod = prefix == '+';
    return YES;
}

static NSString *RYGHookKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@%@#%@", classMethod ? @"+" : @"-", className ?: @"", selectorName ?: @""];
}

static NSDictionary *RYGHookValidatedSpec(id raw, NSString *fallbackKey, NSNumber *legacyValue) {
    NSString *className = nil;
    NSString *selectorName = nil;
    NSNumber *meta = nil;
    NSNumber *kind = nil;
    NSNumber *value = legacyValue;

    if ([raw isKindOfClass:NSDictionary.class]) {
        NSDictionary *input = raw;
        className = [input[@"class"] isKindOfClass:NSString.class] ? input[@"class"] : nil;
        selectorName = [input[@"selector"] isKindOfClass:NSString.class] ? input[@"selector"] : nil;
        meta = [input[@"meta"] isKindOfClass:NSNumber.class] ? input[@"meta"] : nil;
        kind = [input[@"kind"] isKindOfClass:NSNumber.class] ? input[@"kind"] : nil;
        value = [input[@"value"] isKindOfClass:NSNumber.class] ? input[@"value"] : value;
    }
    if ((!className.length || !selectorName.length || !meta) && fallbackKey.length) {
        BOOL classMethod = NO;
        if (!RYGHookParseLegacyKey(fallbackKey, &className, &selectorName, &classMethod)) return nil;
        meta = @(classMethod);
    }
    if (!className.length || !selectorName.length || !meta || !value) return nil;

    NSInteger rawKind = kind ? kind.integerValue : -1;
    if (rawKind < RYGRuntimeArgumentNone || rawKind > RYGRuntimeArgumentInteger) {
        Class cls = objc_lookUpClass(className.UTF8String);
        Class owner = cls ? (meta.boolValue ? object_getClass(cls) : cls) : Nil;
        Method method = RYGHookDirectMethod(owner, NSSelectorFromString(selectorName));
        rawKind = RYGHookArgumentKind(method);
    }
    if (rawKind < RYGRuntimeArgumentNone || rawKind > RYGRuntimeArgumentInteger) return nil;
    return @{@"class":className, @"selector":selectorName, @"meta":@(meta.boolValue), @"kind":@(rawKind), @"value":@(value.boolValue)};
}

static NSArray<NSString *> *RYGSortedStringKeys(NSDictionary *dictionary) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in dictionary) if ([key isKindOfClass:NSString.class]) [keys addObject:key];
    [keys sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return keys.copy;
}

static void RYGWriteQuarantine(NSUInteger originalCount, NSUInteger keptCount, NSString *source) {
    if (originalCount <= keptCount) return;
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"reason": @"pathological generic Runtime Browser persistence was bounded to protect launch time",
        @"source": source ?: @"unknown",
        @"original_count": @(originalCount),
        @"kept_count": @(keptCount),
        @"dropped_count": @(originalCount - keptCount),
    } forKey:kRYGRuntimeQuarantineKey];
}

static void RYGWritePersistedSpecs(NSDictionary *snapshot) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (snapshot.count) [defaults setObject:snapshot forKey:kRYGRuntimeSpecsV7Key];
    else [defaults removeObjectForKey:kRYGRuntimeSpecsV7Key];
    [defaults removeObjectForKey:kRYGRuntimeV6Key];
    [defaults removeObjectForKey:kRYGRuntimeLegacyV5Key];
    [defaults removeObjectForKey:kRYGRuntimeLegacyV4Key];
    [defaults synchronize];
}

// Builds prior to session-only Reveal All could migrate a huge bulk set into a
// capped v7 dictionary. If the quarantine record proves that happened and the
// v7 count still exactly matches the untouched migrated subset, purge that
// polluted generic set once. Dedicated Developer/MobileConfig owners are stored
// elsewhere and are unaffected.
static void RYGPurgeUntouchedLegacyBulkIfNeeded(NSUserDefaults *defaults) {
    if ([defaults boolForKey:kRYGRuntimeLegacyBulkCleanupV8Key]) return;
    NSDictionary *quarantine = [defaults dictionaryForKey:kRYGRuntimeQuarantineKey];
    NSString *source = [quarantine[@"source"] isKindOfClass:NSString.class] ? quarantine[@"source"] : @"";
    NSUInteger original = [quarantine[@"original_count"] unsignedIntegerValue];
    NSUInteger kept = [quarantine[@"kept_count"] unsignedIntegerValue];
    NSDictionary *current = [defaults dictionaryForKey:kRYGRuntimeSpecsV7Key];
    BOOL legacyBulk = ([source isEqualToString:@"v4"] || [source isEqualToString:@"v5"] || [source containsString:@"legacy"]);
    BOOL untouchedSubset = legacyBulk && original > kept && kept >= 32 && current.count == kept;
    if (untouchedSubset) {
        [defaults removeObjectForKey:kRYGRuntimeSpecsV7Key];
        [defaults removeObjectForKey:kRYGRuntimeV6Key];
        [defaults removeObjectForKey:kRYGRuntimeLegacyV5Key];
        [defaults removeObjectForKey:kRYGRuntimeLegacyV4Key];
        [defaults setObject:@{
            @"reason": @"legacy bulk Reveal All persistence removed to restore launch performance",
            @"source": source,
            @"original_count": @(original),
            @"kept_count": @0,
            @"dropped_count": @(current.count),
        } forKey:kRYGRuntimeQuarantineKey];
    }
    [defaults setBool:YES forKey:kRYGRuntimeLegacyBulkCleanupV8Key];
    // No synchronize here: cold launch must not wait for preference flushing.
}

static void RYGHookLoadStore(void) {
    dispatch_once(&gRYGRuntimeStoreOnce, ^{
        gRYGRuntimeValues = [NSMutableDictionary dictionary];
        gRYGRuntimeObserved = [NSMutableDictionary dictionary];
        gRYGRuntimeHooks = [NSMutableDictionary dictionary];
        gRYGRuntimeSpecs = [NSMutableDictionary dictionary];
        gRYGRuntimePending = [NSMutableSet set];

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        RYGPurgeUntouchedLegacyBulkIfNeeded(defaults);
        NSDictionary *source = [defaults dictionaryForKey:kRYGRuntimeSpecsV7Key];
        NSString *sourceName = @"v7";
        BOOL legacyValuesOnly = NO;
        if (!source.count) { source = [defaults dictionaryForKey:kRYGRuntimeV6Key]; sourceName = @"v6"; }
        if (!source.count) { source = [defaults dictionaryForKey:kRYGRuntimeLegacyV5Key]; sourceName = @"v5"; legacyValuesOnly = YES; }
        if (!source.count) { source = [defaults dictionaryForKey:kRYGRuntimeLegacyV4Key]; sourceName = @"v4"; legacyValuesOnly = YES; }
        if (!source.count) return;

        NSArray<NSString *> *keys = RYGSortedStringKeys(source);
        NSUInteger limit = MIN(keys.count, kRYGRuntimePersistentSpecLimit);
        RYGWriteQuarantine(keys.count, limit, sourceName);
        for (NSUInteger index = 0; index < limit; index++) {
            NSString *rawKey = keys[index];
            id raw = source[rawKey];
            NSNumber *legacyValue = legacyValuesOnly && [raw isKindOfClass:NSNumber.class] ? raw : nil;
            NSDictionary *spec = RYGHookValidatedSpec(raw, rawKey, legacyValue);
            if (!spec) continue;
            NSString *key = RYGHookKey(spec[@"class"], spec[@"selector"], [spec[@"meta"] boolValue]);
            gRYGRuntimeSpecs[key] = spec;
            gRYGRuntimeValues[key] = spec[@"value"];
            [gRYGRuntimePending addObject:key];
        }

        BOOL rewrite = ![sourceName isEqualToString:@"v7"] || keys.count > limit;
        if (rewrite) {
            NSDictionary *snapshot = gRYGRuntimeSpecs.copy;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RYGWritePersistedSpecs(snapshot); });
        }
    });
}

static NSNumber *RYGHookOverride(NSString *key) {
    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    NSNumber *value = gRYGRuntimeValues[key];
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    return value;
}

static void RYGHookSetHotForced(RYGRuntimeHookRecord *record, NSNumber *value) {
    RYGRuntimeHotState *state = record.state;
    if (!state) return;
    if (value) {
        atomic_store_explicit(&state->forcedValue, value.boolValue, memory_order_relaxed);
        atomic_store_explicit(&state->forcedSet, true, memory_order_release);
    } else {
        atomic_store_explicit(&state->forcedSet, false, memory_order_release);
    }
}

static BOOL RYGHookHotResult(RYGRuntimeHookRecord *record, BOOL native) {
    RYGRuntimeHotState *state = record.state;
    if (!state) return native;
    int observed = native ? 1 : 0;
    int previous = atomic_exchange_explicit(&state->nativeValue, observed, memory_order_acq_rel);
    if (previous != observed) {
        NSString *key = record.key;
        os_unfair_lock_lock(&gRYGRuntimeLock);
        gRYGRuntimeObserved[key] = @(native);
        os_unfair_lock_unlock(&gRYGRuntimeLock);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:RYGRuntimeNativeValueDidChangeNotification
                                                               object:nil
                                                             userInfo:@{RYGRuntimeNativeValueKeyUserInfoKey:key ?: @""}];
        });
    }
    if (!atomic_load_explicit(&state->forcedSet, memory_order_acquire)) return native;
    return atomic_load_explicit(&state->forcedValue, memory_order_relaxed);
}

static RYGRuntimeHookRecord *RYGHookCreateRecord(NSString *key,
                                                  Class owner,
                                                  SEL selector,
                                                  BOOL classMethod,
                                                  RYGRuntimeArgumentKind kind,
                                                  IMP upstream,
                                                  NSNumber *forcedValue) {
    RYGRuntimeHotState *state = calloc(1, sizeof(*state));
    if (!state) return nil;
    atomic_init(&state->forcedSet, forcedValue != nil);
    atomic_init(&state->forcedValue, forcedValue.boolValue);
    atomic_init(&state->nativeValue, -1);

    RYGRuntimeHookRecord *record = [RYGRuntimeHookRecord new];
    record.key = key;
    record.owner = owner;
    record.selector = selector;
    record.classMethod = classMethod;
    record.kind = kind;
    record.upstream = upstream;
    record.state = state;
    __weak RYGRuntimeHookRecord *weakRecord = record;

    if (kind == RYGRuntimeArgumentNone) {
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            RYGRuntimeHookRecord *strongRecord = weakRecord; if (!strongRecord) return NO;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id,SEL))nativeIMP)(receiver,strongRecord.selector) : NO;
            return RYGHookHotResult(strongRecord, native);
        });
    } else if (kind == RYGRuntimeArgumentObject) {
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
            RYGRuntimeHookRecord *strongRecord = weakRecord; if (!strongRecord) return NO;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id,SEL,id))nativeIMP)(receiver,strongRecord.selector,argument) : NO;
            return RYGHookHotResult(strongRecord, native);
        });
    } else if (kind == RYGRuntimeArgumentInteger) {
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver, uint64_t argument) {
            RYGRuntimeHookRecord *strongRecord = weakRecord; if (!strongRecord) return NO;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id,SEL,uint64_t))nativeIMP)(receiver,strongRecord.selector,argument) : NO;
            return RYGHookHotResult(strongRecord, native);
        });
    }

    if (!record.replacement) { free(state); return nil; }
    return record;
}

static BOOL RYGHookInstallExact(NSString *className,
                                NSString *selectorName,
                                BOOL classMethod,
                                RYGRuntimeArgumentKind expectedKind,
                                NSString *key) {
    if (!className.length || !selectorName.length || !key.length) return NO;
    Class cls = objc_lookUpClass(className.UTF8String); if (!cls) return NO;
    Class owner = classMethod ? object_getClass(cls) : cls;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = RYGHookDirectMethod(owner,selector);
    RYGRuntimeArgumentKind runtimeKind = RYGHookArgumentKind(method);
    if (!owner || !method || runtimeKind < RYGRuntimeArgumentNone || runtimeKind > RYGRuntimeArgumentInteger) return NO;
    if (expectedKind >= RYGRuntimeArgumentNone && expectedKind <= RYGRuntimeArgumentInteger && runtimeKind != expectedKind) return NO;
    IMP current = method_getImplementation(method); if (!current) return NO;

    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    RYGRuntimeHookRecord *record = gRYGRuntimeHooks[key];
    if (record && current == record.replacement) {
        RYGHookSetHotForced(record, gRYGRuntimeValues[key]);
        os_unfair_lock_unlock(&gRYGRuntimeLock);
        return YES;
    }
    if (!record || record.owner != owner || record.selector != selector || record.kind != runtimeKind) {
        record = RYGHookCreateRecord(key, owner, selector, classMethod, runtimeKind, current, gRYGRuntimeValues[key]);
        if (!record) { os_unfair_lock_unlock(&gRYGRuntimeLock); return NO; }
        gRYGRuntimeHooks[key] = record;
    } else {
        record.upstream = current;
        RYGHookSetHotForced(record, gRYGRuntimeValues[key]);
    }
    IMP replacement = record.replacement;
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    (void)method_setImplementation(method,replacement);
    return method_getImplementation(method) == replacement;
}

static BOOL RYGHookInstallMethod(RYGRuntimeBoolMethod *method) {
    if (![method isKindOfClass:RYGRuntimeBoolMethod.class] || !method.className.length || !method.selectorName.length) return NO;
    return RYGHookInstallExact(method.className,method.selectorName,method.classMethod,method.argumentKind,method.overrideKey);
}

static NSString *RYGCImageID(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *executable = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if ([standard isEqualToString:executable]) return @"@executable";
    NSString *root = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([standard hasPrefix:prefix]) return [standard substringFromIndex:prefix.length];
    return standard.lastPathComponent ?: @"";
}

static NSString *RYGCLoadedPath(NSString *imageID) {
    if (!imageID.length) return nil;
    if ([imageID isEqualToString:@"@executable"]) return NSBundle.mainBundle.executablePath;
    for (uint32_t index=0; index<_dyld_image_count(); index++) {
        const char *raw=_dyld_get_image_name(index); if (!raw) continue;
        NSString *path=[[NSString stringWithUTF8String:raw] stringByStandardizingPath];
        if ([RYGCImageID(path) caseInsensitiveCompare:imageID] == NSOrderedSame) return path;
    }
    return nil;
}

static void RYGCWriteDefaults(NSDictionary *records) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if (records.count) [defaults setObject:records forKey:kRYGRuntimeCSpecsV7Key];
    else [defaults removeObjectForKey:kRYGRuntimeCSpecsV7Key];
    [defaults removeObjectForKey:kRYGRuntimeCV6Key];
    [defaults removeObjectForKey:kRYGRuntimeCLegacyV5Key];
    [defaults removeObjectForKey:kRYGRuntimeCLegacyV4Key];
    [defaults synchronize];
}

static void RYGCLoadStore(void) {
    dispatch_once(&gRYGCStoreOnce, ^{
        gRYGCRecords=[NSMutableDictionary dictionary];
        gRYGCPending=[NSMutableSet set];
        NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
        NSDictionary *source=[defaults dictionaryForKey:kRYGRuntimeCSpecsV7Key];
        BOOL rewrite=NO;
        if (!source.count) { source=[defaults dictionaryForKey:kRYGRuntimeCV6Key]; rewrite=source.count>0; }
        if (!source.count) { source=[defaults dictionaryForKey:kRYGRuntimeCLegacyV5Key]; rewrite=source.count>0; }
        if (!source.count) { source=[defaults dictionaryForKey:kRYGRuntimeCLegacyV4Key]; rewrite=source.count>0; }
        NSArray *keys=RYGSortedStringKeys(source ?: @{});
        NSUInteger limit=MIN(keys.count,kRYGRuntimeCPersistentSpecLimit);
        if (keys.count>limit) { RYGWriteQuarantine(keys.count,limit,@"C-import persistence"); rewrite=YES; }
        for (NSUInteger index=0; index<limit; index++) {
            id record=source[keys[index]];
            if (![record isKindOfClass:NSDictionary.class]) continue;
            gRYGCRecords[keys[index]]=record;
            [gRYGCPending addObject:keys[index]];
        }
        if (rewrite) {
            NSDictionary *snapshot=gRYGCRecords.copy;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{ RYGCWriteDefaults(snapshot); });
        }
    });
}

static NSMutableDictionary *RYGCStoredMutable(void) {
    RYGCLoadStore();
    @synchronized(RYGRuntimeHookManager.class) { return gRYGCRecords.mutableCopy ?: [NSMutableDictionary dictionary]; }
}

static void RYGCWrite(NSDictionary *records) {
    RYGCLoadStore();
    @synchronized(RYGRuntimeHookManager.class) { gRYGCRecords=[records mutableCopy] ?: [NSMutableDictionary dictionary]; }
    RYGCWriteDefaults(records ?: @{});
}

static BOOL RYGHasPendingRestore(void) {
    RYGHookLoadStore(); RYGCLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    BOOL methodPending=gRYGRuntimePending.count>0;
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    @synchronized(RYGRuntimeHookManager.class) { return methodPending || gRYGCPending.count>0; }
}

@implementation RYGRuntimeHookManager

+ (BOOL)observeMethod:(RYGRuntimeBoolMethod *)method { RYGHookLoadStore(); return RYGHookInstallMethod(method); }

+ (NSNumber *)observedNativeValueForKey:(NSString *)overrideKey {
    if (!overrideKey.length) return nil;
    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    NSNumber *value=gRYGRuntimeObserved[overrideKey];
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    return value;
}

+ (NSNumber *)overrideForKey:(NSString *)overrideKey { return overrideKey.length ? RYGHookOverride(overrideKey) : nil; }

+ (BOOL)setSessionOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method {
    if (![method isKindOfClass:RYGRuntimeBoolMethod.class] || !method.overrideKey.length) return NO;
    if (value && !RYGHookInstallMethod(method)) return NO;
    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    if (value) gRYGRuntimeValues[method.overrideKey]=@(value.boolValue);
    else [gRYGRuntimeValues removeObjectForKey:method.overrideKey];
    RYGRuntimeHookRecord *record=gRYGRuntimeHooks[method.overrideKey];
    RYGHookSetHotForced(record,value);
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    return YES;
}

+ (BOOL)setOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method {
    if (![method isKindOfClass:RYGRuntimeBoolMethod.class] || !method.overrideKey.length) return NO;
    if (value && !RYGHookInstallMethod(method)) return NO;
    RYGHookLoadStore();
    NSString *key=method.overrideKey;
    NSDictionary *snapshot=nil;
    os_unfair_lock_lock(&gRYGRuntimeLock);
    if (value) {
        NSNumber *normalized=@(value.boolValue);
        gRYGRuntimeValues[key]=normalized;
        BOOL already=gRYGRuntimeSpecs[key]!=nil;
        if (already || gRYGRuntimeSpecs.count<kRYGRuntimePersistentSpecLimit)
            gRYGRuntimeSpecs[key]=@{@"class":method.className ?: @"",@"selector":method.selectorName ?: @"",@"meta":@(method.classMethod),@"kind":@(method.argumentKind),@"value":normalized};
        [gRYGRuntimePending removeObject:key];
    } else {
        [gRYGRuntimeValues removeObjectForKey:key];
        [gRYGRuntimeSpecs removeObjectForKey:key];
        [gRYGRuntimePending removeObject:key];
    }
    RYGHookSetHotForced(gRYGRuntimeHooks[key],value);
    snapshot=gRYGRuntimeSpecs.copy ?: @{};
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    RYGWritePersistedSpecs(snapshot);
    return YES;
}

+ (void)restorePersistedOverrides {
    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    NSArray<NSString *> *pending=gRYGRuntimePending.allObjects.copy ?: @[];
    NSDictionary *specs=gRYGRuntimeSpecs.copy ?: @{};
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    for (NSString *key in pending) {
        NSDictionary *spec=specs[key]; if (!spec) continue;
        if (RYGHookInstallExact(spec[@"class"],spec[@"selector"],[spec[@"meta"] boolValue],(RYGRuntimeArgumentKind)[spec[@"kind"] integerValue],key)) {
            os_unfair_lock_lock(&gRYGRuntimeLock);
            [gRYGRuntimePending removeObject:key];
            os_unfair_lock_unlock(&gRYGRuntimeLock);
        }
    }
}

+ (NSUInteger)persistedOverrideCount {
    RYGHookLoadStore();
    os_unfair_lock_lock(&gRYGRuntimeLock);
    NSUInteger count=gRYGRuntimeSpecs.count;
    os_unfair_lock_unlock(&gRYGRuntimeLock);
    return count;
}

@end

@interface RYGRuntimeBrowserEngine (RYGRuntimeHookManagerBridge)
+ (BOOL)ryg_manager_observeMethod:(RYGRuntimeBoolMethod *)method;
+ (NSNumber *)ryg_manager_observedNativeValueForKey:(NSString *)overrideKey;
+ (NSNumber *)ryg_manager_overrideForKey:(NSString *)overrideKey;
+ (void)ryg_manager_setOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method;
+ (void)ryg_manager_reinstallPersistedOverrides;
+ (BOOL)ryg_manager_setCOverride:(NSNumber *)value forSymbol:(RYGMachOSymbol *)symbol abi:(RYGCFunctionABI)abi;
@end

@implementation RYGRuntimeBrowserEngine (RYGRuntimeHookManagerBridge)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct { SEL original; SEL replacement; } swaps[]={
            {@selector(observeMethod:),@selector(ryg_manager_observeMethod:)},
            {@selector(observedNativeValueForKey:),@selector(ryg_manager_observedNativeValueForKey:)},
            {@selector(overrideForKey:),@selector(ryg_manager_overrideForKey:)},
            {@selector(setOverride:forMethod:),@selector(ryg_manager_setOverride:forMethod:)},
            {@selector(reinstallPersistedOverrides),@selector(ryg_manager_reinstallPersistedOverrides)},
            {@selector(setCOverride:forSymbol:abi:),@selector(ryg_manager_setCOverride:forSymbol:abi:)},
        };
        for (NSUInteger index=0;index<sizeof(swaps)/sizeof(swaps[0]);index++) {
            Method original=class_getClassMethod(self,swaps[index].original);
            Method replacement=class_getClassMethod(self,swaps[index].replacement);
            if (original&&replacement) method_exchangeImplementations(original,replacement);
        }
    });
}

+ (BOOL)ryg_manager_observeMethod:(RYGRuntimeBoolMethod *)method { return [RYGRuntimeHookManager observeMethod:method]; }
+ (NSNumber *)ryg_manager_observedNativeValueForKey:(NSString *)overrideKey { return [RYGRuntimeHookManager observedNativeValueForKey:overrideKey]; }
+ (NSNumber *)ryg_manager_overrideForKey:(NSString *)overrideKey { return [RYGRuntimeHookManager overrideForKey:overrideKey]; }
+ (void)ryg_manager_setOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method { (void)[RYGRuntimeHookManager setOverride:value forMethod:method]; }

+ (void)ryg_manager_reinstallPersistedOverrides {
    [RYGRuntimeHookManager restorePersistedOverrides];
    RYGCLoadStore();
    @synchronized(RYGRuntimeHookManager.class) {
        NSArray *pending=gRYGCPending.allObjects.copy ?: @[];
        NSDictionary *records=gRYGCRecords.copy ?: @{};
        for (NSString *key in pending) {
            NSDictionary *record=records[key]; if (![record isKindOfClass:NSDictionary.class]) continue;
            NSString *imageID=[record[@"image"] isKindOfClass:NSString.class] ? record[@"image"] : nil;
            NSString *name=[record[@"name"] isKindOfClass:NSString.class] ? record[@"name"] : nil;
            NSNumber *abi=[record[@"abi"] isKindOfClass:NSNumber.class] ? record[@"abi"] : nil;
            NSNumber *value=[record[@"value"] isKindOfClass:NSNumber.class] ? record[@"value"] : nil;
            NSString *path=RYGCLoadedPath(imageID);
            if (!path.length||!name.length||!abi||!value) continue;
            RYGMachOSymbol *symbol=[RYGMachOSymbol new];
            symbol.imagePath=path; symbol.name=name; symbol.external=YES; symbol.rebindableImport=YES;
            if ([self ryg_manager_setCOverride:value forSymbol:symbol abi:(RYGCFunctionABI)abi.integerValue])
                [gRYGCPending removeObject:key];
        }
    }
}

+ (BOOL)ryg_manager_setCOverride:(NSNumber *)value forSymbol:(RYGMachOSymbol *)symbol abi:(RYGCFunctionABI)abi {
    // After method exchange this selector invokes the engine's native C rebinder.
    BOOL success=[self ryg_manager_setCOverride:value forSymbol:symbol abi:abi];
    NSString *imageID=RYGCImageID(symbol.imagePath), *name=symbol.name ?: @"";
    if (!imageID.length||!name.length) return success;
    NSMutableDictionary *stored=RYGCStoredMutable();
    NSString *recordKey=[NSString stringWithFormat:@"%@|%@",imageID,name];
    if (!value) {
        [stored removeObjectForKey:recordKey];
        @synchronized(RYGRuntimeHookManager.class){[gRYGCPending removeObject:recordKey];}
    } else if (success) {
        stored[recordKey]=@{@"image":imageID,@"name":name,@"abi":@(abi),@"value":@(value.boolValue)};
        @synchronized(RYGRuntimeHookManager.class){[gRYGCPending removeObject:recordKey];}
    }
    RYGCWrite(stored);
    return success;
}

@end

static void RYGScheduleExactRuntimeRestore(void) {
    if (!RYGHasPendingRestore()) return;
    os_unfair_lock_lock(&gRYGRestoreLock);
    if (gRYGRestoreScheduled) { os_unfair_lock_unlock(&gRYGRestoreLock); return; }
    gRYGRestoreScheduled=YES;
    os_unfair_lock_unlock(&gRYGRestoreLock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(200*NSEC_PER_MSEC)),RYGRuntimeRestoreQueue(), ^{
        [RYGRuntimeBrowserEngine reinstallPersistedOverrides];
        os_unfair_lock_lock(&gRYGRestoreLock);
        gRYGRestoreScheduled=NO;
        os_unfair_lock_unlock(&gRYGRestoreLock);
    });
}

static void RYGRuntimeExactImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    // Only unresolved exact identities are retried. Once resolved, the callback
    // immediately returns via RYGHasPendingRestore without scanning the runtime.
    RYGScheduleExactRuntimeRestore();
}

__attribute__((constructor(205))) static void RYGRuntimeHookManagerBootstrap(void) {
    @autoreleasepool {
        RYGHookLoadStore();
        RYGCLoadStore();
        // Exact persisted hooks are cheap enough to install before first use now:
        // their invocation path is atomic-only, so startup-sensitive gates keep
        // their persistence semantics without dictionary/lock amplification.
        [RYGRuntimeBrowserEngine reinstallPersistedOverrides];
        if (RYGHasPendingRestore()) _dyld_register_func_for_add_image(RYGRuntimeExactImageDidLoad);
        // No second timer replay here. Late images alone drive unresolved retry.
    }
}
