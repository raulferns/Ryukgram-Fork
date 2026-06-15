// SCICSymbolEngine.h
//
// Runtime browser + safe runtime hooking for C symbols (imported via GOT),
// mirroring the ObjC SCISymbolBrowserEngine but for plain C functions such as
// Instagram's MobileConfig / EasyGating boolean readers.
//
// Why this is safe and works (validated against IG 433 + FBSharedFramework):
//   • The boolean readers (GetMobileConfigBoolean, EasyGatingGetBoolean_Internal_
//     DoNotUseOrMock, MSGCSessionedMobileConfigGetBoolean, IGMobileConfigBoolean
//     ValueForInternalUse, MCDDasmNativeGetMobileConfigBooleanV2DvmAdapter, …) are
//     all imported by the Instagram exec from FBSharedFramework via chained-fixup
//     GOT slots. fishhook (rebind_symbols) rebinds exactly those GOT slots, so we
//     intercept every call the exec makes — this is the THEOS.md "C imported
//     symbol → fishhook, flag latched" pattern.
//   • Each reader has a specific ABI. We do NOT use one generic block for all of
//     them (a wrong C ABI is an uncatchable crash). Instead each symbol is bound
//     to a typed replacement matching its real disassembled signature, grouped by
//     "ABI family". The family is recorded per symbol below.
//   • Hot path reads only a static C cache (atomics), never NSUserDefaults.
//   • Persistence: one dict (sci_c_symbol_overrides) via SCIUtils, registered in
//     SCIDefaults. Installed once from a Logos %ctor (SCICSymbolBootstrap.x),
//     gated by a cheap pref. New selections take effect after relaunch; an
//     already-installed symbol updates from the in-memory cache immediately.
//
// Force semantics (same as the ObjC browser):
//   ON  = force return YES for this symbol (optionally only for a captured ID)
//   OFF = remove override, return the app's real value
//
// Diagnostics: when a reader takes a small-integer gating/param ID as its first
// integer argument (EasyGating family), the replacement records the set of IDs it
// has been called with, plus the real value observed for each. That is how we
// discover *which* numeric ID corresponds to IG_INTERNAL_SETTINGS so we can later
// force only that one instead of forcing the symbol globally.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ABI families discovered by disassembly. Each maps to a typed replacement.
typedef NS_ENUM(NSInteger, SCICAbiFamily) {
	// BOOL f(...): no usable integer ID in a known register; force-only, no per-ID.
	SCICAbiFamilyOpaqueBool = 0,
	// BOOL f(int32 gating_id, ...): EasyGating-style; first int arg is the ID.
	//   _EasyGatingGetBoolean_Internal_DoNotUseOrMock          (id in w0)
	SCICAbiFamilyGatingId_w0 = 1,
	// BOOL f(void* a, int32 gating_id, ...): id in w1.
	//   _MCQEasyGatingGetBooleanInternalDoNotUseOrMock          (id in w1)
	SCICAbiFamilyGatingId_w1 = 2,
};

@interface SCICSymbol : NSObject
@property (nonatomic, copy)   NSString *symbolName;     // e.g. "EasyGatingGetBoolean_Internal_DoNotUseOrMock"
@property (nonatomic, copy)   NSString *displayName;    // short, for the cell title
@property (nonatomic, copy)   NSString *originImage;    // "FBSharedFramework"
@property (nonatomic, assign) SCICAbiFamily abiFamily;
@property (nonatomic, readonly) NSString *overrideKey;  // "C#<symbolName>"
@property (nonatomic, readonly, nullable) NSNumber *override;     // forced value, if any
@property (nonatomic, readonly) BOOL hookInstalled;
@property (nonatomic, readonly) NSUInteger observedCallCount;     // hits since launch
@property (nonatomic, readonly) NSArray<NSNumber *> *observedIDs; // captured gating IDs (families 1/2)
@end

@interface SCICSymbolEngine : NSObject

// The curated, binary-validated list of hookable C boolean readers.
+ (NSArray<SCICSymbol *> *)allSymbols;

// Force value for a whole symbol (nil = remove override).
+ (void)setOverride:(nullable NSNumber *)value forSymbolName:(NSString *)name;
+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name;

// Force value for a specific captured gating ID under a symbol (families 1/2 only).
// This is the surgical path: force ONLY the internal-settings ID, leave the rest.
+ (void)setOverride:(nullable NSNumber *)value
	  forSymbolName:(NSString *)name
		 gatingID:(int32_t)gatingID;
+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name gatingID:(int32_t)gatingID;

// Diagnostics readout for the UI.
+ (NSUInteger)callCountForSymbolName:(NSString *)name;
+ (NSArray<NSNumber *> *)observedIDsForSymbolName:(NSString *)name;
+ (nullable NSNumber *)observedValueForSymbolName:(NSString *)name gatingID:(int32_t)gatingID;

// Whether a global enable for C-symbol forcing is on (cheap pref).
+ (BOOL)masterEnabled;

// Install fishhook rebindings for every symbol that has any persisted override.
// Called once from the %ctor. Idempotent.
+ (void)reinstallPersistedHooks;

@end

NS_ASSUME_NONNULL_END
