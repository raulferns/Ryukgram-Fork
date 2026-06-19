// SCIRuntimeXrefScanner.h
//
// Realtime, in-process, READ-ONLY ARM64 xref resolver.
//
// Purpose: given the runtime address of a DATA symbol (e.g. a MobileConfig
// param descriptor like ig_is_employee), find the call sites that load that
// address into a register (adrp+add) and then `bl` into a reader/consumer
// function. This turns "Likely consumer: unknown" into a concrete, resolved
// consumer (e.g. IGMobileConfigBooleanValueForInternalUse) so the patch
// resolver can pick the correct, sideload-safe strategy automatically.
//
// Hard guarantees:
//   • Read-only. It never writes memory. It cannot patch __TEXT (sideload W^X).
//   • Bounded. Every scan is capped by an instruction budget and a max-hit
//     count, and runs off the main thread.
//   • In-bounds. It only reads inside the resolved __TEXT section of a mapped
//     image; all reads are range-checked.
//
// The decode math (adrp/add/bl) is unit-validated against the real binary.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIXrefHit : NSObject
@property (nonatomic, assign) uintptr_t loadPC;        // adrp that loaded the target
@property (nonatomic, assign) uintptr_t callPC;        // the bl instruction
@property (nonatomic, assign) uintptr_t calleeAddress; // resolved bl target
@property (nonatomic, copy, nullable) NSString *calleeSymbol;  // consumer/reader name (dladdr)
@property (nonatomic, copy, nullable) NSString *callerSymbol;  // function containing the bl (dladdr)
@property (nonatomic, copy, nullable) NSString *image;         // owning image short name
@property (nonatomic, copy, nullable) NSString *referenceKind; // direct-call, address-load, got-load, indirect-call
@property (nonatomic, copy, nullable) NSString *detail;        // UI-friendly resolved summary
@end

@interface SCIRuntimeXrefScanner : NSObject

// Default instruction budget per scan (keeps a single scan fast and bounded).
+ (uint64_t)defaultBudget;

// Resolve consumers of `targetAddress`. If `imageSubstring` is nil, every
// loaded runtime image in the supported scope (Instagram exec + FBShared) is
// scanned. This is necessary because DATA descriptors often live in FBShared
// while callers/import slots can be in Instagram, and function xrefs are BL/BLR
// callsites instead of DATA loads. Completion is always called on the main
// queue. Safe to call repeatedly; cancels nothing.
+ (void)findConsumersOfAddress:(uintptr_t)targetAddress
                 imageSubstring:(nullable NSString *)imageSubstring
                         budget:(uint64_t)budget
                        maxHits:(int)maxHits
                     completion:(void (^)(NSArray<SCIXrefHit *> *hits, BOOL hitBudget))completion;

// Synchronous variant for callers already off the main thread.
+ (NSArray<SCIXrefHit *> *)consumersOfAddress:(uintptr_t)targetAddress
                                imageSubstring:(nullable NSString *)imageSubstring
                                        budget:(uint64_t)budget
                                       maxHits:(int)maxHits
                                     hitBudget:(nullable BOOL *)outHitBudget;

// Resolve a code address to "image`symbol+0x..`" for display.
+ (NSString *)describeAddress:(uintptr_t)address;

@end

NS_ASSUME_NONNULL_END
