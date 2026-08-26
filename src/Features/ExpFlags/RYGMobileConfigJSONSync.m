#import "RYGMobileConfigJSONIO.h"
#import "RYGMobileConfigNameMappingStore.h"
#import <objc/runtime.h>

static NSString *RYGMCJSONSyncCanonicalCachePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    NSString *directory = [support stringByAppendingPathComponent:@"RyukGram"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"mc_overrides_canonical.json"];
}

static BOOL RYGMCJSONSyncWriteAndVerify(NSData *data, NSString *path) {
    if (!data.length || !path.length) return NO;
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) return NO;
    NSData *roundTrip = [NSData dataWithContentsOfFile:path options:0 error:&error];
    return roundTrip.length && [roundTrip isEqualToData:data];
}

@implementation RYGMobileConfig (RYGPersistedJSONSync)

- (BOOL)ryg_syncPersistedJSONToNativeDataDirectory {
    // Build the canonical document first and persist it locally. The App Group
    // may not be resolvable on the first call, but a valid override document must
    // never disappear just because Instagram has not exposed its native path yet.
    NSError *exportError = nil;
    NSData *overrides = [self ryg_exportOverridesData:&exportError];
    NSString *cachePath = RYGMCJSONSyncCanonicalCachePath();
    if (!overrides.length || !cachePath.length || !RYGMCJSONSyncWriteAndVerify(overrides, cachePath)) return NO;

    NSString *directory = [self ryg_nativeDataDirectory];
    if (!directory.length) return NO;

    BOOL success = YES;
    NSData *mapping = RYGMCLoadCachedNameMappingData();
    NSString *mappingPath = [self ryg_nativeNameMappingPath];
    if (mapping.length && mappingPath.length && !RYGMCJSONSyncWriteAndVerify(mapping, mappingPath)) success = NO;

    NSString *overridesPath = [self ryg_nativeOverridesJSONPath];
    if (!overridesPath.length || !RYGMCJSONSyncWriteAndVerify(overrides, overridesPath)) success = NO;
    return success;
}

// RYGMobileConfig.xm already coalesces syncOverridesJSON after a user mutation.
// Own that callback here so every edit updates BOTH the durable local canonical
// document and the exact native App Group file; the old implementation wrote
// only the latter and silently did nothing when its path was nil.
- (void)ryg_ownedSyncOverridesJSON {
    (void)[self ryg_syncPersistedJSONToNativeDataDirectory];
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"syncOverridesJSON"));
        Method replacement = class_getInstanceMethod(self, @selector(ryg_ownedSyncOverridesJSON));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

@end
