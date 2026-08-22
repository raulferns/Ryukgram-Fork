#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeLiveObserver.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static NSString *const kRYGOwnedMethodOverridesKey = @"ryg_runtime_method_overrides_v5";
static NSString *const kRYGLegacyMethodOverridesKey = @"ryg_runtime_method_overrides_v4";
static NSString *const kRYGOwnedCOverridesKey = @"ryg_runtime_c_overrides_v5";
static NSString *const kRYGLegacyCOverridesKey = @"ryg_runtime_c_overrides_v4";

@interface RYGOwnedRuntimeHook : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) Class owner;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, assign) RYGRuntimeArgumentKind kind;
@property (nonatomic, assign) IMP upstream;
@property (nonatomic, assign) IMP replacement;
@end
@implementation RYGOwnedRuntimeHook @end

static NSMutableDictionary<NSString *, NSNumber *> *gRYGOwnedOverrides;
static NSMutableDictionary<NSString *, NSNumber *> *gRYGOwnedObserved;
static NSMutableDictionary<NSString *, RYGOwnedRuntimeHook *> *gRYGOwnedHooks;
static BOOL gRYGRuntimeOwnerRestoreScheduled;
static BOOL gRYGRuntimeOwnerAppActive;

static const char *RYGOwnerSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGOwnerBoolReturn(Method method) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGOwnerSkipQualifiers(encoded);
    return type && strchr("BcC", *type) != NULL;
}

static RYGRuntimeArgumentKind RYGOwnerArgumentKind(Method method) {
    if (!method || !RYGOwnerBoolReturn(method)) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[96] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    const char *type = RYGOwnerSkipQualifiers(encoded);
    if (!type || !*type) return (RYGRuntimeArgumentKind)-1;
    if (*type == '@') return RYGRuntimeArgumentObject;
    if (*type == 'q' || *type == 'Q') return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static BOOL RYGOwnerParseMethodKey(NSString *key, NSString **className, NSString **selectorName, BOOL *classMethod) {
    if (key.length < 4) return NO;
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

// class_getInstanceMethod may invoke +resolveInstanceMethod:. Runtime Browser rows
// come from class_copyMethodList, so ownership lookup must use the same direct
// method-list semantics and never trigger dynamic resolution while restoring.
static Method RYGOwnerDirectMethod(Class owner, SEL selector) {
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

static NSNumber *RYGOwnerOverride(NSString *key) {
    @synchronized(RYGRuntimeBrowserEngine.class) { return gRYGOwnedOverrides[key]; }
}

static void RYGOwnerRememberNative(NSString *key, BOOL value) {
    if (!key.length) return;
    BOOL changed = NO;
    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (!gRYGOwnedObserved) gRYGOwnedObserved = [NSMutableDictionary dictionary];
        NSNumber *old = gRYGOwnedObserved[key];
        if (!old || old.boolValue != value) {
            gRYGOwnedObserved[key] = @(value);
            changed = YES;
        }
    }
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:RYGRuntimeNativeValueDidChangeNotification
                                                               object:nil
                                                             userInfo:@{RYGRuntimeNativeValueKeyUserInfoKey:key}];
        });
    }
}

