#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeLiveObserver.h"
#import "RYGRuntimeValueStore.h"
#import "../../modules/fishhook/fishhook.h"
#import <os/lock.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static NSMutableDictionary<NSString *, NSNumber *> *gRYGOverrides;
static NSMutableDictionary<NSString *, NSNumber *> *gRYGObservedValues;
static NSMutableSet<NSString *> *gRYGInstalledKeys;
static NSMutableDictionary<NSString *, NSArray<RYGMachOSymbol *> *> *gRYGSymbolCache;

static NSString *RYGCanonicalImagePath(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved.stringByStandardizingPath : standard;
}

static const struct mach_header *RYGDyldHeaderForImagePath(NSString *path) {
    if (!path.length) return NULL;
    NSString *wanted = RYGCanonicalImagePath(path);
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *loaded = RYGCanonicalImagePath([NSString stringWithUTF8String:raw]);
        if ([loaded isEqualToString:wanted]) return _dyld_get_image_header(index);
    }
    return NULL;
}

static NSString *RYGDyldRuntimeNameForImagePath(NSString *path) {
    if (!path.length) return nil;
    NSString *wanted = RYGCanonicalImagePath(path);
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *loaded = [NSString stringWithUTF8String:raw];
        if ([RYGCanonicalImagePath(loaded) isEqualToString:wanted]) return loaded;
    }
    return nil;
}

static BOOL RYGImagePathMatches(NSString *left, NSString *right) {
    if (!left.length || !right.length) return NO;
    const struct mach_header *lh = RYGDyldHeaderForImagePath(left);
    const struct mach_header *rh = RYGDyldHeaderForImagePath(right);
    if (lh && rh) return lh == rh;
    return [RYGCanonicalImagePath(left) isEqualToString:RYGCanonicalImagePath(right)];
}

static NSString *RYGMethodKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@%@#%@", classMethod ? @"+" : @"-", className ?: @"", selectorName ?: @""];
}

static const char *RYGSkipTypeQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGIsBoolType(const char *type) {
    type = RYGSkipTypeQualifiers(type);
    return type && strchr("BcC", *type) != NULL;
}

static BOOL RYGIsObjectRegisterType(const char *type) {
    type = RYGSkipTypeQualifiers(type);
    return type && *type == '@';
}

static BOOL RYGIsInt64RegisterType(const char *type) {
    type = RYGSkipTypeQualifiers(type);
    return type && (*type == 'q' || *type == 'Q');
}

static RYGRuntimeArgumentKind RYGArgumentKindForMethod(Method method) {
    if (!method) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[128] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    if (RYGIsObjectRegisterType(encoded)) return RYGRuntimeArgumentObject;
    if (RYGIsInt64RegisterType(encoded)) return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static BOOL RYGMethodHasSupportedBoolABI(Method method) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    if (!RYGIsBoolType(encoded)) return NO;
    RYGRuntimeArgumentKind kind = RYGArgumentKindForMethod(method);
    return kind >= RYGRuntimeArgumentNone && kind <= RYGRuntimeArgumentInteger;
}

static NSString *RYGTypedGetterType(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    SEL selector = method_getName(method);
    NSString *name = selector ? NSStringFromSelector(selector) : @"";
    if (!RYGRuntimeValueSelectorIsSafeGetter(name)) return nil;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    NSString *type = RYGRuntimeValueNormalizedType([NSString stringWithUTF8String:encoded]);
    return RYGRuntimeValueTypeIsSupported(type) ? type : nil;
}

static BOOL RYGMethodIMPBelongsToImage(Method method, NSString *imagePath) {
    IMP imp = method ? method_getImplementation(method) : NULL;
    if (!imp || !imagePath.length) return NO;
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info)) return NO;
    const struct mach_header *target = RYGDyldHeaderForImagePath(imagePath);
    if (target && info.dli_fbase) return info.dli_fbase == (const void *)target;
    if (!info.dli_fname) return NO;
    return RYGImagePathMatches([NSString stringWithUTF8String:info.dli_fname], imagePath);
}

static BOOL RYGClassDefinedInImage(Class cls, NSString *imagePath) {
    if (!cls || !imagePath.length) return NO;
    const char *raw = class_getImageName(cls);
    if (!raw) return NO;
    return RYGImagePathMatches([NSString stringWithUTF8String:raw], imagePath);
}

static NSNumber *RYGOverrideForKey(NSString *key) {
    @synchronized(RYGRuntimeBrowserEngine.class) { return gRYGOverrides[key]; }
}

static NSNumber *RYGObservedForKey(NSString *key) {
    @synchronized(RYGRuntimeBrowserEngine.class) { return gRYGObservedValues[key]; }
}

