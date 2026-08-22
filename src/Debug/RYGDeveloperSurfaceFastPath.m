#import "RYGDeveloperTopicViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "../Features/ExpFlags/RYGMobileConfig.h"
#import <objc/runtime.h>
#include <string.h>

// Fast, targeted data source for Developer surfaces that previously performed
// process-global discovery from viewDidLoad. Runtime Browser is not involved.

@interface RYGDeveloperTopicViewController (RYGDeveloperSurfaceFastPathPrivate)
- (void)rebuildModels;
- (void)rebuildNativeControls;
- (void)rebuildFilteredModel;
@end

static dispatch_queue_t RYGDeveloperSurfaceQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ryukgram.developer-surface.fast", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static const char *RYGSurfaceSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGSurfaceBoolReturn(Method method) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGSurfaceSkipQualifiers(encoded);
    return type && *type == 'B';
}

static RYGRuntimeArgumentKind RYGSurfaceArgumentKind(Method method) {
    if (!RYGSurfaceBoolReturn(method)) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[64] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    const char *type = RYGSurfaceSkipQualifiers(encoded);
    if (!type || !*type) return (RYGRuntimeArgumentKind)-1;
    if (*type == '@') return RYGRuntimeArgumentObject;
    if (*type == 'q' || *type == 'Q') return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static Method RYGSurfaceDirectMethod(Class owner, SEL selector) {
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

static RYGRuntimeBoolMethod *RYGSurfaceMethod(NSString *className, NSString *selectorName, BOOL classMethod) {
    if (!className.length || !selectorName.length) return nil;
    Class cls = objc_lookUpClass(className.UTF8String);
    if (!cls) return nil;
    Class owner = classMethod ? object_getClass(cls) : cls;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = RYGSurfaceDirectMethod(owner, selector);
    RYGRuntimeArgumentKind kind = RYGSurfaceArgumentKind(method);
    if (!method || kind < RYGRuntimeArgumentNone || kind > RYGRuntimeArgumentInteger) return nil;

    RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
    row.className = className;
    row.selectorName = selectorName;
    row.classMethod = classMethod;
    row.argumentKind = kind;
    const char *types = method_getTypeEncoding(method);
    row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
    const char *image = class_getImageName(cls);
    row.imagePath = image ? [NSString stringWithUTF8String:image] : @"";
    return row;
}

static NSArray<RYGRuntimeBoolMethod *> *RYGFastStoryRows(void) {
    NSMutableArray<RYGRuntimeBoolMethod *> *rows = [NSMutableArray arrayWithCapacity:3];
    RYGRuntimeBoolMethod *row = nil;

    row = RYGSurfaceMethod(@"_TtC27IGPersistentStoryTrayGating38IGPersistentStoryTrayGatingStaticFuncs",
                           @"isTrayAttachedToHeaderEnabled:", YES);
    if (row) [rows addObject:row];

    row = RYGSurfaceMethod(@"_TtC38IGStoryViewerRedesignExperimentHelpers38IGStoryViewerRedesignExperimentHelpers",
                           @"isStoryViewerCardAnimationEnabledWithLauncherSet:", YES);
    if (row) [rows addObject:row];

    // Verified in FBSharedFramework(20260821-132949):
    // _TtC18IGNavConfiguration25IGHomecomingConfiguration
    // TB,N,R,VisDynamicTabStoryGridEnabled
    row = RYGSurfaceMethod(@"_TtC18IGNavConfiguration25IGHomecomingConfiguration",
                           @"isDynamicTabStoryGridEnabled", NO);
    if (row) [rows addObject:row];

    return rows.copy;
}

static BOOL RYGFastDogfoodName(NSString *name) {
    NSString *value = name.lowercaseString ?: @"";
    return [value containsString:@"dogfood"] ||
           [value containsString:@"employee"] ||
           [value containsString:@"internal"];
}

static NSArray<RYGMCParam *> *gRYGFastDogfoodCandidates;
static BOOL gRYGFastDogfoodLoadRunning;
static NSMutableArray<void (^)(NSArray<RYGMCParam *> *)> *gRYGFastDogfoodWaiters;

static void RYGLoadDogfoodCandidates(void (^completion)(NSArray<RYGMCParam *> *rows)) {
    dispatch_async(RYGDeveloperSurfaceQueue(), ^{
        if (gRYGFastDogfoodCandidates) {
            NSArray *snapshot = gRYGFastDogfoodCandidates;
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(snapshot); });
            return;
        }
        if (!gRYGFastDogfoodWaiters) gRYGFastDogfoodWaiters = [NSMutableArray array];
        if (completion) [gRYGFastDogfoodWaiters addObject:[completion copy]];
        if (gRYGFastDogfoodLoadRunning) return;
        gRYGFastDogfoodLoadRunning = YES;

        RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
        [mobileConfig prepare];
        NSMutableArray<RYGMCParam *> *out = [NSMutableArray array];
        for (RYGMCConfig *config in mobileConfig.allConfigs) {
            BOOL configMatch = RYGFastDogfoodName(config.name);
            for (RYGMCParam *param in config.params) {
                if (!param.isRuntimeBacked || param.type != RYGMCTypeBool || !param.name.length) continue;
                if (configMatch || RYGFastDogfoodName(param.name)) [out addObject:param];
            }
        }
        [out sortUsingComparator:^NSComparisonResult(RYGMCParam *left, RYGMCParam *right) {
            if (left.configNumber != right.configNumber)
                return left.configNumber < right.configNumber ? NSOrderedAscending : NSOrderedDescending;
            if (left.paramIndex == right.paramIndex) return NSOrderedSame;
            return left.paramIndex < right.paramIndex ? NSOrderedAscending : NSOrderedDescending;
        }];
        gRYGFastDogfoodCandidates = out.copy;
        NSArray *waiters = gRYGFastDogfoodWaiters.copy;
        [gRYGFastDogfoodWaiters removeAllObjects];
        gRYGFastDogfoodLoadRunning = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^block)(NSArray<RYGMCParam *> *) in waiters) block(gRYGFastDogfoodCandidates);
        });
    });
}

