#import "SCISettingsSections.h"
#import "../SCIDogfoodBrowserViewController.h"
#import "../SCIGatingCatalogViewController.h"
#import "../SCIInternalActionsViewController.h"
#import "../../Features/Dogfooding/SCIInternalSettingsApplier.h"
#import "../../Features/Dogfooding/SCIInternalMenusLauncher.h"
#import "../SCISymbolsBrowserViewController.h"
#import "../SCIIGDSLauncherConfigViewController.h"

@implementation SCITweakSettings (Section_Advanced)

+ (SCISetting *)advancedNavCell {
	return [SCISetting navigationCellWithTitle:SCILocalized(@"Advanced")
										   subtitle:@""
											   icon:[SCISymbol symbolWithIGName:@"toolbox" fallback:@"gearshape.2"]
										navSections:@[@{
											@"header": SCILocalized(@"Notifications"),
											@"footer": SCILocalized(@"Suppresses the second notification IG enqueues in-app while the notification extension is also delivering it."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Fix duplicate notifications") subtitle:SCILocalized(@"Prevents two banners for the same message when IG is in the foreground") defaultsKey:@"sci_fix_duplicate_notifications"],
											]
										},
										@{
											@"header": SCILocalized(@"Tweak settings"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable tweak settings quick-access") subtitle:SCILocalized(@"Hold on the home tab to open RyukGram settings") defaultsKey:@"settings_shortcut" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Show tweak settings on app launch") subtitle:SCILocalized(@"Automatically opens settings when the app launches") defaultsKey:@"tweak_settings_app_launch"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Pause playback when opening settings") subtitle:SCILocalized(@"Pauses any playing video/audio when settings opens") defaultsKey:@"settings_pause_playback"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Always show what's new") subtitle:SCILocalized(@"Keep the blue dot on every new feature instead of clearing it once viewed") defaultsKey:@"whatsnew_always_show"],
											]
										},
										@{
											@"header": SCILocalized(@"Cache"),
											@"footer": SCILocalized(@"Clearing still scans on demand."),
											@"rows": @[
												[self clearCacheButtonCell],
												[self autoClearCacheMenuCell],
												[self autoCheckCacheSizeCell],
												[self preserveMessagesDBCell],
											]
										},
										@{
											@"header": SCILocalized(@"Instagram"),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable safe mode") subtitle:SCILocalized(@"Prevents Instagram from resetting settings after crashes (at your own risk)") defaultsKey:@"disable_safe_mode"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide TestFlight popup") subtitle:SCILocalized(@"Suppresses the \"It's time to update Instagram Beta\" nag") defaultsKey:@"hide_testflight_nag" requiresRestart:YES],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Reset onboarding state")
																		   subtitle:@""
																			   icon:[SCISymbol symbolWithIGName:@"bcn_arrow-ccw_outline_24" fallback:@"arrow.counterclockwise.circle"]
																			 action:^(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SCInstaFirstRun"]; [SCIUtils showRestartConfirmation];}
												],
											]
										},
										@{
											@"header": SCILocalized(@"IG-only/debug gates"),
											@"footer": SCILocalized(@"These hook real BOOL getters and safe imported C BOOL gates confirmed in Instagram metadata. Restart Instagram after changing them. Action/update functions are intentionally not fishhooked because they crash at launch."),
												@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"★ Internal & Dogfood Menus") subtitle:SCILocalized(@"Persists ON/OFF. Applies only when switched ON inside Settings; never auto-runs during launch.") defaultsKey:@"sci_internal_menus" requiresRestart:NO],
													[SCISetting switchCellWithTitle:SCILocalized(@"Internal hook crash guard") subtitle:SCILocalized(@"Auto-disables active internal gates if the previous launch crashed before becoming stable") defaultsKey:@"sci_internal_gate_crash_guard_enabled" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Force all IG-only/debug ObjC gates") subtitle:SCILocalized(@"Master switch for isEmployee, internal badges, launch debug info and story debug underlay") defaultsKey:@"sci_force_ig_internal_employee" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"★ Force ALL MobileConfig gates") subtitle:SCILocalized(@"sci_force_all_mc_gates — master único para TODOS: IGMobileConfigBooleanValueForInternalUse, EasyGating, MCIExperimentCache, MSGCSessioned. Sem restart.") defaultsKey:@"sci_force_all_mc_gates" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all MobileConfig BOOL gates") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_all" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"MobileConfig internal-use BOOL") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_boolean" requiresRestart:NO],
													[SCISetting switchCellWithTitle:SCILocalized(@"Instagram internal apps installed") subtitle:@"" defaultsKey:@"sci_force_ig_internal_apps_installed_after_ios18" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Minos dogfood MEK encryption") subtitle:@"" defaultsKey:@"sci_force_minos_dogfood_mek_encryption" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"IGFacebookUserInfo.isEmployee") subtitle:@"" defaultsKey:@"sci_force_ig_is_employee" requiresRestart:NO],
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
											@"footer": SCILocalized(@"Hooks BOOL-returning EasyGating C functions exported by FBSharedFramework and imported by Instagram via GOT (fishhook — sideload safe). Master switch ativa os 4 simultaneamente. Individual para diagnóstico granular. Confirme nos logs: [SCIGate] EasyGate rebind_symbols=0."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all EasyGating BOOL gates") subtitle:@"" defaultsKey:@"sci_force_easy_gating_all" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — Internal DoNotUseOrMock") subtitle:@"" defaultsKey:@"sci_force_easy_gating_internal" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — Platform") subtitle:SCILocalized(@"EasyGatingPlatformGetBoolean (implementação central)") defaultsKey:@"sci_force_easy_gating_platform" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — AuthDataContext") subtitle:SCILocalized(@"EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock") defaultsKey:@"sci_force_easy_gating_auth" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"EasyGating — MCQ dispatch") subtitle:SCILocalized(@"MCQEasyGatingGetBooleanInternalDoNotUseOrMock (dispatch por int32 jump-table)") defaultsKey:@"sci_force_easy_gating_mcq" requiresRestart:NO],
											]
										},
										@{
											@"header": SCILocalized(@"Sessioned/MCI MobileConfig BOOL gates (FBSharedFramework)"),
											@"footer": SCILocalized(@"fishhook de 3 gates BOOL do FBShared importados pelo Instagram. Symbols Browser classifica como \'candidate: no\' por heurístico — disasm confirma retorno BOOL. MCIExperiment chama MCIExtension como tail-call."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all Sessioned/MCI BOOL gates") subtitle:SCILocalized(@"Master: MSGCSessionedMobileConfigGetBoolean + MCIExperiment + MCIExtension") defaultsKey:@"sci_force_sessioned_mc_all" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"MSGCSessionedMobileConfigGetBoolean") subtitle:SCILocalized(@"Gate booleano ligado à sessão de usuário (MSGC)") defaultsKey:@"sci_force_msgc_sessioned_boolean" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExtensionExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Helper interno do MCIExperiment") defaultsKey:@"sci_force_mci_extension_boolean" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Entry point externo do cache de experimento") defaultsKey:@"sci_force_mci_experiment_boolean" requiresRestart:NO],
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
														NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
														NSArray *d = [ud arrayForKey:@"sci_internal_gate_crash_disabled_keys"] ?: @[];
														for (NSString *key in d) [ud setBool:YES forKey:key];
														[ud removeObjectForKey:@"sci_internal_gate_crash_pending_keys"];
														[ud removeObjectForKey:@"sci_internal_gate_crash_disabled_keys"];
														[ud removeObjectForKey:@"sci_internal_gate_crash_last_source"];
														NSString *msg = d.count ? [NSString stringWithFormat:@"Restored %lu gate(s):\n%@",(unsigned long)d.count,[d componentsJoinedByString:@"\n"]] : @"No disabled gates. Guard cleared.";
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
												[SCISetting switchCellWithTitle:SCILocalized(@"Show Internal Settings menu") subtitle:SCILocalized(@"Forces showInternalSettings=YES in IGBugReportMenuViewController (shake-to-report menu). Shake device to open it.") defaultsKey:@"sci_force_internal_settings_menu" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"\u2514 also when logged out") subtitle:SCILocalized(@"Also forces showLoggedOutInternalSettings=YES") defaultsKey:@"sci_force_internal_settings_loggedout" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Auto-apply on launch (native)") subtitle:SCILocalized(@"Re-applies a few seconds after login") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable debug footer") subtitle:SCILocalized(@"Gateway to internal/debug menus (applied by the button above)") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force Bloks experience ON") subtitle:SCILocalized(@"setForceBloksExperienceOn") defaultsKey:@"sci_apply_force_bloks" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Bloks prefetch ON") subtitle:SCILocalized(@"setBloksPrefetchEnabledWithEnabled:") defaultsKey:@"sci_apply_bloks_prefetch" requiresRestart:YES],
											]
										},
										@{
											@"header": SCILocalized(@"Open internal menus (direct, live session)"),
											@"footer": SCILocalized(@"Presents Instagram\u2019s own internal/dogfooding screens via validated class-method entrypoints using the live user session. Open after you are logged in. The VC/URL routes are best-effort and depend on the IG build."),
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
												[SCISetting buttonCellWithTitle:SCILocalized(@"Open internal URL\u2026")
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
											@"footer": SCILocalized(@"Exports ALL Mach-O C symbols from the selected image — including IGMobileConfigBoolean*, EasyGating*, and other C functions FLEX cannot show. Blue = Bool gating candidate. Tap a row to copy name+address."),
											@"rows": @[
												[SCISetting navigationCellWithTitle:SCILocalized(@"Symbols Browser")
																							   subtitle:SCILocalized(@"All exported C symbols from Instagram / FBSharedFramework")
																							      icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"function"]
																						viewController:[SCISymbolsBrowserViewController new]],
											]
										},
										@{
											@"header": SCILocalized(@"Advanced experimental features"),
											@"footer": SCILocalized(@"Toggle hidden Instagram experiments. StatusBarOldSchool and StoryTray take effect at next launch via SCIRuntimeBoolForce (safe, constant block). No restart needed for live session; full effect on next cold launch."),
											@"rows": @[
												[self experimentalEntryCell],

											[SCISetting switchCellWithTitle:SCILocalized(@"Status Bar Old School")
															   subtitle:@""
															defaultsKey:@"sci_statusbar_oldschool"
														requiresRestart:NO],
											[SCISetting switchCellWithTitle:SCILocalized(@"Story Tray")
															   subtitle:@""
															defaultsKey:@"sci_story_tray"
														requiresRestart:NO],
											[SCISetting menuCellWithTitle:SCILocalized(@"Instagram wordmark")
													 subtitle:@""
													     menu:[self menus][@"ig_wordmark_variant"]],

													[SCISetting navigationCellWithTitle:SCILocalized(@"IGDSLauncherConfig")
									   subtitle:@""
									       icon:[SCISymbol symbolWithName:@"wand.and.stars"]
									viewController:[SCIIGDSLauncherConfigViewController new]],
								[SCISetting navigationCellWithTitle:SCILocalized(@"Dogfood & Internal Browser") subtitle:SCILocalized(@"Runtime stubs, live IGUserSession objects, dogfood actions and native internal setters") icon:[SCISymbol symbolWithName:@"pawprint"] viewController:[SCIDogfoodBrowserViewController new]],
								[SCISetting navigationCellWithTitle:SCILocalized(@"Internal Actions") subtitle:SCILocalized(@"Live IGUserSession actions, IGFacebookUserInfo.isEmployee, Notes dogfood and native Autofill setters") icon:[SCISymbol symbolWithName:@"switch.2"] viewController:[SCIInternalActionsViewController new]],
				[SCISetting navigationCellWithTitle:SCILocalized(@"Feature Gatings") subtitle:SCILocalized(@"Browse named gating/experiment/config BOOL accessors and force values by hooking the getter directly.") icon:[SCISymbol symbolWithName:@"switch.2"] viewController:[SCIGatingCatalogViewController new]],
											]
										}]
				];
}

@end
