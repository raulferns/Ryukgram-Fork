#import "SCISettingsSections.h"
#import "../../Features/Experimental/SCIExperimentalGuard.h"


@implementation SCITweakSettings (Section_Experimental)

// MARK: - Advanced experimental features

+ (void)pushExperimentalMenu {
	SCISettingsViewController *vc = [[SCISettingsViewController alloc]
		initWithTitle:SCILocalized(@"Advanced experimental features")
			 sections:[self experimentalNavSections]
		 reduceMargin:NO];
	UIViewController *top = sciTopVC();
	if ([top isKindOfClass:[UINavigationController class]]) {
		[(UINavigationController *)top pushViewController:vc animated:YES];
	} else if (top.navigationController) {
		[top.navigationController pushViewController:vc animated:YES];
	} else {
		UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
		[top presentViewController:nav animated:YES completion:nil];
	}
}

+ (SCISetting *)experimentalEntryCell {
	return [SCISetting buttonCellWithTitle:SCILocalized(@"Advanced experimental features")
								  subtitle:SCILocalized(@"Hidden Instagram experiments")
									  icon:[SCISymbol symbolWithName:@"flask"]
									action:^{
		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"sci_exp_warning_seen"]) {
			[self pushExperimentalMenu];
			return;
		}
		UIAlertController *a = [UIAlertController
			alertControllerWithTitle:SCILocalized(@"Heads up")
							 message:SCILocalized(@"These toggles flip hidden Instagram experiments on. Some features may not work on every account or IG version. If IG keeps crashing on launch, the flags auto-reset after 3 failed starts.")
					  preferredStyle:UIAlertControllerStyleAlert];
		[a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Got it") style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *_) {
			[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"sci_exp_warning_seen"];
			[self pushExperimentalMenu];
		}]];
		[sciTopVC() presentViewController:a animated:YES completion:nil];
	}];
}

+ (SCISetting *)advancedExperimentalShortcutCell {
	return [SCISetting buttonCellWithTitle:SCILocalized(@"Advanced experimental features")
								  subtitle:SCILocalized(@"Hidden Instagram experiments (in Advanced)")
									  icon:[SCISymbol symbolWithName:@"flask"]
									action:^{ [self pushExperimentalMenu]; }];
}

+ (SCISetting *)applyRestartCell {
	SCISetting *cell = [SCISetting buttonCellWithTitle:SCILocalized(@"Apply & restart")
											  subtitle:SCILocalized(@"Restart Instagram to apply changes")
												  icon:[SCISymbol symbolWithIGName:@"bcn_circle-check_outline_24" fallback:@"checkmark.circle.fill"]
												action:^{ [SCIUtils showRestartConfirmation]; }];
	cell.titleColor = [UIColor systemBlueColor];
	return cell;
}

+ (SCISetting *)resetAllExperimentalCell {
	SCISetting *cell = [SCISetting buttonCellWithTitle:SCILocalized(@"Reset all experimental flags")
											  subtitle:SCILocalized(@"Turn every experimental toggle off")
												  icon:[SCISymbol symbolWithIGName:@"bcn_arrow-ccw_outline_24" fallback:@"arrow.counterclockwise.circle"]
												action:^{
		UIAlertController *a = [UIAlertController
			alertControllerWithTitle:SCILocalized(@"Reset experimental flags?")
							 message:SCILocalized(@"All experimental toggles will be turned off. Instagram will restart.")
					  preferredStyle:UIAlertControllerStyleAlert];
		[a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
		[a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Reset") style:UIAlertActionStyleDestructive
											handler:^(UIAlertAction *_) {
			[SCIExperimentalGuard resetAll];
			[SCIUtils showRestartConfirmation];
		}]];
		[sciTopVC() presentViewController:a animated:YES completion:nil];
	}];
	cell.titleColor = [UIColor systemRedColor];
	return cell;
}

+ (NSArray *)experimentalNavSections {
	return @[
		@{
			@"header": @"",
			@"footer": SCILocalized(@"Flip what you want on, then tap Apply to restart. Some flags may not work on every account or IG version. Flags auto-reset if IG crashes on launch 3 times."),
			@"rows": @[]
		},
		@{
			@"header": SCILocalized(@"Instagram UI"),
			@"rows": @[
				({
					SCISetting *s = [SCISetting switchCellWithTitle:SCILocalized(@"Friends Maps")
											   subtitle:SCILocalized(@"Shows the map entry in Direct Notes")
											defaultsKey:@"igt_directnotes_friendmap"];
					s.icon = [SCISymbol symbolWithName:@"friends_maps" color:UIColor.labelColor];
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
				({
					SCISetting *s = [SCISetting switchCellWithTitle:SCILocalized(@"Status Bar Old School")
											   subtitle:@""
											defaultsKey:@"sci_statusbar_oldschool"
										requiresRestart:NO];
					s.icon = [SCISymbol symbolWithName:@"statusbar_oldschool" color:UIColor.labelColor];
					s;
				}),
				({
					SCISetting *s = [SCISetting switchCellWithTitle:SCILocalized(@"Instagram Plus")
									   subtitle:SCILocalized(@"Unlocks client-side IG+ benefits (custom lists, story extend/rewatch/superlikes, silent posts, bio font, pinned limit). Server side unchanged.")
									defaultsKey:@"sci_force_igplus_all"
									requiresRestart:YES];
					s.icon = [SCISymbol symbolWithName:@"instagram_plus" color:UIColor.labelColor];
					s;
				}),
			]
		},
		@{
			@"header": SCILocalized(@"Surfaces"),
			@"rows": @[
				[SCISetting switchCellWithTitle:SCILocalized(@"Homecoming")
									   subtitle:SCILocalized(@"Forces the Homecoming home surface / nav on")
									defaultsKey:@"igt_homecoming"],
				[SCISetting switchCellWithTitle:SCILocalized(@"Prism design system")
									   subtitle:SCILocalized(@"Forces Prism-gated experiments on")
									defaultsKey:@"igt_prism"],
			]
		},
		@{
			@"header": SCILocalized(@"Actions"),
			@"rows": @[
				[self applyRestartCell],
				[self resetAllExperimentalCell],
			]
		},
	];
}

@end
