#import "TweakSettings.h"
#import "SCIInternalGlobalSettingsIntegration.h"
#import "Sections/SCISettingsSections.h"
#import "../SCIDefaults.h"
#import "../UI/SCIOptionSheet.h"
#import <objc/message.h>
#import "../UI/Notification/SCINotificationSettings.h"
#import "SCILinksSheet.h"
#import "SCISettingsBackup.h"
#import "SCIFakeLocationSettingsVC.h"
#import "../Features/ProfileAnalyzer/SCIProfileAnalyzerViewController.h"
#import "../Features/DeletedMessages/SCIDeletedMessagesViewController.h"
#import "../Gallery/SCIGalleryViewController.h"
#import "SCIExcludedChatsViewController.h"
#import "SCIHomeShortcutConfigViewController.h"
#import "../Features/StoriesAndMessages/SCIExcludedThreads.h"
#import "../Features/StoriesAndMessages/SCIExcludedStoryUsers.h"
#import "SCIExcludedStoryUsersViewController.h"
#import "SCIEmbedDomainViewController.h"
#import "SCIDateFormatPickerVC.h"
#import "SCIAppIconPickerViewController.h"
#import "../UI/SCIPopupChrome.h"
#import "../Features/ChatBackground/SCIChatBgSettingsVC.h"
#import "../Features/General/SCICacheManager.h"
#import "../Features/General/SCIChangelog.h"
#import "../SCIFFmpeg.h"
#import "../Features/Experimental/SCIExperimentalGuard.h"
#import "../Features/Theme/SCITheme.h"
#import "../Tweak.h"
#import "../ActionButton/SCIActionIcon.h"
#import "../ActionButton/SCIActionCatalog.h"
#import "SCIActionMenuConfigViewController.h"
#import "../UI/SCIIconPicker.h"
#import "../UI/SCIActionIconListViewController.h"
#import "SCISettingsViewController.h"
#import "../Lock/SCILockSettingsBuilder.h"
#import "../Lock/SCILockGate.h"
#import "../Lock/SCILockGroups.h"
#import <objc/runtime.h>

@implementation SCITweakSettings

// MARK: - Sections

