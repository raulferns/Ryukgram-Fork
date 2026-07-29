#import "SCIGraphQLDogfoodDiagnostics.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>
#import <stdlib.h>

#define DGLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGraphQLDogfood] " fmt, ##__VA_ARGS__)

static NSMutableArray<NSString *> *sDGEvents;
static NSNumber *sDGLastEligibilityStatus;
static NSNumber *sDGLastLookbackDays;
static NSUInteger sDGEligibilityQueryCount;
static NSUInteger sDGSessionStartCount;
static NSUInteger sDGAvailableUpdateCheckCount;
static NSUInteger sDGBuildStatusCheckCount;
static NSUInteger sDGTriggerUpdateCount;
static NSUInteger sDGWarningExpirationCount;
static id sDGDebugProvider;

static BOOL sDGBuilderHooked;
static BOOL sDGEmployeeFragmentHooked;
static BOOL sDGDogfooderFragmentHooked;
static BOOL sDGShowIssueFragmentHooked;
static BOOL sDGCoordinatorHooked;
static BOOL sDGWarningHooked;
static BOOL sDGAvailableUpdatesHooked;
static BOOL sDGBuildStatusHooked;
static BOOL sDGTriggerUpdateHooked;
static BOOL sDGE2EObserverHooked;

static NSMutableArray<NSString *> *DGEvents(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sDGEvents = [NSMutableArray array]; });
    return sDGEvents;
}

static NSMutableSet<NSString *> *DGRootAccessorHookKeys(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSMutableSet<NSString *> *DGStatusHookKeys(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSString *DGTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:NSDate.date] ?: @"--:--:--";
    }
}

static NSString *DGClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"nil";
}

static void DGRecord(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@  %@", DGTimestamp(), message ?: @""];
    @synchronized (DGEvents()) {
        [DGEvents() addObject:line];
        while (DGEvents().count > 40) [DGEvents() removeObjectAtIndex:0];
    }
    DGLOG("%{public}@", line);
}

// Runtime encodings may preserve quoted class/protocol names and detailed block
// signatures. Strip those annotations while preserving the ABI shape.
static NSString *DGNormalizedEncoding(const char *encoding) {
    if (!encoding) return @"";
    NSMutableString *out = [NSMutableString string];
    const char *p = encoding;
    while (*p) {
        if (*p != '@') {
            [out appendFormat:@"%c", *p++];
            continue;
        }

        [out appendString:@"@"];
        p++;
        if (*p == '"') {
            p++;
            while (*p && *p != '"') p++;
            if (*p == '"') p++;
            continue;
        }
        if (*p == '?') {
            [out appendString:@"?"];
            p++;
            if (*p == '<') {
                NSInteger depth = 0;
                do {
                    if (*p == '<') depth++;
                    else if (*p == '>') depth--;
                    p++;
                } while (*p && depth > 0);
            }
        }
    }
    return out;
}

static BOOL DGTypeMatches(Method method, const char *expected) {
    if (!method || !expected) return NO;
    return [DGNormalizedEncoding(method_getTypeEncoding(method))
        isEqualToString:DGNormalizedEncoding(expected)];
}

static BOOL DGInstallInstanceHook(Class cls, SEL sel, IMP replacement, IMP *original, const char *encoding) {
    if (!original) return NO;
    if (*original) return YES;
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!DGTypeMatches(method, encoding)) {
        if (method) {
            DGLOG("skip %{public}@ %{public}s ABI=%{public}s normalized=%{public}@",
                  NSStringFromClass(cls), sel_getName(sel), method_getTypeEncoding(method),
                  DGNormalizedEncoding(method_getTypeEncoding(method)));
        }
        return NO;
    }
    MSHookMessageEx(cls, sel, replacement, original);
    return *original != NULL;
}

static BOOL DGInstallClassHook(Class cls, SEL sel, IMP replacement, IMP *original, const char *encoding) {
    return cls ? DGInstallInstanceHook(object_getClass(cls), sel, replacement, original, encoding) : NO;
}

#pragma mark - Exact DogfoodingEligibilityQuery model

// The generated Pando response uses protocols/model-info references rather than
// a guaranteed Objective-C class named "...ResponseImpl". Resolve the concrete
// runtime class through the exact root accessor, then hook status only on the
// object returned by that accessor. This avoids a global -status hook.
typedef struct {
    Class cls;
    SEL sel;
    IMP original;
} DGDynamicGetterHook;

