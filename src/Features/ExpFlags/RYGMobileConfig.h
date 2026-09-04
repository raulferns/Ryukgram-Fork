#import <Foundation/Foundation.h>

typedef uint8_t RYGMCType;
enum {
    RYGMCTypeUnknown = 0,
    RYGMCTypeBool    = 1,
    RYGMCTypeInt     = 2,
    // Revalidated against the current FBSharedFramework parameter table and
    // native mc_overrides.json: discriminator 3 is string and 4 is double.
    RYGMCTypeString  = 3,
    RYGMCTypeDouble  = 4,
};

static inline BOOL RYGMCTypeIsRuntimeValue(RYGMCType type) {
    return type == RYGMCTypeBool || type == RYGMCTypeInt ||
           type == RYGMCTypeString || type == RYGMCTypeDouble;
}

typedef NS_ENUM(NSInteger, RYGMCOverrideState) {
    RYGMCOverrideNone = 0,
    RYGMCOverrideSet,
};

@interface RYGMCParam : NSObject
@property (nonatomic, assign) unsigned long long paramID;
@property (nonatomic, assign) unsigned int ordinal;
@property (nonatomic, assign) unsigned int configNumber;
@property (nonatomic, assign) unsigned int paramIndex;
@property (nonatomic, assign) RYGMCType type;
@property (nonatomic, assign, getter=isRuntimeBacked) BOOL runtimeBacked;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, readonly) NSString *typeName;
@end

@interface RYGMCConfig : NSObject
@property (nonatomic, assign) unsigned int number;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSArray<RYGMCParam *> *params;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) BOOL hasRuntimeBacking;
@end

@interface RYGMobileConfig : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) NSUInteger namedConfigCount;

- (void)prepare;
/// Rebuilds the browser from Instagram's live exported parameter table. A cached
/// id/name catalog may decorate matching rows, but never creates runtime values.
- (void)reloadFromRuntime;
- (NSArray<RYGMCConfig *> *)allConfigs;
- (NSArray<RYGMCConfig *> *)configsMatching:(NSString *)query onlyOverridden:(BOOL)onlyOverridden;
- (NSArray<NSString *> *)paramsMatching:(NSString *)query inConfig:(RYGMCConfig *)config;

/// Native-disk fallback used only before an explicit imported mapping exists.
- (void)mergeDiskNamesInto:(NSMutableDictionary *)catalog;

- (id)liveValueFor:(RYGMCParam *)param;

- (RYGMCOverrideState)overrideStateFor:(RYGMCParam *)param;
- (id)overrideValueFor:(RYGMCParam *)param;
- (BOOL)setOverride:(id)value for:(RYGMCParam *)param;
- (void)clearOverrideFor:(RYGMCParam *)param;
- (NSUInteger)overrideCount;
- (void)resetAllOverrides;
- (void)resetOverridesForConfig:(RYGMCConfig *)config;

- (NSString *)callSiteFor:(RYGMCParam *)param;

- (NSString *)noteFor:(RYGMCParam *)param;
- (void)setNote:(NSString *)note for:(RYGMCParam *)param;

- (void)markLaunchStable;
- (BOOL)consumeCrashLoopFlag;
- (void)reapplyOverridesToNativeTable;

@end
