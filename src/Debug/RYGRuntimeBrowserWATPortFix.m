#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeValueStore.h"
#import "RYGPortedRuntimeBrowserViewController.h"

// WATweaks-style runtime bridge for RyukGram.
//
// The selected Mach-O image owns the class inventory.  Getter IMPs are not
// required to point back into that same image: categories, merged ObjC method
// lists and compiler/runtime thunks can legitimately place an implementation
// elsewhere.  The old RyukGram scanner imposed that extra restriction and
// could therefore produce an empty FBSharedFramework surface even though the
// framework had many loaded classes/getters.

static NSString *RYGWATCanonicalImagePath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved : standard;
}

static BOOL RYGWATImagePathsMatch(NSString *requested, NSString *actual) {
    if (!requested.length || !actual.length) return NO;
    NSString *lhs = RYGWATCanonicalImagePath(requested);
    NSString *rhs = RYGWATCanonicalImagePath(actual);
    if ([lhs isEqualToString:rhs]) return YES;

    // dyld and class_getImageName can expose equivalent app-container paths
    // through different symlink spellings.  Basename fallback is deliberately
    // narrow and only exists to avoid a false-empty surface in that case.
    NSString *leftName = lhs.lastPathComponent;
    NSString *rightName = rhs.lastPathComponent;
    return leftName.length && [leftName isEqualToString:rightName];
}

static BOOL RYGWATMethodIsTypedGetter(Method method, NSString **normalizedTypeOut) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    SEL selector = method_getName(method);
    NSString *selectorName = selector ? NSStringFromSelector(selector) : @"";
    if (!RYGRuntimeValueSelectorIsSafeGetter(selectorName)) return NO;
    if ([RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:selectorName]) return NO;

    char *returnType = method_copyReturnType(method);
    NSString *rawType = returnType ? [NSString stringWithUTF8String:returnType] : @"";
    if (returnType) free(returnType);
    NSString *normalized = RYGRuntimeValueNormalizedType(rawType ?: @"");
    if (!RYGRuntimeValueTypeIsSupported(normalized)) return NO;

    if (normalizedTypeOut) *normalizedTypeOut = normalized;
    return YES;
}

static NSArray<RYGRuntimeMemberRow *> *RYGWATMembersForRuntimeClass(Class cls, NSString *imagePath) {
    if (!cls) return @[];
    NSString *className = NSStringFromClass(cls) ?: @"";
    if (!className.length) return @[];

    NSMutableArray<RYGRuntimeMemberRow *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    Class containers[2] = { cls, object_getClass(cls) };
    RYGRuntimeMemberKind kinds[2] = { RYGRuntimeMemberInstanceMethod, RYGRuntimeMemberClassMethod };

    for (NSUInteger pass = 0; pass < 2; pass++) {
        Class container = containers[pass];
        if (!container) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(container, &methodCount);
        for (unsigned int idx = 0; idx < methodCount; idx++) {
            Method method = methods[idx];
            NSString *normalized = nil;
            if (!RYGWATMethodIsTypedGetter(method, &normalized)) continue;

            NSString *selectorName = NSStringFromSelector(method_getName(method)) ?: @"";
            NSString *identity = [NSString stringWithFormat:@"%lu|%@", (unsigned long)pass, selectorName];
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];

            const char *encoding = method_getTypeEncoding(method);
            RYGRuntimeMemberRow *row = [RYGRuntimeMemberRow new];
            row.imagePath = imagePath ?: @"";
            row.className = className;
            row.name = selectorName;
            row.typeEncoding = encoding ? [NSString stringWithUTF8String:encoding] : @"";
            row.kind = kinds[pass];
            row.valueTypeCode = normalized ?: @"";
            row.hookableValue = YES;
            row.hookableBool = RYGRuntimeValueTypeIsBoolean(normalized ?: @"");
            row.argumentKind = RYGRuntimeArgumentNone;
            [rows addObject:row];
        }
        if (methods) free(methods);
    }

    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeMemberRow *lhs, RYGRuntimeMemberRow *rhs) {
        NSComparisonResult byName = [lhs.name localizedCaseInsensitiveCompare:rhs.name];
        if (byName != NSOrderedSame) return byName;
        if (lhs.kind < rhs.kind) return NSOrderedAscending;
        if (lhs.kind > rhs.kind) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return rows;
}