static void DGRecordEligibilityValue(id value) {
    if ([value respondsToSelector:@selector(boolValue)]) {
        BOOL eligible = ((BOOL (*)(id, SEL))objc_msgSend)(value, @selector(boolValue));
        @synchronized (DGEvents()) { sDGLastEligibilityStatus = @(eligible); }
        DGRecord([NSString stringWithFormat:@"DogfoodingEligibilityQuery status=%@ (%@)",
                  eligible ? @"YES / eligible-normal path" : @"NO / show-issue path",
                  DGClassName(value)]);
    } else {
        DGRecord([NSString stringWithFormat:@"DogfoodingEligibilityQuery status object=%@ (no boolValue)",
                  DGClassName(value)]);
    }
}

static BOOL DGInstallStatusHookForObject(id object) {
    if (!object) return NO;
    Class cls = object_getClass(object);
    SEL sel = NSSelectorFromString(@"status");
    Method method = class_getInstanceMethod(cls, sel);
    if (!DGTypeMatches(method, "@16@0:8")) {
        DGRecord([NSString stringWithFormat:@"eligibility nested model %@ has no compatible -status", NSStringFromClass(cls)]);
        return NO;
    }

    NSString *key = [NSString stringWithFormat:@"%@#status", NSStringFromClass(cls)];
    @synchronized (DGStatusHookKeys()) {
        if ([DGStatusHookKeys() containsObject:key]) return YES;
        [DGStatusHookKeys() addObject:key];
    }

    DGDynamicGetterHook *descriptor = calloc(1, sizeof(*descriptor));
    descriptor->cls = cls;
    descriptor->sel = sel;

    id block = ^id(id receiver) {
        id value = descriptor->original
            ? ((id (*)(id, SEL))descriptor->original)(receiver, descriptor->sel)
            : nil;
        DGRecordEligibilityValue(value);
        return value;
    };
    IMP replacement = imp_implementationWithBlock(block);
    MSHookMessageEx(cls, sel, replacement, &descriptor->original);
    if (!descriptor->original) {
        @synchronized (DGStatusHookKeys()) { [DGStatusHookKeys() removeObject:key]; }
        imp_removeBlock(replacement);
        free(descriptor);
        return NO;
    }

    DGRecord([NSString stringWithFormat:@"installed exact eligibility -status hook on %@", NSStringFromClass(cls)]);
    return YES;
}

static BOOL DGInstallRootAccessorHook(Class cls, Method method) {
    SEL sel = NSSelectorFromString(@"xdtApi_V1_Dogfooding_EligibilityStatus");
    if (!cls || !method || method_getName(method) != sel || !DGTypeMatches(method, "@16@0:8")) return NO;

    NSString *key = [NSString stringWithFormat:@"%@#%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    @synchronized (DGRootAccessorHookKeys()) {
        if ([DGRootAccessorHookKeys() containsObject:key]) return YES;
        [DGRootAccessorHookKeys() addObject:key];
    }

    DGDynamicGetterHook *descriptor = calloc(1, sizeof(*descriptor));
    descriptor->cls = cls;
    descriptor->sel = sel;

    id block = ^id(id receiver) {
        id nested = descriptor->original
            ? ((id (*)(id, SEL))descriptor->original)(receiver, descriptor->sel)
            : nil;
        if (nested) {
            DGInstallStatusHookForObject(nested);
            DGRecord([NSString stringWithFormat:@"eligibility nested response class=%@", DGClassName(nested)]);
        }
        return nested;
    };
    IMP replacement = imp_implementationWithBlock(block);
    MSHookMessageEx(cls, sel, replacement, &descriptor->original);
    if (!descriptor->original) {
        @synchronized (DGRootAccessorHookKeys()) { [DGRootAccessorHookKeys() removeObject:key]; }
        imp_removeBlock(replacement);
        free(descriptor);
        return NO;
    }

    DGRecord([NSString stringWithFormat:@"installed exact eligibility root accessor on %@", NSStringFromClass(cls)]);
    return YES;
}

static NSUInteger DGInstallEligibilityRuntimeModelHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return 0;

    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSUInteger installed = 0;
    SEL target = NSSelectorFromString(@"xdtApi_V1_Dogfooding_EligibilityStatus");

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) != target) continue;
            if (DGInstallRootAccessorHook(cls, methods[j])) installed++;
        }
        free(methods);
    }
    free(classes);
    return installed;
}

