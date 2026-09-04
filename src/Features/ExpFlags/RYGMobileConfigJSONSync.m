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
    // The canonical JSON is a portable RyukGram snapshot only. Runtime authority
    // belongs to FBMobileConfigStartupConfigs and the typed getter-hook store.
    // Never overwrite Instagram's C++-owned mc_overrides.json or name mapping.
    NSError *exportError = nil;
    NSData *overrides = [self ryg_exportOverridesData:&exportError];
    NSString *cachePath = RYGMCJSONSyncCanonicalCachePath();
    if (!overrides.length || !cachePath.length || !RYGMCJSONSyncWriteAndVerify(overrides, cachePath)) return NO;

    [self reapplyOverridesToNativeTable];
    return YES;
}

// RYGMobileConfig.xm already coalesces syncOverridesJSON after a user mutation.
// Own that callback here so every edit updates the durable local snapshot and
// reapplies native StartupConfigs without introducing a competing JSON writer.
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
