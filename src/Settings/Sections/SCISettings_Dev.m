#import "SCISettingsSections.h"
#import "SCIMCBrowser.h"
#import "../SCISymbolsBrowserViewController.h"
#import "../SCIIGDSLauncherConfigViewController.h"
#import "../../Features/Dogfooding/SCIInternalSettingsApplier.h"
#import "../../Features/Dogfooding/SCIInternalMenusLauncher.h"
#import "../../Features/Dogfooding/SCISymbolBrowserEngine.h"
#import "../../Features/Dogfooding/SCIGraphQLDogfoodDiagnostics.h"
#import "../../Features/Dogfooding/SCIDogfoodObjectRuntime.h"
#import "../../Features/MobileConfig/SCIIdNameMapGenerator.h"

void SCIInstallUnifiedExperimentManagerHooksIfNeeded(void);
void SCIInstallInternalDevMenuHooksIfNeeded(void);
void SCIInstallEmployeeInternalHooksIfNeeded(void);
void SCIInstallGraphQLDogfoodForceHooksIfNeeded(void);
void SCIRefreshGraphQLDogfoodForceEnabled(void);
void SCIInstallE2EBypassHookIfNeeded(void);

static UIViewController *SCIDevTop(void) {
	UIWindow *window = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		if (scene.activationState != UISceneActivationStateForegroundActive) continue;
		for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
			if (candidate.isKeyWindow) { window = candidate; break; }
		}
		if (window) break;
	}
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	return top;
}

static void SCIDevShow(NSString *title, NSString *message) {
	UIViewController *top = SCIDevTop();
	if (!top) return;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
		message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK"
		style:UIAlertActionStyleDefault handler:nil]];
	[top presentViewController:alert animated:YES completion:nil];
}

static void SCIDevShowNextTurn(NSString *title, NSString *message) {
	dispatch_async(dispatch_get_main_queue(), ^{ SCIDevShow(title, message); });
}

static BOOL SCIDevResultWasHandled(NSString *result) {
	return [result hasPrefix:@"opened"] ||
		[result hasPrefix:@"presented"] ||
		[result hasPrefix:@"scheduled"] ||
		[result hasPrefix:@"requested"];
}

static void SCIDevPromptFOASandboxHostname(void) {
	UIViewController *top = SCIDevTop();
	if (!top) return;

	UIAlertController *alert = [UIAlertController
		alertControllerWithTitle:SCILocalized(@"FOA Sandbox Hostname")
		message:SCILocalized(@"Enter a DNS hostname only. This changes the client environment; it does not bypass authentication or server authorization.")
		preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.placeholder = @"sandbox.example.internal";
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.keyboardType = UIKeyboardTypeURL;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel")
		style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Set")
		style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
			NSString *hostname = alert.textFields.firstObject.text ?: @"";
			NSString *result = [SCIGraphQLDogfoodDiagnostics setFOASandboxHostname:hostname];
			SCIDevShowNextTurn(SCILocalized(@"FOA Sandbox"), result);
		}]];
	[top presentViewController:alert animated:YES completion:nil];
}

static SCISetting *SCIExperimentSwitch(
	NSString *title,
	NSString *subtitle,
	NSString *key,
	NSUInteger (^apply)(NSNumber *)
) {
	return [SCISetting switchCellWithTitle:title subtitle:subtitle value:^BOOL {
		return [SCIUtils getBoolPref:key];
	} action:^(BOOL on) {
		[SCIUtils setPref:@(on) forKey:key];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			NSUInteger count = apply(on ? @YES : nil);
			dispatch_async(dispatch_get_main_queue(), ^{
				[SCIUtils showToastForDuration:2.5
					title:[NSString stringWithFormat:@"%@ — %lu methods",
						on ? @"Applied" : @"Cleared", (unsigned long)count]
					subtitle:nil];
			});
		});
	}];
}