static void RYGRememberObserved(NSString *key, BOOL value) {
    if (!key.length) return;
    BOOL changed = NO;
    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (!gRYGObservedValues) gRYGObservedValues = [NSMutableDictionary dictionary];
        NSNumber *previous = gRYGObservedValues[key];
        if (!previous || previous.boolValue != value) {
            gRYGObservedValues[key] = @(value);
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

static BOOL RYGParseMethodKey(NSString *key, NSString **className, NSString **selectorName, BOOL *classMethod) {
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

static void RYGForgetInstalledKey(NSString *key) {
    @synchronized(RYGRuntimeBrowserEngine.class) { [gRYGInstalledKeys removeObject:key]; }
}

static BOOL RYGInstallUnifiedBoolHook(NSString *key) {
    if (!key.length) return NO;
    @synchronized(RYGRuntimeBrowserEngine.class) {
        if (!gRYGInstalledKeys) gRYGInstalledKeys = [NSMutableSet set];
        if ([gRYGInstalledKeys containsObject:key]) return YES;
        [gRYGInstalledKeys addObject:key];
    }

    NSString *className = nil;
    NSString *selectorName = nil;
    BOOL classMethod = NO;
    if (!RYGParseMethodKey(key, &className, &selectorName, &classMethod)) {
        RYGForgetInstalledKey(key);
        return NO;
    }

    Class cls = objc_lookUpClass(className.UTF8String);
    SEL selector = selectorName.length ? NSSelectorFromString(selectorName) : NULL;
    Class owner = cls ? (classMethod ? object_getClass(cls) : cls) : Nil;
    Method method = owner && selector ? class_getInstanceMethod(owner, selector) : NULL;
    if (!cls || !owner || !selector || !RYGMethodHasSupportedBoolABI(method)) {
        RYGForgetInstalledKey(key);
        return NO;
    }

    RYGRuntimeArgumentKind kind = RYGArgumentKindForMethod(method);
    NSString *capturedKey = key.copy;
    SEL capturedSelector = selector;
    __block IMP original = NULL;
    IMP replacement = NULL;

    if (kind == RYGRuntimeArgumentNone) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver) {
            BOOL native = original ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector) : NO;
            RYGRememberObserved(capturedKey, native);
            NSNumber *forced = RYGOverrideForKey(capturedKey);
            return forced ? forced.boolValue : native;
        });
    } else if (kind == RYGRuntimeArgumentObject) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
            BOOL native = original ? ((BOOL (*)(id, SEL, id))original)(receiver, capturedSelector, argument) : NO;
            RYGRememberObserved(capturedKey, native);
            NSNumber *forced = RYGOverrideForKey(capturedKey);
            return forced ? forced.boolValue : native;
        });
    } else if (kind == RYGRuntimeArgumentInteger) {
        replacement = imp_implementationWithBlock(^BOOL(id receiver, uint64_t argument) {
            BOOL native = original ? ((BOOL (*)(id, SEL, uint64_t))original)(receiver, capturedSelector, argument) : NO;
            RYGRememberObserved(capturedKey, native);
            NSNumber *forced = RYGOverrideForKey(capturedKey);
            return forced ? forced.boolValue : native;
        });
    }

    if (!replacement) {
        RYGForgetInstalledKey(key);
        return NO;
    }

    Method current = class_getInstanceMethod(owner, selector);
    if (!current || !RYGMethodHasSupportedBoolABI(current)) {
        imp_removeBlock(replacement);
        RYGForgetInstalledKey(key);
        return NO;
    }
    original = method_setImplementation(current, replacement);
    if (!original) {
        imp_removeBlock(replacement);
        RYGForgetInstalledKey(key);
        return NO;
    }
    return YES;
}

static RYGRuntimeBoolMethod *RYGBoolRow(Class cls, Method method, BOOL classMethod, NSString *imagePath) {
    if (!cls || !method || !RYGMethodHasSupportedBoolABI(method)) return nil;
    SEL selector = method_getName(method);
    if (!selector) return nil;
    RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
    row.imagePath = imagePath ?: @"";
    row.className = NSStringFromClass(cls) ?: @"";
    row.selectorName = NSStringFromSelector(selector) ?: @"";
    row.classMethod = classMethod;
    row.argumentKind = RYGArgumentKindForMethod(method);
    const char *types = method_getTypeEncoding(method);
    row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
    return row;
}

static void RYGCountHookableMembersForClass(Class cls,
                                             NSString *imagePath,
                                             NSUInteger *instanceCount,
                                             NSUInteger *classCount) {
    NSUInteger counts[2] = {0, 0};
    for (NSUInteger pass = 0; pass < 2; pass++) {
        Class owner = pass ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = owner ? class_copyMethodList(owner, &count) : NULL;
        for (unsigned int index = 0; methods && index < count; index++) {
            Method method = methods[index];
            if (!RYGMethodHasSupportedBoolABI(method) && !RYGTypedGetterType(method).length) continue;
            if (!RYGMethodIMPBelongsToImage(method, imagePath)) continue;
            SEL selector = method_getName(method);
            NSString *name = selector ? NSStringFromSelector(selector) : @"";
            if ([RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:name]) continue;
            counts[pass]++;
        }
        if (methods) free(methods);
    }
    if (instanceCount) *instanceCount = counts[0];
    if (classCount) *classCount = counts[1];
}

