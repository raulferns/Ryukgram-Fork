#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeIndex.h"
#import "RYGFastRuntimeBrowserViewController.h"
#import "../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <stdlib.h>

// Runtime Browser fast path
// -------------------------
// The browser must never be a prerequisite for Developer features. Its root
// screen is only an image/class catalogue. Method enumeration is lazy per class
// and selector-wide searching is explicit, asynchronous and cancellable.
//
// This deliberately uses objc_copyClassNamesForImage(), the image-scoped API,
// instead of objc_getClassList() + class_copyMethodList() over the whole process.

static NSString *RYGFastPathCanonical(NSString *path) {
    return path.length ? path.stringByStandardizingPath : @"";
}

static NSArray<NSString *> *RYGFastPathTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens.copy;
}

static BOOL RYGFastPathMatches(NSString *text, NSArray<NSString *> *tokens) {
    if (!tokens.count) return YES;
    NSString *lower = text.lowercaseString ?: @"";
    NSString *compact = [[lower componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    for (NSString *group in tokens) {
        BOOL matched = NO;
        for (NSString *token in [group componentsSeparatedByString:@"|"]) {
            if (!token.length) continue;
            NSString *compactToken = [[token componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
            if ([lower rangeOfString:token].location != NSNotFound ||
                (compactToken.length && [compact rangeOfString:compactToken].location != NSNotFound)) {
                matched = YES;
                break;
            }
        }
        if (!matched) return NO;
    }
    return YES;
}

#pragma mark - O(n) loaded-image catalogue

@implementation RYGRuntimeBrowserEngine (RYGRuntimeFastPath)

+ (NSArray<NSString *> *)ryg_fast_runtimeImagePaths {
    NSString *bundle = RYGFastPathCanonical(NSBundle.mainBundle.bundlePath);
    NSString *executable = RYGFastPathCanonical(NSBundle.mainBundle.executablePath);
    NSString *frameworkPrefix = [[bundle stringByAppendingPathComponent:@"Frameworks"] stringByAppendingString:@"/"];
    NSString *bundlePrefix = [bundle stringByAppendingString:@"/"];

    // Snapshot the dyld count once. Do not recursively call path->header lookup
    // for each image and again from the sort comparator.
    uint32_t count = _dyld_image_count();
    NSMutableOrderedSet<NSString *> *images = [NSMutableOrderedSet orderedSet];
    for (uint32_t index = 0; index < count; index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw || !*raw) continue;
        NSString *path = RYGFastPathCanonical([NSString stringWithUTF8String:raw]);
        if (!path.length) continue;
        BOOL main = [path isEqualToString:executable];
        BOOL framework = [path hasPrefix:frameworkPrefix];
        BOOL bundledDylib = [path hasPrefix:bundlePrefix] && [path.pathExtension.lowercaseString isEqualToString:@"dylib"];
        if (main || framework || bundledDylib) [images addObject:path];
    }
    if (executable.length) [images addObject:executable];

    return [images.array sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        BOOL leftMain = [left isEqualToString:executable];
        BOOL rightMain = [right isEqualToString:executable];
        if (leftMain != rightMain) return leftMain ? NSOrderedAscending : NSOrderedDescending;
        return [left.lastPathComponent localizedCaseInsensitiveCompare:right.lastPathComponent];
    }];
}

+ (NSArray<RYGRuntimeClassRow *> *)ryg_fast_classesForImagePath:(NSString *)imagePath {
    NSString *path = RYGFastPathCanonical(imagePath);
    if (!path.length) return @[];

    unsigned int count = 0;
    const char **rawNames = objc_copyClassNamesForImage(path.fileSystemRepresentation, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; rawNames && index < count; index++) {
        const char *raw = rawNames[index];
        if (!raw || !*raw) continue;
        NSString *name = [NSString stringWithUTF8String:raw];
        if (name.length) [names addObject:name];
    }
    if (rawNames) free(rawNames);

    // Some dyld spellings differ from NSBundle paths. Fall back only when the
    // image-scoped runtime API returned no classes, and still do no method scan.
    if (!names.count) {
        int total = objc_getClassList(NULL, 0);
        if (total > 0 && total < 500000) {
            Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
            int filled = classes ? objc_getClassList(classes, total) : 0;
            for (int index = 0; index < filled; index++) {
                Class cls = classes[index];
                const char *image = cls ? class_getImageName(cls) : NULL;
                if (!image || !*image) continue;
                if (![RYGFastPathCanonical([NSString stringWithUTF8String:image]) isEqualToString:path]) continue;
                const char *raw = class_getName(cls);
                if (!raw || !*raw) continue;
                NSString *name = [NSString stringWithUTF8String:raw];
                if (name.length) [names addObject:name];
            }
            if (classes) free(classes);
        }
    }

    NSArray<NSString *> *ordered = [[NSOrderedSet orderedSetWithArray:names].array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray arrayWithCapacity:ordered.count];
    for (NSString *name in ordered) {
        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = path;
        row.className = name;
        // Counts are intentionally unresolved at root level. They are populated
        // only when that class is opened/searched.
        row.instanceMethodCount = 0;
        row.classMethodCount = 0;
        row.propertyCount = 0;
        [rows addObject:row];
    }
    return rows.copy;
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getClassMethod(self, @selector(runtimeImagePaths));
        Method b = class_getClassMethod(self, @selector(ryg_fast_runtimeImagePaths));
        if (a && b) method_exchangeImplementations(a, b);
        a = class_getClassMethod(self, @selector(classesForImagePath:));
        b = class_getClassMethod(self, @selector(ryg_fast_classesForImagePath:));
        if (a && b) method_exchangeImplementations(a, b);
    });
}