+ (NSArray *)sections {
	NSMutableArray *sections = [NSMutableArray array];

	if ([SCIUtils allTweakOptionsDisabled]) {
		SCISetting *warn = [SCISetting buttonCellWithTitle:SCILocalized(@"All tweak options are disabled")
												  subtitle:SCILocalized(@"Tap to re-enable everything")
													  icon:[SCISymbol symbolWithIGName:@"warning" fallback:@"exclamationmark.triangle.fill"]
													action:^{
			[SCIUtils setPref:@(NO) forKey:@"sci_disable_all"];
			[NSNotificationCenter.defaultCenter postNotificationName:@"SCISettingsShouldReload" object:nil];
			[SCIUtils showRestartConfirmation];
		}];
		warn.titleColor = [UIColor systemRedColor];
		[sections addObject:@{ @"header": @"", @"rows": @[warn] }];
	}

	[sections addObjectsFromArray:@[
		@{
			@"header": @"",
			@"rows": @[
				({
					SCISetting *s = [SCISetting buttonCellWithTitle:@"RyukGram"
														   subtitle:[NSString stringWithFormat:SCILocalized(@"%@ — GitHub, Telegram, Donate"), SCIVersionString]
															   icon:nil
															 action:^{
						UIWindow *win = nil;
						for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { win = w; break; }
						UIViewController *top = win.rootViewController;
						while (top.presentedViewController) top = top.presentedViewController;
						[SCILinksSheet presentFrom:top];
					}];
					s.bundleImageName = @"ryukgram";
					s.titleColor = [UIColor labelColor];
					s;
				})
			]
		},
		@{
			@"header": @"",
			@"rows": @[
				[self generalNavCell],
				[self feedNavCell],
				[self storiesNavCell],
				[self reelsNavCell],
				[self messagesNavCell],
				[self profileNavCell],
				({ SCISetting *s = [self interfaceNavCell]; s.whatsNewID = @"ui_interface"; s; }),
				[self mediaSavingNavCell],
				[self confirmActionsNavCell]
			]
		},
		@{
			@"header": @"",
			@"rows": @[
				({
					SCISetting *s = [SCISetting buttonCellWithTitle:[NSString stringWithFormat:SCILocalized(@"%@ - BETA"), SCILocalized(@"Profile Analyzer")]
									   subtitle:@""
										   icon:[SCISymbol symbolWithIGName:@"green_screen" fallback:@"person.fill.viewfinder"]
										 action:^{
						UIWindow *kw = nil;
						for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow) { kw = w; break; }
						UIViewController *top = kw.rootViewController;
						while (top.presentedViewController) top = top.presentedViewController;
						[SCILockGate runGated:SCILockGroupProfileAnalyzer from:top then:^{
							UIViewController *t = kw.rootViewController;
							while (t.presentedViewController) t = t.presentedViewController;
							SCIProfileAnalyzerViewController *pa = [[SCIProfileAnalyzerViewController alloc] init];
							if ([t isKindOfClass:[UINavigationController class]]) [(UINavigationController *)t pushViewController:pa animated:YES];
							else if (t.navigationController) [t.navigationController pushViewController:pa animated:YES];
						}];
					}];
					s.whatsNewID = @"ui_profileanalyzer";
					s;
				}),
				({ SCISetting *s = [self followRequestsNavCell]; s.whatsNewID = @"ui_followrequests"; s; }),
				({
					SCISetting *s = [SCISetting buttonCellWithTitle:SCILocalized(@"Gallery")
									   subtitle:@""
										   icon:[SCISymbol symbolWithIGName:@"ig_icon_photo_gallery_outline_24" fallback:@"photo.on.rectangle.angled"]
										 action:^{ [SCIGalleryViewController presentGallery]; }];
					s.whatsNewID = @"ui_gallery";
					s;
				}),
				[SCISetting navigationCellWithTitle:SCILocalized(@"Fake location")
										   subtitle:@""
											   icon:[SCISymbol symbolWithIGName:@"location_arrow" fallback:@"location.fill.viewfinder"]
									 viewController:[[SCIFakeLocationSettingsVC alloc] init]],
				[self themeNavCell],
			]
		},
		@{
			@"header": @"",
			@"rows": @[
				({ SCISetting *s = [SCILockSettingsBuilder topLevelNavCell]; s.whatsNewID = @"ui_lock"; s; }),
			]
		},
		@{
			@"header": @"",
			@"rows": @[
				({ SCISetting *s = [self backupNavCell]; s.whatsNewID = @"ui_backup"; s; }),
				[self advancedNavCell],
				[self debugNavCell],
				SCIInternalGlobalEntryCell(),
				[self devNavCell]
			]
		},
		@{
			@"header": @"",
			@"rows": @[
				[self aboutNavCell]
			]
		},
	]];

	return sections;
}

// MARK: - Action button icon

+ (SCISetting *)actionIconNavCell {
	SCISetting *cell = [SCISetting navigationCellWithTitle:SCILocalized(@"Action button icon")
									  subtitle:SCILocalized(@"Shared icon, or override per button")
										  icon:[SCISymbol symbolWithIGName:@"more_horizontal" fallback:@"ellipsis.circle"]
								viewController:[SCIActionIconListViewController new]];
	cell.whatsNewID = @"ui_actionicon";
	return cell;
}

// MARK: - Date format

+ (SCISetting *)dateFormatNavCell {
	SCISetting *cell = [SCISetting navigationCellWithTitle:SCILocalized(@"Date format")
												 subtitle:@""
													 icon:nil
										   viewController:[[SCIDateFormatPickerVC alloc] init]];
	cell.dynamicTitle = ^{
		NSString *ex = [SCIDateFormatPickerVC currentFormatExample];
		return [NSString stringWithFormat:SCILocalized(@"Date format — %@"), ex];
	};
	cell.whatsNewID = @"ui_dateformat";
	return cell;
}

// MARK: - Title

+ (NSString *)title {
	return SCILocalized(@"settings.title");
}

@end