@implementation RYGRuntimeClassRow @end

@implementation RYGRuntimeMemberRow
- (BOOL)method { return self.kind == RYGRuntimeMemberInstanceMethod || self.kind == RYGRuntimeMemberClassMethod; }
- (BOOL)classMember { return self.kind == RYGRuntimeMemberClassMethod || self.kind == RYGRuntimeMemberClassProperty; }
@end

@implementation RYGRuntimeBoolMethod
- (NSString *)overrideKey { return RYGMethodKey(self.className, self.selectorName, self.classMethod); }
- (NSNumber *)overrideValue { return [RYGRuntimeBrowserEngine overrideForKey:self.overrideKey]; }
- (NSNumber *)liveValue { return [RYGRuntimeBrowserEngine observedNativeValueForKey:self.overrideKey]; }
@end

@implementation RYGMachOSymbol
- (NSString *)overrideKey {
    return [NSString stringWithFormat:@"C|%@|%@", RYGCanonicalImagePath(self.imagePath ?: @""), self.name ?: @""];
}
- (NSNumber *)overrideValue { return [RYGRuntimeBrowserEngine cOverrideForSymbol:self]; }
@end


#pragma mark - Safe C import rebinding

// Mach-O symbol tables do not contain C prototypes.  C patching is therefore
// limited to imports that fishhook can rebind in this exact image, and the user
// must choose an explicit integer/pointer-register BOOL ABI (0...4 args).  We
// never inline-patch __TEXT and never guess float/vector/struct calling classes.
#define RYG_C_REBIND_SLOTS 8
static os_unfair_lock gRYGCSlotLock = OS_UNFAIR_LOCK_INIT;
static void *gRYGCOriginal[RYG_C_REBIND_SLOTS];
static NSString *gRYGCKey[RYG_C_REBIND_SLOTS];
static NSString *gRYGCImage[RYG_C_REBIND_SLOTS];
static NSString *gRYGCFishName[RYG_C_REBIND_SLOTS];
static uint8_t gRYGCArgc[RYG_C_REBIND_SLOTS];
static BOOL gRYGCForcedValue[RYG_C_REBIND_SLOTS];
static BOOL gRYGCForcedSet[RYG_C_REBIND_SLOTS];

static uintptr_t RYGCInvoke0(NSUInteger slot) {
    void *original = NULL; BOOL forced = NO, value = NO;
    os_unfair_lock_lock(&gRYGCSlotLock); original = gRYGCOriginal[slot]; forced = gRYGCForcedSet[slot]; value = gRYGCForcedValue[slot]; os_unfair_lock_unlock(&gRYGCSlotLock);
    uintptr_t native = original ? ((uintptr_t (*)(void))original)() : 0;
    return forced ? (value ? 1u : 0u) : native;
}
static uintptr_t RYGCInvoke1(NSUInteger slot, uintptr_t a0) {
    void *original = NULL; BOOL forced = NO, value = NO;
    os_unfair_lock_lock(&gRYGCSlotLock); original = gRYGCOriginal[slot]; forced = gRYGCForcedSet[slot]; value = gRYGCForcedValue[slot]; os_unfair_lock_unlock(&gRYGCSlotLock);
    uintptr_t native = original ? ((uintptr_t (*)(uintptr_t))original)(a0) : 0;
    return forced ? (value ? 1u : 0u) : native;
}
static uintptr_t RYGCInvoke2(NSUInteger slot, uintptr_t a0, uintptr_t a1) {
    void *original = NULL; BOOL forced = NO, value = NO;
    os_unfair_lock_lock(&gRYGCSlotLock); original = gRYGCOriginal[slot]; forced = gRYGCForcedSet[slot]; value = gRYGCForcedValue[slot]; os_unfair_lock_unlock(&gRYGCSlotLock);
    uintptr_t native = original ? ((uintptr_t (*)(uintptr_t, uintptr_t))original)(a0, a1) : 0;
    return forced ? (value ? 1u : 0u) : native;
}
static uintptr_t RYGCInvoke3(NSUInteger slot, uintptr_t a0, uintptr_t a1, uintptr_t a2) {
    void *original = NULL; BOOL forced = NO, value = NO;
    os_unfair_lock_lock(&gRYGCSlotLock); original = gRYGCOriginal[slot]; forced = gRYGCForcedSet[slot]; value = gRYGCForcedValue[slot]; os_unfair_lock_unlock(&gRYGCSlotLock);
    uintptr_t native = original ? ((uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t))original)(a0, a1, a2) : 0;
    return forced ? (value ? 1u : 0u) : native;
}
static uintptr_t RYGCInvoke4(NSUInteger slot, uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3) {
    void *original = NULL; BOOL forced = NO, value = NO;
    os_unfair_lock_lock(&gRYGCSlotLock); original = gRYGCOriginal[slot]; forced = gRYGCForcedSet[slot]; value = gRYGCForcedValue[slot]; os_unfair_lock_unlock(&gRYGCSlotLock);
    uintptr_t native = original ? ((uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t))original)(a0, a1, a2, a3) : 0;
    return forced ? (value ? 1u : 0u) : native;
}