@end

#pragma mark - Class-only index; methods resolved lazily

static dispatch_queue_t RYGFastIndexStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ queue = dispatch_queue_create("com.ryukgram.runtime-index.fast-state", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSMutableDictionary<NSString *, RYGRuntimeImageIndex *> *gRYGFastIndexes;
static const void *kRYGLazyMethodsCacheKey = &kRYGLazyMethodsCacheKey;

@implementation RYGRuntimeIndex (RYGRuntimeFastPath)

+ (void)ryg_fast_requestIndexForImagePath:(NSString *)imagePath completion:(RYGRuntimeIndexCompletion)completion {
    NSString *path = RYGFastPathCanonical(imagePath);
    if (!path.length) {
        RYGRuntimeImageIndex *empty = [RYGRuntimeImageIndex new];
        empty.imagePath = @""; empty.classes = @[]; empty.methodsByClass = @{};
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(empty); });
        return;
    }

    dispatch_async(RYGFastIndexStateQueue(), ^{
        RYGRuntimeImageIndex *cached = gRYGFastIndexes[path];
        if (cached) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(cached); });
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
            NSArray<RYGRuntimeClassRow *> *classes = [RYGRuntimeBrowserEngine classesForImagePath:path] ?: @[];
            RYGRuntimeImageIndex *index = [RYGRuntimeImageIndex new];
            index.imagePath = path;
            index.classes = classes;
            index.methodsByClass = @{};
            index.classesScanned = classes.count;
            index.methodsScanned = 0;
            index.buildDuration = CFAbsoluteTimeGetCurrent() - started;
            dispatch_async(RYGFastIndexStateQueue(), ^{
                if (!gRYGFastIndexes) gRYGFastIndexes = [NSMutableDictionary dictionary];
                gRYGFastIndexes[path] = index;
                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(index); });
            });
        });
    });
}

+ (RYGRuntimeImageIndex *)ryg_fast_cachedIndexForImagePath:(NSString *)imagePath {
    __block RYGRuntimeImageIndex *index = nil;
    NSString *path = RYGFastPathCanonical(imagePath);
    dispatch_sync(RYGFastIndexStateQueue(), ^{ index = gRYGFastIndexes[path]; });
    return index;
}

+ (void)ryg_fast_invalidate {
    dispatch_async(RYGFastIndexStateQueue(), ^{ [gRYGFastIndexes removeAllObjects]; });
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct { SEL oldSel; SEL newSel; } swaps[] = {
            {@selector(requestIndexForImagePath:completion:), @selector(ryg_fast_requestIndexForImagePath:completion:)},
            {@selector(cachedIndexForImagePath:), @selector(ryg_fast_cachedIndexForImagePath:)},
            {@selector(invalidate), @selector(ryg_fast_invalidate)},
        };
        for (NSUInteger i = 0; i < sizeof(swaps)/sizeof(swaps[0]); i++) {
            Method a = class_getClassMethod(self, swaps[i].oldSel);
            Method b = class_getClassMethod(self, swaps[i].newSel);
            if (a && b) method_exchangeImplementations(a, b);
        }
    });
}

@end

@implementation RYGRuntimeImageIndex (RYGRuntimeFastPath)

