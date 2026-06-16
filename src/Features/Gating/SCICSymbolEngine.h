// SCICSymbolEngine.h
//
// Runtime browser for FBSharedFramework C symbols.
//
// Important model:
// - The browser enumerates the whole FBSharedFramework export universe at runtime.
// - Hooking is NOT generic. C ABI cannot be inferred safely from a name.
// - Only symbols with a known safe profile get observe/force controls.
// - Data/key symbols remain visible/searchable, but are not function-hookable.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCICImport : NSObject
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSString *symbolKind;       // function, data, const, string-key, absolute, unknown
@property (nonatomic, copy) NSString *hookProfile;      // none, bool-observe, bool-force
@property (nonatomic, copy) NSString *safetyReason;
@property (nonatomic, assign) BOOL resolvable;
@property (nonatomic, assign) BOOL functionSymbol;
@property (nonatomic, assign) BOOL boolLike;
@property (nonatomic, assign) BOOL hookable;
@property (nonatomic, assign) BOOL forceAllowed;
@property (nonatomic, assign) BOOL forceBlacklisted;
@property (nonatomic, assign) BOOL mobileConfigKeySymbol;
@property (nonatomic, assign) NSUInteger mobileConfigParamCount;
@property (nonatomic, readonly) NSString *overrideKey;
@property (nonatomic, readonly, nullable) NSNumber *override;
@property (nonatomic, readonly) BOOL observing;
@property (nonatomic, readonly) BOOL hookInstalled;
@property (nonatomic, readonly) NSUInteger observedCallCount;
@property (nonatomic, readonly, nullable) NSNumber *observedValue;
@end

@interface SCICSymbolEngine : NSObject

// Runtime FBSharedFramework export universe. Search is evaluated when the UI asks
// for it; no full symbol scan runs in %ctor.
+ (NSArray<SCICImport *> *)searchImports:(nullable NSString *)query limit:(NSUInteger)limit;
+ (NSUInteger)totalImportCount;
+ (NSUInteger)hookableImportCount;

// Force value for a symbol (nil = remove override). Returns NO unless the symbol
// has a known bool-force profile.
+ (BOOL)setForce:(nullable NSNumber *)value forSymbolName:(NSString *)name;
+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name;

// Observe-only hook. Replacement calls original, records hit count + real value,
// and returns original unless a force override exists. Returns NO unless the
// symbol has a known bool-observe/bool-force profile.
+ (BOOL)setObserve:(BOOL)observe forSymbolName:(NSString *)name;
+ (BOOL)isObserving:(NSString *)name;

+ (NSUInteger)callCountForSymbolName:(NSString *)name;
+ (nullable NSNumber *)observedValueForSymbolName:(NSString *)name;
+ (BOOL)hookInstalledForSymbolName:(NSString *)name;
+ (BOOL)isForceBlacklistedSymbolName:(NSString *)name;
+ (BOOL)isBoolLikeSymbolName:(NSString *)name;
+ (BOOL)isHookableSymbolName:(NSString *)name;
+ (BOOL)isForceAllowedSymbolName:(NSString *)name;
+ (BOOL)isMobileConfigKeySymbolName:(NSString *)name;
+ (NSUInteger)mobileConfigParamCountForSymbolName:(NSString *)name;
+ (NSString *)safetyReasonForSymbolName:(NSString *)name;

// Cheap launch gate used by SCICSymbolBootstrap.x.
+ (BOOL)hasPersistedHooks;
+ (BOOL)masterEnabled;
+ (void)reinstallPersistedHooks;

// Back-compat helpers used by the Dev UI quick toggle. These only target curated
// single-purpose bool gates. Multi-tenant config readers stay observe-only.
+ (NSArray<NSString *> *)internalGateSymbolNames;
+ (NSArray<NSString *> *)forceInternalReadersEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
