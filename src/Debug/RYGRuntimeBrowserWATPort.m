#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeValueStore.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

/*
 * WATweaks dogfood2 runtime-scanner semantics, adapted to Ryukgram.
 *
 * The previous scanner incorrectly required every Method IMP to resolve, via
 * dladdr(), to the same Mach-O selected in the browser. Modern Meta builds use
 * thunks/shared implementations heavily, so a class can be defined by
 * FBSharedFramework while a valid getter's IMP resolves elsewhere. That made
 * whole images appear as "(0)" even though the Objective-C runtime contained
 * thousands of classes/getters.
 *
 * WATweaks instead treats class_getImageName(cls) as ownership and validates
 * the getter ABI independently. This late policy replaces only the two scanner
 * entry points; hook/persistence/readback remain owned by RYGRuntimeValueStore.
 */

static NSString *RYGWATCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved.stringByStandardizingPath : standard;
}

static const struct mach_header *RYGWATHeaderForPath(NSString *path) {
    if (!path.length) return NULL;
    NSString *wanted = RYGWATCanonicalPath(path);
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *loaded = RYGWATCanonicalPath([NSString stringWithUTF8String:raw] ?: @"");
        if ([loaded isEqualToString:wanted]) return _dyld_get_image_header(index);
    }
    return NULL;
}

static BOOL RYGWATImageMatches(NSString *left, NSString *right) {
    if (!left.length || !right.length) return NO;
    NSString *a = RYGWATCanonicalPath(left);
    NSString *b = RYGWATCanonicalPath(right);
    if ([a isEqualToString:b]) return YES;

    const struct mach_header *ah = RYGWATHeaderForPath(a);
    const struct mach_header *bh = RYGWATHeaderForPath(b);
    if (ah && bh && ah == bh) return YES;

    // Some sideload layouts expose the same framework through a different
    // container prefix. A basename fallback is safe only after both paths are
    // known app-bundle images and their final components match exactly.
    NSString *bundle = RYGWATCanonicalPath(NSBundle.mainBundle.bundlePath ?: @"");
    BOOL aOwned = bundle.length && [a hasPrefix:[bundle stringByAppendingString:@"/"]];
    BOOL bOwned = bundle.length && [b hasPrefix:[bundle stringByAppendingString:@"/"]];
    return aOwned && bOwned && a.lastPathComponent.length &&
           [a.lastPathComponent isEqualToString:b.lastPathComponent];
}

static BOOL RYGWATClassBelongsToImage(Class cls, NSString *imagePath) {
    if (!cls || !imagePath.length) return NO;
    const char *raw = class_getImageName(cls);
    if (!raw || !*raw) return NO;
    NSString *owner = [NSString stringWithUTF8String:raw] ?: @"";
    return RYGWATImageMatches(owner, imagePath);
}

static NSString *RYGWATGetterType(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    SEL selector = method_getName(method);
    NSString *name = selector ? NSStringFromSelector(selector) : @"";
    if (!name.length || [name containsString:@":"] ||
        !RYGRuntimeValueSelectorIsSafeGetter(name) ||
        [RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:name]) return nil;

    char raw[64] = {0};
    method_getReturnType(method, raw, sizeof(raw));
    NSString *type = RYGRuntimeValueNormalizedType([NSString stringWithUTF8String:raw] ?: @"");
    return RYGRuntimeValueTypeIsSupported(type) ? type : nil;
}

static void RYGWATCountTypedGetters(Class cls, NSUInteger *instanceCount, NSUInteger *classCount) {
    NSUInteger counts[2] = {0, 0};
    for (NSUInteger pass = 0; pass < 2; pass++) {
        Class owner = pass ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = owner ? class_copyMethodList(owner, &count) : NULL;
        for (unsigned int index = 0; methods && index < count; index++) {
            if (RYGWATGetterType(methods[index]).length) counts[pass]++;
        }
        if (methods) free(methods);
    }
    if (instanceCount) *instanceCount = counts[0];
    if (classCount) *classCount = counts[1];
}

