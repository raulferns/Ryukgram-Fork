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
#import "../SCIInternalActionsViewController.h"
#import "../SCISymbolBrowserViewController.h"
#import "../SCICSymbolBrowserViewController.h"
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
													[SCISetting switchCellWithTitle:SCILocalized(@"Force all IG-only/debug ObjC gates") subtitle:SCILocalized(@"Master switch for isEmployee, internal badges, launch debug info and story debug underlay") defaultsKey:@"sci_force_ig_internal_employee" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"★ Force ALL MobileConfig gates") subtitle:SCILocalized(@"sci_force_all_mc_gates — master único para IGMobileConfig, EasyGating, MCIExperimentCache, MSGCSessioned. Requer restart.") defaultsKey:@"sci_force_all_mc_gates" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all MobileConfig BOOL gates") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_all" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MobileConfig internal-use BOOL") subtitle:@"" defaultsKey:@"sci_force_mc_internal_use_boolean" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MobileConfig read inventory (diagnostic)") subtitle:SCILocalized(@"sci_mc_adapter_diag — não força nada; chama orig e registra cada call site (caller offset) em Documents/sci_mobileconfig_adapter_diag.csv. Use para mapear ID↔feature. Requer restart.") defaultsKey:@"sci_mc_adapter_diag" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Instagram internal apps installed") subtitle:SCILocalized(@"Uses the exported installed-internal-apps symbol when available; requires restart.") defaultsKey:@"sci_force_ig_internal_apps_installed_after_ios18" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Minos dogfood MEK encryption") subtitle:@"" defaultsKey:@"sci_force_minos_dogfood_mek_encryption" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"IGAdPlatformLogger.isEmployee") subtitle:SCILocalized(@"Validated class: IGAdPlatformLogger_objc") defaultsKey:@"sci_force_ig_is_employee" requiresRestart:NO],
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
											@"footer": SCILocalized(@"Hooks BOOL-returning EasyGating C functions exported by FBSharedFramework and imported by Instagram via GOT. Flags are read once in %ctor; restart required."),
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
											@"footer": SCILocalized(@"fishhook de 3 gates BOOL do FBShared importados pelo Instagram. Flags são lidas uma vez no %ctor e exigem restart. MCIExperiment chama MCIExtension como tail-call."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Force all Sessioned/MCI BOOL gates") subtitle:SCILocalized(@"Master: MSGCSessionedMobileConfigGetBoolean + MCIExperiment + MCIExtension") defaultsKey:@"sci_force_sessioned_mc_all" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MSGCSessionedMobileConfigGetBoolean") subtitle:SCILocalized(@"Gate booleano ligado à sessão de usuário (MSGC)") defaultsKey:@"sci_force_msgc_sessioned_boolean" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExtensionExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Helper interno do MCIExperiment") defaultsKey:@"sci_force_mci_extension_boolean" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"MCIExperimentCacheGetMobileConfigBoolean") subtitle:SCILocalized(@"Entry point externo do cache de experimento") defaultsKey:@"sci_force_mci_experiment_boolean" requiresRestart:YES],
											]
										},

											@{
												@"header": SCILocalized(@"IGPlus"),
												@"footer": SCILocalized(@"Submenu dedicado dos gates de IGPlus (codinome interno \"Aura\"). Veja o diagnostico no Dogfood se um gate nao surtir efeito."),
												@"rows": @[
													[SCISetting navigationCellWithTitle:SCILocalized(@"★ IGPlus / Aura unlock")
																		   subtitle:SCILocalized(@"Todos os gates do IGConsumerSubsService")
																			   icon:nil
																	navSections:@[
														@{
															@"header": SCILocalized(@"Master"),
															@"footer": SCILocalized(@"Primeiro enable a partir de um launch all-off precisa de relaunch (o grupo instala no construtor)."),
															@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"★ Force all IGPlus benefits") subtitle:SCILocalized(@"Master: todos os getters de benefit do IGConsumerSubsService + eligibility helpers") defaultsKey:@"sci_force_igplus_all" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"IGPlus eligibility/data-provider") subtitle:SCILocalized(@"SUBSBenefitDataProvider + peek/chat eligibility") defaultsKey:@"sci_igplus_eligibility" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"★ Force eligibility HELPERS (agressivo)") subtitle:SCILocalized(@"Hooka os class-methods de elegibilidade (isUpsellEligible..., isAuraQuietPosting..., isChatPeek...) que o IG consulta via Swift direct dispatch. Caminho que o MSHookMessageEx no service nao pega. Requer restart.") defaultsKey:@"sci_igplus_force_eligibility_helpers" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"IGPlus access") subtitle:SCILocalized(@"hasAccessToIGPlus") defaultsKey:@"sci_igplus_has_access" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Any active benefit") subtitle:SCILocalized(@"hasAnyActiveBenefit") defaultsKey:@"sci_igplus_any_active" requiresRestart:YES]
															]
														},
														@{
															@"header": SCILocalized(@"Individual benefits"),
															@"rows": @[
													[SCISetting switchCellWithTitle:SCILocalized(@"Custom Lists") subtitle:@"" defaultsKey:@"sci_igplus_custom_lists" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Superlikes") subtitle:@"" defaultsKey:@"sci_igplus_story_superlikes" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Search Story Viewers") subtitle:@"" defaultsKey:@"sci_igplus_search_story_viewers" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Extend") subtitle:@"" defaultsKey:@"sci_igplus_story_extend" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Rewatch") subtitle:@"" defaultsKey:@"sci_igplus_story_rewatch" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Peeks") subtitle:@"" defaultsKey:@"sci_igplus_story_peeks" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Spotlight") subtitle:@"" defaultsKey:@"sci_igplus_story_spotlight" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Silent Post to Highlights") subtitle:@"" defaultsKey:@"sci_igplus_silent_post_highlights" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Direct Message Peek") subtitle:@"" defaultsKey:@"sci_igplus_dm_peek" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Custom App Icon") subtitle:@"" defaultsKey:@"sci_igplus_custom_app_icon" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Branded Threads") subtitle:@"" defaultsKey:@"sci_igplus_branded_threads" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Timestamp Viewers List") subtitle:@"" defaultsKey:@"sci_igplus_timestamp_viewers" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Custom Bio Font") subtitle:@"" defaultsKey:@"sci_igplus_custom_bio_font" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Silent Post to Profile") subtitle:@"" defaultsKey:@"sci_igplus_silent_post_profile" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Pinned Posts Increased Limit") subtitle:@"" defaultsKey:@"sci_igplus_pinned_posts_limit" requiresRestart:YES],
													[SCISetting switchCellWithTitle:SCILocalized(@"Story Peek Active") subtitle:@"" defaultsKey:@"sci_igplus_story_peek_active" requiresRestart:YES]
															]
														}
													]]
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
												[SCISetting switchCellWithTitle:SCILocalized(@"└ also when logged out") subtitle:SCILocalized(@"Also forces showLoggedOutInternalSettings=YES") defaultsKey:@"sci_force_internal_settings_loggedout" requiresRestart:NO],
												[SCISetting switchCellWithTitle:SCILocalized(@"Auto-apply on launch (native)") subtitle:SCILocalized(@"Re-applies a few seconds after login") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Enable debug footer") subtitle:SCILocalized(@"Gateway to internal/debug menus (applied by the button above)") defaultsKey:@"sci_apply_internal_native" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Force Bloks experience ON") subtitle:SCILocalized(@"setForceBloksExperienceOn") defaultsKey:@"sci_apply_force_bloks" requiresRestart:YES],
												[SCISetting switchCellWithTitle:SCILocalized(@"Bloks prefetch ON") subtitle:SCILocalized(@"setBloksPrefetchEnabledWithEnabled:") defaultsKey:@"sci_apply_bloks_prefetch" requiresRestart:YES],
											]
										},
										@{
											@"header": SCILocalized(@"Open internal menus (direct, live session)"),
											@"footer": SCILocalized(@"Apenas entrypoints onde o IG constroi o VC (seguros contra trap do Swift). Precisam de sessao ativa (abra apos o login). Os menus que exigiam construir VC Swift foram removidos porque um cast falho do Swift e um trap que nenhum @try segura."),
											@"rows": @[
												[SCISetting buttonCellWithTitle:SCILocalized(@"★ Best available (cascade)")
													   subtitle:SCILocalized(@"Tenta Notes → DogfoodVC → URL handler (so caminhos seguros)")
													       icon:[SCISymbol symbolWithName:@"wrench.and.screwdriver"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openBestAvailableInternalMenu];
														if ([r hasPrefix:@"opened"]||[r hasPrefix:@"pushed"]||[r hasPrefix:@"presented"]) return;
														UIWindow *w=nil; for(UIScene *sc in UIApplication.sharedApplication.connectedScenes){if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break;}
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menus") message:r preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Notes dogfooding settings")
													   subtitle:SCILocalized(@"notesDogfoodingSettingsOpenOnViewController:userSession: — confiavel")
													       icon:[SCISymbol symbolWithName:@"note.text"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openDogfoodingNotesSettings];
														if ([r hasPrefix:@"opened"]||[r hasPrefix:@"pushed"]||[r hasPrefix:@"presented"]) return;
														UIWindow *w=nil; for(UIScene *sc in UIApplication.sharedApplication.connectedScenes){if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break;}
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menus") message:r preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Dogfooding Settings VC")
													   subtitle:SCILocalized(@"openWithConfig:onViewController:userSession: (precisa de config capturado — ative employee gate antes)")
													       icon:[SCISymbol symbolWithName:@"dog.fill"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openDogfoodingSettingsVC];
														if ([r hasPrefix:@"opened"]||[r hasPrefix:@"pushed"]||[r hasPrefix:@"presented"]) return;
														UIWindow *w=nil; for(UIScene *sc in UIApplication.sharedApplication.connectedScenes){if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break;}
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menus") message:r preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}],
												[SCISetting buttonCellWithTitle:SCILocalized(@"URL handler: instagram://internal_settings")
													   subtitle:SCILocalized(@"IGURLHandler openInternalURL: — fallback")
													       icon:[SCISymbol symbolWithName:@"link"]
													     action:^(void) {
														NSString *r = [SCIInternalMenusLauncher openInternalURLString:@"instagram://internal_settings"];
														if ([r hasPrefix:@"opened"]||[r hasPrefix:@"pushed"]||[r hasPrefix:@"presented"]) return;
														UIWindow *w=nil; for(UIScene *sc in UIApplication.sharedApplication.connectedScenes){if([sc isKindOfClass:UIWindowScene.class]) for(UIWindow *win in((UIWindowScene*)sc).windows) if(win.isKeyWindow){w=win;break;} if(w)break;}
														UIViewController *top=w.rootViewController; while(top.presentedViewController) top=top.presentedViewController;
														UIAlertController *a=[UIAlertController alertControllerWithTitle:SCILocalized(@"Internal menus") message:r preferredStyle:UIAlertControllerStyleAlert];
														[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
														if(top)[top presentViewController:a animated:YES completion:nil];
													}]
											]
										},
										@{
											@"header": SCILocalized(@"Runtime"),
											@"footer": SCILocalized(@"Browses classes in the selected loaded image. Search scans the full cached class index and BOOL getter names; no 80-row cap."),
											@"rows": @[
												[SCISetting navigationCellWithTitle:SCILocalized(@"Instagram (exec) Browser")
							   subtitle:SCILocalized(@"Classes in the Instagram binary → hookable BOOL getters. Toggle shows the live value (IG default + your override) and forces it.")
								   icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"function"]
							viewController:[[SCISymbolBrowserViewController alloc] initWithImage:SCISymbolImageInstagram]],
								[SCISetting navigationCellWithTitle:SCILocalized(@"FBSharedFramework Browser")
							   subtitle:SCILocalized(@"Classes in FBSharedFramework → hookable BOOL getters, live state, force toggles.")
								   icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"shippingbox"]
							viewController:[[SCISymbolBrowserViewController alloc] initWithImage:SCISymbolImageFBShared]],
				[SCISetting navigationCellWithTitle:SCILocalized(@"C Symbols Browser (MobileConfig / EasyGating)")
					   subtitle:SCILocalized(@"Readers C importados do FBSharedFramework (hookados por fishhook). Liga forcing, captura IDs em tempo real e forca por simbolo ou por ID. Caminho para o internal settings gate.")
						icon:[SCISymbol symbolWithIGName:@"bcn_link_outline_24" fallback:@"terminal"]
					viewController:[[SCICSymbolBrowserViewController alloc] init]]
											]
										},
										@{
											@"header": SCILocalized(@"Advanced experimental features"),
											@"footer": SCILocalized(@"Toggle hidden Instagram experiments. StatusBarOldSchool and StoryTray take effect at next launch via SCIRuntimeBoolForce (safe, constant block). No restart needed for live session; full effect on next cold launch."),
											@"rows": @[

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
											]
						}
				]];
}

@end