#define RYG_DECL_C_SLOT(N) \
static uintptr_t RYGC0_##N(void){ return RYGCInvoke0(N); } \
static uintptr_t RYGC1_##N(uintptr_t a0){ return RYGCInvoke1(N,a0); } \
static uintptr_t RYGC2_##N(uintptr_t a0,uintptr_t a1){ return RYGCInvoke2(N,a0,a1); } \
static uintptr_t RYGC3_##N(uintptr_t a0,uintptr_t a1,uintptr_t a2){ return RYGCInvoke3(N,a0,a1,a2); } \
static uintptr_t RYGC4_##N(uintptr_t a0,uintptr_t a1,uintptr_t a2,uintptr_t a3){ return RYGCInvoke4(N,a0,a1,a2,a3); }
RYG_DECL_C_SLOT(0) RYG_DECL_C_SLOT(1) RYG_DECL_C_SLOT(2) RYG_DECL_C_SLOT(3)
RYG_DECL_C_SLOT(4) RYG_DECL_C_SLOT(5) RYG_DECL_C_SLOT(6) RYG_DECL_C_SLOT(7)
#undef RYG_DECL_C_SLOT

static void *const gRYGCWrappers[5][RYG_C_REBIND_SLOTS] = {
    {(void*)RYGC0_0,(void*)RYGC0_1,(void*)RYGC0_2,(void*)RYGC0_3,(void*)RYGC0_4,(void*)RYGC0_5,(void*)RYGC0_6,(void*)RYGC0_7},
    {(void*)RYGC1_0,(void*)RYGC1_1,(void*)RYGC1_2,(void*)RYGC1_3,(void*)RYGC1_4,(void*)RYGC1_5,(void*)RYGC1_6,(void*)RYGC1_7},
    {(void*)RYGC2_0,(void*)RYGC2_1,(void*)RYGC2_2,(void*)RYGC2_3,(void*)RYGC2_4,(void*)RYGC2_5,(void*)RYGC2_6,(void*)RYGC2_7},
    {(void*)RYGC3_0,(void*)RYGC3_1,(void*)RYGC3_2,(void*)RYGC3_3,(void*)RYGC3_4,(void*)RYGC3_5,(void*)RYGC3_6,(void*)RYGC3_7},
    {(void*)RYGC4_0,(void*)RYGC4_1,(void*)RYGC4_2,(void*)RYGC4_3,(void*)RYGC4_4,(void*)RYGC4_5,(void*)RYGC4_6,(void*)RYGC4_7},
};

static NSInteger RYGCArgCountForABI(RYGCFunctionABI abi) {
    switch (abi) {
        case RYGCFunctionABIBool0: return 0; case RYGCFunctionABIBool1: return 1;
        case RYGCFunctionABIBool2: return 2; case RYGCFunctionABIBool3: return 3;
        case RYGCFunctionABIBool4: return 4; default: return -1;
    }
}

static BOOL RYGDyldHeaderSlideForPath(NSString *path, const struct mach_header **headerOut, intptr_t *slideOut) {
    NSString *wanted = RYGCanonicalImagePath(path);
    for (uint32_t i=0; i<_dyld_image_count(); i++) {
        const char *raw = _dyld_get_image_name(i); if (!raw) continue;
        if (![RYGCanonicalImagePath([NSString stringWithUTF8String:raw]) isEqualToString:wanted]) continue;
        if (headerOut) *headerOut = _dyld_get_image_header(i);
        if (slideOut) *slideOut = _dyld_get_image_vmaddr_slide(i);
        return YES;
    }
    return NO;
}

static NSInteger RYGCSlotForKey(NSString *key) {
    for (NSInteger i=0;i<RYG_C_REBIND_SLOTS;i++) if (gRYGCKey[i] && [gRYGCKey[i] isEqualToString:key]) return i;
    return NSNotFound;
}

static void RYGCClearSlotUnlocked(NSUInteger slot) {
    gRYGCOriginal[slot]=NULL; gRYGCKey[slot]=nil; gRYGCImage[slot]=nil; gRYGCFishName[slot]=nil;
    gRYGCArgc[slot]=0; gRYGCForcedSet[slot]=NO; gRYGCForcedValue[slot]=NO;
}

