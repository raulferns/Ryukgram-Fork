// SCIIdNameMapGenerator.h — RyukGram-Fork
//
// Runtime generation of id_name_mapping.json for the CURRENT Instagram build.
//
// Neither the iOS .app bundle nor the Android APK ship a populated name table:
// Android ships assets/params_names_v4_u0.txt == "[]", and this iOS build ships
// no mobileconfig_res/ directory at all. The names only ever materialise when
// the OEM MobileConfig stack performs a param-list request and persists the
// extra data. This module drives exactly that OEM path — it never fabricates,
// patches or transplants a mapping from another app.
//
// Verified ABI in Instagram(440) / FBSharedFramework, by ObjC metadata dump:
//
//   FBMobileConfigFBTGlobalSessionManager
//     + sharedInstance                                @16@0:8
//     - currentSessionContextManagerHolder            @16@0:8
//     - adminSessionContextManagerHolder              @16@0:8
//     - sessionlessContextManagerHolder               @16@0:8
//
//   FBMobileConfigFBTContextManagerHolder
//     ivar _mcFbtManager  _containerPath  _fbLocale  _fetcherSetter  _contextManagerCreator
//     - reload:                                       q24@0:8d16
//     - syncConfigsAndMayUpdateManager:syncFetchTimeout:
//                                                     q40@0:8{shared_ptr<...FBMobileConfigManager>}16d32
//     - mcFbtManager / fetcherSetter / contextManagerCreator
//
//   FBMobileConfigFBTContextManager
//     ivar _mobileconfig  ->  FBMobileConfigContextObjcImpl
//   FBMobileConfigContextObjcImpl
//     ivar _configManager  {weak_ptr<mobileconfig::IFBMobileConfigManager>}
//
//   C++ (mangled, resolved with dlsym; may be a local symbol):
//     _ZN12mobileconfig21FBMobileConfigManager40updateConfigsWithParamsListSynchronouslyEiNS_37FBMobileConfigRequestForParamListModeE
//
// The "missing wiring" the reverse-engineering notes describe is that the
// holder's _fetcherSetter must be re-applied after a reload recreates the
// manager. syncConfigsAndMayUpdateManager: takes the manager shared_ptr BY
// VALUE; handing it a null shared_ptr makes the holder rebuild the manager
// through its own _contextManagerCreator and reinstall the fetcher through its
// own _fetcherSetter — i.e. the OEM code performs the rebind for us.
//
// Every step validates the exact ObjC type encoding before dispatching. When an
// encoding does not match, the step reports the mismatch and returns instead of
// calling into an ABI it cannot prove.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCIIdNameMapUnit) {
	SCIIdNameMapUnitCurrentSession = 0,   // sessionbased
	SCIIdNameMapUnitAdmin          = 1,   // kMobileConfigAdminId
	SCIIdNameMapUnitSessionless    = 2,   // sessionless
};

@interface SCIIdNameMapGenerator : NSObject

/// Static validation of the whole chain. No fetch, no reload, no side effects.
+ (NSString *)wiringState;

/// Re-applies _fetcherSetter on the live manager and reports what happened.
+ (NSString *)rebindFetcherForUnit:(SCIIdNameMapUnit)unit;

/// Reinstalls the fetcher captured at startup onto the unit's live manager.
+ (NSString *)reinstallFetcherForUnit:(SCIIdNameMapUnit)unit;

/// reload: on the selected holder (OEM signature takes a double timeout).
+ (NSString *)reloadUnit:(SCIIdNameMapUnit)unit timeout:(double)timeout;

/// Full sequence: bind -> reload -> rebind -> param-list sync (mode) -> poll for
/// the persisted file. Runs off the main thread; completion is on the main queue.
+ (void)generateForUnit:(SCIIdNameMapUnit)unit
				timeout:(double)timeout
				   mode:(int)mode
			 completion:(void (^)(NSString *report))completion;

/// Where the mapping actually landed, plus size / entry count / admin coverage.
+ (NSString *)mappingFileState;
+ (nullable NSURL *)mappingFileURL;

+ (NSString *)nameForUnit:(SCIIdNameMapUnit)unit;

/// One-line status for the settings row accessory: "5,581 configs", "none",
/// "no manager". Cheap enough to evaluate on every cell render.
+ (NSString *)shortStatus;

/// One-line verdict for the setup row accessory: "ready", "no session",
/// "no fetcher", "blocked".
+ (NSString *)wiringSummary;

@end

NS_ASSUME_NONNULL_END