static RYGOwnedRuntimeHook *RYGOwnerCreateHook(NSString *key, Class owner, SEL selector, RYGRuntimeArgumentKind kind, IMP upstream) {
    RYGOwnedRuntimeHook *record = [RYGOwnedRuntimeHook new];
    record.key = key;
    record.owner = owner;
    record.selector = selector;
    record.kind = kind;
    record.upstream = upstream;

    if (kind == RYGRuntimeArgumentNone) {
        __weak RYGOwnedRuntimeHook *weakRecord = record;
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            RYGOwnedRuntimeHook *strongRecord = weakRecord;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id, SEL))nativeIMP)(receiver, strongRecord.selector) : NO;
            RYGOwnerRememberNative(strongRecord.key, native);
            NSNumber *forced = RYGOwnerOverride(strongRecord.key);
            return forced ? forced.boolValue : native;
        });
    } else if (kind == RYGRuntimeArgumentObject) {
        __weak RYGOwnedRuntimeHook *weakRecord = record;
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
            RYGOwnedRuntimeHook *strongRecord = weakRecord;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id, SEL, id))nativeIMP)(receiver, strongRecord.selector, argument) : NO;
            RYGOwnerRememberNative(strongRecord.key, native);
            NSNumber *forced = RYGOwnerOverride(strongRecord.key);
            return forced ? forced.boolValue : native;
        });
    } else if (kind == RYGRuntimeArgumentInteger) {
        __weak RYGOwnedRuntimeHook *weakRecord = record;
        record.replacement = imp_implementationWithBlock(^BOOL(id receiver, uint64_t argument) {
            RYGOwnedRuntimeHook *strongRecord = weakRecord;
            IMP nativeIMP = strongRecord.upstream;
            BOOL native = nativeIMP ? ((BOOL (*)(id, SEL, uint64_t))nativeIMP)(receiver, strongRecord.selector, argument) : NO;
            RYGOwnerRememberNative(strongRecord.key, native);
            NSNumber *forced = RYGOwnerOverride(strongRecord.key);
            return forced ? forced.boolValue : native;
        });
    }
    return record.replacement ? record : nil;
}

static BOOL RYGOwnerEnsureHookForKey(NSString *key) {
    NSString *className = nil;
    NSString *selectorName = nil;
    BOOL classMethod = NO;
    if (!RYGOwnerParseMethodKey(key, &className, &selectorName, &classMethod)) return NO;
    Class cls = objc_lookUpClass(className.UTF8String);
    SEL selector = selectorName.length ? NSSelectorFromString(selectorName) : NULL;
    Class owner = cls ? (classMethod ? object_getClass(cls) : cls) : Nil;
    Method method = RYGOwnerDirectMethod(owner, selector);
    RYGRuntimeArgumentKind kind = RYGOwnerArgumentKind(method);
    if (!cls || !owner || !method || kind < RYGRuntimeArgumentNone || kind > RYGRuntimeArgumentInteger) return NO;

    IMP current = method_getImplementation(method);
    if (!current) return NO;

    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (!gRYGOwnedHooks) gRYGOwnedHooks = [NSMutableDictionary dictionary];
        RYGOwnedRuntimeHook *record = gRYGOwnedHooks[key];
        if (record && current == record.replacement) return YES;

        // Persisted hooks are intentionally first installed only after the app
        // becomes active. If a previously owned method is no longer ours, treat
        // the current IMP as the new native owner before re-installing.
        if (!record || record.kind != kind || record.owner != owner || record.selector != selector) {
            record = RYGOwnerCreateHook(key, owner, selector, kind, current);
            if (!record) return NO;
            gRYGOwnedHooks[key] = record;
        } else {
            record.upstream = current;
        }

        (void)method_setImplementation(method, record.replacement);
        return method_getImplementation(method) == record.replacement;
    }
}

static NSDictionary *RYGOwnerStoredMethods(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = [defaults dictionaryForKey:kRYGOwnedMethodOverridesKey];
    if (current.count) return current;
    NSDictionary *legacy = [defaults dictionaryForKey:kRYGLegacyMethodOverridesKey];
    return legacy.count ? legacy : @{};
}