static BOOL RYGCUnbindSlot(NSUInteger slot) {
    void *original=NULL; NSString *image=nil; NSString *fish=nil;
    os_unfair_lock_lock(&gRYGCSlotLock);
    original=gRYGCOriginal[slot]; image=gRYGCImage[slot]; fish=gRYGCFishName[slot];
    os_unfair_lock_unlock(&gRYGCSlotLock);
    if (original && image.length && fish.length) {
        const struct mach_header *header=NULL; intptr_t slide=0;
        if (RYGDyldHeaderSlideForPath(image,&header,&slide) && header) {
            struct rebinding binding = {.name=fish.UTF8String,.replacement=original,.replaced=NULL};
            (void)rebind_symbols_image((void *)header,slide,&binding,1);
        }
    }
    os_unfair_lock_lock(&gRYGCSlotLock); RYGCClearSlotUnlocked(slot); os_unfair_lock_unlock(&gRYGCSlotLock);
    return YES;
}

@implementation RYGRuntimeBrowserEngine

+ (NSArray<NSString *> *)runtimeImagePaths {
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *executable = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    NSString *frameworks = [[bundle stringByAppendingPathComponent:@"Frameworks"] stringByStandardizingPath];
    NSMutableOrderedSet<NSString *> *images = [NSMutableOrderedSet orderedSet];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *path = [[NSString stringWithUTF8String:raw] stringByStandardizingPath];
        BOOL main = RYGImagePathMatches(path, executable);
        BOOL framework = [path hasPrefix:[frameworks stringByAppendingString:@"/"]];
        BOOL bundledDylib = [path hasPrefix:[bundle stringByAppendingString:@"/"]] && [path.pathExtension.lowercaseString isEqualToString:@"dylib"];
        if (main || framework || bundledDylib) [images addObject:path];
    }
    return [images.array sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        BOOL leftMain = RYGImagePathMatches(left, executable);
        BOOL rightMain = RYGImagePathMatches(right, executable);
        if (leftMain != rightMain) return leftMain ? NSOrderedAscending : NSOrderedDescending;
        return [[self shortNameForImagePath:left] localizedCaseInsensitiveCompare:[self shortNameForImagePath:right]];
    }];
}

+ (NSString *)shortNameForImagePath:(NSString *)imagePath {
    return imagePath.lastPathComponent.length ? imagePath.lastPathComponent : @"Image";
}

+ (BOOL)isStructuralNoiseSelectorName:(NSString *)selectorName {
    if (!selectorName.length) return YES;
    static NSSet<NSString *> *noise;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        noise = [NSSet setWithArray:@[
            @"isEqual:", @"hash", @"class", @"self", @"superclass",
            @"respondsToSelector:", @"isKindOfClass:", @"isMemberOfClass:",
            @"conformsToProtocol:", @"methodForSelector:", @"description",
            @"debugDescription", @"retainCount", @"zone"
        ]];
    });
    if ([noise containsObject:selectorName]) return YES;

    // Swift/Objective-C bridges expose spelling variants of NSObject
    // introspection (for example canRespondToSelector:) that are BOOL-shaped
    // but are not product gates. Normalize punctuation/case and exclude the
    // semantic family instead of showing misleading on/off rows.
    NSString *normalized = [[[selectorName lowercaseString]
        componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
        componentsJoinedByString:@""];
    static NSArray<NSString *> *structuralPrefixes;
    static dispatch_once_t semanticOnce;
    dispatch_once(&semanticOnce, ^{
        structuralPrefixes = @[
            @"isequal", @"equalto", @"canrespond", @"respondstoselector",
            @"iskindofclass", @"ismemberofclass", @"conformstoprotocol",
            @"isproxy", @"allowsweakreference", @"retainweakreference"
        ];
    });
    for (NSString *prefix in structuralPrefixes) {
        if ([normalized hasPrefix:prefix]) return YES;
    }
    return NO;
}

+ (NSArray<RYGRuntimeClassRow *> *)classesForImagePath:(NSString *)imagePath {
    if (!imagePath.length || !RYGDyldHeaderForImagePath(imagePath)) return @[];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSString *runtimeName = RYGDyldRuntimeNameForImagePath(imagePath) ?: imagePath;
    unsigned int directCount = 0;
    const char **directNames = objc_copyClassNamesForImage(runtimeName.fileSystemRepresentation, &directCount);
    for (unsigned int index = 0; directNames && index < directCount; index++) {
        if (!directNames[index] || !*directNames[index]) continue;
        NSString *name = [NSString stringWithUTF8String:directNames[index]];
        if (name.length) [names addObject:name];
    }
    if (directNames) free(directNames);

    if (!names.count) {
        int total = objc_getClassList(NULL, 0);
        if (total > 0 && total < 500000) {
            Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
            int filled = classes ? objc_getClassList(classes, total) : 0;
            for (int index = 0; index < filled; index++) {
                Class cls = classes[index];
                if (!cls || !RYGClassDefinedInImage(cls, imagePath)) continue;
                const char *rawName = class_getName(cls);
                if (!rawName || !*rawName) continue;
                NSString *name = [NSString stringWithUTF8String:rawName];
                if (name.length) [names addObject:name];
            }
            if (classes) free(classes);
        }
    }

    NSArray<NSString *> *ordered = [names.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray array];
    for (NSString *name in ordered) {
        Class cls = objc_lookUpClass(name.UTF8String);
        if (!cls) continue;
        NSUInteger instanceCount = 0, classCount = 0;
        RYGCountHookableMembersForClass(cls, imagePath, &instanceCount, &classCount);
        if (!instanceCount && !classCount) continue;
        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = imagePath;
        row.className = name;
        row.instanceMethodCount = instanceCount;
        row.classMethodCount = classCount;
        row.propertyCount = 0;
        [rows addObject:row];
    }
    return rows.copy;
}

