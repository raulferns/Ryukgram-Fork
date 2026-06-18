// SCICRuntimePatchResolver.h
// Realtime patch resolver/applicator for the unified runtime browser.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const SCICPatchStrategyObserve;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyObjCBool;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyFunctionBool;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyFunctionTyped;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyDataReaderBool;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyDataStringRebind;
FOUNDATION_EXPORT NSString *const SCICPatchStrategyDataBytesPatch;

@interface SCICPatchPlan : NSObject
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *image;
@property (nonatomic, copy) NSString *section;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *consumerSummary;
@property (nonatomic, copy) NSString *strategySummary;
@property (nonatomic, copy) NSString *safetySummary;
@property (nonatomic, copy) NSArray<NSString *> *importedByImages;
@property (nonatomic, copy) NSArray<NSString *> *bindPointerSummary;
@property (nonatomic, copy) NSArray<NSString *> *xrefSummary;
@property (nonatomic, assign) BOOL hasBindPointer;
@property (nonatomic, assign) BOOL hasXrefs;
@property (nonatomic, assign) BOOL dataPatchable;
@property (nonatomic, assign) BOOL functionHookable;
@property (nonatomic, assign) NSUInteger knownSize;
@property (nonatomic, copy, nullable) NSString *appliedStrategy;
@property (nonatomic, copy, nullable) id appliedValue;
@end

@interface SCICRuntimePatchResolver : NSObject

+ (SCICPatchPlan *)resolveSymbol:(NSString *)symbol
                           image:(NSString *)image
                         section:(NSString *)section
                         address:(uintptr_t)address
                       isFunction:(BOOL)isFunction
                           isData:(BOOL)isData
                        swiftLike:(BOOL)swiftLike
                    objcClassName:(nullable NSString *)objcClassName
                 objcSelectorName:(nullable NSString *)objcSelectorName
                objcIsClassMethod:(BOOL)objcIsClassMethod;

+ (nullable NSDictionary<NSString *, id> *)persistedPatchForSymbol:(NSString *)symbol;
+ (BOOL)applyBoolForce:(nullable NSNumber *)value
             forSymbol:(NSString *)symbol
              strategy:(NSString *)strategy
                  plan:(nullable SCICPatchPlan *)plan
         objcClassName:(nullable NSString *)objcClassName
      objcSelectorName:(nullable NSString *)objcSelectorName
     objcIsClassMethod:(BOOL)objcIsClassMethod;
+ (BOOL)applyTypedValue:(nullable id)value returnKind:(NSString *)returnKind forSymbol:(NSString *)symbol plan:(nullable SCICPatchPlan *)plan;
+ (BOOL)applyStringRebind:(NSString *)replacement forSymbol:(NSString *)symbol plan:(nullable SCICPatchPlan *)plan;
+ (BOOL)applyHexPatch:(NSString *)hexString forSymbol:(NSString *)symbol address:(uintptr_t)address maxSize:(NSUInteger)maxSize plan:(nullable SCICPatchPlan *)plan error:(NSString *_Nullable *_Nullable)errorOut;
+ (BOOL)observeSymbol:(NSString *)symbol plan:(nullable SCICPatchPlan *)plan;
+ (void)clearPatchForSymbol:(NSString *)symbol address:(uintptr_t)address;
+ (void)reinstallPersistedPatchPlans;
+ (NSString *)stateSummaryForSymbol:(NSString *)symbol;
+ (NSString *)reportForPlan:(SCICPatchPlan *)plan;

@end

NS_ASSUME_NONNULL_END