static id (*orig_DGEligibilityBuilder)(id, SEL, id) = NULL;
static id DGEligibilityBuilder(id self, SEL _cmd, id lookbackDays) {
    @synchronized (DGEvents()) {
        sDGEligibilityQueryCount++;
        sDGLastLookbackDays = [lookbackDays isKindOfClass:NSNumber.class] ? lookbackDays : nil;
    }
    DGRecord([NSString stringWithFormat:@"DogfoodingEligibilityQuery built lookback_days=%@", lookbackDays ?: @"nil"]);
    return orig_DGEligibilityBuilder ? orig_DGEligibilityBuilder(self, _cmd, lookbackDays) : nil;
}

#pragma mark - Exact user fragment accessors

static void DGRecordBadgesFromModel(id model) {
    if (!model) {
        DGRecord(@"employee/test-user fragment=nil");
        return;
    }
    SEL badgesSel = NSSelectorFromString(@"accountBadges");
    id badges = [model respondsToSelector:badgesSel]
        ? ((id (*)(id, SEL))objc_msgSend)(model, badgesSel)
        : nil;
    BOOL employeeBadge = [badges respondsToSelector:@selector(containsObject:)]
        ? [badges containsObject:@0]
        : NO;
    NSUInteger count = [badges respondsToSelector:@selector(count)]
        ? ((NSUInteger (*)(id, SEL))objc_msgSend)(badges, @selector(count))
        : 0;
    DGRecord([NSString stringWithFormat:@"account_badges fragment=%@ count=%lu employeeBadge0=%d",
              DGClassName(model), (unsigned long)count, employeeBadge]);
}

static id (*orig_DGEmployeeFragment)(id, SEL) = NULL;
static id DGEmployeeFragment(id self, SEL _cmd) {
    id model = orig_DGEmployeeFragment ? orig_DGEmployeeFragment(self, _cmd) : nil;
    DGRecordBadgesFromModel(model);
    return model;
}

static id (*orig_DGDogfooderFragment)(id, SEL) = NULL;
static id DGDogfooderFragment(id self, SEL _cmd) {
    id model = orig_DGDogfooderFragment ? orig_DGDogfooderFragment(self, _cmd) : nil;
    DGRecord([NSString stringWithFormat:@"IGDogfooderInformationFragment present=%d class=%@", model != nil, DGClassName(model)]);
    return model;
}

static id (*orig_DGShowIssueFragment)(id, SEL) = NULL;
static id DGShowIssueFragment(id self, SEL _cmd) {
    id model = orig_DGShowIssueFragment ? orig_DGShowIssueFragment(self, _cmd) : nil;
    DGRecord([NSString stringWithFormat:@"IGDogfoodingFirstShowIssueFragment present=%d class=%@", model != nil, DGClassName(model)]);
    return model;
}

#pragma mark - Session coordinator and repeated backend checks

static void (*orig_DGSessionStart)(id, SEL, id, id, id) = NULL;
static void DGSessionStart(id self, SEL _cmd, id mainVC, id pandoService, id dogfooder) {
    @synchronized (DGEvents()) { sDGSessionStartCount++; }
    DGRecord([NSString stringWithFormat:@"dogfood session start pando=%@ dogfooder=%@",
              DGClassName(pandoService), DGClassName(dogfooder)]);
    if (orig_DGSessionStart) orig_DGSessionStart(self, _cmd, mainVC, pandoService, dogfooder);
}

static void (*orig_DGWarningExpired)(id, SEL, id) = NULL;
static void DGWarningExpired(id self, SEL _cmd, id user) {
    @synchronized (DGEvents()) { sDGWarningExpirationCount++; }
    DGRecord(@"local dogfood warning expiration evaluated");
    if (orig_DGWarningExpired) orig_DGWarningExpired(self, _cmd, user);
}

static void (*orig_DGCheckAvailableUpdates)(id, SEL, id) = NULL;
static void DGCheckAvailableUpdates(id self, SEL _cmd, id completion) {
    @synchronized (DGEvents()) { sDGAvailableUpdateCheckCount++; }
    DGRecord(@"backend check: available dogfood app updates");
    if (orig_DGCheckAvailableUpdates) orig_DGCheckAvailableUpdates(self, _cmd, completion);
}

