// SCIMCParamAutoResolve.m — see header for the full rationale.

#import "SCIMCParamAutoResolve.h"
#import "../../Utils.h"
#import <pthread.h>
#import <os/log.h>

#define MCLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] MCAutoResolve " fmt, ##__VA_ARGS__)

static NSString *const kSCIMCLearnedParamsKey   = @"sci_mc_learned_internal_params";
static NSString *const kSCIMCLearnedSourceKey   = @"sci_mc_learned_params_source";

// Hard ceiling on what one scope may record. The internal-settings path reads
// a handful of params; anything far beyond that means the scope was left open
// by an early return / exception and we must not start forcing a wide set.
static const NSUInteger kSCIMCMaxLearnedParams = 24;

// ---------------------------------------------------------------------
// Per-thread scope depth. Thread-local because getBool* is called from
// several queues and a global counter would leak forcing into unrelated
// work running concurrently.
// ---------------------------------------------------------------------
static pthread_key_t gDepthKey;
static pthread_once_t gDepthOnce = PTHREAD_ONCE_INIT;
static void SCIMCDepthKeyInit(void) { pthread_key_create(&gDepthKey, NULL); }

static intptr_t SCIMCDepth(void) {
    pthread_once(&gDepthOnce, SCIMCDepthKeyInit);
    return (intptr_t)pthread_getspecific(gDepthKey);
}
static void SCIMCSetDepth(intptr_t d) {
    pthread_once(&gDepthOnce, SCIMCDepthKeyInit);
    pthread_setspecific(gDepthKey, (void *)d);
}

void SCIMCLearnScopeEnter(void) { SCIMCSetDepth(SCIMCDepth() + 1); }
void SCIMCLearnScopeExit(void) {
    intptr_t d = SCIMCDepth();
    SCIMCSetDepth(d > 0 ? d - 1 : 0);
}

// ---------------------------------------------------------------------
// Learned set (persisted) + seeds (compiled-in, non-authoritative).
// ---------------------------------------------------------------------
static NSMutableDictionary<NSNumber *, NSNumber *> *gSeeds = nil;   // raw -> requiresDogfoodPayload
static NSMutableSet<NSNumber *> *gLearned = nil;
static dispatch_once_t gStateOnce;

static void SCIMCLoadState(void) {
    dispatch_once(&gStateOnce, ^{
        gSeeds = [NSMutableDictionary dictionary];
        gLearned = [NSMutableSet set];
        NSArray *persisted = [SCIUtils getArrayPref:kSCIMCLearnedParamsKey];
        if ([persisted isKindOfClass:NSArray.class]) {
            for (id v in persisted) {
                if ([v isKindOfClass:NSNumber.class]) [gLearned addObject:v];
                else if ([v isKindOfClass:NSString.class]) {
                    unsigned long long raw = strtoull([(NSString *)v UTF8String], NULL, 0);
                    if (raw) [gLearned addObject:@(raw)];
                }
            }
        }
    });
}

static void SCIMCPersistLearned(NSString *source) {
    NSMutableArray *out = [NSMutableArray array];
    @synchronized (gLearned) {
        for (NSNumber *n in gLearned) [out addObject:[NSString stringWithFormat:@"0x%016llX", n.unsignedLongLongValue]];
    }
    [SCIUtils setPref:out forKey:kSCIMCLearnedParamsKey];
    if (source.length) [SCIUtils setPref:source forKey:kSCIMCLearnedSourceKey];
}

void SCIMCRegisterSeedParam(uint64_t raw, BOOL requiresDogfoodPayload) {
    if (!raw) return;
    SCIMCLoadState();
    @synchronized (gSeeds) { gSeeds[@(raw)] = @(requiresDogfoodPayload); }
}

void SCIMCNoteObservedParam(uint64_t raw) {
    if (!raw) return;
    if (SCIMCDepth() <= 0) return;   // hot path: one TLS read when not learning
    SCIMCLoadState();

    BOOL added = NO;
    @synchronized (gLearned) {
        if (gLearned.count >= kSCIMCMaxLearnedParams) return;
        NSNumber *key = @(raw);
        if (![gLearned containsObject:key]) { [gLearned addObject:key]; added = YES; }
    }
    if (added) {
        MCLOG("learned param 0x%{public}llX inside internal-settings scope", (unsigned long long)raw);
        SCIMCPersistLearned(@"observed inside internal-settings / bug-report path");
    }
}

BOOL SCIMCShouldForceLearnedParam(uint64_t raw) {
    if (!raw) return NO;
    SCIMCLoadState();
    @synchronized (gLearned) { if ([gLearned containsObject:@(raw)]) return YES; }
    @synchronized (gSeeds)   { if (gSeeds[@(raw)] != nil) return YES; }
    return NO;
}

BOOL SCIMCLearnedParamRequiresDogfoodPayload(uint64_t raw) {
    SCIMCLoadState();
    NSNumber *flag = nil;
    @synchronized (gSeeds) { flag = gSeeds[@(raw)]; }
    return flag.boolValue;   // learned IDs default to NO (no payload precondition)
}

NSString *SCIMCAutoResolveStatusSummary(void) {
    SCIMCLoadState();
    NSUInteger learned = 0, seeds = 0;
    @synchronized (gLearned) { learned = gLearned.count; }
    @synchronized (gSeeds)   { seeds = gSeeds.count; }
    NSString *source = [SCIUtils getStringPref:kSCIMCLearnedSourceKey];
    if (learned == 0) {
        return [NSString stringWithFormat:
            @"%lu seed ID%@, nothing learned yet. Open the shake / bug-report menu once with the master ON to calibrate this build.",
            (unsigned long)seeds, seeds == 1 ? @"" : @"s"];
    }
    return [NSString stringWithFormat:@"%lu learned + %lu seed ID%@ · %@",
        (unsigned long)learned, (unsigned long)seeds, seeds == 1 ? @"" : @"s",
        source.length ? source : @"persisted"];
}

void SCIMCAutoResolveReset(void) {
    SCIMCLoadState();
    @synchronized (gLearned) { [gLearned removeAllObjects]; }
    [SCIUtils setPref:nil forKey:kSCIMCLearnedParamsKey];
    [SCIUtils setPref:nil forKey:kSCIMCLearnedSourceKey];
    MCLOG("learned param set cleared");
}