+ (NSArray<RYGRuntimeMemberRow *> *)membersForClassName:(NSString *)className imagePath:(NSString *)imagePath {
    Class cls = className.length ? objc_lookUpClass(className.UTF8String) : Nil;
    if (!cls || !imagePath.length || !RYGDyldHeaderForImagePath(imagePath)) return @[];
    NSMutableArray<RYGRuntimeMemberRow *> *rows = [NSMutableArray array];
    for (NSUInteger pass = 0; pass < 2; pass++) {
        BOOL classMember = pass == 1;
        Class owner = classMember ? object_getClass(cls) : cls;
        unsigned int methodCount = 0;
        Method *methods = owner ? class_copyMethodList(owner, &methodCount) : NULL;
        for (unsigned int index = 0; methods && index < methodCount; index++) {
            Method method = methods[index];
            NSString *valueType = RYGTypedGetterType(method);
            BOOL boolABI = RYGMethodHasSupportedBoolABI(method);
            if (!boolABI && !valueType.length) continue;
            if (!RYGMethodIMPBelongsToImage(method, imagePath)) continue;
            SEL selector = method_getName(method);
            NSString *name = selector ? NSStringFromSelector(selector) : @"";
            if ([self isStructuralNoiseSelectorName:name]) continue;
            RYGRuntimeMemberRow *row = [RYGRuntimeMemberRow new];
            row.imagePath = imagePath;
            row.className = className;
            row.name = name;
            row.kind = classMember ? RYGRuntimeMemberClassMethod : RYGRuntimeMemberInstanceMethod;
            const char *types = method_getTypeEncoding(method);
            row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
            row.hookableBool = boolABI;
            row.hookableValue = valueType.length > 0;
            row.valueTypeCode = valueType ?: @"";
            row.argumentKind = boolABI ? RYGArgumentKindForMethod(method) : RYGRuntimeArgumentNone;
            [rows addObject:row];
        }
        if (methods) free(methods);
    }
    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeMemberRow *left, RYGRuntimeMemberRow *right) {
        if (left.kind != right.kind) return left.kind < right.kind ? NSOrderedAscending : NSOrderedDescending;
        return [left.name localizedCaseInsensitiveCompare:right.name];
    }];
    return rows.copy;
}

+ (RYGRuntimeBoolMethod *)boolMethodForMember:(RYGRuntimeMemberRow *)member {
    if (!member.method || !member.hookableBool || !member.className.length || !member.name.length) return nil;
    Class cls = objc_lookUpClass(member.className.UTF8String);
    BOOL classMethod = member.kind == RYGRuntimeMemberClassMethod;
    Class owner = cls ? (classMethod ? object_getClass(cls) : cls) : Nil;
    Method method = owner ? class_getInstanceMethod(owner, NSSelectorFromString(member.name)) : NULL;
    if (!method || !RYGMethodHasSupportedBoolABI(method) || !RYGMethodIMPBelongsToImage(method, member.imagePath)) return nil;
    return RYGBoolRow(cls, method, classMethod, member.imagePath);
}

+ (NSArray<RYGRuntimeBoolMethod *> *)boolMethodsForImagePath:(NSString *)imagePath scope:(RYGRuntimeBrowserScope)scope {
    (void)scope;
    NSMutableArray<RYGRuntimeBoolMethod *> *rows = [NSMutableArray array];
    for (RYGRuntimeClassRow *classRow in [self classesForImagePath:imagePath]) {
        for (RYGRuntimeMemberRow *member in [self membersForClassName:classRow.className imagePath:imagePath]) {
            RYGRuntimeBoolMethod *method = [self boolMethodForMember:member];
            if (method) [rows addObject:method];
        }
    }
    return rows.copy;
}

+ (NSInteger)dyldIndexForImagePath:(NSString *)imagePath {
    const struct mach_header *target = RYGDyldHeaderForImagePath(imagePath);
    if (!target) return NSNotFound;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) if (_dyld_get_image_header(index) == target) return (NSInteger)index;
    return NSNotFound;
}