- (NSArray<RYGRuntimeBoolMethod *> *)ryg_fast_methodsForClassName:(NSString *)className {
    if (!className.length || !self.imagePath.length) return @[];
    NSArray *prebuilt = self.methodsByClass[className];
    if (prebuilt) return prebuilt;

    @synchronized(self) {
        NSMutableDictionary *cache = objc_getAssociatedObject(self, kRYGLazyMethodsCacheKey);
        NSArray *cached = cache[className];
        if (cached) return cached;
    }

    NSArray<RYGRuntimeMemberRow *> *members = [RYGRuntimeBrowserEngine membersForClassName:className imagePath:self.imagePath] ?: @[];
    NSMutableArray<RYGRuntimeBoolMethod *> *methods = [NSMutableArray arrayWithCapacity:members.count];
    for (RYGRuntimeMemberRow *member in members) {
        if (!member.method || !member.hookableBool) continue;
        RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
        row.imagePath = member.imagePath ?: self.imagePath;
        row.className = member.className ?: className;
        row.selectorName = member.name ?: @"";
        row.typeEncoding = member.typeEncoding ?: @"";
        row.classMethod = member.kind == RYGRuntimeMemberClassMethod;
        row.argumentKind = member.argumentKind;
        [methods addObject:row];
    }
    NSArray *snapshot = methods.copy;
    @synchronized(self) {
        NSMutableDictionary *cache = objc_getAssociatedObject(self, kRYGLazyMethodsCacheKey);
        if (!cache) {
            cache = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, kRYGLazyMethodsCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        cache[className] = snapshot;
    }
    return snapshot;
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getInstanceMethod(self, @selector(methodsForClassName:));
        Method b = class_getInstanceMethod(self, @selector(ryg_fast_methodsForClassName:));
        if (a && b) method_exchangeImplementations(a, b);
    });
}

@end

#pragma mark - Non-blocking selector search

static const void *kRYGFastSearchGenerationKey = &kRYGFastSearchGenerationKey;

static NSUInteger RYGFastNextSearchGeneration(id controller) {
    NSNumber *old = objc_getAssociatedObject(controller, kRYGFastSearchGenerationKey);
    NSUInteger next = old.unsignedIntegerValue + 1;
    objc_setAssociatedObject(controller, kRYGFastSearchGenerationKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return next;
}

static BOOL RYGFastSearchStillCurrent(id controller, NSUInteger generation) {
    NSNumber *current = objc_getAssociatedObject(controller, kRYGFastSearchGenerationKey);
    return current.unsignedIntegerValue == generation;
}

static void RYGFastPublishClassMatches(RYGFastRuntimeBrowserViewController *controller,
                                       RYGRuntimeImageIndex *index,
                                       NSSet<NSString *> *matchedNames,
                                       NSUInteger generation,
                                       BOOL finished) {
    if (!controller || !index || !RYGFastSearchStillCurrent(controller, generation)) return;
    NSArray *visible = [index.classes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RYGRuntimeClassRow *row, NSDictionary *bindings) {
        (void)bindings;
        return [matchedNames containsObject:row.className ?: @""];
    }]];
    [controller setValue:visible forKey:@"visibleClasses"];
    UITableView *table = [controller valueForKey:@"tableView"];
    UILabel *empty = [controller valueForKey:@"emptyLabel"];
    if (visible.count) table.backgroundView = nil;
    else {
        empty.text = finished ? @"No ABI-validated BOOL method matched this loaded image." : @"Searching selectors in this image…";
        table.backgroundView = empty;
    }
    [table reloadData];
}

@implementation RYGFastRuntimeBrowserViewController (RYGRuntimeFastPath)

