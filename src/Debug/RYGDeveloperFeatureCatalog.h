#import <Foundation/Foundation.h>
#import "RYGDeveloperTopicViewController.h"

@class RYGRuntimeBoolMethod;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const RYGDeveloperFeatureCatalogDidUpdateNotification;
FOUNDATION_EXPORT NSString *const RYGDeveloperFeatureCatalogSurfaceUserInfoKey;

/// Lightweight Developer-only feature catalogue.
///
/// It is intentionally independent from the Runtime Browser UI. Starting the
/// catalogue does not enumerate the Objective-C runtime: it only installs a
/// cheap dyld generation marker. Known owner classes are prewarmed on a utility
/// queue and the global class walk is deferred until a Developer domain is
/// explicitly opened.
@interface RYGDeveloperFeatureCatalog : NSObject

+ (instancetype)sharedCatalog;

/// Idempotent. Safe to call when Developer is first opened. No class walk is
/// performed synchronously from this method.
- (void)startIfNeeded;

/// Immutable in-memory snapshot. Never performs discovery synchronously.
- (NSArray<RYGRuntimeBoolMethod *> *)snapshotForSurface:(RYGDeveloperRuntimeSurface)surface;

/// Refreshes on the private utility queue. When discoverAdditionalClasses is
/// NO, only a very small set of known owners is checked with objc_lookUpClass.
/// When YES, a scoped loaded-class walk is allowed for this one Developer
/// domain so new owner classes can be discovered without opening Runtime
/// Browser.
- (void)requestRefreshForSurface:(RYGDeveloperRuntimeSurface)surface
        discoverAdditionalClasses:(BOOL)discoverAdditionalClasses;

- (BOOL)isRefreshingSurface:(RYGDeveloperRuntimeSurface)surface;

@end

NS_ASSUME_NONNULL_END
