#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeValueStore.h"
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

/*
 * WATweaks-style live runtime inventory.
 *
 * The old RyukGram engine started from _dyld_image_count(), then tried to map
 * the selected dyld path back to Objective-C classes and finally required each
 * method IMP to resolve to that same image. On Instagram this is too strict:
 * classes/categories can be registered from a different image path spelling
 * and category IMPs can live outside the image that owns the class. The result
 * on-device was a loaded FBSharedFramework surface with zero getters.
 *
 * WATweaks solves this in the opposite direction: enumerate the live Objective-C
 * runtime first, take class_getImageName() as the image authority, and build the
 * image surfaces from classes that actually expose supported no-argument typed
 * getters. This file ports that model without changing the public engine API.
 */

static NSString *RYGWATStandardPath(NSString *path) {
    return path.length ? path.stringByStandardizingPath : @"";
}

static BOOL RYGWATPathsEqual(NSString *left, NSString *right) {
    if (!left.length || !right.length) return NO;
    if ([RYGWATStandardPath(left) isEqualToString:RYGWATStandardPath(right)]) return YES;
    NSString *a = left.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *b = right.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    return a.length && b.length && [a isEqualToString:b];
}

static BOOL RYGWATAppOwnedImage(NSString *path) {
    if (!path.length) return NO;
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath ?: @"";
    NSString *standard = path.stringByStandardizingPath;
    if (bundle.length && ([standard isEqualToString:bundle] || [standard hasPrefix:[bundle stringByAppendingString:@"/"]])) return YES;
    return [standard rangeOfString:@"/Instagram.app/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *RYGWATGetterType(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    SEL selector = method_getName(method);
    NSString *name = selector ? NSStringFromSelector(selector) : @"";
    if (!name.length || [name containsString:@":"] || !RYGRuntimeValueSelectorIsSafeGetter(name)) return nil;
    if ([RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:name]) return nil;
    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    NSString *type = RYGRuntimeValueNormalizedType([NSString stringWithUTF8String:raw]);
    return RYGRuntimeValueTypeIsSupported(type) ? type : nil;
}

static void RYGWATCountsForClass(Class cls, NSUInteger *instanceCount, NSUInteger *classCount) {
    NSUInteger counts[2] = {0, 0};
    for (NSUInteger pass = 0; pass < 2; pass++) {
        Class owner = pass ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = owner ? class_copyMethodList(owner, &count) : NULL;
        for (unsigned int i = 0; methods && i < count; i++) {
            if (RYGWATGetterType(methods[i]).length) counts[pass]++;
        }
        if (methods) free(methods);
    }
    if (instanceCount) *instanceCount = counts[0];
    if (classCount) *classCount = counts[1];
}

static NSArray<Class> *RYGWATLiveAppClasses(void) {
    int total = objc_getClassList(NULL, 0);
    if (total <= 0 || total > 500000) return @[];
    Class __unsafe_unretained *buffer = (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
    if (!buffer) return @[];
    int filled = objc_getClassList(buffer, total);
    NSMutableArray *classes = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, filled)];
    for (int i = 0; i < filled; i++) {
        Class cls = buffer[i];
        const char *rawPath = cls ? class_getImageName(cls) : NULL;
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
        if (!RYGWATAppOwnedImage(path)) continue;
        NSUInteger instanceCount = 0, classCount = 0;
        RYGWATCountsForClass(cls, &instanceCount, &classCount);
        if (instanceCount || classCount) [classes addObject:cls];
    }
    free(buffer);
    return classes.copy;
}

static BOOL RYGWATClassBelongsToImage(Class cls, NSString *imagePath) {
    const char *raw = cls ? class_getImageName(cls) : NULL;
    NSString *path = raw ? [NSString stringWithUTF8String:raw] : @"";
    return RYGWATPathsEqual(path, imagePath);
}

@interface RYGRuntimeBrowserEngine (RYGWATInventory)
+ (NSArray<NSString *> *)ryg_wat_runtimeImagePaths;
+ (NSArray<RYGRuntimeClassRow *> *)ryg_wat_classesForImagePath:(NSString *)imagePath;
+ (NSArray<RYGRuntimeMemberRow *> *)ryg_wat_membersForClassName:(NSString *)className imagePath:(NSString *)imagePath;
@end