static void (*orig_DGCheckBuildStatus)(id, SEL, id, BOOL, id) = NULL;
static void DGCheckBuildStatus(id self, SEL _cmd, id build, BOOL useCache, id completion) {
    @synchronized (DGEvents()) { sDGBuildStatusCheckCount++; }
    DGRecord([NSString stringWithFormat:@"backend check: dogfood build status buildClass=%@ useCache=%d",
              DGClassName(build), useCache]);
    if (orig_DGCheckBuildStatus) orig_DGCheckBuildStatus(self, _cmd, build, useCache, completion);
}

static void (*orig_DGTriggerUpdate)(id, SEL, NSInteger, id) = NULL;
static void DGTriggerUpdate(id self, SEL _cmd, NSInteger mode, id completion) {
    @synchronized (DGEvents()) { sDGTriggerUpdateCount++; }
    DGRecord([NSString stringWithFormat:@"backend action: trigger dogfood update mode=%ld", (long)mode]);
    if (orig_DGTriggerUpdate) orig_DGTriggerUpdate(self, _cmd, mode, completion);
}

#pragma mark - E2E observer; preserves original result

static BOOL (*orig_DGE2EBypass)(id, SEL, id) = NULL;
static BOOL DGE2EBypass(id self, SEL _cmd, id launcherSet) {
    BOOL result = orig_DGE2EBypass ? orig_DGE2EBypass(self, _cmd, launcherSet) : NO;
    DGRecord([NSString stringWithFormat:@"E2E bypass evaluated original=%d launcherSet=%@",
              result, DGClassName(launcherSet)]);
    return result;
}

#pragma mark - Install

@implementation SCIGraphQLDogfoodDiagnostics