- (void)ryg_fast_applyFilter {
    UISegmentedControl *mode = [self valueForKey:@"modeControl"];
    if (mode.selectedSegmentIndex != 0) {
        // After exchange this selector invokes the original implementation.
        [self ryg_fast_applyFilter];
        return;
    }

    UISearchController *search = [self valueForKey:@"searchController"];
    RYGRuntimeImageIndex *index = [self valueForKey:@"index"];
    UITableView *table = [self valueForKey:@"tableView"];
    UILabel *empty = [self valueForKey:@"emptyLabel"];
    NSArray<RYGRuntimeClassRow *> *classes = index.classes ?: @[];
    NSArray<NSString *> *tokens = RYGFastPathTokens(search.searchBar.text ?: @"");
    NSUInteger generation = RYGFastNextSearchGeneration(self);

    if (!tokens.count) {
        [self setValue:classes forKey:@"visibleClasses"];
        empty.text = @"No Objective-C classes in this loaded image.";
        table.backgroundView = classes.count ? nil : empty;
        [table reloadData];
        return;
    }

    NSMutableSet<NSString *> *matched = [NSMutableSet set];
    for (RYGRuntimeClassRow *row in classes) {
        if (RYGFastPathMatches(row.className ?: @"", tokens)) [matched addObject:row.className ?: @""];
    }
    RYGFastPublishClassMatches(self, index, matched.copy, generation, tokens.count && classes.count == 0);

    NSString *query = [search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length < 2 || !classes.count) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableSet<NSString *> *methodMatches = matched.mutableCopy;
        NSUInteger scanned = 0;
        for (RYGRuntimeClassRow *row in classes) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !RYGFastSearchStillCurrent(strongSelf, generation)) return;
            if (![methodMatches containsObject:row.className ?: @""]) {
                for (RYGRuntimeBoolMethod *method in [index methodsForClassName:row.className]) {
                    NSString *text = [NSString stringWithFormat:@"%@ %@ %@", row.className ?: @"", method.selectorName ?: @"", method.typeEncoding ?: @""];
                    if (RYGFastPathMatches(text, tokens)) { [methodMatches addObject:row.className ?: @""]; break; }
                }
            }
            scanned++;
            if ((scanned % 64) == 0) {
                NSSet *snapshot = methodMatches.copy;
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) innerSelf = weakSelf;
                    RYGFastPublishClassMatches(innerSelf, index, snapshot, generation, NO);
                });
            }
        }
        NSSet *snapshot = methodMatches.copy;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) innerSelf = weakSelf;
            RYGFastPublishClassMatches(innerSelf, index, snapshot, generation, YES);
        });
    });
}

- (void)ryg_fast_revealAllVisibilityRows {
    NSNumber *allows = [self valueForKey:@"allowsBulkVisibilityOverride"];
    RYGRuntimeImageIndex *index = [self valueForKey:@"index"];
    if (!allows.boolValue || !index) return;
    UISearchController *search = [self valueForKey:@"searchController"];
    NSArray<NSString *> *tokens = RYGFastPathTokens(search.searchBar.text ?: @"");
    NSArray<RYGRuntimeClassRow *> *classes = index.classes ?: @[];
    [RYGUtils showToastForDuration:1.0 title:@"Scanning visibility gates" subtitle:@"Runs off the UI thread; the browser remains usable"];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
        for (RYGRuntimeClassRow *classRow in classes) {
            for (RYGRuntimeBoolMethod *method in [index methodsForClassName:classRow.className]) {
                NSString *text = [NSString stringWithFormat:@"%@ %@ %@", method.className ?: @"", method.selectorName ?: @"", method.typeEncoding ?: @""];
                if (!RYGFastPathMatches(text, tokens)) continue;
                NSString *normalized = [[[method.selectorName lowercaseString]
                    componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                    componentsJoinedByString:@""];
                NSNumber *desired = nil;
                if ([normalized hasPrefix:@"ishidden"] || [normalized hasPrefix:@"shouldhide"] || [normalized hasPrefix:@"hide"]) desired = @NO;
                else if ([normalized hasPrefix:@"shouldshow"] || [normalized hasPrefix:@"canshow"] ||
                         [normalized hasPrefix:@"isvisible"] || [normalized hasPrefix:@"isavailable"] ||
                         [normalized hasPrefix:@"shoulddisplay"]) desired = @YES;
                if (desired) [targets addObject:@{@"method":method, @"value":desired}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            for (NSDictionary *target in targets) {
                [RYGRuntimeBrowserEngine setOverride:target[@"value"] forMethod:target[@"method"]];
            }
            UITableView *table = [strongSelf valueForKey:@"tableView"];
            [table reloadData];
            [RYGUtils showToastForDuration:1.3 title:@"Settings visibility applied" subtitle:[NSString stringWithFormat:@"%lu ABI-validated gate(s)", (unsigned long)targets.count]];
        });
    });
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getInstanceMethod(self, NSSelectorFromString(@"applyFilter"));
        Method b = class_getInstanceMethod(self, @selector(ryg_fast_applyFilter));
        if (a && b) method_exchangeImplementations(a, b);
        a = class_getInstanceMethod(self, NSSelectorFromString(@"revealAllVisibilityRows"));
        b = class_getInstanceMethod(self, @selector(ryg_fast_revealAllVisibilityRows));
        if (a && b) method_exchangeImplementations(a, b);
    });
}

@end
