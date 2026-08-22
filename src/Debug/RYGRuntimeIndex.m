#import "RYGRuntimeIndex.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

@implementation RYGRuntimeImageIndex
- (NSArray<RYGRuntimeBoolMethod *> *)methodsForClassName:(NSString *)className {
    return self.methodsByClass[className] ?: @[];
}
@end

static dispatch_queue_t RYGIndexStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.runtime-index.state", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_queue_t RYGIndexWorkerQueue(void) {
    return dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
}

static NSMutableDictionary<NSString *, RYGRuntimeImageIndex *> *gRYGIndexes;
static NSMutableDictionary<NSString *, NSMutableArray *> *gRYGListeners;
static NSMutableSet<NSString *> *gRYGInFlight;
static NSMutableSet<NSString *> *gRYGCompleted;
static atomic_uint_fast64_t gRYGIndexEpoch = 1;

static NSString *RYGIndexCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved.stringByStandardizingPath : standard;
}

static NSString *RYGIndexRuntimeNameForPath(NSString *path) {
    NSString *wanted = RYGIndexCanonicalPath(path);
    if (!wanted.length) return nil;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *runtimeName = [NSString stringWithUTF8String:raw];
        if ([RYGIndexCanonicalPath(runtimeName) isEqualToString:wanted]) return runtimeName;
    }
    return nil;
}

static const struct mach_header *RYGIndexHeaderForPath(NSString *path) {
    NSString *wanted = RYGIndexCanonicalPath(path);
    if (!wanted.length) return NULL;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *loaded = RYGIndexCanonicalPath([NSString stringWithUTF8String:raw]);
        if ([loaded isEqualToString:wanted]) return _dyld_get_image_header(index);
    }
    return NULL;
}

static const char *RYGIndexSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGIndexBoolReturn(Method method) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGIndexSkipQualifiers(encoded);
    return type && strchr("BcC", *type) != NULL;
}

static RYGRuntimeArgumentKind RYGIndexArgumentKind(Method method) {
    if (!method || !RYGIndexBoolReturn(method)) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[96] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    const char *type = RYGIndexSkipQualifiers(encoded);
    if (!type || !*type) return (RYGRuntimeArgumentKind)-1;
    if (*type == '@') return RYGRuntimeArgumentObject;
    if (*type == 'q' || *type == 'Q') return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static BOOL RYGIndexIMPBelongsToHeader(Method method, const struct mach_header *target) {
    IMP imp = method ? method_getImplementation(method) : NULL;
    if (!imp || !target) return NO;
    Dl_info info = {0};
    return dladdr((const void *)imp, &info) && info.dli_fbase == (const void *)target;
}

static RYGRuntimeBoolMethod *RYGIndexMethodRow(Class cls,
                                                Method method,
                                                BOOL classMethod,
                                                NSString *imagePath) {
    RYGRuntimeArgumentKind kind = RYGIndexArgumentKind(method);
    if (kind < RYGRuntimeArgumentNone || kind > RYGRuntimeArgumentInteger) return nil;
    SEL selector = method_getName(method);
    const char *rawClass = class_getName(cls);
    if (!selector || !rawClass || !*rawClass) return nil;
    NSString *selectorName = NSStringFromSelector(selector) ?: @"";
    if ([RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:selectorName]) return nil;

    RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
    row.imagePath = imagePath ?: @"";
    row.className = [NSString stringWithUTF8String:rawClass] ?: @"";
    row.selectorName = selectorName;
    row.classMethod = classMethod;
    row.argumentKind = kind;
    const char *types = method_getTypeEncoding(method);
    row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
    return row;
}

static RYGRuntimeClassRow *RYGIndexClassRow(NSString *className,
                                             NSString *imagePath,
                                             NSUInteger instanceCount,
                                             NSUInteger classCount) {
    RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
    row.imagePath = imagePath ?: @"";
    row.className = className ?: @"";
    row.instanceMethodCount = instanceCount;
    row.classMethodCount = classCount;
    row.propertyCount = 0;
    return row;
}

static RYGRuntimeImageIndex *RYGIndexSnapshot(NSString *imagePath,
                                               NSArray<RYGRuntimeClassRow *> *classRows,
                                               NSDictionary<NSString *, NSArray<RYGRuntimeBoolMethod *> *> *methodsByClass,
                                               NSUInteger classesScanned,
                                               NSUInteger methodsScanned,
                                               NSDate *started,
                                               BOOL finalSnapshot) {
    NSArray<RYGRuntimeClassRow *> *rows = classRows ?: @[];
    if (finalSnapshot) {
        rows = [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RYGRuntimeClassRow *row, NSDictionary *bindings) {
            (void)bindings;
            return row.instanceMethodCount || row.classMethodCount;
        }]];
    }
    RYGRuntimeImageIndex *snapshot = [RYGRuntimeImageIndex new];
    snapshot.imagePath = imagePath ?: @"";
    snapshot.classes = rows.copy;
    snapshot.methodsByClass = methodsByClass.copy ?: @{};
    snapshot.classesScanned = classesScanned;
    snapshot.methodsScanned = methodsScanned;
    snapshot.buildDuration = started ? -[started timeIntervalSinceNow] : 0;
    return snapshot;
}