static NSArray<RYGRuntimeClassRow *> *RYGWATClassesForImage(id self, SEL _cmd, NSString *imagePath) {
    (void)self; (void)_cmd;
    if (![imagePath isKindOfClass:NSString.class] || imagePath.length == 0) return @[];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return @[];
    count = objc_getClassList(classes, count);

    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray array];
    for (int idx = 0; idx < count; idx++) {
        Class cls = classes[idx];
        if (!cls) continue;
        const char *imageCString = class_getImageName(cls);
        NSString *actualImage = imageCString ? [NSString stringWithUTF8String:imageCString] : @"";
        if (!RYGWATImagePathsMatch(imagePath, actualImage)) continue;

        NSArray<RYGRuntimeMemberRow *> *members = RYGWATMembersForRuntimeClass(cls, imagePath);
        if (members.count == 0) continue;

        NSUInteger instanceCount = 0;
        NSUInteger classCount = 0;
        for (RYGRuntimeMemberRow *member in members) {
            if (member.kind == RYGRuntimeMemberClassMethod) classCount++;
            else instanceCount++;
        }

        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = imagePath;
        row.className = NSStringFromClass(cls) ?: @"";
        row.instanceMethodCount = instanceCount;
        row.classMethodCount = classCount;
        row.propertyCount = 0;
        [rows addObject:row];
    }
    free(classes);

    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeClassRow *lhs, RYGRuntimeClassRow *rhs) {
        return [lhs.className localizedCaseInsensitiveCompare:rhs.className];
    }];
    return rows;
}

static NSArray<RYGRuntimeMemberRow *> *RYGWATMembersForClass(id self, SEL _cmd, NSString *className, NSString *imagePath) {
    (void)self; (void)_cmd;
    if (![className isKindOfClass:NSString.class] || !className.length || !imagePath.length) return @[];
    Class cls = NSClassFromString(className);
    if (!cls) return @[];

    const char *imageCString = class_getImageName(cls);
    NSString *actualImage = imageCString ? [NSString stringWithUTF8String:imageCString] : @"";
    if (!RYGWATImagePathsMatch(imagePath, actualImage)) return @[];
    return RYGWATMembersForRuntimeClass(cls, imagePath);
}

static void RYGWATReinstallEngineOverrides(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    RYGRuntimeValueReinstallPersistedHooks();
}

static void RYGWATInstallEngineBridge(void) {
    Class engine = RYGRuntimeBrowserEngine.class;
    if (!engine) return;

    Method classesMethod = class_getClassMethod(engine, @selector(classesForImagePath:));
    Method membersMethod = class_getClassMethod(engine, @selector(membersForClassName:imagePath:));
    Method reinstallMethod = class_getClassMethod(engine, @selector(reinstallPersistedOverrides));

    if (classesMethod) method_setImplementation(classesMethod, (IMP)RYGWATClassesForImage);
    if (membersMethod) method_setImplementation(membersMethod, (IMP)RYGWATMembersForClass);
    if (reinstallMethod) method_setImplementation(reinstallMethod, (IMP)RYGWATReinstallEngineOverrides);
    [RYGRuntimeBrowserEngine invalidateRuntimeCaches];
}

#pragma mark - Adaptive navigation chrome

static void RYGWATUsePlainNavigationTitle(UIViewController *controller, NSString *fallbackTitle) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    controller.navigationItem.titleView = nil;
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (fallbackTitle.length) controller.title = fallbackTitle;
}

static void (*RYGWATRootViewDidLoadOriginal)(id, SEL);
static void RYGWATRootViewDidLoad(id self, SEL _cmd) {
    if (RYGWATRootViewDidLoadOriginal) RYGWATRootViewDidLoadOriginal(self, _cmd);
    RYGWATUsePlainNavigationTitle((UIViewController *)self, @"Runtime Browser");
}