static SCISetting *SCITier2EmployeeInternalSwitch(void) {
	// Sideload-safe employee/internal identity. The former Tier-2 gate used
	// ElleKit's EKHookFunction to inline-patch the _ig_is_employee __TEXT thunk;
	// on iOS 27 that left the code page rw- and the app was SIGKILLed
	// (CODESIGNING / Invalid Page). Disassembly also proved that thunk never
	// reaches the imported EasyGating evaluator, so a fishhook could not cover it
	// either. The only sideload-safe surface is the ObjC identity getters, which
	// SCIEmployeeInternal.x swizzles via MSHookMessageEx (__DATA, never __TEXT).
	return [SCISetting switchCellWithTitle:SCILocalized(@"Tier-2")
		subtitle:SCILocalized(@"Single master: forces employee/internal ObjC identity + GraphQL dogfooding eligibility + bypasses the production lockout screen. Sideload-safe (__DATA swizzle only). Restart for cached checks.")
		value:^BOOL {
			return [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"];
		} action:^(BOOL on) {
			[SCIUtils setPref:@(on) forKey:@"sci_force_ig_internal_employee"];
			[SCIUtils setPref:@(on) forKey:@"sci_force_ig_is_employee"];
			[SCIUtils setPref:@NO forKey:@"sci_tier2_employee_internal"]; // retire unsafe pref
			// Single Tier-2 master drives every sideload-safe layer:
			SCIInstallEmployeeInternalHooksIfNeeded();            // ObjC -isEmployee/-isInternal swizzles
			SCIRefreshGraphQLDogfoodForceEnabled();               // re-read master for dogfood force
			SCIInstallGraphQLDogfoodForceHooksIfNeeded();         // eligibility + production-lockout bypass
			[SCIUtils showToastForDuration:2.5
				title:on ? @"Tier-2 applied" : @"Tier-2 disabled"
				subtitle:on
					? @"Employee/internal + dogfooding eligibility forced; lockout bypassed. Restart for cached checks."
					: @"Original identity results are used"];
		}];
}

static SCISetting *SCIInternalSettingsSwitch(
	NSString *title,
	NSString *subtitle,
	NSString *key
) {
	return [SCISetting switchCellWithTitle:title subtitle:subtitle value:^BOOL {
		return [SCIUtils getBoolPref:key];
	} action:^(BOOL on) {
		[SCIUtils setPref:@(on) forKey:key];
		SCIRefreshGraphQLDogfoodForceEnabled();
		SCIInstallEmployeeInternalHooksIfNeeded();
		SCIInstallGraphQLDogfoodForceHooksIfNeeded();
		[SCIUtils showToastForDuration:2.0
			title:on
				? @"Internal preference applied"
				: @"Preference disabled"
			subtitle:nil];
	}];
}

#pragma mark - id_name_mapping generator

static SCIIdNameMapUnit SCIIdNameMapSelectedUnit(void) {
	// The menu cell stores STRING values through UICommand.propertyList, so this
	// pref must be read with getStringPref — not as a number.
	NSString *raw = [SCIUtils getStringPref:@"sci_idnamemap_unit"];
	if ([raw isEqualToString:@"admin"]) return SCIIdNameMapUnitAdmin;
	if ([raw isEqualToString:@"sessionless"]) return SCIIdNameMapUnitSessionless;
	return SCIIdNameMapUnitCurrentSession;
}

static double SCIIdNameMapTimeout(void) {
	NSInteger seconds = (NSInteger)[SCIUtils getDoublePref:@"sci_idnamemap_timeout"];
	if (seconds < 5) seconds = 30;
	return (double)seconds;
}

static int SCIIdNameMapMode(void) {
	NSInteger mode = (NSInteger)[SCIUtils getDoublePref:@"sci_idnamemap_mode"];
	if (mode < 0 || mode > 3) mode = 1;
	return (int)mode;
}

static void SCIIdNameMapPresentReport(NSString *title, NSString *report) {
	UIViewController *top = SCIDevTop();
	if (!top) return;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
		message:report preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Copy")
		style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
			UIPasteboard.generalPasteboard.string = report ?: @"";
		}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK"
		style:UIAlertActionStyleCancel handler:nil]];
	[top presentViewController:alert animated:YES completion:nil];
}

static void SCIIdNameMapExport(void) {
	NSURL *url = [SCIIdNameMapGenerator mappingFileURL];
	if (!url) {
		[SCIUtils showErrorHUDWithDescription:SCILocalized(@"id_name_mapping.json not generated yet")];
		return;
	}
	UIViewController *top = SCIDevTop();
	if (!top) return;
	UIActivityViewController *sheet =
		[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
	if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
		sheet.popoverPresentationController.sourceView = top.view;
		sheet.popoverPresentationController.sourceRect =
			CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
	}
	[top presentViewController:sheet animated:YES completion:nil];
}

@implementation SCITweakSettings (Section_Dev)