+ (NSString *)installObservers {
    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    Class builder = objc_getClass("DogfoodingEligibilityQueryBuilder");
    if (DGInstallClassHook(builder, NSSelectorFromString(@"builderWithLookbackDays:"),
                           (IMP)DGEligibilityBuilder, (IMP *)&orig_DGEligibilityBuilder,
                           "@24@0:8@16")) {
        sDGBuilderHooked = YES; [installed addObject:@"eligibility query builder"];
    } else if (!sDGBuilderHooked) [missing addObject:@"eligibility query builder"];

    NSUInteger rootHooks = DGInstallEligibilityRuntimeModelHooks();
    if (rootHooks || DGRootAccessorHookKeys().count) {
        [installed addObject:[NSString stringWithFormat:@"eligibility runtime model (%lu classes)",
                              (unsigned long)DGRootAccessorHookKeys().count]];
    } else {
        [missing addObject:@"eligibility runtime model (retry after response is loaded)"];
    }

    Class baseUser = objc_getClass("IGBaseUser");
    if (DGInstallInstanceHook(baseUser, NSSelectorFromString(@"asIGUserIsEmployeeOrTestUserFragmentImmutableModel"),
                              (IMP)DGEmployeeFragment, (IMP *)&orig_DGEmployeeFragment,
                              "@16@0:8")) {
        sDGEmployeeFragmentHooked = YES; [installed addObject:@"employee/test-user fragment"];
    } else if (!sDGEmployeeFragmentHooked) [missing addObject:@"employee/test-user fragment"];

    if (DGInstallInstanceHook(baseUser, NSSelectorFromString(@"asIGDogfooderInformationFragmentImmutableModel"),
                              (IMP)DGDogfooderFragment, (IMP *)&orig_DGDogfooderFragment,
                              "@16@0:8")) {
        sDGDogfooderFragmentHooked = YES; [installed addObject:@"dogfooder information fragment"];
    } else if (!sDGDogfooderFragmentHooked) [missing addObject:@"dogfooder information fragment"];

    if (DGInstallInstanceHook(baseUser, NSSelectorFromString(@"asIGDogfoodingFirstShowIssueFragmentImmutableModel"),
                              (IMP)DGShowIssueFragment, (IMP *)&orig_DGShowIssueFragment,
                              "@16@0:8")) {
        sDGShowIssueFragmentHooked = YES; [installed addObject:@"show-issue fragment"];
    } else if (!sDGShowIssueFragmentHooked) [missing addObject:@"show-issue fragment"];

    Class coordinator = objc_getClass("_TtC17IGDogfoodingFirst26DogfoodingFirstCoordinator");
    if (DGInstallInstanceHook(coordinator,
                              NSSelectorFromString(@"didBeginSessionWithMainAppViewController:pandoGraphQLService:dogfooder:"),
                              (IMP)DGSessionStart, (IMP *)&orig_DGSessionStart,
                              "v40@0:8@16@24@32")) {
        sDGCoordinatorHooked = YES; [installed addObject:@"dogfood session coordinator"];
    } else if (!sDGCoordinatorHooked) [missing addObject:@"dogfood session coordinator"];

    if (DGInstallInstanceHook(coordinator, NSSelectorFromString(@"didPassWarningExpirationForUser:"),
                              (IMP)DGWarningExpired, (IMP *)&orig_DGWarningExpired,
                              "v24@0:8@16")) {
        sDGWarningHooked = YES; [installed addObject:@"warning expiration"];
    } else if (!sDGWarningHooked) [missing addObject:@"warning expiration"];

    Class prod = objc_getClass("IGDogfooderProd");
    if (DGInstallInstanceHook(prod, NSSelectorFromString(@"checkAvailableAppUpdatesWithCompletion:"),
                              (IMP)DGCheckAvailableUpdates, (IMP *)&orig_DGCheckAvailableUpdates,
                              "v24@0:8@?16")) {
        sDGAvailableUpdatesHooked = YES; [installed addObject:@"available-update check"];
    } else if (!sDGAvailableUpdatesHooked) [missing addObject:@"available-update check"];

    if (DGInstallInstanceHook(prod, NSSelectorFromString(@"checkBuildStatusForBuild:useCacheResultIfAvailable:completion:"),
                              (IMP)DGCheckBuildStatus, (IMP *)&orig_DGCheckBuildStatus,
                              "v36@0:8@16B24@?28")) {
        sDGBuildStatusHooked = YES; [installed addObject:@"build-status check"];
    } else if (!sDGBuildStatusHooked) [missing addObject:@"build-status check"];

    if (DGInstallInstanceHook(prod, NSSelectorFromString(@"triggerUpdateWithMode:completion:"),
                              (IMP)DGTriggerUpdate, (IMP *)&orig_DGTriggerUpdate,
                              "v32@0:8q16@?24")) {
        sDGTriggerUpdateHooked = YES; [installed addObject:@"dogfood update action"];
    } else if (!sDGTriggerUpdateHooked) [missing addObject:@"dogfood update action"];

    Class e2e = objc_getClass("_TtC15IGE2EBypassUtil15IGE2EBypassUtil");
    if (DGInstallClassHook(e2e, NSSelectorFromString(@"shouldBypassForE2EWithLauncherSet:"),
                           (IMP)DGE2EBypass, (IMP *)&orig_DGE2EBypass,
                           "B24@0:8@16")) {
        sDGE2EObserverHooked = YES; [installed addObject:@"E2E original-result observer"];
    } else if (!sDGE2EObserverHooked) [missing addObject:@"E2E observer"];

    DGRecord([NSString stringWithFormat:@"observer install pass: installed=%lu missing=%lu",
              (unsigned long)installed.count, (unsigned long)missing.count]);

    return [NSString stringWithFormat:@"Installed/active: %@\n\nNot loaded or ABI-mismatched: %@\n\nTap again after login or after the dogfood query runs to resolve generated Pando model classes.",
            installed.count ? [installed componentsJoinedByString:@", "] : @"none",
            missing.count ? [missing componentsJoinedByString:@", "] : @"none"];
}

+ (NSString *)snapshot {
    NSArray<NSString *> *events;
    NSNumber *status;
    NSNumber *lookback;
    NSUInteger queryCount, sessionCount, availableCount, buildCount, updateCount, warningCount;
    @synchronized (DGEvents()) {
        events = DGEvents().copy;
        status = sDGLastEligibilityStatus;
        lookback = sDGLastLookbackDays;
        queryCount = sDGEligibilityQueryCount;
        sessionCount = sDGSessionStartCount;
        availableCount = sDGAvailableUpdateCheckCount;
        buildCount = sDGBuildStatusCheckCount;
        updateCount = sDGTriggerUpdateCount;
        warningCount = sDGWarningExpirationCount;
    }

    NSString *eligibility = status
        ? (status.boolValue ? @"YES — eligible/normal path" : @"NO — show-issue path")
        : @"not observed";

    NSString *header = [NSString stringWithFormat:
        @"Eligibility status: %@\nLast lookback_days: %@\nQuery builds: %lu\nRuntime root hooks: %lu\nRuntime status hooks: %lu\nSession starts: %lu\nAvailable-update checks: %lu\nBuild-status checks: %lu\nUpdate actions: %lu\nWarning expirations: %lu",
        eligibility, lookback ?: @"not observed",
        (unsigned long)queryCount,
        (unsigned long)DGRootAccessorHookKeys().count,
        (unsigned long)DGStatusHookKeys().count,
        (unsigned long)sessionCount,
        (unsigned long)availableCount, (unsigned long)buildCount,
        (unsigned long)updateCount, (unsigned long)warningCount];

    NSString *tail = events.count ? [events componentsJoinedByString:@"\n"] : @"No runtime events yet.";
    return [NSString stringWithFormat:@"%@\n\nRecent events:\n%@", header, tail];
}