static void (*RYGWATImageApplyFilterOriginal)(id, SEL);
static void RYGWATImageApplyFilter(id self, SEL _cmd) {
    if (RYGWATImageApplyFilterOriginal) RYGWATImageApplyFilterOriginal(self, _cmd);
    NSString *imagePath = nil;
    @try { imagePath = [self valueForKey:@"imagePath"]; } @catch (__unused NSException *exception) { }
    NSString *shortName = imagePath.length ? [RYGRuntimeBrowserEngine shortNameForImagePath:imagePath] : @"Runtime Image";
    RYGWATUsePlainNavigationTitle((UIViewController *)self, shortName);
}

static void (*RYGWATObjectViewDidLoadOriginal)(id, SEL);
static void RYGWATObjectViewDidLoad(id self, SEL _cmd) {
    if (RYGWATObjectViewDidLoadOriginal) RYGWATObjectViewDidLoadOriginal(self, _cmd);
    UIViewController *controller = (UIViewController *)self;
    RYGWATUsePlainNavigationTitle(controller, controller.title);
}

static void RYGWATSwizzleInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    if (!cls || !selector || !replacement) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    if (originalOut) *originalOut = original;
    method_setImplementation(method, replacement);
}

static void RYGWATInstallAdaptiveChrome(void) {
    RYGWATSwizzleInstanceMethod(NSClassFromString(@"RYGPortedRuntimeBrowserViewController"),
                                @selector(viewDidLoad),
                                (IMP)RYGWATRootViewDidLoad,
                                (IMP *)&RYGWATRootViewDidLoadOriginal);
    RYGWATSwizzleInstanceMethod(NSClassFromString(@"RYGPortedRuntimeImageViewController"),
                                NSSelectorFromString(@"applyFilter"),
                                (IMP)RYGWATImageApplyFilter,
                                (IMP *)&RYGWATImageApplyFilterOriginal);
    RYGWATSwizzleInstanceMethod(NSClassFromString(@"RYGPortObjectEditorViewController"),
                                @selector(viewDidLoad),
                                (IMP)RYGWATObjectViewDidLoad,
                                (IMP *)&RYGWATObjectViewDidLoadOriginal);
}

#pragma mark - Retire the legacy runtime entry point

static const void *kRYGWATLegacyForwardedKey = &kRYGWATLegacyForwardedKey;
static void (*RYGWATLegacyViewDidAppearOriginal)(id, SEL, BOOL);
static void RYGWATLegacyViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (RYGWATLegacyViewDidAppearOriginal) RYGWATLegacyViewDidAppearOriginal(self, _cmd, animated);
    if (objc_getAssociatedObject(self, kRYGWATLegacyForwardedKey)) return;
    objc_setAssociatedObject(self, kRYGWATLegacyForwardedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationController *navigationController = [(UIViewController *)self navigationController];
    if (!navigationController) return;
    NSMutableArray<UIViewController *> *stack = [navigationController.viewControllers mutableCopy];
    NSUInteger index = [stack indexOfObjectIdenticalTo:self];
    if (index == NSNotFound) return;

    RYGPortedRuntimeBrowserViewController *replacement = [RYGPortedRuntimeBrowserViewController new];
    stack[index] = replacement;
    [navigationController setViewControllers:stack animated:NO];
}

static void RYGWATInstallLegacyForwarder(void) {
    RYGWATSwizzleInstanceMethod(NSClassFromString(@"RYGFastRuntimeBrowserViewController"),
                                @selector(viewDidAppear:),
                                (IMP)RYGWATLegacyViewDidAppear,
                                (IMP *)&RYGWATLegacyViewDidAppearOriginal);
}

static id gRYGWATDidBecomeActiveObserver;

__attribute__((constructor))
static void RYGInstallWATRuntimePortFix(void) {
    @autoreleasepool {
        RYGWATInstallEngineBridge();

        dispatch_async(dispatch_get_main_queue(), ^{
            RYGWATInstallAdaptiveChrome();
            RYGWATInstallLegacyForwarder();

            // Persist-first/pending-retry semantics from WATweaks: an override
            // survives a failed immediate hook and is retried at startup and
            // whenever the app becomes active again.
            RYGRuntimeValueReinstallPersistedHooks();
            if (!gRYGWATDidBecomeActiveObserver) {
                gRYGWATDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                    queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
                        RYGRuntimeValueReinstallPersistedHooks();
                    }];
            }
        });
    }
}