static void RYGOwnerWriteMethods(void) {
    NSDictionary *snapshot = nil;
    @synchronized(RYGRuntimeBrowserEngine.class) { snapshot = gRYGOwnedOverrides.copy ?: @{}; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (snapshot.count) [defaults setObject:snapshot forKey:kRYGOwnedMethodOverridesKey];
    else [defaults removeObjectForKey:kRYGOwnedMethodOverridesKey];
    [defaults removeObjectForKey:kRYGLegacyMethodOverridesKey];
    [defaults synchronize];
}

static NSString *RYGOwnerImageID(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *executable = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if ([standard isEqualToString:executable]) return @"@executable";
    NSString *root = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([standard hasPrefix:prefix]) return [standard substringFromIndex:prefix.length];
    return standard.lastPathComponent ?: @"";
}

static NSString *RYGOwnerLoadedPath(NSString *imageID) {
    if ([imageID isEqualToString:@"@executable"]) return NSBundle.mainBundle.executablePath;
    for (NSString *path in [RYGRuntimeBrowserEngine runtimeImagePaths]) {
        if ([[RYGOwnerImageID(path) lowercaseString] isEqualToString:imageID.lowercaseString]) return path;
    }
    return nil;
}

static NSMutableDictionary *RYGOwnerStoredCMutable(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = [defaults dictionaryForKey:kRYGOwnedCOverridesKey];
    if (!current.count) current = [defaults dictionaryForKey:kRYGLegacyCOverridesKey];
    return current ? current.mutableCopy : [NSMutableDictionary dictionary];
}

static void RYGOwnerWriteC(NSDictionary *records) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (records.count) [defaults setObject:records forKey:kRYGOwnedCOverridesKey];
    else [defaults removeObjectForKey:kRYGOwnedCOverridesKey];
    [defaults removeObjectForKey:kRYGLegacyCOverridesKey];
    [defaults synchronize];
}

static void RYGOwnerRestoreMethods(void) {
    NSDictionary *stored = RYGOwnerStoredMethods();
    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (!gRYGOwnedOverrides) gRYGOwnedOverrides = [NSMutableDictionary dictionary];
        [stored enumerateKeysAndObjectsUsingBlock:^(id rawKey, id rawValue, BOOL *stop) {
            (void)stop;
            if ([rawKey isKindOfClass:NSString.class] && [rawValue isKindOfClass:NSNumber.class])
                gRYGOwnedOverrides[rawKey] = @([(NSNumber *)rawValue boolValue]);
        }];
    }
    for (NSString *key in stored) (void)RYGOwnerEnsureHookForKey(key);
    if (stored.count) RYGOwnerWriteMethods();
}

static void RYGOwnerRestoreC(void) {
    NSDictionary *stored = RYGOwnerStoredCMutable().copy;
    [stored enumerateKeysAndObjectsUsingBlock:^(id rawKey, id rawRecord, BOOL *stop) {
        (void)rawKey; (void)stop;
        if (![rawRecord isKindOfClass:NSDictionary.class]) return;
        NSDictionary *record = rawRecord;
        NSString *imageID = [record[@"image"] isKindOfClass:NSString.class] ? record[@"image"] : nil;
        NSString *name = [record[@"name"] isKindOfClass:NSString.class] ? record[@"name"] : nil;
        NSNumber *abi = [record[@"abi"] isKindOfClass:NSNumber.class] ? record[@"abi"] : nil;
        NSNumber *value = [record[@"value"] isKindOfClass:NSNumber.class] ? record[@"value"] : nil;
        NSString *path = RYGOwnerLoadedPath(imageID);
        if (!path.length || !name.length || !abi || !value) return;
        RYGMachOSymbol *symbol = [RYGMachOSymbol new];
        symbol.imagePath = path;
        symbol.name = name;
        symbol.external = YES;
        symbol.rebindableImport = YES;
        [RYGRuntimeBrowserEngine setCOverride:@(value.boolValue) forSymbol:symbol abi:(RYGCFunctionABI)abi.integerValue];
    }];
    if (stored.count) RYGOwnerWriteC(stored);
}

static void RYGOwnerRestoreAll(void) {
    RYGOwnerRestoreMethods();
    RYGOwnerRestoreC();
}

static void RYGScheduleRuntimeOwnerRestore(void) {
    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (gRYGRuntimeOwnerRestoreScheduled) return;
        gRYGRuntimeOwnerRestoreScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(RYGRuntimeBrowserEngine.class) { gRYGRuntimeOwnerRestoreScheduled = NO; }
        if (!gRYGRuntimeOwnerAppActive) return;
        RYGOwnerRestoreAll();
    });
}