#pragma mark - FOA sandbox environment

+ (Class)foaSandboxClass {
    return objc_getClass("_TtC26FOAPlatformSandboxOverride18FOASandboxOverride");
}

+ (NSString *)currentFOASandboxOverride {
    Class cls = [self foaSandboxClass];
    SEL sel = NSSelectorFromString(@"currentOverride");
    Method method = cls ? class_getClassMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "@16@0:8")) return @"FOASandboxOverride.currentOverride unavailable or ABI changed";
    id value = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
    return value ? [NSString stringWithFormat:@"Current FOA sandbox override:\n%@", value] : @"No FOA sandbox override is active.";
}

+ (BOOL)isValidHostname:(NSString *)hostname {
    if (!hostname.length || hostname.length > 253) return NO;
    if ([hostname containsString:@"://"] || [hostname containsString:@"/"] || [hostname containsString:@" "]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [hostname rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

+ (NSString *)setFOASandboxHostname:(NSString *)hostname {
    NSString *trimmed = [hostname stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![self isValidHostname:trimmed]) return @"Invalid hostname. Enter only a DNS hostname, without scheme, path or spaces.";

    Class cls = [self foaSandboxClass];
    SEL sel = NSSelectorFromString(@"setSandboxOverrideWithHostname:reason:");
    Method method = cls ? class_getClassMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "v32@0:8@16@24")) return @"FOASandboxOverride setter unavailable or ABI changed";

    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cls, sel, trimmed, @"RyukGram Dev menu");
        DGRecord([NSString stringWithFormat:@"FOA sandbox hostname set to %@", trimmed]);
        return [NSString stringWithFormat:@"FOA sandbox override set to %@. Restart Instagram so every client subsystem adopts the new environment. Authentication and server authorization are unchanged.", trimmed];
    } @catch (id exception) {
        return [NSString stringWithFormat:@"FOA sandbox setter threw: %@", exception];
    }
}

+ (NSString *)resetFOASandboxOverride {
    Class cls = [self foaSandboxClass];
    SEL sel = NSSelectorFromString(@"setSandboxOverrideWithHostname:reason:");
    Method method = cls ? class_getClassMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "v32@0:8@16@24")) return @"FOASandboxOverride setter unavailable or ABI changed";

    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cls, sel, nil, @"RyukGram reset");
        DGRecord(@"FOA sandbox override reset");
        return @"FOA sandbox override cleared. Restart Instagram.";
    } @catch (id exception) {
        return [NSString stringWithFormat:@"FOA sandbox reset threw: %@", exception];
    }
}

#pragma mark - GraphQL Debug provider

+ (Class)graphQLDebugProviderClass {
    return objc_getClass("_TtC38IGDirectDeidentifiedRequestProviderKit35IGDirectDeidentifiedRequestProvider");
}

+ (id)graphQLDebugProvider {
    Class cls = [self graphQLDebugProviderClass];
    if (!cls) return nil;
    if (!sDGDebugProvider) sDGDebugProvider = [[cls alloc] init];
    return sDGDebugProvider;
}

static void DGComplete(void (^completion)(NSString *), NSString *result) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(result ?: @""); });
}

+ (NSString *)graphQLDebugCapabilities {
    Class cls = [self graphQLDebugProviderClass];
    if (!cls) return @"IGDirectDeidentifiedRequestProvider is not loaded.";

    NSArray<NSString *> *selectors = @[
        @"getStoredOHAIConfig",
        @"warmupForGraphQLDebugWithCompletionHandler:",
        @"retrieveACSTokenForGraphQLDebugWithCompletionHandler:",
        @"retrieveACSTokenAndOHAIConfigForGraphQLDebugWithCompletionHandler:"
    ];
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, sel);
        NSString *encoding = method ? [NSString stringWithUTF8String:method_getTypeEncoding(method)] : @"no ABI";
        [rows addObject:[NSString stringWithFormat:@"%@ — %@ — %@", name, method ? @"present" : @"absent", encoding]];
    }
    [rows addObject:@"\nCredential actions report only presence, runtime class and errors. Token/config contents are not logged or displayed."];
    return [rows componentsJoinedByString:@"\n"];
}