+ (NSArray<RYGMachOSymbol *> *)machOSymbolsForImagePath:(NSString *)imagePath {
    NSString *cacheKey = RYGCanonicalImagePath(imagePath);
    @synchronized(self) {
        NSArray *cached = gRYGSymbolCache[cacheKey];
        if (cached) return cached;
    }

    NSInteger imageIndex = [self dyldIndexForImagePath:imagePath];
    if (imageIndex == NSNotFound) return @[];
    const struct mach_header *generic = _dyld_get_image_header((uint32_t)imageIndex);
    if (!generic || generic->magic != MH_MAGIC_64) return @[];
    const struct mach_header_64 *header = (const struct mach_header_64 *)generic;
    if (!header->sizeofcmds || header->sizeofcmds > 64 * 1024 * 1024 || header->ncmds > 65535) return @[];

    const uint8_t *cursor = (const uint8_t *)header + sizeof(*header);
    const uint8_t *commandsEnd = cursor + header->sizeofcmds;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) return @[];
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || cursor + command->cmdsize > commandsEnd) return @[];
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)cursor;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)cursor;
        else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)cursor;
            if (!strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname))) linkedit = segment;
        }
        cursor += command->cmdsize;
    }
    if (!symtab || !linkedit || symtab->nsyms > 2000000 || symtab->strsize > 512 * 1024 * 1024) return @[];
    intptr_t slide = _dyld_get_image_vmaddr_slide((uint32_t)imageIndex);
    uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);

    // Mark exactly the imported symbols backed by lazy/non-lazy pointer slots;
    // these are the targets fishhook can rebind without modifying __TEXT.
    NSMutableIndexSet *rebindable = [NSMutableIndexSet indexSet];
    if (dysymtab && dysymtab->nindirectsyms && dysymtab->nindirectsyms < 4000000) {
        const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);
        cursor = (const uint8_t *)header + sizeof(*header);
        for (uint32_t ci=0; ci<header->ncmds; ci++) {
            const struct load_command *command=(const struct load_command *)cursor;
            if (command->cmd==LC_SEGMENT_64) {
                const struct segment_command_64 *segment=(const struct segment_command_64 *)cursor;
                const struct section_64 *section=(const struct section_64 *)(segment+1);
                for (uint32_t si=0; si<segment->nsects; si++) {
                    uint32_t st=section[si].flags & SECTION_TYPE;
                    if (st!=S_LAZY_SYMBOL_POINTERS && st!=S_NON_LAZY_SYMBOL_POINTERS) continue;
                    uint64_t count=section[si].size/sizeof(uintptr_t);
                    uint64_t first=section[si].reserved1;
                    if (first+count>dysymtab->nindirectsyms) continue;
                    for (uint64_t j=0;j<count;j++) {
                        uint32_t symIndex=indirect[first+j];
                        if (symIndex & (INDIRECT_SYMBOL_LOCAL|INDIRECT_SYMBOL_ABS)) continue;
                        if (symIndex < symtab->nsyms) [rebindable addIndex:symIndex];
                    }
                }
            }
            cursor += command->cmdsize;
        }
    }

    NSMutableArray<RYGMachOSymbol *> *rows = [NSMutableArray array];
    for (uint32_t index = 0; index < symtab->nsyms; index++) {
        struct nlist_64 entry = symbols[index];
        if ((entry.n_type & N_STAB) || !entry.n_un.n_strx || entry.n_un.n_strx >= symtab->strsize) continue;
        const char *name = strings + entry.n_un.n_strx;
        size_t remaining = symtab->strsize - entry.n_un.n_strx;
        if (!name || !*name || !memchr(name, 0, remaining)) continue;
        RYGMachOSymbol *row = [RYGMachOSymbol new];
        row.imagePath = cacheKey;
        row.name = [NSString stringWithUTF8String:name] ?: @"";
        row.external = (entry.n_type & N_EXT) != 0;
        uint8_t type = entry.n_type & N_TYPE;
        if (type == N_UNDF) row.kind = @"import";
        else if (type == N_ABS) row.kind = @"absolute";
        else if (type == N_SECT) row.kind = @"local/export";
        else if (type == N_INDR) row.kind = @"indirect";
        else row.kind = @"symbol";
        row.rebindableImport = type == N_UNDF && row.external && [rebindable containsIndex:index];
        if (entry.n_value) row.address = type == N_ABS ? entry.n_value : (uint64_t)((intptr_t)entry.n_value + slide);
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(RYGMachOSymbol *left, RYGMachOSymbol *right) {
        if (left.isRebindableImport != right.isRebindableImport) return left.isRebindableImport ? NSOrderedAscending : NSOrderedDescending;
        return [left.name localizedCaseInsensitiveCompare:right.name];
    }];
    NSArray *snapshot = rows.copy;
    @synchronized(self) {
        if (!gRYGSymbolCache) gRYGSymbolCache = [NSMutableDictionary dictionary];
        if (cacheKey.length) gRYGSymbolCache[cacheKey] = snapshot;
    }
    return snapshot;
}