static void RYGRuntimeOwnerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    if (gRYGRuntimeOwnerAppActive) RYGScheduleRuntimeOwnerRestore();
}

@implementation RYGRuntimeBrowserEngine (RYGRuntimeOverrideOwner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct { SEL original; SEL owned; } swaps[] = {
            {@selector(observeMethod:), @selector(ryg_owner_observeMethod:)},
            {@selector(observedNativeValueForKey:), @selector(ryg_owner_observedNativeValueForKey:)},
            {@selector(overrideForKey:), @selector(ryg_owner_overrideForKey:)},
            {@selector(setOverride:forMethod:), @selector(ryg_owner_setOverride:forMethod:)},
            {@selector(reinstallPersistedOverrides), @selector(ryg_owner_reinstallPersistedOverrides)},
            {@selector(setCOverride:forSymbol:abi:), @selector(ryg_owner_setCOverride:forSymbol:abi:)},
        };
        for (NSUInteger index = 0; index < sizeof(swaps)/sizeof(swaps[0]); index++) {
            Method a = class_getClassMethod(self, swaps[index].original);
            Method b = class_getClassMethod(self, swaps[index].owned);
            if (a && b) method_exchangeImplementations(a, b);
        }
    });
}

+ (BOOL)ryg_owner_observeMethod:(RYGRuntimeBoolMethod *)method {
    return [method isKindOfClass:RYGRuntimeBoolMethod.class] && method.overrideKey.length && RYGOwnerEnsureHookForKey(method.overrideKey);
}

+ (NSNumber *)ryg_owner_observedNativeValueForKey:(NSString *)overrideKey {
    @synchronized(self) { return gRYGOwnedObserved[overrideKey]; }
}

+ (NSNumber *)ryg_owner_overrideForKey:(NSString *)overrideKey {
    return RYGOwnerOverride(overrideKey);
}

+ (void)ryg_owner_setOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method {
    if (![method isKindOfClass:RYGRuntimeBoolMethod.class] || !method.overrideKey.length) return;
    if (value && !RYGOwnerEnsureHookForKey(method.overrideKey)) return;
    @synchronized(self) {
        if (!gRYGOwnedOverrides) gRYGOwnedOverrides = [NSMutableDictionary dictionary];
        if (value) gRYGOwnedOverrides[method.overrideKey] = @(value.boolValue);
        else [gRYGOwnedOverrides removeObjectForKey:method.overrideKey];
    }
    RYGOwnerWriteMethods();
}

+ (void)ryg_owner_reinstallPersistedOverrides {
    RYGOwnerRestoreAll();
}

+ (BOOL)ryg_owner_setCOverride:(NSNumber *)value forSymbol:(RYGMachOSymbol *)symbol abi:(RYGCFunctionABI)abi {
    // After method exchange this selector points to the engine's native C
    // rebinding implementation. Persist only when that actual rebind succeeds.
    BOOL success = [self ryg_owner_setCOverride:value forSymbol:symbol abi:abi];
    NSString *imageID = RYGOwnerImageID(symbol.imagePath);
    NSString *name = symbol.name ?: @"";
    if (!imageID.length || !name.length) return success;
    NSMutableDictionary *stored = RYGOwnerStoredCMutable();
    NSString *recordKey = [NSString stringWithFormat:@"%@|%@", imageID, name];
    if (!value) [stored removeObjectForKey:recordKey];
    else if (success) stored[recordKey] = @{@"image":imageID, @"name":name, @"abi":@(abi), @"value":@(value.boolValue)};
    RYGOwnerWriteC(stored);
    return success;
}

@end

__attribute__((constructor)) static void RYGInstallRuntimeOverrideOwner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGRuntimeOwnerAppActive = YES;
            RYGScheduleRuntimeOwnerRestore();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            gRYGRuntimeOwnerAppActive = NO;
        }];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            gRYGRuntimeOwnerAppActive = YES;
            RYGScheduleRuntimeOwnerRestore();
        }
    });
    _dyld_register_func_for_add_image(RYGRuntimeOwnerImageDidLoad);
}