+ (void)warmupGraphQLDebugWithCompletion:(void (^)(NSString *result))completion {
    Class cls = [self graphQLDebugProviderClass];
    SEL sel = NSSelectorFromString(@"warmupForGraphQLDebugWithCompletionHandler:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "v24@0:8@?16")) {
        DGComplete(completion, @"GraphQL Debug warmup unavailable or ABI changed.");
        return;
    }

    @try {
        id provider = [self graphQLDebugProvider];
        if (!provider) {
            DGComplete(completion, @"GraphQL Debug provider init returned nil.");
            return;
        }
        void (^handler)(void) = ^{
            DGRecord(@"GraphQL Debug provider warmup completed");
            DGComplete(completion, @"GraphQL Debug provider warmup completed.");
        };
        ((void (*)(id, SEL, id))objc_msgSend)(provider, sel, handler);
        DGRecord(@"GraphQL Debug provider warmup started");
    } @catch (id exception) {
        DGComplete(completion, [NSString stringWithFormat:@"GraphQL Debug warmup threw: %@", exception]);
    }
}

+ (void)retrieveGraphQLDebugACSTokenStatusWithCompletion:(void (^)(NSString *result))completion {
    Class cls = [self graphQLDebugProviderClass];
    SEL sel = NSSelectorFromString(@"retrieveACSTokenForGraphQLDebugWithCompletionHandler:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "v24@0:8@?16")) {
        DGComplete(completion, @"ACS token retrieval unavailable or ABI changed.");
        return;
    }

    @try {
        id provider = [self graphQLDebugProvider];
        if (!provider) {
            DGComplete(completion, @"GraphQL Debug provider init returned nil.");
            return;
        }
        void (^handler)(id, id) = ^(id token, id error) {
            NSString *result = [NSString stringWithFormat:
                @"ACS token present: %@\nToken class: %@\nError: %@",
                token ? @"YES" : @"NO", DGClassName(token), error ?: @"none"];
            DGRecord([NSString stringWithFormat:@"GraphQL Debug ACS result token=%d error=%d", token != nil, error != nil]);
            DGComplete(completion, result);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(provider, sel, handler);
        DGRecord(@"GraphQL Debug ACS retrieval started");
    } @catch (id exception) {
        DGComplete(completion, [NSString stringWithFormat:@"ACS retrieval threw: %@", exception]);
    }
}

+ (void)retrieveGraphQLDebugACSAndOHAIStatusWithCompletion:(void (^)(NSString *result))completion {
    Class cls = [self graphQLDebugProviderClass];
    SEL sel = NSSelectorFromString(@"retrieveACSTokenAndOHAIConfigForGraphQLDebugWithCompletionHandler:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!DGTypeMatches(method, "v24@0:8@?16")) {
        DGComplete(completion, @"ACS/OHAI retrieval unavailable or ABI changed.");
        return;
    }

    @try {
        id provider = [self graphQLDebugProvider];
        if (!provider) {
            DGComplete(completion, @"GraphQL Debug provider init returned nil.");
            return;
        }
        void (^handler)(id, id, id) = ^(id token, id config, id error) {
            NSString *result = [NSString stringWithFormat:
                @"ACS token present: %@\nToken class: %@\nOHAI config present: %@\nConfig class: %@\nError: %@",
                token ? @"YES" : @"NO", DGClassName(token),
                config ? @"YES" : @"NO", DGClassName(config), error ?: @"none"];
            DGRecord([NSString stringWithFormat:@"GraphQL Debug ACS/OHAI result token=%d config=%d error=%d",
                      token != nil, config != nil, error != nil]);
            DGComplete(completion, result);
        };
        ((void (*)(id, SEL, id))objc_msgSend)(provider, sel, handler);
        DGRecord(@"GraphQL Debug ACS/OHAI retrieval started");
    } @catch (id exception) {
        DGComplete(completion, [NSString stringWithFormat:@"ACS/OHAI retrieval threw: %@", exception]);
    }
}

@end
