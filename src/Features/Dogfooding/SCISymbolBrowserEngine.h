// SCISymbolBrowserEngine.h
//
// Shared runtime engine for the two dynamic symbol browsers (Instagram exec and
// FBSharedFramework). It enumerates ObjC classes belonging to one image, lists
// their hookable BOOL getters, reports each getter's LIVE current value, and
// lets the user persist a force override.
//
// Runtime-force timing model:
//   • Persistence: one NSUserDefaults dict (sci_symbol_overrides) via SCIUtils,
//     registered in SCIDefaults so backup/export includes it.
//   • Hooking: persisted overrides are installed once from Logos bootstrap.
//     A newly selected getter is saved and installed live immediately; the
//     replacement reads the in-memory cache, not NSUserDefaults.
//   • Replacement hot path never reads NSUserDefaults. It reads only a static
//     immutable cache refreshed when the settings UI changes.
//   • Enumeration remains on-demand when the browser opens; no class crawling at
//     launch unless the user already saved overrides.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCISymbolImage) {
	SCISymbolImageInstagram = 0,
	SCISymbolImageFBShared  = 1,
};

@interface SCISymbolGetter : NSObject
@property (nonatomic, copy) NSString *selectorName;
@property (nonatomic, copy) NSString *ownerClassName;
@property (nonatomic, readonly) NSString *overrideKey;
@property (nonatomic, assign) BOOL isClassMethod;
@property (nonatomic, readonly, nullable) NSNumber *liveValue;
@property (nonatomic, readonly, nullable) NSNumber *override;
@end

@interface SCISymbolClass : NSObject
@property (nonatomic, copy) NSString *className;
@property (nonatomic, strong) NSArray<SCISymbolGetter *> *getters;
@end

@interface SCISymbolBrowserEngine : NSObject

+ (NSArray<SCISymbolClass *> *)classesForImage:(SCISymbolImage)image;

+ (nullable NSNumber *)liveValueForClass:(NSString *)className
								selector:(NSString *)selectorName
						 isClassMethod:(BOOL)isClassMethod;

+ (nullable NSNumber *)overrideForKey:(NSString *)overrideKey;
+ (BOOL)hookInstalledForKey:(NSString *)overrideKey;
+ (BOOL)installOverrideForKey:(NSString *)overrideKey;

+ (void)setOverride:(nullable NSNumber *)value
		   forClass:(NSString *)className
		   selector:(NSString *)selectorName
	  isClassMethod:(BOOL)isClassMethod;

+ (void)reinstallPersistedHooks;

@end

NS_ASSUME_NONNULL_END
