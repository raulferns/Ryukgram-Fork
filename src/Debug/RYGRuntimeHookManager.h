#import <Foundation/Foundation.h>

@class RYGRuntimeBoolMethod;

NS_ASSUME_NONNULL_BEGIN

/// Single owner for Runtime Browser method overrides.
/// Discovery belongs to the browser; this manager only installs/replays exact
/// {class, selector, meta, ABI} identities and keeps the getter hot path in RAM.
@interface RYGRuntimeHookManager : NSObject
+ (BOOL)observeMethod:(RYGRuntimeBoolMethod *)method;
+ (nullable NSNumber *)observedNativeValueForKey:(NSString *)overrideKey;
+ (nullable NSNumber *)overrideForKey:(NSString *)overrideKey;

/// User-selected override. Persisted with an exact identity, subject to the
/// bounded persistent-spec limit used to protect application launch time.
+ (BOOL)setOverride:(nullable NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method;

/// Temporary bulk override. Installs the same exact ABI-safe hook but never adds
/// a startup replay record. Used by Reveal All so one action cannot create
/// thousands of launch-time hooks.
+ (BOOL)setSessionOverride:(nullable NSNumber *)value forMethod:(RYGRuntimeBoolMethod *)method;

+ (void)restorePersistedOverrides;
+ (NSUInteger)persistedOverrideCount;
@end

NS_ASSUME_NONNULL_END