+ (NSNumber *)cOverrideForSymbol:(RYGMachOSymbol *)symbol {
    if (![symbol isKindOfClass:RYGMachOSymbol.class]) return nil;
    NSString *key = symbol.overrideKey;
    os_unfair_lock_lock(&gRYGCSlotLock);
    NSInteger slot = RYGCSlotForKey(key);
    NSNumber *value = slot == NSNotFound || !gRYGCForcedSet[slot] ? nil : @(gRYGCForcedValue[slot]);
    os_unfair_lock_unlock(&gRYGCSlotLock);
    return value;
}

+ (BOOL)setCOverride:(NSNumber *)value forSymbol:(RYGMachOSymbol *)symbol abi:(RYGCFunctionABI)abi {
    if (![symbol isKindOfClass:RYGMachOSymbol.class] || !symbol.isRebindableImport || !symbol.imagePath.length || !symbol.name.length) return NO;
    NSString *key = symbol.overrideKey;
    os_unfair_lock_lock(&gRYGCSlotLock);
    NSInteger existing = RYGCSlotForKey(key);
    os_unfair_lock_unlock(&gRYGCSlotLock);
    if (!value) return existing == NSNotFound ? YES : RYGCUnbindSlot((NSUInteger)existing);

    NSInteger argc = RYGCArgCountForABI(abi);
    if (argc < 0 || argc > 4) return NO;
    if (existing != NSNotFound) {
        os_unfair_lock_lock(&gRYGCSlotLock);
        BOOL sameABI = gRYGCArgc[existing] == (uint8_t)argc;
        if (sameABI) { gRYGCForcedSet[existing]=YES; gRYGCForcedValue[existing]=value.boolValue; }
        os_unfair_lock_unlock(&gRYGCSlotLock);
        if (sameABI) return YES;
        RYGCUnbindSlot((NSUInteger)existing);
    }

    os_unfair_lock_lock(&gRYGCSlotLock);
    NSInteger slot=NSNotFound; for (NSInteger i=0;i<RYG_C_REBIND_SLOTS;i++) if (!gRYGCKey[i]) { slot=i; break; }
    os_unfair_lock_unlock(&gRYGCSlotLock);
    if (slot==NSNotFound) return NO;

    const struct mach_header *header=NULL; intptr_t slide=0;
    if (!RYGDyldHeaderSlideForPath(symbol.imagePath,&header,&slide) || !header) return NO;
    NSString *fishName = [symbol.name hasPrefix:@"_"] ? [symbol.name substringFromIndex:1] : symbol.name;
    if (!fishName.length) return NO;
    void *original=NULL;
    struct rebinding binding={.name=fishName.UTF8String,.replacement=gRYGCWrappers[argc][slot],.replaced=&original};
    if (rebind_symbols_image((void *)header,slide,&binding,1)!=0 || !original) return NO;

    os_unfair_lock_lock(&gRYGCSlotLock);
    gRYGCOriginal[slot]=original; gRYGCKey[slot]=key.copy; gRYGCImage[slot]=symbol.imagePath.copy; gRYGCFishName[slot]=fishName.copy;
    gRYGCArgc[slot]=(uint8_t)argc; gRYGCForcedSet[slot]=YES; gRYGCForcedValue[slot]=value.boolValue;
    os_unfair_lock_unlock(&gRYGCSlotLock);
    return YES;
}

+ (void)invalidateRuntimeCaches {
    @synchronized(self) { [gRYGSymbolCache removeAllObjects]; }
}

+ (BOOL)observeMethod:(RYGRuntimeBoolMethod *)method {
    return [method isKindOfClass:RYGRuntimeBoolMethod.class] && RYGInstallUnifiedBoolHook(method.overrideKey);
}

+ (NSNumber *)observedNativeValueForKey:(NSString *)overrideKey { return RYGObservedForKey(overrideKey); }
+ (NSNumber *)overrideForKey:(NSString *)overrideKey { return RYGOverrideForKey(overrideKey); }

+ (void)setOverride:(NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method {
    if (![method isKindOfClass:RYGRuntimeBoolMethod.class] || !method.overrideKey.length) return;
    if (value && !RYGInstallUnifiedBoolHook(method.overrideKey)) return;
    @synchronized(self) {
        if (!gRYGOverrides) gRYGOverrides = [NSMutableDictionary dictionary];
        if (value) gRYGOverrides[method.overrideKey] = @(value.boolValue);
        else [gRYGOverrides removeObjectForKey:method.overrideKey];
    }
}

+ (void)reinstallPersistedOverrides { }

@end