@interface RYGRuntimeBrowserEngine (WATPortScanner)
+ (NSArray<RYGRuntimeClassRow *> *)ryg_wat_classesForImagePath:(NSString *)imagePath;
+ (NSArray<RYGRuntimeMemberRow *> *)ryg_wat_membersForClassName:(NSString *)className imagePath:(NSString *)imagePath;
@end

@implementation RYGRuntimeBrowserEngine (WATPortScanner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class meta = object_getClass((id)self);
        Method originalClasses = class_getInstanceMethod(meta, @selector(classesForImagePath:));
        Method portClasses = class_getInstanceMethod(meta, @selector(ryg_wat_classesForImagePath:));
        if (originalClasses && portClasses) method_exchangeImplementations(originalClasses, portClasses);

        Method originalMembers = class_getInstanceMethod(meta, @selector(membersForClassName:imagePath:));
        Method portMembers = class_getInstanceMethod(meta, @selector(ryg_wat_membersForClassName:imagePath:));
        if (originalMembers && portMembers) method_exchangeImplementations(originalMembers, portMembers);
    });
}

+ (NSArray<RYGRuntimeClassRow *> *)ryg_wat_classesForImagePath:(NSString *)imagePath {
    if (!imagePath.length || !RYGWATHeaderForPath(imagePath)) return @[];

    int total = objc_getClassList(NULL, 0);
    if (total <= 0 || total > 500000) return @[];
    Class __unsafe_unretained *classes =
        (Class __unsafe_unretained *)calloc((size_t)total, sizeof(Class));
    if (!classes) return @[];
    int filled = objc_getClassList(classes, total);

    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray array];
    for (int index = 0; index < filled; index++) {
        Class cls = classes[index];
        if (!cls || !RYGWATClassBelongsToImage(cls, imagePath)) continue;
        const char *rawName = class_getName(cls);
        if (!rawName || !*rawName) continue;

        NSUInteger instanceCount = 0, classCount = 0;
        RYGWATCountTypedGetters(cls, &instanceCount, &classCount);
        if (!instanceCount && !classCount) continue;

        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = imagePath;
        row.className = [NSString stringWithUTF8String:rawName] ?: @"";
        row.instanceMethodCount = instanceCount;
        row.classMethodCount = classCount;
        row.propertyCount = 0;
        if (row.className.length) [rows addObject:row];
    }
    free(classes);

    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeClassRow *left, RYGRuntimeClassRow *right) {
        return [left.className localizedCaseInsensitiveCompare:right.className];
    }];
    return rows.copy;
}

+ (NSArray<RYGRuntimeMemberRow *> *)ryg_wat_membersForClassName:(NSString *)className imagePath:(NSString *)imagePath {
    Class cls = className.length ? objc_lookUpClass(className.UTF8String) : Nil;
    if (!cls || !imagePath.length || !RYGWATClassBelongsToImage(cls, imagePath)) return @[];

    NSMutableArray<RYGRuntimeMemberRow *> *rows = [NSMutableArray array];
    for (NSUInteger pass = 0; pass < 2; pass++) {
        BOOL classMember = pass == 1;
        Class owner = classMember ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = owner ? class_copyMethodList(owner, &count) : NULL;
        for (unsigned int index = 0; methods && index < count; index++) {
            Method method = methods[index];
            NSString *type = RYGWATGetterType(method);
            if (!type.length) continue;
            SEL selector = method_getName(method);
            NSString *name = selector ? NSStringFromSelector(selector) : @"";
            if (!name.length) continue;

            RYGRuntimeMemberRow *row = [RYGRuntimeMemberRow new];
            row.imagePath = imagePath;
            row.className = className;
            row.name = name;
            row.kind = classMember ? RYGRuntimeMemberClassMethod : RYGRuntimeMemberInstanceMethod;
            const char *encoding = method_getTypeEncoding(method);
            row.typeEncoding = encoding ? [NSString stringWithUTF8String:encoding] : @"";
            row.hookableBool = RYGRuntimeValueTypeIsBoolean(type);
            row.hookableValue = YES;
            row.valueTypeCode = type;
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
