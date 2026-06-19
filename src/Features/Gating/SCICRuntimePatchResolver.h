// SCICRuntimePatchResolver.h
// Central runtime patch resolver/applicator for the Unified Runtime Browser.
//
// This engine owns the decision tree. UI code supplies facts collected while
// enumerating dyld/ObjC plus optional realtime xref hits; the resolver returns a
// concrete, sideload-safe strategy and applies/reverts it through the proven
// backends (ObjC MSHookMessageEx engine, C fishhook engine, MobileConfig reader
// filter, DATA pointer rebind, DATA byte patch with snapshot).

#import <Foundation/Foundation.h>
#import "SCIRuntimeXrefScanner.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCICRuntimePatchStrategy) {
    SCICRuntimePatchStrategyNone = 0,
    SCICRuntimePatchStrategyObjCBool,
    SCICRuntimePatchStrategyFunctionBool,
    SCICRuntimePatchStrategyFunctionTyped,
    SCICRuntimePatchStrategyFunctionObserve,
    SCICRuntimePatchStrategyDataReaderBool,
    SCICRuntimePatchStrategyDataRebindString,
    SCICRuntimePatchStrategyDataPatchBytes,
};

@interface SCICRuntimePatchPlan : NSObject <NSCopying>
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy, nullable) NSString *image;
@property (nonatomic, copy, nullable) NSString *section;
@property (nonatomic, copy, nullable) NSString *kind;
@property (nonatomic, copy, nullable) NSString *abi;
@property (nonatomic, assign) uintptr_t runtimeAddress;
@property (nonatomic, assign) uintptr_t symtabAddress;
@property (nonatomic, assign) NSUInteger dataSize;
@property (nonatomic, assign) BOOL function;
@property (nonatomic, assign) BOOL data;
@property (nonatomic, assign) BOOL swiftLike;
@property (nonatomic, assign) BOOL hasBindPointer;
@property (nonatomic, copy, nullable) NSString *objcClassName;
@property (nonatomic, copy, nullable) NSString *objcSelectorName;
@property (nonatomic, assign) BOOL objcClassMethod;
@property (nonatomic, copy, nullable) NSString *consumerSymbol;
@property (nonatomic, copy, nullable) NSString *callerSymbol;
@property (nonatomic, assign) SCICRuntimePatchStrategy strategy;
@property (nonatomic, copy) NSString *strategyName;
@property (nonatomic, copy) NSString *shortStrategyName;
@property (nonatomic, copy) NSString *reason;
@property (nonatomic, copy, nullable) NSString *returnKind;
@property (nonatomic, assign) BOOL inlineToggleSafe;
@property (nonatomic, assign) BOOL safeAtLaunch;
@property (nonatomic, assign) BOOL requiresPromptValue;
@property (nonatomic, assign) BOOL requiresConfirmedConsumer;
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
+ (nullable instancetype)planWithDictionary:(NSDictionary<NSString *, id> *)dict;
@end

@interface SCICRuntimePatchResolver : NSObject

+ (NSString *)persistedPlansKey;
+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)persistedPatchPlans;
+ (nullable NSDictionary<NSString *, id> *)persistedPatchForSymbol:(NSString *)symbol;
+ (void)forgetPatchPlanForSymbol:(NSString *)symbol;

// `entryInfo` keys are intentionally plain Foundation values so the Settings
// browser can keep its private row model local:
// symbol,image,section,kind,abi,function,data,swiftLike,hasBindPointer,
// runtimeAddress,symtabAddress,dataSize,objcClassName,objcSelectorName,
// objcClassMethod.
+ (SCICRuntimePatchPlan *)resolvePlanForEntryInfo:(NSDictionary<NSString *, id> *)entryInfo
                                         xrefHits:(nullable NSArray<SCIXrefHit *> *)xrefHits;

+ (BOOL)isAppliedPlan:(SCICRuntimePatchPlan *)plan;
+ (NSUInteger)hitCountForPlan:(SCICRuntimePatchPlan *)plan;
+ (BOOL)isHookInstalledForPlan:(SCICRuntimePatchPlan *)plan;
+ (nullable id)currentForcedValueForPlan:(SCICRuntimePatchPlan *)plan;
+ (nullable id)currentNativeValueForPlan:(SCICRuntimePatchPlan *)plan;
+ (BOOL)isEffectivelyEnabledForPlan:(SCICRuntimePatchPlan *)plan;
+ (NSString *)stateSummaryForPlan:(SCICRuntimePatchPlan *)plan;

// `value` is strategy-specific:
// ObjC/function BOOL/DATA reader BOOL -> NSNumber BOOL.
// Function typed -> NSNumber or NSString matching returnKind.
// DATA rebind string -> NSString.
// DATA patch bytes -> NSData.
// Observe -> nil.
+ (BOOL)applyPlan:(SCICRuntimePatchPlan *)plan value:(nullable id)value error:(NSError **)error;
+ (BOOL)revertPlan:(SCICRuntimePatchPlan *)plan error:(NSError **)error;

// Cold launch entry. Reads only the cheap persisted plan dictionary first;
// returns immediately if empty. Reapplies only plans marked safeAtLaunch and
// revalidated against the current runtime.
+ (void)reinstallSafePersistedPatchPlansAtLaunch;

+ (nullable NSData *)dataFromHexString:(NSString *)hex error:(NSError **)error;
+ (NSString *)hexStringFromData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
