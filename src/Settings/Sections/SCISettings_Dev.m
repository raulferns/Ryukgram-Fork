// SCISettings_Dev.m — RyukGram "Dev" menu.
//
// All Instagram-internal / dogfood / gating / runtime-browser tooling lives
// here, split out of Advanced. Brought over from the experiments2 branch and
// re-based onto priv-main's hook/persistence/backup conventions.
//
// Persistence: every toggle writes a plain NSUserDefaults BOOL via SCISetting's
// defaultsKey (same path priv-main's backup system serialises). Force-apply and
// runtime browsing are driven by the Features/{Dogfooding,EasyGating,Gating,
// MobileConfig} units, all gated so nothing heavy runs during launch.

#import "SCISettingsSections.h"
#import "../SCIDogfoodBrowserViewController.h"
#import "../SCISymbolBrowserViewController.h"
#import "../SCISymbolsBrowserViewController.h"
#import "../SCIIGDSLauncherConfigViewController.h"
#import "../../Features/Dogfooding/SCIInternalSettingsApplier.h"
#import "../../Features/Dogfooding/SCIInternalMenusLauncher.h"
#import "../../Features/Dogfooding/SCIInternalGatePrefs.h"


@implementation SCITweakSettings (Section_Dev)

+ (SCISetting *)devNavCell {
	return [SCISetting navigationCellWithTitle:SCILocalized(@"Dev")
									   subtitle:@""
										   icon:[SCISymbol symbolWithIGName:@"wrench" fallback:@"hammer"]
									navSections:@[
										@{
											@"header": SCILocalized(@"IG-only/debug gates"),
											@"footer": SCILocalized(@"ObjC BOOL getters apply live. Imported C gates use fishhook with flags latched once in %ctor, so C-gate rows require restart."),
												@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"★ Internal & Dogfood Menus") subtitle:SCILocalized(@"Persists ON/OFF. Applies only when switched ON inside Settings; never auto-runs during launch.") defaultsKey:@"sci_internal_menus" requiresRestart:NO],
													[SCISetting switchCellWithTitle:SCILocalized(@"Internal hook crash guard") subtitle:SCILocalized(@"Auto-disables active internal gates if the previous launch crashed before becoming stable") defaultsKey:@"sci_internal_gate_crash_guard_enabled" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Force all IG-only/debug ObjC gates") subtitle:SCILocalized(@"Badges internos, launch debug info e story debug underlay (isEmployee agora fica no toggle Employee / Internal acima)") defaultsKey:@"sci_force_ig_internal_employee" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"★ Force ALL MobileConfig gates") subtitle:SCILocalized(@"Master legacy agora só cobre IGMobileConfig bool, iOS18 internal apps e Minos; EasyGating/MCI/MSGC usam seus próprios toggles para evitar crash em lote.") defaultsKey:@"sci_force_all_mc_gates" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all MobileConfig BOOL gates") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_all" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MobileConfig internal-use BOOL") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_boolean" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Instagram internal apps installed") subtitle:SCILocalized(@"Uses the exported installed-internal-apps symbol when available; requires restart.") defaultsKey:@"sci_force_ig_internal_apps_installed_after_ios18" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Minos dogfood MEK encryption") subtitle:@"" defaultsKey:@"sci_force_minos_dogfood_mek_encryption" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"★ Employee / Internal") subtitle:SCILocalized(@"Um toggle (estilo FBTweak): força isEmployee (ObjC+Swift), os C gates ig_is_employee/ig_is_employee_or_test_user (fishhook) e o init do bug reporter — as entradas internal/dogfood aparecem naturalmente. Requer restart.") defaultsKey:@"sci_employee_internal" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Internal settings menu") subtitle:SCILocalized(@"Força showInternalSettings + showShake no init do bug reporter (caminho separado do Employee, pra isolar o comportamento em runtime). Requer restart.") defaultsKey:@"sci_force_internal_settings_menu" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Internal settings (logged out)") subtitle:SCILocalized(@"Também força o showLoggedOutInternalSettings no mesmo init. Requer restart.") defaultsKey:@"sci_force_internal_settings_loggedout" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Override availability status") subtitle:SCILocalized(@"Sobrescreve o internalSettingsAvailabilityStatus (enum Swift) com o valor abaixo. O valor exato não pôde ser provado estaticamente — teste 1/2/3 ao vivo. Sob crash guard. Requer restart.") defaultsKey:@"sci_force_internal_settings_availability" requiresRestart:YES],
												[SCISetting stepperCellWithTitle:SCILocalized(@"Availability status value") subtitle:SCILocalized(@"internalSettingsAvailabilityStatus = %@%@") defaultsKey:@"sci_internal_settings_availability_value" min:0 max:5 step:1 label:@"" singularLabel:@""],
												[SCISetting switchCellWithTitle:SCILocalized(@"Persist employee defaults") subtitle:@"" defaultsKey:@"sci_force_employee_defaults_persist" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Featured internal badge") subtitle:@"" defaultsKey:@"sci_force_ig_featured_internal_badge" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Inbox internal badge") subtitle:@"" defaultsKey:@"sci_force_ig_inbox_internal_badge" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Creation internal label") subtitle:@"" defaultsKey:@"sci_force_ig_creation_internal_label" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Launch debug info") subtitle:@"" defaultsKey:@"sci_force_ig_launch_debug_info" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Launch debug info V2") subtitle:@"" defaultsKey:@"sci_force_ig_launch_debug_info_v2" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Story debug underlay") subtitle:@"" defaultsKey:@"sci_force_ig_story_debug_underlay" requiresRestart:NO],
											]
										},
										@{
											@"header": SCILocalized(@"EasyGating C gates (FBSharedFramework)"),
											@"footer": SCILocalized(@"Hard-stub via fishhook: o import ligado vira mov w0,#1; ret. Nenhum orig/defaults na hot path. Restart required."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all EasyGating BOOL gates") subtitle:@"" defaultsKey:@"sci_force_easy_gating_all" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — Internal DoNotUseOrMock") subtitle:@"" defaultsKey:@"sci_force_easy_gating_internal" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — Platform") subtitle:SCILocalized(@"EasyGatingPlatformGetBoolean") defaultsKey:@"sci_force_easy_gating_platform" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — AuthDataContext") subtitle:SCILocalized(@"EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock") defaultsKey:@"sci_force_easy_gating_auth" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — MCQ dispatch") subtitle:SCILocalized(@"MCQEasyGatingGetBooleanInternalDoNotUseOrMock") defaultsKey:@"sci_force_easy_gating_mcq" requiresRestart:YES],
											]
										},
										@{
											@"header": SCILocalized(@"Sessioned/MCI MobileConfig BOOL gates (FBSharedFramework)"),
											@"footer": SCILocalized(@"Hard-stub via fishhook: o import ligado retorna YES direto (mov w0,#1; ret). Use isoladamente; crash guard cobre estas keys."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all Sessioned/MCI BOOL gates") subtitle:SCILocalized(@"Master: MSGCSessionedMobileConfigGetBoolean + MCIExperiment + MCIExtension") defaultsKey:@"sci_force_sessioned_mc_all" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MSGCSessionedMobileConfigGetBoolean") subtitle:SCILocalized(@"Gate booleano ligado à sessão de usuário (MSGC)") defaultsKey:@"sci_force_msgc_sessioned_boolean" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExtensionExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Helper interno do MCIExperiment") defaultsKey:@"sci_force_mci_extension_boolean" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Entry point externo do cache de experimento") defaultsKey:@"sci_force_mci_experiment_boolean" requiresRestart:YES],
											]
										},

										@{
											@"header": SCILocalized(@"XPlugins"),
											@"footer": SCILocalized(@"XPlugins fica documentado, mas o hook direto não é compilado neste patch porque toca exatamente o caminho do watchdog visto no crash. Reative só isoladamente, em arquivo separado e nunca no launch."),
											@"rows": @[
												[SCISetting staticCellWithTitle:SCILocalized(@"XPlugins direct hook disabled")
																 subtitle:SCILocalized(@"The direct XPlugins hook is intentionally not exposed because the crash stack is in XPluginsGetListLookupDataPair / XPluginsGetDataPair during METARunPreApplicationMain.")
																     icon:[SCISymbol symbolWithName:@"exclamationmark.triangle"]],
											]
										},
										@{
											@"header": SCILocalized(@"Internal / Debug (native, live session)"),
											@"footer": SCILocalized(@"Uses the native IGAutofillInternalSettings setters on the live user session to enable the debug footer and internal experience (persists via sessionUserDefaults). Tap Apply after you are logged in; toggles take effect after applying/restart."),
											@"rows": @[
												[SCISetting buttonCellWithTitle:SCILocalized(@"⚠️ Reset crash guard → restore gates")
													   subtitle:SCILocalized(@"Restores gates auto-disabled after a crash. Tap after enabling toggles that were reset.")
													       icon:[SCISymbol symbolWithName:@"arrow.counterclockwise.circle"]
													     action:^(void) {
														NSArray *d = [NSUserDefaults.standardUserDefaults arrayForKey:@"sci_internal_gate_crash_disabled_keys"] ?: @[];
												NSDictionary *plans = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"sci_internal_gate_crash_disabled_runtime_plans"] ?: @{};
												[SCIInternalGatePrefs resetCrashGuardAndRestoreKeys];
												NSString *msg = (d.count || plans.count) ? [NSString stringWithFormat:@"Restored %lu gate(s) and %lu runtime patch plan(s):\n%@",(unsigned long)d.count,(unsigned long)plans.count,[d componentsJoinedByString:@"\n"]] : @"No disabled gates or runtime plans. Guard cleared.";
												UIWindow *w=nil; for(UIScene *sc in UIApplication.sharedApplication.connectedScenes){if([sc isKindOfClass:UIWindowScene.class])for(UIWindow *win in((UIWindowScene*)sc).windows)if(win.isKeyWindow){w=win;break;}if(w)break;}
														UIViewController *top=w.rootViewController; while(top.presentedViewController)top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Crash guard reset" message:msg preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Apply internal/debug now (native)")
													   subtitle:SCILocalized(@"Calls IGAutofillInternalSettings setters on the live session")
													       icon:[SCISymbol symbolWithIGName:@"bcn_wrench_outline_24" fallback:@"wrench.and.screwdriver"]
													     action:^(void) {
														NSString *r = [SCIInternalSettingsApplier applyNow];
														UIWindow *w=nil; for (UIScene *sc in UIApplication.sharedApplication.connectedScenes){ if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in ((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break; }
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Applied") message:r preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}
												],
												[SCISetting switchCellWithTitle:SCILocalized(@"Auto-apply on launch (native)") subtitle:SCILocalized(@"Re-applies a few seconds after login") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable debug footer") subtitle:SCILocalized(@"Gateway to internal/debug menus (applied by the button above)") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force Bloks experience ON") subtitle:SCILocalized(@"setForceBloksExperienceOn") defaultsKey:@"sci_apply_force_bloks" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Bloks prefetch ON") subtitle:SCILocalized(@"setBloksPrefetchEnabledWithEnabled:") defaultsKey:@"sci_apply_bloks_prefetch" requiresRestart:YES],
											]
										},
										@{
											@"header": SCILocalized(@"Open internal menus (direct, live session)"),
											@"footer": SCILocalized(@"Presents Instagram’s own internal/dogfooding screens via validated class-method entrypoints using the live user session. Open after you are logged in. The VC/URL routes are best-effort and depend on the IG build."),
											@"rows": @[
												[SCISetting buttonCellWithTitle:SCILocalized(@"Open Dogfooding/Notes settings")
													   subtitle:SCILocalized(@"Reliable entrypoint (no config needed)")
													       icon:[SCISymbol symbolWithIGName:@"bcn_settings_outline_24" fallback:@"gearshape"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openDogfoodingNotesSettings];
														UIWindow *w=nil; for (UIScene *sc in UIApplication.sharedApplication.connectedScenes){ if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in ((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break; }
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														if(![r hasPrefix:@"opened"] && ![r hasPrefix:@"presented"]){ UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menu") message:r preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; if(top)[top presentViewController:a animated:YES completion:nil]; }
													}
												],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Open Dogfooding Settings VC")
													   subtitle:SCILocalized(@"Best-effort: constructs the internal settings VC directly")
													       icon:[SCISymbol symbolWithIGName:@"toolbox" fallback:@"wrench.and.screwdriver"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openDogfoodingSettingsVC];
														UIWindow *w=nil; for (UIScene *sc in UIApplication.sharedApplication.connectedScenes){ if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in ((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break; }
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														if(![r hasPrefix:@"opened"] && ![r hasPrefix:@"presented"]){ UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menu") message:r preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; if(top)[top presentViewController:a animated:YES completion:nil]; }
													}
												],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Open internal URL…")
													   subtitle:SCILocalized(@"Routes via IGURLHandler internal URL opener")
													       icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"link"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openInternalURLString:@"instagram://internal_settings"];
														UIWindow *w=nil; for (UIScene *sc in UIApplication.sharedApplication.connectedScenes){ if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in ((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break; }
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														if(![r hasPrefix:@"opened"] && ![r hasPrefix:@"presented"]){ UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menu") message:r preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; if(top)[top presentViewController:a animated:YES completion:nil]; }
													}
												],
											]
										},
										@{
											@"header": SCILocalized(@"Runtime"),
											@"footer": SCILocalized(@"Browses classes in the selected loaded image. Search scans the full cached class index and BOOL getter names; no 80-row cap."),
											@"rows": @[
												[SCISetting navigationCellWithTitle:SCILocalized(@"Unified Runtime Browser")
							   subtitle:SCILocalized(@"Exec + FBShared in one Liquid Glass browser. Tabs: image scope and ObjC/C/DATA/Swift, with safe ABI-aware actions.")
							       icon:[SCISymbol symbolWithIGName:@"bcn_code_outline_24" fallback:@"square.grid.2x2"]
							viewController:[[SCISymbolsBrowserViewController alloc] initWithMode:SCICSymbolsBrowserModeObjCMethods]],
											]
										},
										@{
											@"header": SCILocalized(@"Advanced experimental features"),
											@"footer": SCILocalized(@"Toggle hidden Instagram experiments. StatusBarOldSchool and StoryTray take effect at next launch via SCIRuntimeBoolForce (safe, constant block). No restart needed for live session; full effect on next cold launch."),
											@"rows": @[
												[self experimentalEntryCell],

							({
								SCISetting *s = [SCISetting switchCellWithTitle:SCILocalized(@"Status Bar Old School")
																  subtitle:@""
															defaultsKey:@"sci_statusbar_oldschool"
														requiresRestart:NO];
								s.icon = [SCISymbol symbolWithName:@"statusbar_oldschool" color:UIColor.labelColor];
								s;
							}),
							({
								SCISetting *s = [SCISetting switchCellWithTitle:SCILocalized(@"Stories Tray")
																  subtitle:@""
															defaultsKey:@"sci_story_tray"
														requiresRestart:NO];
								s.icon = [SCISymbol symbolWithName:@"story_tray" color:UIColor.labelColor];
								s;
							}),
							({
								SCISetting *s = [SCISetting menuCellWithTitle:SCILocalized(@"Custom Feed Header")
						 subtitle:@""
						     menu:[self menus][@"ig_wordmark_variant"]];
							s.icon = [SCISymbol symbolWithName:@"custom_feed_header" color:UIColor.labelColor];
							s;
							}),

									[SCISetting navigationCellWithTitle:SCILocalized(@"IGDSLauncherConfig")
							   subtitle:@""
							       icon:[SCISymbol symbolWithName:@"wand.and.stars"]
							viewController:[SCIIGDSLauncherConfigViewController new]],
					[SCISetting navigationCellWithTitle:SCILocalized(@"Dogfood & Internal Browser") subtitle:SCILocalized(@"Runtime stubs, live IGUserSession objects, dogfood actions and native internal setters") icon:[SCISymbol symbolWithName:@"pawprint"] viewController:[SCIDogfoodBrowserViewController new]],
											]
						}
				]];
}

@end