static void RYGIndexPublish(NSString *key,
                            RYGRuntimeImageIndex *snapshot,
                            uint64_t epoch,
                            BOOL finalSnapshot) {
    if (!key.length || !snapshot) return;
    dispatch_async(RYGIndexStateQueue(), ^{
        if (atomic_load_explicit(&gRYGIndexEpoch, memory_order_relaxed) != epoch) return;
        if (!gRYGIndexes) gRYGIndexes = [NSMutableDictionary dictionary];
        if (!gRYGCompleted) gRYGCompleted = [NSMutableSet set];
        gRYGIndexes[key] = snapshot;
        NSArray *listeners = [gRYGListeners[key] copy] ?: @[];
        if (finalSnapshot) {
            [gRYGInFlight removeObject:key];
            [gRYGCompleted addObject:key];
            [gRYGListeners removeObjectForKey:key];
        }
        if (!listeners.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (RYGRuntimeIndexCompletion completion in listeners) {
                if (completion) completion(snapshot);
            }
        });
    });
}

static void RYGBuildIndexIncrementally(NSString *requested, NSString *key, uint64_t epoch) {
    @autoreleasepool {
        NSDate *started = NSDate.date;
        NSString *canonical = RYGIndexCanonicalPath(requested);
        const struct mach_header *target = RYGIndexHeaderForPath(canonical);
        if (!target) {
            RYGIndexPublish(key, RYGIndexSnapshot(canonical, @[], @{}, 0, 0, started, YES), epoch, YES);
            return;
        }

        NSString *runtimeName = RYGIndexRuntimeNameForPath(canonical) ?: requested;
        unsigned int imageClassCount = 0;
        const char **imageClassNames = objc_copyClassNamesForImage(runtimeName.fileSystemRepresentation, &imageClassCount);
        if (!imageClassNames || imageClassCount == 0 || imageClassCount > 500000) {
            if (imageClassNames) free(imageClassNames);
            RYGIndexPublish(key, RYGIndexSnapshot(canonical, @[], @{}, 0, 0, started, YES), epoch, YES);
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:imageClassCount];
        for (unsigned int index = 0; index < imageClassCount; index++) {
            const char *raw = imageClassNames[index];
            if (!raw || !*raw) continue;
            NSString *name = [NSString stringWithUTF8String:raw];
            if (name.length) [names addObject:name];
        }
        free(imageClassNames);
        [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

        NSMutableArray<RYGRuntimeClassRow *> *classRows = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *name in names) [classRows addObject:RYGIndexClassRow(name, canonical, 0, 0)];
        NSMutableDictionary<NSString *, NSArray<RYGRuntimeBoolMethod *> *> *methodsByClass = [NSMutableDictionary dictionary];

        // Second paint: the class list is usable before any class_copyMethodList
        // or dladdr pass. Method eligibility fills progressively afterwards.
        RYGIndexPublish(key, RYGIndexSnapshot(canonical, classRows, methodsByClass, 0, 0, started, NO), epoch, NO);

        NSUInteger methodsScanned = 0;
        NSUInteger classesScanned = 0;
        const NSUInteger publishBatch = 256;

        for (NSUInteger classIndex = 0; classIndex < names.count; classIndex++) {
            if (atomic_load_explicit(&gRYGIndexEpoch, memory_order_relaxed) != epoch) return;
            @autoreleasepool {
                NSString *className = names[classIndex];
                Class cls = objc_lookUpClass(className.UTF8String);
                if (!cls) {
                    classesScanned++;
                    continue;
                }

                NSMutableArray<RYGRuntimeBoolMethod *> *rows = nil;
                NSUInteger instanceCount = 0;
                NSUInteger classCount = 0;
                for (NSUInteger pass = 0; pass < 2; pass++) {
                    BOOL classMethod = pass == 1;
                    Class owner = classMethod ? object_getClass(cls) : cls;
                    unsigned int methodCount = 0;
                    Method *methods = owner ? class_copyMethodList(owner, &methodCount) : NULL;
                    methodsScanned += methodCount;
                    for (unsigned int methodIndex = 0; methods && methodIndex < methodCount; methodIndex++) {
                        Method method = methods[methodIndex];
                        if (!RYGIndexBoolReturn(method) || !RYGIndexIMPBelongsToHeader(method, target)) continue;
                        RYGRuntimeBoolMethod *methodRow = RYGIndexMethodRow(cls, method, classMethod, canonical);
                        if (!methodRow) continue;
                        if (!rows) rows = [NSMutableArray array];
                        [rows addObject:methodRow];
                        if (classMethod) classCount++; else instanceCount++;
                    }
                    if (methods) free(methods);
                }

                if (rows.count) {
                    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeBoolMethod *left, RYGRuntimeBoolMethod *right) {
                        if (left.classMethod != right.classMethod) return left.classMethod ? NSOrderedDescending : NSOrderedAscending;
                        return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
                    }];
                    methodsByClass[className] = rows.copy;
                }
                classRows[classIndex] = RYGIndexClassRow(className, canonical, instanceCount, classCount);
                classesScanned++;
            }

            if ((classesScanned % publishBatch) == 0) {
                RYGIndexPublish(key,
                                RYGIndexSnapshot(canonical, classRows, methodsByClass, classesScanned, methodsScanned, started, NO),
                                epoch,
                                NO);
            }
        }

        RYGIndexPublish(key,
                        RYGIndexSnapshot(canonical, classRows, methodsByClass, classesScanned, methodsScanned, started, YES),
                        epoch,
                        YES);
    }
}