+ (SCISetting *)devNavCell {
	SCIRegisterGraphQLDogfoodDevDefaults();

	// Migrate the retired unsafe Tier-2 pref onto the sideload-safe employee master.
	if ([SCIUtils getBoolPref:@"sci_tier2_employee_internal"]) {
		[SCIUtils setPref:@YES forKey:@"sci_force_ig_internal_employee"];
		[SCIUtils setPref:@YES forKey:@"sci_force_ig_is_employee"];
		[SCIUtils setPref:@NO forKey:@"sci_tier2_employee_internal"];
	}
	if ([SCIUtils getBoolPref:@"sci_force_internal_settings_availability"] ||
		[SCIUtils getBoolPref:@"sci_force_internal_settings_menu"] ||
		[SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
		SCIInstallEmployeeInternalHooksIfNeeded();
		SCIInstallGraphQLDogfoodForceHooksIfNeeded();
	}
	if ([SCIUtils getBoolPref:@"sci_force_e2e_bypass"]) {
		SCIInstallE2EBypassHookIfNeeded();
	}

	return [SCISetting navigationCellWithTitle:SCILocalized(@"Dev")
		subtitle:@""
		icon:[SCISymbol symbolWithIGName:@"wrench" fallback:@"hammer"]
		navSections:@[
		@{
			@"header": SCILocalized(@"Unified experiment engines"),
			@"footer": SCILocalized(@"Validated in Instagram(4): FBCCIGExperimentManager/FBCustomExperimentManager use BOOL isFeatureEnabled:(uint64_t). ExperimentConfig and helper sweeps enumerate only supported BOOL methods with zero or one ObjC/integer argument."),
			@"rows": @[
				[SCISetting switchCellWithTitle:SCILocalized(@"Force unified experiment managers")
					subtitle:SCILocalized(@"Forces isFeatureEnabled: and isFeatureEnabledWithoutLogging: on both managers")
					value:^BOOL { return [SCIUtils getBoolPref:@"sci_force_unified_experiment_managers"]; }
					action:^(BOOL on) {
						[SCIUtils setPref:@(on) forKey:@"sci_force_unified_experiment_managers"];
						if (on) SCIInstallUnifiedExperimentManagerHooksIfNeeded();
					}],
				SCIExperimentSwitch(
					SCILocalized(@"Force ExperimentConfig / QE gates"),
					SCILocalized(@"isEnabled:, isBacktestEnabled:, shouldLogImmediately and equivalent config gates"),
					@"sci_force_experiment_configs",
					^NSUInteger(NSNumber *value) { return [SCISymbolBrowserEngine setExperimentConfigsForced:value]; }
				),
				SCIExperimentSwitch(
					SCILocalized(@"Force experiment helpers"),
					SCILocalized(@"IGMagicMod, IGStoriesTab, IGDirectNotes, IGLiquidGlass and experiment/gating helpers"),
					@"sci_force_experiment_helpers",
					^NSUInteger(NSNumber *value) { return [SCISymbolBrowserEngine setExperimentHelpersForced:value]; }
				),
				[SCISetting buttonCellWithTitle:SCILocalized(@"Rescan current experiment surfaces")
					subtitle:SCILocalized(@"Discovers newly loaded ExperimentConfig/helper classes and reapplies enabled masters")
					icon:[SCISymbol symbolWithName:@"arrow.clockwise"]
					action:^{
						dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
							NSUInteger count = 0;
							if ([SCIUtils getBoolPref:@"sci_force_experiment_configs"])
								count += [SCISymbolBrowserEngine setExperimentConfigsForced:@YES];
							if ([SCIUtils getBoolPref:@"sci_force_experiment_helpers"])
								count += [SCISymbolBrowserEngine setExperimentHelpersForced:@YES];
							dispatch_async(dispatch_get_main_queue(), ^{
								[SCIUtils showToastForDuration:2.5
									title:[NSString stringWithFormat:@"Experiment rescan: %lu methods", (unsigned long)count]
									subtitle:nil];
							});
						});
					}],
			]
		},
		@{
			@"header": SCILocalized(@"Employee / Internal, GraphQL Dogfood & Internal Settings"),
			@"footer": SCILocalized(@"Employee / Internal forces the local ObjC identity getters to YES using a __DATA method swizzle (MSHookMessageEx) — never an inline __TEXT patch, which crashes under sideload on iOS 27. The C-level is_employee thunk is intentionally not hooked. Internal-only content may still require server authorization."),
			@"rows": @[
				SCITier2EmployeeInternalSwitch(),
				SCIInternalSettingsSwitch(
					SCILocalized(@"Override Internal Settings availability"),
					SCILocalized(@"Applies the selected IGInternalSettingsAvailabilityStatus raw value; this field is an enum, not a BOOL"),
					@"sci_force_internal_settings_availability"
				),
				[SCISetting stepperCellWithTitle:SCILocalized(@"Internal Settings availability raw value")
					subtitle:SCILocalized(@"0 = available/open, 1 = unavailable/silent, 2 = access denied; applies on next refresh or tap")
					defaultsKey:@"sci_internal_settings_availability_raw_value"
					min:0 max:2 step:1 label:@"raw" singularLabel:@"raw"],
				SCIInternalSettingsSwitch(
					SCILocalized(@"Internal settings menu"),
					SCILocalized(@"Forces showInternalSettings and shake-to-report in both validated initializer ABIs"),
					@"sci_force_internal_settings_menu"
				),
				SCIInternalSettingsSwitch(
					SCILocalized(@"Internal settings while logged out"),
					SCILocalized(@"Explicitly forces showLoggedOutInternalSettings; it is independent from Tier-2"),
					@"sci_force_internal_settings_loggedout"
				),
				[SCISetting buttonCellWithTitle:SCILocalized(@"Sessionless MobileConfig state")
					subtitle:SCILocalized(@"Validates the OEM singleton, manager, custom refresh handler and tryUpdateConfigs ABI without fetching")
					icon:[SCISymbol symbolWithName:@"checkmark.shield"]
					action:^{
						SCIDevShow(SCILocalized(@"Sessionless MobileConfig"),
							[SCIDogfoodObjectRuntime sessionlessMobileConfigState]);
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Fetch sessionless MobileConfig (OEM)")
					subtitle:SCILocalized(@"Calls FBMobileConfigContextManager(UpdateConfigsExtension).tryUpdateConfigs; its native handler owns API client, queue and completion")
					icon:[SCISymbol symbolWithName:@"arrow.triangle.2.circlepath"]
					action:^{
						SCIDevShow(SCILocalized(@"Sessionless MobileConfig"),
							[SCIDogfoodObjectRuntime tryFetchSessionlessMobileConfig]);
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Refresh GraphQL dogfood hooks")
					subtitle:SCILocalized(@"Installs exact eligibility, fragment, warning and backend-check observers")
					icon:[SCISymbol symbolWithIGName:@"bcn_code_outline_24" fallback:@"arrow.clockwise"]
					action:^{
						SCIInstallGraphQLDogfoodForceHooksIfNeeded();
						SCIDevShow(SCILocalized(@"GraphQL dogfood"),
							[SCIGraphQLDogfoodDiagnostics installObservers]);
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"GraphQL dogfood snapshot")
					subtitle:SCILocalized(@"Shows exact BOOL status, lookback_days, fragments and repeated update/build checks")
					icon:[SCISymbol symbolWithIGName:@"bcn_info_outline_24" fallback:@"doc.text.magnifyingglass"]
					action:^{
						SCIDevShow(SCILocalized(@"GraphQL dogfood snapshot"),
							[SCIGraphQLDogfoodDiagnostics snapshot]);
					}],
				[SCISetting switchCellWithTitle:SCILocalized(@"Force E2E bypass")
					subtitle:SCILocalized(@"Forces +shouldBypassForE2EWithLauncherSet: on the validated Swift metaclass")
					value:^BOOL { return [SCIUtils getBoolPref:@"sci_force_e2e_bypass"]; }
					action:^(BOOL on) {
						[SCIUtils setPref:@(on) forKey:@"sci_force_e2e_bypass"];
						if (on) SCIInstallE2EBypassHookIfNeeded();
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Current FOA Sandbox Override")
					subtitle:SCILocalized(@"Reads +currentOverride")
					icon:[SCISymbol symbolWithName:@"server.rack"]
					action:^{ SCIDevShow(SCILocalized(@"FOA Sandbox"),
						[SCIGraphQLDogfoodDiagnostics currentFOASandboxOverride]); }],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Set FOA Sandbox Hostname")
					subtitle:SCILocalized(@"Calls the validated native setter; restart required")
					icon:[SCISymbol symbolWithName:@"network"]
					action:^{ SCIDevPromptFOASandboxHostname(); }],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Reset FOA Sandbox Override")
					subtitle:SCILocalized(@"Clears the override through the native nil-hostname path")
					icon:[SCISymbol symbolWithName:@"arrow.counterclockwise"]
					action:^{ SCIDevShow(SCILocalized(@"FOA Sandbox"),
						[SCIGraphQLDogfoodDiagnostics resetFOASandboxOverride]); }],
				[SCISetting buttonCellWithTitle:SCILocalized(@"GraphQL Debug capabilities")
					subtitle:SCILocalized(@"Validates warmup and ACS/OHAI selectors without requesting credentials")
					icon:[SCISymbol symbolWithName:@"checkmark.shield"]
					action:^{ SCIDevShow(SCILocalized(@"GraphQL Debug"),
						[SCIGraphQLDogfoodDiagnostics graphQLDebugCapabilities]); }],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Warm up GraphQL Debug provider")
					subtitle:SCILocalized(@"Runs the native warmup")
					icon:[SCISymbol symbolWithName:@"bolt.horizontal"]
					action:^{
						[SCIGraphQLDogfoodDiagnostics warmupGraphQLDebugWithCompletion:^(NSString *result) {
							SCIDevShow(SCILocalized(@"GraphQL Debug"), result);
						}];
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Retrieve GraphQL ACS status")
					subtitle:SCILocalized(@"Runs the native provider; reports presence/class without exposing token contents")
					icon:[SCISymbol symbolWithName:@"key"]
					action:^{
						[SCIGraphQLDogfoodDiagnostics retrieveGraphQLDebugACSTokenStatusWithCompletion:^(NSString *result) {
							SCIDevShow(SCILocalized(@"GraphQL ACS"), result);
						}];
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Retrieve ACS + OHAI status")
					subtitle:SCILocalized(@"Runs the validated native callback; credential contents remain redacted")
					icon:[SCISymbol symbolWithName:@"shield.lefthalf.filled"]
					action:^{
						[SCIGraphQLDogfoodDiagnostics retrieveGraphQLDebugACSAndOHAIStatusWithCompletion:^(NSString *result) {
							SCIDevShow(SCILocalized(@"GraphQL ACS + OHAI"), result);
						}];
					}],
				[SCISetting switchCellWithTitle:SCILocalized(@"React Native Dev Menu")
					subtitle:SCILocalized(@"Forces RCTDevMenu devMenuEnabled, shakeToShow, hot loading and keyboard shortcuts")
					value:^BOOL { return [SCIUtils getBoolPref:@"sci_force_rct_dev_menu"]; }
					action:^(BOOL on) {
						[SCIUtils setPref:@(on) forKey:@"sci_force_rct_dev_menu"];
						if (on) SCIInstallInternalDevMenuHooksIfNeeded();
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Open MetaLocalExperiment browser")
										   subtitle:SCILocalized(@"Native experiment list VC — needs internal build to be effective.")
											   icon:[SCISymbol symbolWithIGName:@"grid" fallback:@"square.grid.3x3.square"]
										 action:^{ [SCIDogfoodObjectRuntime tryOpenMetaLocalExperimentBrowser]; }],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Apply internal/debug now")
					subtitle:SCILocalized(@"Uses the live IGAutofillInternalSettings session object")
					icon:[SCISymbol symbolWithIGName:@"bcn_wrench_outline_24" fallback:@"wrench.and.screwdriver"]
					action:^{ SCIDevShow(SCILocalized(@"Internal/debug"),
						[SCIInternalSettingsApplier applyNow]); }],
				[SCISetting switchCellWithTitle:SCILocalized(@"Force Bloks experience")
					subtitle:@"" defaultsKey:@"sci_apply_force_bloks" requiresRestart:YES],
				[SCISetting switchCellWithTitle:SCILocalized(@"Bloks prefetch")
					subtitle:@"" defaultsKey:@"sci_apply_bloks_prefetch" requiresRestart:YES],
			]
		},
		@{
			@"header": SCILocalized(@"Current C experiment gates"),
			@"footer": SCILocalized(@"The removed IGMobileConfigBooleanValueForInternalUse reader is not exposed. Remaining rows map to imports/exports confirmed in Instagram(4) and FBSharedFramework(4); complex readers call the original first, then force YES."),
			@"rows": @[
				[SCISetting switchCellWithTitle:SCILocalized(@"Instagram internal apps installed") subtitle:@"IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18" defaultsKey:@"sci_force_ig_internal_apps_installed_after_ios18" requiresRestart:YES],
				[SCISetting switchCellWithTitle:SCILocalized(@"Minos dogfood MEK") subtitle:@"MEBIsMinosDogfoodMekEncryptionVersionEnabled" defaultsKey:@"sci_force_minos_dogfood_mek_encryption" requiresRestart:YES],
				[SCISetting switchCellWithTitle:SCILocalized(@"Force all EasyGating BOOL readers") subtitle:@"" defaultsKey:@"sci_force_easy_gating_all" requiresRestart:YES],
				[SCISetting switchCellWithTitle:SCILocalized(@"Dogfooding Assistant: socket bypass") subtitle:SCILocalized(@"Intercept tap and present IGSundialYourAlgoDogfoodingAssistantViewController directly") defaultsKey:@"sci_dogfooding_socket_bypass" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"EasyGating Internal" subtitle:@"EasyGatingGetBoolean_Internal_DoNotUseOrMock" defaultsKey:@"sci_force_easy_gating_internal" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"EasyGating Platform" subtitle:@"EasyGatingPlatformGetBoolean" defaultsKey:@"sci_force_easy_gating_platform" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"EasyGating AuthDataContext" subtitle:@"" defaultsKey:@"sci_force_easy_gating_auth" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"MCQ EasyGating" subtitle:@"" defaultsKey:@"sci_force_easy_gating_mcq" requiresRestart:YES],
				[SCISetting switchCellWithTitle:SCILocalized(@"Force Sessioned/MCI BOOL readers") subtitle:SCILocalized(@"MSGC + MCIExperiment + MCIExtension") defaultsKey:@"sci_force_sessioned_mc_all" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"MSGC Sessioned BOOL" subtitle:@"MSGCSessionedMobileConfigGetBoolean" defaultsKey:@"sci_force_msgc_sessioned_boolean" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"MCI Experiment BOOL" subtitle:@"MCIExperimentCacheGetMobileConfigBoolean" defaultsKey:@"sci_force_mci_experiment_boolean" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"MCI Extension BOOL" subtitle:@"MCIExtensionExperimentCacheGetMobileConfigBoolean" defaultsKey:@"sci_force_mci_extension_boolean" requiresRestart:YES],
				[SCISetting switchCellWithTitle:@"META Extensions experiments" subtitle:@"GetBoolean + WithoutExposure" defaultsKey:@"sci_force_meta_ext_experiment" requiresRestart:YES],
			]
		},
		@{
			@"header": SCILocalized(@"Open native internal menus"),
			@"footer": SCILocalized(@"The Debug Menu opener fully dismisses RyukGram, invokes the validated native -showDebugMenu entry-point-0 thunk, keeps the temporary rageshake opt-in through the asynchronous account/build callback and verifies the presented controller before reporting success."),
			@"rows": @[
				[SCISetting buttonCellWithTitle:SCILocalized(@"Open Instagram Debug Menu")
					subtitle:SCILocalized(@"Dismisses this sheet, calls -[IGWindow showDebugMenu] and reports a concrete presentation or gate failure")
					icon:[SCISymbol symbolWithIGName:@"bcn_bug_outline_24" fallback:@"ladybug"]
					action:^{
						[SCIInternalMenusLauncher openInstagramDebugMenuWithCompletion:^(NSString *result) {
							if (![result hasPrefix:@"presented"]) SCIDevShow(@"Instagram Debug Menu", result);
						}];
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Open Dogfooding/Notes settings")
					subtitle:@""
					icon:[SCISymbol symbolWithIGName:@"bcn_settings_outline_24" fallback:@"gearshape"]
					action:^{
						NSString *result = [SCIInternalMenusLauncher openDogfoodingNotesSettings];
						if (!SCIDevResultWasHandled(result)) SCIDevShow(@"Internal menu", result);
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Open Dogfooding Settings VC")
					subtitle:@""
					icon:[SCISymbol symbolWithIGName:@"toolbox" fallback:@"wrench.and.screwdriver"]
					action:^{
						NSString *result = [SCIInternalMenusLauncher openDogfoodingSettingsVC];
						if (!SCIDevResultWasHandled(result)) SCIDevShow(@"Internal menu", result);
					}],
				[SCISetting buttonCellWithTitle:SCILocalized(@"Open internal URL")
					subtitle:@"instagram://internal_settings"
					icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"link"]
					action:^{
						NSString *result = [SCIInternalMenusLauncher openInternalURLString:@"instagram://internal_settings"];
						if (!SCIDevResultWasHandled(result)) SCIDevShow(@"Internal URL", result);
					}],
			]
		},
		@{
			@"header": SCILocalized(@"Config name mapping"),
			@"footer": SCILocalized(@"Instagram ships config IDs but no names: the iOS bundle has no mobileconfig_res/ folder at all, and the Android APK ships an empty name table. Names only exist after the app itself runs a param-list request and writes them to disk. Step 1 checks whether that is possible on this build; step 2 attempts it. Both are read-only diagnostics until step 2, which moves any existing file aside and restores it if nothing new is written. A signed-in session is required."),
			@"rows": @[
				[SCISetting menuCellWithTitle:SCILocalized(@"Unit")
					subtitle:SCILocalized(@"Which config table to ask for")
					menu:[self menus][@"sci_idnamemap_unit"]],
				// The stepper prints its value INTO the subtitle via
				// -formatString:withValue:label:singularLabel:, so the subtitle
				// must carry the two %@ placeholders — without them the row shows
				// bare +/- buttons and no number at all.
				[SCISetting stepperCellWithTitle:SCILocalized(@"Request timeout")
					subtitle:SCILocalized(@"Give up after %@ %@")
					defaultsKey:@"sci_idnamemap_timeout"
					min:5 max:120 step:5 label:@"seconds" singularLabel:@"second"],
				[SCISetting stepperCellWithTitle:SCILocalized(@"Request mode")
					subtitle:SCILocalized(@"Using mode %@%@ — mode 1 is the one that writes names")
					defaultsKey:@"sci_idnamemap_mode"
					min:0 max:3 step:1 label:@"" singularLabel:@""],

				({ SCISetting *setting = [SCISetting buttonCellWithTitle:SCILocalized(@"1 · Check what's possible")
					subtitle:SCILocalized(@"Which pieces of the native config stack are reachable on this build")
					icon:[SCISymbol symbolWithName:@"checkmark.shield"]
					action:^{
						SCIIdNameMapPresentReport(SCILocalized(@"Setup check"),
							[SCIIdNameMapGenerator wiringState]);
					}];
					setting.dynamicValueText = ^NSString *{ return [SCIIdNameMapGenerator wiringSummary]; };
					setting; }),

				({ SCISetting *setting = [SCISetting buttonCellWithTitle:SCILocalized(@"2 · Generate names")
					subtitle:SCILocalized(@"Asks Instagram's own config manager for the name list and waits for it to be written")
					icon:[SCISymbol symbolWithName:@"square.and.arrow.down"]
					action:^{
						[SCIUtils showToastForDuration:2.0
							title:SCILocalized(@"Requesting name list…")
							subtitle:SCILocalized(@"Up to the timeout above")];
						[SCIIdNameMapGenerator generateForUnit:SCIIdNameMapSelectedUnit()
													   timeout:SCIIdNameMapTimeout()
														  mode:SCIIdNameMapMode()
													completion:^(NSString *report) {
							SCIIdNameMapPresentReport(SCILocalized(@"Generate"), report);
						}];
					}];
					setting.whatsNewID = @"dev_idnamemap";
					setting; }),

				({ SCISetting *setting = [SCISetting buttonCellWithTitle:SCILocalized(@"3 · Current file")
					subtitle:SCILocalized(@"Where it is, how big, how many configs and params it names")
					icon:[SCISymbol symbolWithName:@"doc.text.magnifyingglass"]
					action:^{
						SCIIdNameMapPresentReport(SCILocalized(@"Mapping file"),
							[SCIIdNameMapGenerator mappingFileState]);
					}];
					setting.dynamicValueText = ^NSString *{ return [SCIIdNameMapGenerator shortStatus]; };
					setting; }),

				[SCISetting buttonCellWithTitle:SCILocalized(@"Share the file")
					subtitle:SCILocalized(@"Send id_name_mapping.json out of the app")
					icon:[SCISymbol symbolWithName:@"square.and.arrow.up"]
					action:^{ SCIIdNameMapExport(); }],

				[SCISetting navigationCellWithTitle:SCILocalized(@"Advanced")
					subtitle:SCILocalized(@"Manual steps — only useful when step 2 fails")
					icon:[SCISymbol symbolWithName:@"wrench.and.screwdriver"]
					navSections:@[
						@{
							@"header": SCILocalized(@"Manual steps"),
							@"footer": SCILocalized(@"Step 2 already runs all of these in order — use them one at a time to see which one fails.\n\nReinstall the network fetcher: Instagram creates a network component at launch and hands it to the config manager. It is captured on the way through and put back here. Without it the manager has no way to send anything, and the request returns instantly having done nothing.\n\nInspect fetcher wiring: reports whether the app left a hook to reattach that component automatically after the manager is rebuilt. On this build it did not — which is why the reinstall above is manual.\n\nRebuild the manager: throws the current config manager away and asks Instagram for a new one. The number it returns is Instagram's own status code, not a result. With no rebuild hooks present this changes nothing useful."),
							@"rows": @[
								[SCISetting buttonCellWithTitle:SCILocalized(@"Reinstall the network fetcher")
									subtitle:SCILocalized(@"Puts the captured fetcher back on the live manager")
									icon:[SCISymbol symbolWithName:@"bolt.horizontal"]
									action:^{
										SCIIdNameMapPresentReport(SCILocalized(@"Fetcher"),
											[SCIIdNameMapGenerator reinstallFetcherForUnit:SCIIdNameMapSelectedUnit()]);
									}],
								[SCISetting buttonCellWithTitle:SCILocalized(@"Inspect fetcher wiring")
									subtitle:SCILocalized(@"Whether the app left a hook to reattach the fetcher automatically")
									icon:[SCISymbol symbolWithName:@"link"]
									action:^{
										SCIIdNameMapPresentReport(SCILocalized(@"Fetcher wiring"),
											[SCIIdNameMapGenerator rebindFetcherForUnit:SCIIdNameMapSelectedUnit()]);
									}],
								[SCISetting buttonCellWithTitle:SCILocalized(@"Rebuild the manager")
									subtitle:SCILocalized(@"Discards the current config manager and reports the status code")
									icon:[SCISymbol symbolWithName:@"arrow.clockwise"]
									action:^{
										SCIIdNameMapPresentReport(SCILocalized(@"Rebuild"),
											[SCIIdNameMapGenerator reloadUnit:SCIIdNameMapSelectedUnit()
																	  timeout:SCIIdNameMapTimeout()]);
									}],
							]
						}
					]],
			]
		},
				@{
			@"header": SCILocalized(@"Runtime"),
			@"footer": SCILocalized(@"The ObjC index includes supported BOOL methods with zero or one object/integer argument; GraphQL dogfood uses exact typed hooks instead of a global status hook."),
			@"rows": @[
				[SCISetting navigationCellWithTitle:SCILocalized(@"Unified Runtime Browser")
					subtitle:SCILocalized(@"Exec + FBShared: ObjC, C, DATA and Swift/xrefs")
					icon:[SCISymbol symbolWithIGName:@"bcn_code_outline_24" fallback:@"square.grid.2x2"]
					viewController:[[SCISymbolsBrowserViewController alloc] initWithMode:SCICSymbolsBrowserModeObjCMethods]],
				[SCISetting navigationCellWithTitle:@"IGDSLauncherConfig"
					subtitle:@""
					icon:[SCISymbol symbolWithName:@"wand.and.stars"]
					viewController:[SCIIGDSLauncherConfigViewController new]],
				[SCISetting navigationCellWithTitle:@"MobileConfig Overrides"
					subtitle:@"Browse every config/param by name; toggle overrides, export mc_overrides.json"
					icon:[SCISymbol symbolWithName:@"slider.horizontal.3"]
					viewController:[SCIMCBrowserListController new]],
			]
		},
		@{
			@"header": SCILocalized(@"Advanced experimental features"),
			@"rows": @[
				[self experimentalEntryCell],
				({ SCISetting *setting = [SCISetting switchCellWithTitle:SCILocalized(@"Status Bar Old School") subtitle:@"" defaultsKey:@"sci_statusbar_oldschool" requiresRestart:NO]; setting.icon = [SCISymbol symbolWithName:@"statusbar_oldschool" color:UIColor.labelColor]; setting; }),
				({ SCISetting *setting = [SCISetting switchCellWithTitle:SCILocalized(@"Stories Tray") subtitle:@"" defaultsKey:@"sci_story_tray" requiresRestart:NO]; setting.icon = [SCISymbol symbolWithName:@"story_tray" color:UIColor.labelColor]; setting; }),
				({ SCISetting *setting = [SCISetting menuCellWithTitle:SCILocalized(@"Custom Feed Header") subtitle:@"" menu:[self menus][@"ig_wordmark_variant"]]; setting.icon = [SCISymbol symbolWithName:@"custom_feed_header" color:UIColor.labelColor]; setting; }),
			]
		}
	]];
}

@end
