#import "SCISettingsSections.h"
#import "../SCISymbolsBrowserViewController.h"

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
											@"footer": SCILocalized(@"Instagram runs stock while this is on. Turn it back off to restore your settings."),
											@"rows": @[
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable safe mode") subtitle:SCILocalized(@"Prevents Instagram from resetting settings after crashes (at your own risk)") defaultsKey:@"disable_safe_mode"],
												[SCISetting switchCellWithTitle:SCILocalized(@"Hide TestFlight popup") subtitle:SCILocalized(@"Suppresses the \"It's time to update Instagram Beta\" nag") defaultsKey:@"hide_testflight_nag" requiresRestart:YES],
												[SCISetting buttonCellWithTitle:SCILocalized(@"Reset onboarding state")
																		   subtitle:@""
																			   icon:[SCISymbol symbolWithIGName:@"bcn_arrow-ccw_outline_24" fallback:@"arrow.counterclockwise.circle"]
																			 action:^(void) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SCInstaFirstRun"]; [SCIUtils showRestartConfirmation];}
												],
												[SCISetting switchCellWithTitle:SCILocalized(@"Disable all tweak options") subtitle:SCILocalized(@"Turn every feature off — your settings are kept") defaultsKey:@"sci_disable_all" requiresRestart:YES],
											]
										},
										@{
											@"header": SCILocalized(@"Advanced experimental features"),
											@"footer": SCILocalized(@"Toggle hidden Instagram experiments. Some may not work on every account or IG version."),
											@"rows": @[
												[self experimentalEntryCell],
								[SCISetting navigationCellWithTitle:SCILocalized(@"FBShared C Symbols Browser")
												   subtitle:SCILocalized(@"Runtime browser for FBShared exported C symbols with safe BOOL stubs")
												       icon:[SCISymbol symbolWithIGName:@"bcn_code_outline_24" fallback:@"function"]
											viewController:[SCISymbolsBrowserViewController new]],
											]
										}]
				];
}

@end
