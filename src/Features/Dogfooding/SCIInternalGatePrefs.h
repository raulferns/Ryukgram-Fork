#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIInternalGatePrefs : NSObject
+ (BOOL)boolForKey:(NSString *)key;
+ (BOOL)objCGateEnabledForKey:(NSString *)key;
+ (BOOL)mobileConfigBoolGateEnabledForKey:(NSString *)key;
+ (BOOL)individualGateEnabledForKey:(NSString *)key;
+ (NSDictionary *)mobileConfigCustomOverrides;
+ (void)installCrashGuardIfNeeded;
+ (NSArray<NSString *> *)allGateKeys;
+ (NSArray<NSString *> *)crashDisabledKeys;
+ (void)resetCrashGuard;
+ (void)resetCrashGuardAndRestoreKeys;
@end

NS_ASSUME_NONNULL_END
