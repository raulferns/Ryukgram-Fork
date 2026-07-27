#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>

#define DGBLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] GraphQLDynamicBridge " fmt, ##__VA_ARGS__)

extern NSUInteger SCIRefreshGraphQLDogfoodDynamicStatusHooks(void);

static NSString *(*orig_SCIGraphQLInstallObservers)(id, SEL) = NULL;
static id (*orig_SCIDogfoodEligibilityBuilder)(id, SEL, id) = NULL;

static NSString *SCIGraphQLInstallObservers(id self, SEL _cmd) {
    NSUInteger dynamicCount = SCIRefreshGraphQLDogfoodDynamicStatusHooks();
    NSString *base = orig_SCIGraphQLInstallObservers
        ? orig_SCIGraphQLInstallObservers(self, _cmd)
        : @"observer installer unavailable";
    return [NSString stringWithFormat:@"Dynamic eligibility roots installed: %lu\n\n%@",
            (unsigned long)dynamicCount, base ?: @""];
}

static id SCIDogfoodEligibilityBuilder(id self, SEL _cmd, id lookbackDays) {
    id builder = orig_SCIDogfoodEligibilityBuilder
        ? orig_SCIDogfoodEligibilityBuilder(self, _cmd, lookbackDays)
        : nil;

    // This runs only when Instagram actually builds DogfoodingEligibilityQuery,
    // never during launch. Generated Pando response classes are loaded by then,
    // so resolve the concrete root/status model without a ctor-wide scan.
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

    MSHookMessageEx(meta, selector,
                    (IMP)SCIDogfoodEligibilityBuilder,
                    (IMP *)&orig_SCIDogfoodEligibilityBuilder);
    installed = (orig_SCIDogfoodEligibilityBuilder != NULL);
}


// Correct install timing for classes that live in frameworks loaded AFTER the
// dylib (IGDogfoodingFirst, IGDogfooderProd, the Swift coordinator/lockout VC).
// %ctor alone is too early (objc_getClass == nil); a user-triggered/viewDidLoad
// pass is too late (the build-status check already ran and cached useCache=1).
// dyld notifies us as each image loads+binds; we then re-run the idempotent
// installer so every target is hooked the moment its framework appears — before
// Instagram's session-start dogfooding flow uses it. The hook itself is deferred
// off the dyld lock (main queue) to avoid deadlocking the ObjC runtime lock.
static atomic_bool sDGScanQueued = false;
static atomic_bool sDGAllInstalled = false;

static void SCIDGImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    if (atomic_load(&sDGAllInstalled)) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&sDGScanQueued, &expected, true)) return; // coalesce
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&sDGScanQueued, false);
        if (atomic_load(&sDGAllInstalled)) return;
        Class cls = objc_getClass("SCIGraphQLDogfoodDiagnostics");
        if (!cls) return;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSString *result = [cls performSelector:@selector(installObservers)];
        #pragma clang diagnostic pop
        // Latch off once nothing is missing (all target classes have loaded+hooked).
        if ([result isKindOfClass:[NSString class]] &&
            [result rangeOfString:@"ABI-mismatched: none"].location != NSNotFound) {
            atomic_store(&sDGAllInstalled, true);
        }
    });
}

%ctor {
    @autoreleasepool {
        Class cls = objc_getClass("SCIGraphQLDogfoodDiagnostics");
        SEL selector = NSSelectorFromString(@"installObservers");
        Class meta = cls ? object_getClass(cls) : Nil;
        Method method = meta ? class_getInstanceMethod(meta, selector) : NULL;
        if (method) {
            MSHookMessageEx(meta, selector,
                            (IMP)SCIGraphQLInstallObservers,
                            (IMP *)&orig_SCIGraphQLInstallObservers);
        }
        // Install on every image load so late-loading framework classes get hooked
        // at the right time (fires immediately for already-loaded images too).
        _dyld_register_func_for_add_image(SCIDGImageAdded);
    }
}
