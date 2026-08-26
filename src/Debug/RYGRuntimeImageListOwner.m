#import "RYGRuntimeBrowserEngine.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// Browser entry must be cheap.  The previous runtimeImagePaths implementation
// compared each dyld image by rescanning the full dyld list (and repeated that
// inside sort), making viewDidLoad effectively O(N^2+) before the first frame.
// This owner does one dyld pass and only sorts the already-selected app images.

@implementation RYGRuntimeBrowserEngine (RYGRuntimeImageListOwner)

+ (NSArray<NSString *> *)ryg_linearRuntimeImagePaths {
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *executable = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    NSString *frameworkPrefix = [[[bundle stringByAppendingPathComponent:@"Frameworks"] stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *bundlePrefix = [bundle stringByAppendingString:@"/"];

    NSString *mainImage = nil;
    NSMutableOrderedSet<NSString *> *others = [NSMutableOrderedSet orderedSet];
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw || !*raw) continue;
        NSString *path = [[NSString stringWithUTF8String:raw] stringByStandardizingPath];
        if (!path.length) continue;
        if ([path isEqualToString:executable]) {
            mainImage = path;
            continue;
        }
        BOOL framework = [path hasPrefix:frameworkPrefix];
        BOOL bundledDylib = [path hasPrefix:bundlePrefix] && [path.pathExtension.lowercaseString isEqualToString:@"dylib"];
        if (framework || bundledDylib) [others addObject:path];
    }

    NSArray<NSString *> *sorted = [others.array sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSComparisonResult name = [left.lastPathComponent localizedCaseInsensitiveCompare:right.lastPathComponent];
        return name == NSOrderedSame ? [left compare:right] : name;
    }];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:sorted.count + (mainImage.length ? 1 : 0)];
    if (mainImage.length) [result addObject:mainImage];
    [result addObjectsFromArray:sorted];
    return result.copy;
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getClassMethod(self, @selector(runtimeImagePaths));
        Method replacement = class_getClassMethod(self, @selector(ryg_linearRuntimeImagePaths));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

@end