@implementation RYGRuntimeBrowserEngine (RYGWATInventory)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class meta = object_getClass(self);
        NSArray<NSArray<NSString *> *> *pairs = @[
            @[@"runtimeImagePaths", @"ryg_wat_runtimeImagePaths"],
            @[@"classesForImagePath:", @"ryg_wat_classesForImagePath:"],
            @[@"membersForClassName:imagePath:", @"ryg_wat_membersForClassName:imagePath:"],
        ];
        for (NSArray<NSString *> *pair in pairs) {
            Method original = class_getInstanceMethod(meta, NSSelectorFromString(pair[0]));
            Method replacement = class_getInstanceMethod(meta, NSSelectorFromString(pair[1]));
            if (original && replacement) method_exchangeImplementations(original, replacement);
        }
    });
}

+ (NSArray<NSString *> *)ryg_wat_runtimeImagePaths {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (Class cls in RYGWATLiveAppClasses()) {
        const char *rawPath = class_getImageName(cls);
        NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : @"";
        if (!path.length) continue;
        NSUInteger instanceCount = 0, classCount = 0;
        RYGWATCountsForClass(cls, &instanceCount, &classCount);
        counts[path] = @([counts[path] unsignedIntegerValue] + instanceCount + classCount);
    }
    NSString *exec = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    return [counts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        BOOL leftExec = RYGWATPathsEqual(left, exec);
        BOOL rightExec = RYGWATPathsEqual(right, exec);
        if (leftExec != rightExec) return leftExec ? NSOrderedAscending : NSOrderedDescending;
        BOOL leftFB = [left.lastPathComponent.lowercaseString containsString:@"fbsharedframework"];
        BOOL rightFB = [right.lastPathComponent.lowercaseString containsString:@"fbsharedframework"];
        if (leftFB != rightFB) return leftFB ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger lc = [counts[left] unsignedIntegerValue], rc = [counts[right] unsignedIntegerValue];
        if (lc != rc) return lc > rc ? NSOrderedAscending : NSOrderedDescending;
        return [left.lastPathComponent localizedCaseInsensitiveCompare:right.lastPathComponent];
    }];
}

+ (NSArray<RYGRuntimeClassRow *> *)ryg_wat_classesForImagePath:(NSString *)imagePath {
    if (!imagePath.length) return @[];
    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray array];
    for (Class cls in RYGWATLiveAppClasses()) {
        if (!RYGWATClassBelongsToImage(cls, imagePath)) continue;
        NSUInteger instanceCount = 0, classCount = 0;
        RYGWATCountsForClass(cls, &instanceCount, &classCount);
        if (!instanceCount && !classCount) continue;
        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = imagePath;
        row.className = NSStringFromClass(cls) ?: @"";
        row.instanceMethodCount = instanceCount;
        row.classMethodCount = classCount;
        row.propertyCount = 0;
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeClassRow *left, RYGRuntimeClassRow *right) {
        NSUInteger lc = left.instanceMethodCount + left.classMethodCount;
        NSUInteger rc = right.instanceMethodCount + right.classMethodCount;
        if (lc != rc) return lc > rc ? NSOrderedAscending : NSOrderedDescending;
        return [left.className localizedCaseInsensitiveCompare:right.className];
    }];
    return rows.copy;
}

+ (NSArray<RYGRuntimeMemberRow *> *)ryg_wat_membersForClassName:(NSString *)className imagePath:(NSString *)imagePath {
    Class cls = className.length ? NSClassFromString(className) : Nil;
    if (!cls || !imagePath.length || !RYGWATClassBelongsToImage(cls, imagePath)) return @[];
    NSMutableArray<RYGRuntimeMemberRow *> *rows = [NSMutableArray array];
    for (NSUInteger pass = 0; pass < 2; pass++) {
        BOOL classMember = pass == 1;
        Class owner = classMember ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = owner ? class_copyMethodList(owner, &count) : NULL;
        for (unsigned int i = 0; methods && i < count; i++) {
            Method method = methods[i];
            NSString *type = RYGWATGetterType(method);
            if (!type.length) continue;
            SEL selector = method_getName(method);
            RYGRuntimeMemberRow *row = [RYGRuntimeMemberRow new];
            row.imagePath = imagePath;
            row.className = className;
            row.name = selector ? NSStringFromSelector(selector) : @"";
            row.kind = classMember ? RYGRuntimeMemberClassMethod : RYGRuntimeMemberInstanceMethod;
            const char *encoding = method_getTypeEncoding(method);
            row.typeEncoding = encoding ? [NSString stringWithUTF8String:encoding] : @"";
            row.valueTypeCode = type;
            row.hookableValue = YES;
            row.hookableBool = RYGRuntimeValueTypeIsBoolean(type);
            row.argumentKind = RYGRuntimeArgumentNone;
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

@end