@implementation RYGDeveloperTopicViewController (RYGDeveloperSurfaceFastPath)

- (void)ryg_fast_rebuildModels {
    NSNumber *rawSurface = [self valueForKey:@"surface"];
    RYGDeveloperRuntimeSurface surface = (RYGDeveloperRuntimeSurface)rawSurface.integerValue;

    if (surface == RYGDeveloperRuntimeSurfaceStories) {
        [self setValue:RYGFastStoryRows() forKey:@"allRows"];
        [self setValue:@[] forKey:@"mobileConfigCandidates"];
        [self rebuildNativeControls];
        [self rebuildFilteredModel];
        return;
    }

    if (surface == RYGDeveloperRuntimeSurfaceDirectDogfood) {
        [self setValue:@[] forKey:@"allRows"];
        [self rebuildNativeControls];
        NSArray *cached = gRYGFastDogfoodCandidates ?: @[];
        [self setValue:cached forKey:@"mobileConfigCandidates"];
        [self rebuildFilteredModel];

        if (!gRYGFastDogfoodCandidates) {
            __weak typeof(self) weakSelf = self;
            RYGLoadDogfoodCandidates(^(NSArray<RYGMCParam *> *rows) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                NSNumber *current = [strongSelf valueForKey:@"surface"];
                if (current.integerValue != RYGDeveloperRuntimeSurfaceDirectDogfood) return;
                [strongSelf setValue:rows ?: @[] forKey:@"mobileConfigCandidates"];
                [strongSelf rebuildFilteredModel];
            });
        }
        return;
    }

    // Prism, Throwback and the remaining surfaces already use bounded known
    // owners or no method catalogue at all. Keep their native builders intact.
    [self ryg_fast_rebuildModels];
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"rebuildModels"));
        Method replacement = class_getInstanceMethod(self, @selector(ryg_fast_rebuildModels));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

@end
