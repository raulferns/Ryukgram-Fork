#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>

#define DGBLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] GraphQLDynamicBridge " fmt, ##__VA_ARGS__)

extern NSUInteger SCIRefreshGraphQLDogfoodDynamicStatusHooks(void);
extern BOOL SCIInstallInternalGlobalHooksIfNeeded(void);

static NSString *(*orig_SCIGraphQLInstallObservers)(id, SEL) = NULL;
static id (*orig_SCIDogfoodEligibilityBuilder)(id, SEL, id) = NULL;

static NSString *SCIGraphQLInstallObservers(id self, SEL _cmd) {
    BOOL internalReady = SCIInstallInternalGlobalHooksIfNeeded();
    NSUInteger dynamicCount = SCIRefreshGraphQLDogfoodDynamicStatusHooks();
    NSString *base = orig_SCIGraphQLInstallObservers
        ? orig_SCIGraphQLInstallObservers(self, _cmd)
        : @"observer installer unavailable";
    return [NSString stringWithFormat:
            @"Internal global hooks ready: %@\nDynamic eligibility roots installed: %lu\n\n%@",
            internalReady ? @"YES" : @"NO / waiting for framework",
            (unsigned long)dynamicCount, base ?: @""];
}

static id SCIDogfoodEligibilityBuilder(id self, SEL _cmd, id lookbackDays) {
    id builder = orig_SCIDogfoodEligibilityBuilder
        ? orig_SCIDogfoodEligibilityBuilder(self, _cmd, lookbackDays)
        : nil;
    SCIInstallInternalGlobalHooksIfNeeded();
    NSUInteger count = SCIRefreshGraphQLDogfoodDynamicStatusHooks();
    DGBLOG("query built; dynamic roots installed=%lu", (unsigned long)count);
    return builder;
}

void SCIInstallGraphQLDogfoodQueryBridgeIfNeeded(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("DogfoodingEligibilityQueryBuilder");
    SEL selector = NSSelectorFromString(@"builderWithLookbackDays:");
    Class meta = cls ? object_getClass(cls) : Nil;
    Method method = meta ? class_getInstanceMethod(meta, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!method || !encoding || strcmp(encoding, "@24@0:8@16") != 0) {
        if (method) DGBLOG("skip query bridge ABI=%{public}s", encoding ?: "(null)");
        return;
    }
    MSHookMessageEx(meta, selector, (IMP)SCIDogfoodEligibilityBuilder,
                    (IMP *)&orig_SCIDogfoodEligibilityBuilder);
    installed = (orig_SCIDogfoodEligibilityBuilder != NULL);
}

static atomic_bool sDGScanQueued = false;
static atomic_bool sDGAllInstalled = false;

static void SCIDGImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    if (atomic_load(&sDGAllInstalled)) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&sDGScanQueued, &expected, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&sDGScanQueued, false);
        if (atomic_load(&sDGAllInstalled)) return;
        BOOL internalReady = SCIInstallInternalGlobalHooksIfNeeded();
        Class cls = objc_getClass("SCIGraphQLDogfoodDiagnostics");
        if (!cls) return;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSString *result = [cls performSelector:@selector(installObservers)];
        #pragma clang diagnostic pop
        if (internalReady &&
            [result isKindOfClass:[NSString class]] &&
            [result rangeOfString:@"ABI-mismatched: none"].location != NSNotFound) {
            atomic_store(&sDGAllInstalled, true);
        }
    });
}

%ctor {
    @autoreleasepool {
        SCIInstallInternalGlobalHooksIfNeeded();
        Class cls = objc_getClass("SCIGraphQLDogfoodDiagnostics");
        SEL selector = NSSelectorFromString(@"installObservers");
        Class meta = cls ? object_getClass(cls) : Nil;
        Method method = meta ? class_getInstanceMethod(meta, selector) : NULL;
        if (method) {
            MSHookMessageEx(meta, selector, (IMP)SCIGraphQLInstallObservers,
                            (IMP *)&orig_SCIGraphQLInstallObservers);
        }
        _dyld_register_func_for_add_image(SCIDGImageAdded);
    }
}
