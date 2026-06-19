// SCICSymbolStub.h
// ABI-aware FBShared/Instagram C-symbol runtime hook engine.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCICSymbolStub : NSObject

+ (BOOL)isBoolLikeSymbol:(NSString *)name;
+ (BOOL)isHookableSymbol:(NSString *)name;       // validated ABI/profile, observe safe
+ (BOOL)isForceableSymbol:(NSString *)name;      // BOOL forceable
+ (BOOL)isTypedForceableSymbol:(NSString *)name; // int64/double/string forceable
+ (nullable NSString *)returnKindForSymbol:(NSString *)name; // bool/int64/double/string/action/data/unknown
+ (nullable NSString *)blacklistReasonForSymbol:(NSString *)name;
+ (nullable NSString *)notHookableReasonForSymbol:(NSString *)name;
+ (nullable NSString *)notForceableReasonForSymbol:(NSString *)name;

+ (BOOL)observeForSymbol:(NSString *)name;
+ (BOOL)setObserve:(BOOL)value forSymbol:(NSString *)name;
+ (NSArray<NSString *> *)observedSymbols;

+ (nullable NSNumber *)forceForSymbol:(NSString *)name;
+ (BOOL)setForce:(nullable NSNumber *)value forSymbol:(NSString *)name;
+ (NSArray<NSString *> *)forcedSymbols;

+ (nullable NSDictionary<NSString *, id> *)typedForceForSymbol:(NSString *)name;
+ (BOOL)setTypedForceValue:(nullable id)value returnKind:(NSString *)returnKind forSymbol:(NSString *)name;
+ (NSArray<NSString *> *)typedForcedSymbols;

+ (BOOL)hookInstalledForSymbol:(NSString *)name;
+ (NSUInteger)callCountForSymbol:(NSString *)name;
+ (nullable NSNumber *)observedValueForSymbol:(NSString *)name;
+ (nullable id)observedTypedValueForSymbol:(NSString *)name;

+ (BOOL)installStubForSymbol:(NSString *)name;
+ (void)reinstallPersistedStubs;
+ (void)refreshCacheFromDefaults;

+ (BOOL)isParamDescriptorSymbol:(NSString *)name;
+ (nullable NSNumber *)forceForParamDescriptorSymbol:(NSString *)name;
+ (BOOL)setParamDescriptorForce:(nullable NSNumber *)value forSymbol:(NSString *)name;
+ (NSArray<NSString *> *)forcedParamDescriptorSymbols;
+ (BOOL)observeForParamDescriptorSymbol:(NSString *)name;
+ (BOOL)setParamDescriptorObserve:(BOOL)value forSymbol:(NSString *)name;
+ (NSUInteger)paramDescriptorCallCountForSymbol:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