@implementation RYGRuntimeIndex

+ (void)requestIndexForImagePath:(NSString *)imagePath completion:(RYGRuntimeIndexCompletion)completion {
    NSString *requested = [imagePath copy] ?: @"";
    NSString *key = RYGIndexCanonicalPath(requested);
    if (!key.length) {
        RYGRuntimeImageIndex *empty = [RYGRuntimeImageIndex new];
        empty.imagePath = @"";
        empty.classes = @[];
        empty.methodsByClass = @{};
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(empty); });
        return;
    }

    uint64_t epoch = atomic_load_explicit(&gRYGIndexEpoch, memory_order_relaxed);
    dispatch_async(RYGIndexStateQueue(), ^{
        if (atomic_load_explicit(&gRYGIndexEpoch, memory_order_relaxed) != epoch) return;
        if (!gRYGIndexes) gRYGIndexes = [NSMutableDictionary dictionary];
        if (!gRYGListeners) gRYGListeners = [NSMutableDictionary dictionary];
        if (!gRYGInFlight) gRYGInFlight = [NSMutableSet set];
        if (!gRYGCompleted) gRYGCompleted = [NSMutableSet set];

        RYGRuntimeImageIndex *cached = gRYGIndexes[key];
        if ([gRYGCompleted containsObject:key]) {
            RYGRuntimeImageIndex *finalSnapshot = cached ?: RYGIndexSnapshot(key, @[], @{}, 0, 0, nil, YES);
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(finalSnapshot); });
            return;
        }

        if (completion) {
            NSMutableArray *listeners = gRYGListeners[key];
            if (!listeners) {
                listeners = [NSMutableArray array];
                gRYGListeners[key] = listeners;
            }
            [listeners addObject:[completion copy]];
        }

        if (cached && completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        } else if (completion) {
            // First paint is deliberately empty and immediate. This guarantees
            // navigation never waits on Objective-C metadata traversal.
            RYGRuntimeImageIndex *bootstrap = RYGIndexSnapshot(key, @[], @{}, 0, 0, nil, NO);
            gRYGIndexes[key] = bootstrap;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(bootstrap); });
        }

        if ([gRYGInFlight containsObject:key]) return;
        [gRYGInFlight addObject:key];
        dispatch_async(RYGIndexWorkerQueue(), ^{
            RYGBuildIndexIncrementally(requested, key, epoch);
        });
    });
}

+ (RYGRuntimeImageIndex *)cachedIndexForImagePath:(NSString *)imagePath {
    __block RYGRuntimeImageIndex *index = nil;
    NSString *key = RYGIndexCanonicalPath(imagePath);
    dispatch_sync(RYGIndexStateQueue(), ^{
        index = gRYGIndexes[key];
    });
    return index;
}

+ (void)invalidate {
    atomic_fetch_add_explicit(&gRYGIndexEpoch, 1, memory_order_relaxed);
    dispatch_async(RYGIndexStateQueue(), ^{
        [gRYGIndexes removeAllObjects];
        [gRYGListeners removeAllObjects];
        [gRYGInFlight removeAllObjects];
        [gRYGCompleted removeAllObjects];
    });
}

@end
