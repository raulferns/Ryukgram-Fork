#import <substrate.h>
#import "InstagramHeaders.h"
#import "Tweak.h"
#import "Utils.h"
#import "SCIDefaults.h"
#import "Features/General/SCICacheManager.h"
#import "Features/General/SCIChangelog.h"
#import "SCITempFiles.h"
#import "SCIFileLog.h"
#import "Lock/SCILockManager.h"
#import "Lock/SCILockGroups.h"
#import "Features/HiddenChats/SCIHiddenChats.h"
#import "Features/DeletedMessages/SCIDeletedMessagesCapture.h"
#include "../modules/fishhook/fishhook.h"

#define SCI_PREF(key) [SCIUtils getBoolPref:key]
#define SCI_SCREENSHOT_BLOCKED SCI_PREF(@"remove_screenshot_alert")
#define VOID_HANDLESCREENSHOT(orig) do { if (!SCI_SCREENSHOT_BLOCKED) { orig; } } while (0)
#define NONVOID_HANDLESCREENSHOT(orig) do { if (SCI_SCREENSHOT_BLOCKED) return nil; return orig; } while (0)

NSString *SCIVersionString = @"v1.3.1";
BOOL dmVisualMsgsViewedButtonEnabled = false;

// Liquid Glass — per-feature flags (iOS 26 visual API).
// Buttons & notifications:
static BOOL sLG_InAppNotif = NO;
static BOOL sLG_Toast = NO;
static BOOL sLG_EaseInOutBlur = NO;
static BOOL sLG_SwizzleButtons = NO;
// Navigation experiment helper:
static BOOL sLG_NavEnabled = NO;
static BOOL sLG_HomeFeedHeader = NO;
static BOOL sLG_GlassRendering = NO;
static BOOL sLG_GlassBackgroundSteps = NO;
static BOOL sLG_LegibilityBlur = NO;
static BOOL sLG_ProfileNavBarMatch = NO;
static BOOL sLG_ProfileSegmentedTabs = NO;
// Surfaces — fishhook tab bar (works pre-iOS 26 too):
static BOOL sLG_FloatingTabBar = NO;
static BOOL sLG_TabBarDynamicSizing = NO;
static BOOL sLG_TabBarEnhancedSizing = NO;
static BOOL sLG_TabBarHomecomingFloating = NO;
static BOOL sLG_TabBarStyleGlass = NO;

static inline BOOL sciAnyButtonOrNavLGFlag(void) {
	return sLG_SwizzleButtons || sLG_NavEnabled || sLG_HomeFeedHeader ||
	       sLG_GlassRendering || sLG_GlassBackgroundSteps || sLG_LegibilityBlur || sLG_ProfileNavBarMatch ||
	       sLG_ProfileSegmentedTabs || sLG_InAppNotif || sLG_Toast || sLG_EaseInOutBlur;
}
static inline BOOL sciAnyTabBarSurfaceFlag(void) {
	return sLG_FloatingTabBar || sLG_TabBarDynamicSizing || sLG_TabBarEnhancedSizing ||
	       sLG_TabBarHomecomingFloating || sLG_TabBarStyleGlass;
}

static BOOL sciFlexEnabled(void) {return SCI_PREF(@"flex_app_launch") || SCI_PREF(@"flex_app_start") || SCI_PREF(@"flex_instagram");}

static BOOL sciShouldHideMetaAIRecipient(id obj) {
	return SCI_PREF(@"hide_meta_ai") && ([[obj recipient] threadName] && [[[obj recipient] threadName] isEqualToString:@"Meta AI"]);
}

static BOOL sciStringEquals(NSString *a, NSString *b) {
	return a && [a isEqualToString:b];
}

static NSString *sciSafeValue(id obj, NSString *key) {
	@try { return [obj valueForKey:key]; } @catch (__unused id e) { return nil; }
}



// MARK: - App lifecycle

%group SCIAppLifecycleGroup

static BOOL sDidShowSettings;

%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)arg2 {
	[[NSUserDefaults standardUserDefaults] setValue:@(sLG_NavEnabled) forKey:@"instagram.override.project.lucent.navigation"];
	return %orig;
}
- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)arg2 {
	BOOL result = %orig;
	[SCITempFiles sweepLeftovers];
	sciDMUpdateKeepAlive();
	return result;
}
- (void)applicationDidEnterBackground:(id)arg1 {
	%orig;
	[SCICacheManager runAutoClearIfDue];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SCIFileLogExportToDocuments(); });
	[[SCILockManager shared] applyBackgroundInvalidation];
}

%end

%hook IGTabBarController
- (void)viewDidAppear:(BOOL)animated {
	%orig;

	static dispatch_once_t once;
	dispatch_once(&once, ^{[SCIChangelog presentIfNewFromWindow:self.view.window];});

	if (sDidShowSettings) return;

	BOOL firstRun = ![[[NSUserDefaults standardUserDefaults] objectForKey:@"SCInstaFirstRun"] isEqualToString:SCIVersionString];
	if (!firstRun && !SCI_PREF(@"tweak_settings_app_launch")) return;

	sDidShowSettings = YES;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (!topMostController().presentedViewController) {
			NSLog(@"[SCInsta] First run — showing settings modal");
			[SCIUtils showSettingsVC:self.view.window];
		}
	});
}

%end

%end

// MARK: - FLEX

%group SCIFlexGroup

%hook IGRootViewController
- (void)viewDidLoad {
	%orig;
	static BOOL didAddActiveObserver = NO;
	if (!didAddActiveObserver && SCI_PREF(@"flex_app_start")) {
		didAddActiveObserver = YES;
		[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
			if (SCI_PREF(@"flex_app_start")) {
				[[objc_getClass("FLEXManager") sharedManager] showExplorer];
			}
		}];
	}
	if (SCI_PREF(@"flex_instagram")) {
		UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
		longPress.minimumPressDuration = 1.0;
		longPress.numberOfTouchesRequired = 5;
		[self.view addGestureRecognizer:longPress];
	}
}

- (void)viewDidAppear:(BOOL)animated {
	%orig;

	static BOOL didShowFlexOnLaunch = NO;

	if (!didShowFlexOnLaunch && SCI_PREF(@"flex_app_launch")) {
		didShowFlexOnLaunch = YES;

		dispatch_async(dispatch_get_main_queue(), ^{
			[[objc_getClass("FLEXManager") sharedManager] showExplorer];
		});
	}
}

%new
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
	if (sender.state == UIGestureRecognizerStateBegan && SCI_PREF(@"flex_instagram")) {
		[[objc_getClass("FLEXManager") sharedManager] showExplorer];
	}
}

%end

%end

// MARK: - Liquid glass

%group SCILiquidGlassGroup

%hook IGDSLauncherConfig
// IG 431: apenas estes 3 seletores existem no binario.
- (_Bool)isLiquidGlassInAppNotificationEnabled {return sLG_InAppNotif ? YES : %orig;}
- (_Bool)isLiquidGlassToastEnabled {return sLG_Toast ? YES : %orig;}
- (_Bool)isLiquidGlassEaseInOutBlurEnabled {return sLG_EaseInOutBlur ? YES : %orig;}
%end

%end

// MARK: - Debug / bug report blocking
// Removed: do not block Instagram debug/bug-report/internal menus.

// MARK: - Screenshot blocking

%group SCIScreenshotBlockGroup
%hook IGStoryViewerContainerView
- (void)setShouldBlockScreenshot:(BOOL)arg1 viewModel:(id)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end
%hook IGDirectVisualMessageViewerSession
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {NONVOID_HANDLESCREENSHOT(%orig);}
%end
%hook IGDirectVisualMessageReplayService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {NONVOID_HANDLESCREENSHOT(%orig);}
%end
%hook IGDirectVisualMessageReportService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {NONVOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGDirectVisualMessageScreenshotSafetyLogger
- (id)initWithUserSession:(id)arg1 entryPoint:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) return %orig;
	return nil;
}

%end

%hook IGScreenshotObserver
- (id)initForController:(id)arg1 {NONVOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGScreenshotObserverDelegate
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {VOID_HANDLESCREENSHOT(%orig);}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGDirectMediaViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {VOID_HANDLESCREENSHOT(%orig);}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGStoryViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {VOID_HANDLESCREENSHOT(%orig);}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGSundialFeedViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {VOID_HANDLESCREENSHOT(%orig);}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end

%hook IGDirectVisualMessageViewerController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {VOID_HANDLESCREENSHOT(%orig);}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {VOID_HANDLESCREENSHOT(%orig);}
%end
%end

// MARK: - Hide / filter UI items

%group SCIHideItemsGroup

%hook IGDirectInboxSearchListAdapterDataSource

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig();
	BOOL hideMeta = SCI_PREF(@"hide_meta_ai");
	BOOL hideChats = SCI_PREF(@"no_suggested_chats");

	if (!hideMeta && !hideChats) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		BOOL hide = NO;

		if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {
			NSString *uid = sciSafeValue(obj, @"uniqueIdentifier");
			NSString *title = sciSafeValue(obj, @"labelTitle");
			hide = (hideChats && sciStringEquals(uid, @"channels")) || (hideMeta && (sciStringEquals(title, @"Ask Meta AI") || sciStringEquals(title, @"AI")));
		} else if ([obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsPillsSectionViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptLoggingViewModel)]) {
			hide = hideMeta;
		} else if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {
			hide = (hideChats && [[obj recipient] isBroadcastChannel]) || (hideMeta && (([obj sectionType] == 20) || ([obj sectionType] == 18) || sciStringEquals([[obj recipient] threadName], @"Meta AI")));
		}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}

%end

%hook IGDirectThreadCreationViewController

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig();
	BOOL hideMeta = SCI_PREF(@"hide_meta_ai"), hideUsers = SCI_PREF(@"no_suggested_users");
	if (!hideMeta && !hideUsers) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
	for (id obj in items) {
		BOOL hide = NO;

		if (hideMeta && [obj isKindOfClass:%c(IGDirectCreateChatCellViewModel)]) {hide = sciStringEquals(sciSafeValue(obj, @"title"), @"AI chats");
		} else if (hideMeta && [obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {hide = sciStringEquals([[obj recipient] threadName], @"Meta AI");
		} else if (hideUsers && [obj isKindOfClass:%c(IGContactInvitesSearchUpsellViewModel)]) {hide = YES;}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}

%end

%hook _TtC34IGDirectInboxListAdapterDataSource34IGDirectInboxListAdapterDataSource

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig();
	BOOL hideUsers = SCI_PREF(@"no_suggested_users"), hideNotes = SCI_PREF(@"hide_notes_tray");
	BOOL hideLockedChats = SCI_PREF(@"lock_chats_hide_from_inbox")
		&& [[SCILockManager shared] isGroupLocked:SCILockGroupChats];
	NSArray<NSString *> *lockedIDs = hideLockedChats ? [[SCILockManager shared] lockedChatIDs] : nil;
	NSArray<NSString *> *hiddenIDs = [SCIHiddenChats allThreadIDs];
	BOOL hasHiddenChats = hiddenIDs.count > 0;

	if (!hideUsers && !hideNotes && !hideLockedChats && !hasHiddenChats) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
	for (id obj in items) {
		BOOL hide = NO;

		if ([obj isKindOfClass:%c(IGDirectInboxHeaderCellViewModel)]) {
			NSString *title = [obj title];
			hide = hideUsers && (sciStringEquals(title, @"Suggestions") || [title hasPrefix:@"Accounts to"]);
		} else if ([obj isKindOfClass:%c(IGDirectInboxSuggestedThreadCellViewModel)]) {hide = hideUsers;
		} else if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)] || [obj isKindOfClass:%c(IGDiscoverPeopleConnectionItemConfiguration)]) {hide = hideUsers;
		} else if ([obj isKindOfClass:%c(IGDirectNotesTrayRowViewModel)]) {hide = hideNotes;
		} else if ([obj isKindOfClass:%c(IGDirectInboxThreadCellViewModel)]) {
			NSString *tid = sciSafeValue(obj, @"threadId");
			if (tid.length) {
				if (hasHiddenChats && [hiddenIDs containsObject:tid]) hide = YES;
				else if (hideLockedChats && [lockedIDs containsObject:tid]) hide = YES;
			}
		}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}
%end

%hook IGSearchListKitDataSource
- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig();
	BOOL hideMeta = SCI_PREF(@"hide_meta_ai");
	BOOL hideUsers = SCI_PREF(@"no_suggested_users");

	if (!hideMeta && !hideUsers) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		BOOL hide = NO;

		if (hideMeta) {
			if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) hide = sciStringEquals(sciSafeValue(obj, @"labelTitle"), @"Ask Meta AI");
			else if ([obj isKindOfClass:%c(IGSearchNullStateUpsellViewModel)] || [obj isKindOfClass:%c(IGSearchResultNestedGroupViewModel)]) hide = YES;
			else if ([obj isKindOfClass:%c(IGSearchResultViewModel)]) hide = ([obj itemType] == 6) || sciStringEquals([[obj title] string], @"meta.ai");
		}

		if (!hide && hideUsers) {
			if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) hide = sciStringEquals(sciSafeValue(obj, @"labelTitle"), @"Suggested for you");
			else if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)]) hide = YES;
			else if ([obj isKindOfClass:%c(IGSeeAllItemConfiguration)] && ((IGSeeAllItemConfiguration *)obj).destination == 4) hide = YES;
		}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}

%end

%hook IGMainStoryTrayDataSource
- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
	NSArray *items = %orig(cached);
	BOOL hideUsers = SCI_PREF(@"no_suggested_users");
	BOOL hideAds = SCI_PREF(@"hide_ads") && SCI_PREF(@"hide_ads_stories");

	if (!hideUsers && !hideAds) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
	for (IGStoryTrayViewModel *obj in items) {
		BOOL hide = NO;

		if ([obj isKindOfClass:%c(IGStoryTrayViewModel)]) {
			if (hideUsers) {
				NSNumber *type = [obj valueForKey:@"type"];
				hide = [type isEqual:@(8)] || [type isEqual:@(9)];
			}
			if (!hide && hideAds) { hide = obj.isUnseenNux || [obj.pk isEqualToString:@"3538572169"];}
		}
		if (!hide) [out addObject:obj];
	}
	return out.copy;
}

%end

%hook IGStoryTraySectionController
- (void)storyTrayControllerShowSUPOGEducationBump {if (!SCI_PREF(@"no_suggested_users")) %orig;}
%end

%hook IGDSMenu

- (id)initWithMenuItems:(NSArray<IGDSMenuItem *> *)items edr:(BOOL)edr headerLabelText:(id)headerLabelText {
	BOOL hideMeta = SCI_PREF(@"hide_meta_ai");
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		NSString *title = sciSafeValue(obj, @"title");
		BOOL hide = hideMeta && (sciStringEquals(title, @"AI images") || sciStringEquals(title, @"Meta AI"));

		if (!hide) [out addObject:obj];
	}

	extern NSArray *sciMaybeAppendStoryExcludeMenuItem(NSArray *);
	extern NSArray *sciMaybeAppendStoryAudioMenuItem(NSArray *);
	extern NSArray *sciMaybeAppendStoryMentionsMenuItem(NSArray *);

	NSArray *finalItems = sciMaybeAppendStoryExcludeMenuItem(out.copy);
	finalItems = sciMaybeAppendStoryAudioMenuItem(finalItems);
	finalItems = sciMaybeAppendStoryMentionsMenuItem(finalItems);

	return %orig(finalItems, edr, headerLabelText);
}

%end

%end

// MARK: - Confirm / button behavior

%group SCIConfirmActionsGroup

%hook IGFeedItemUFICell

- (void)UFIButtonBarDidTapOnLike:(id)arg1 {
	if (!SCI_PREF(@"like_confirm")) return %orig;
	[SCIUtils showConfirmation:^{ %orig; } title:SCILocalized(@"Confirm like: Posts")];
}

- (void)UFIButtonBarDidTapOnRepost:(id)arg1 {
	if (!SCI_PREF(@"repost_confirm")) return %orig;
	[SCIUtils showConfirmation:^{ %orig; } title:SCILocalized(@"Confirm repost")];
}

- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 {
	if (!SCI_PREF(@"repost_confirm")) return %orig;
}

- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 withGestureRecognizer:(id)arg2 {
	if (!SCI_PREF(@"repost_confirm")) return %orig;
}

%end

%hook IGUFIInteractionCountsView
- (void)updateUFIWithButtonsConfig:(id)config interactionCountProvider:(id)provider {
	%orig;
	if (!SCI_PREF(@"hide_feed_repost")) return;
	Ivar rv = class_getInstanceVariable(object_getClass(self), "_repostView");
	Ivar uv = class_getInstanceVariable(object_getClass(self), "_undoRepostButton");
	if (rv) [object_getIvar((id)self, rv) setHidden:YES];
	if (uv) [object_getIvar((id)self, uv) setHidden:YES];
}
%end

%hook IGSundialViewerVerticalUFI
- (void)_didTapLikeButton:(id)arg1 {
	if (!SCI_PREF(@"like_confirm_reels")) return %orig;
	[SCIUtils showConfirmation:^{ %orig; } title:SCILocalized(@"Confirm like: Reels")];
}
- (void)_didLongPressLikeButton:(id)arg1 {
	if (!SCI_PREF(@"like_confirm_reels")) return %orig;
}
- (void)_didTapRepostButton {
	if (SCI_PREF(@"hide_reels_repost")) return;
	if (!SCI_PREF(@"repost_confirm")) return %orig;
	[SCIUtils showConfirmation:^{ %orig; } title:SCILocalized(@"Confirm repost")];
}

- (void)_didLongPressRepostButton:(id)arg1 {
	if (SCI_PREF(@"hide_reels_repost") || SCI_PREF(@"repost_confirm")) return;
	%orig;
}
%end

%hook IGSundialViewerUFIViewModel
- (BOOL)shouldShowRepostButton {
	return SCI_PREF(@"hide_reels_repost") ? NO : %orig;
}
%end
%end

// MARK: - Safe mode

%group SCISafeModeGroup

%hook IGSafeModeChecker

- (id)initWithInstacrashCounterProvider:(void *)provider crashThreshold:(unsigned long long)threshold {
	return SCI_PREF(@"disable_safe_mode") ? nil : %orig(provider, threshold);
}

- (unsigned long long)crashCount {
	return SCI_PREF(@"disable_safe_mode") ? 0 : %orig;
}

%end

%end

// MARK: - Liquid glass runtime hooks

static BOOL (*orig_swizzleToggle_isEnabled)(id, SEL) = NULL;
static BOOL (*orig_expHelper_isEnabled)(id, SEL) = NULL;
static BOOL (*orig_expHelper_enabled)(id, SEL) = NULL;
static BOOL (*orig_expHelper_isHomeFeed)(id, SEL) = NULL;
static BOOL (*orig_expHelper_homeFeed)(id, SEL) = NULL;
static BOOL (*orig_expHelper_glassRendering)(id, SEL) = NULL;
static BOOL (*orig_expHelper_legibilityBlur)(id, SEL) = NULL;
static BOOL (*orig_expHelper_profileTabsDisabled)(id, SEL) = NULL;
static BOOL (*orig_expHelper_profileTabsDisabledProp)(id, SEL) = NULL;
static BOOL (*orig_expHelper_profileNavBar)(id, SEL) = NULL;
static BOOL (*orig_expHelper_profileNavBarProp)(id, SEL) = NULL;
static NSInteger (*orig_expHelper_glassBackgroundSteps)(id, SEL) = NULL;
static id (*orig_expHelper_shared)(id, SEL) = NULL;

static void sciHookObjCMethodIfPresent(Class cls, SEL sel, IMP imp, IMP *origOut) {
	if (!cls || !sel || !imp || !origOut) return;
	if (!class_getInstanceMethod(cls, sel)) return;
	MSHookMessageEx(cls, sel, imp, origOut);
}

static void sciHookObjCClassMethodIfPresent(Class cls, SEL sel, IMP imp, IMP *origOut) {
	if (!cls || !sel || !imp || !origOut) return;
	Class meta = object_getClass(cls);
	if (!class_getClassMethod(cls, sel)) return;
	MSHookMessageEx(meta, sel, imp, origOut);
}

static BOOL new_swizzleToggle_isEnabled(id self, SEL _cmd) {
	if (sLG_SwizzleButtons) return YES;
	return orig_swizzleToggle_isEnabled ? orig_swizzleToggle_isEnabled(self, _cmd) : NO;
}
static BOOL new_expHelper_isEnabled(id self, SEL _cmd) {
	if (sLG_NavEnabled) return YES;
	return orig_expHelper_isEnabled ? orig_expHelper_isEnabled(self, _cmd) : NO;
}
static BOOL new_expHelper_enabled(id self, SEL _cmd) {
	if (sLG_NavEnabled) return YES;
	return orig_expHelper_enabled ? orig_expHelper_enabled(self, _cmd) : NO;
}
static BOOL new_expHelper_isHomeFeed(id self, SEL _cmd) {
	if (sLG_HomeFeedHeader) return YES;
	return orig_expHelper_isHomeFeed ? orig_expHelper_isHomeFeed(self, _cmd) : NO;
}
static BOOL new_expHelper_homeFeed(id self, SEL _cmd) {
	if (sLG_HomeFeedHeader) return YES;
	return orig_expHelper_homeFeed ? orig_expHelper_homeFeed(self, _cmd) : NO;
}
static BOOL new_expHelper_glassRendering(id self, SEL _cmd) {
	if (sLG_GlassRendering) return YES;
	return orig_expHelper_glassRendering ? orig_expHelper_glassRendering(self, _cmd) : NO;
}
static BOOL new_expHelper_legibilityBlur(id self, SEL _cmd) {
	if (sLG_LegibilityBlur) return YES;
	return orig_expHelper_legibilityBlur ? orig_expHelper_legibilityBlur(self, _cmd) : NO;
}
static BOOL new_expHelper_profileNavBar(id self, SEL _cmd) {
	if (sLG_ProfileNavBarMatch) return YES;
	return orig_expHelper_profileNavBar ? orig_expHelper_profileNavBar(self, _cmd) : NO;
}
static BOOL new_expHelper_profileNavBarProp(id self, SEL _cmd) {
	if (sLG_ProfileNavBarMatch) return YES;
	return orig_expHelper_profileNavBarProp ? orig_expHelper_profileNavBarProp(self, _cmd) : NO;
}
// User flag YES means "glass enabled on profile segmented tabs", so "isDisabled" returns NO.
static BOOL new_expHelper_profileTabsNotDisabled(id self, SEL _cmd) {
	if (sLG_ProfileSegmentedTabs) return NO;
	return orig_expHelper_profileTabsDisabled ? orig_expHelper_profileTabsDisabled(self, _cmd) : NO;
}
static BOOL new_expHelper_profileTabsPropNotDisabled(id self, SEL _cmd) {
	if (sLG_ProfileSegmentedTabs) return NO;
	return orig_expHelper_profileTabsDisabledProp ? orig_expHelper_profileTabsDisabledProp(self, _cmd) : NO;
}
static NSInteger new_expHelper_glassBackgroundSteps(id self, SEL _cmd) {
	if (sLG_GlassBackgroundSteps) return 3;
	return orig_expHelper_glassBackgroundSteps ? orig_expHelper_glassBackgroundSteps(self, _cmd) : 0;
}

static void sciApplyLGOverrides(id helper);
static id new_expHelper_shared(id self, SEL _cmd) {
	id r = orig_expHelper_shared ? orig_expHelper_shared(self, _cmd) : nil;
	if (r) sciApplyLGOverrides(r);
	return r;
}

// Override API native (more reliable for getters registered at runtime).
static void sciApplyLGOverrides(id helper) {
	if (!helper) return;
	typedef void (*SetBool)(id, SEL, BOOL);
	SetBool send = (SetBool)objc_msgSend;
	if (sLG_NavEnabled && [helper respondsToSelector:@selector(overrideIsEnabled:)])
		send(helper, @selector(overrideIsEnabled:), YES);
	if (sLG_GlassRendering && [helper respondsToSelector:@selector(overrideIsGlassRenderingOptimizationEnabled:)])
		send(helper, @selector(overrideIsGlassRenderingOptimizationEnabled:), YES);
	if (sLG_GlassBackgroundSteps && [helper respondsToSelector:@selector(overrideGlassBackgroundAlphaDiscreteSteps:)])
		((void (*)(id, SEL, NSInteger))objc_msgSend)(helper, @selector(overrideGlassBackgroundAlphaDiscreteSteps:), 3);
	if (sLG_LegibilityBlur && [helper respondsToSelector:@selector(overrideIsLegibilityBlurEnabled:)])
		send(helper, @selector(overrideIsLegibilityBlurEnabled:), YES);
	if (sLG_ProfileNavBarMatch && [helper respondsToSelector:@selector(overrideIsProfileOtherNavBarHeightMatchSelf:)])
		send(helper, @selector(overrideIsProfileOtherNavBarHeightMatchSelf:), YES);
	if (sLG_ProfileSegmentedTabs && [helper respondsToSelector:@selector(overrideIsProfileSegmentedTabsGlassDisabled:)])
		send(helper, @selector(overrideIsProfileSegmentedTabsGlassDisabled:), NO);
}

static id (*orig_expHelper_init_id)(id, SEL) = NULL;
static id new_expHelper_init_id(id self, SEL _cmd) {
	id r = orig_expHelper_init_id(self, _cmd);
	if (r) sciApplyLGOverrides(r);
	return r;
}

static BOOL (*orig_IGFloatingTabBarEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarDynamicSizingEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarEnhancedDynamicSizingEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarHomecomingWithFloatingTabEnabled)(void) = NULL;
static NSInteger (*orig_IGTabBarStyleForLauncherSet)(NSInteger) = NULL;

static BOOL hook_IGFloatingTabBarEnabled(void) {
	if (sLG_FloatingTabBar) return YES;
	return orig_IGFloatingTabBarEnabled ? orig_IGFloatingTabBarEnabled() : NO;
}
static BOOL hook_IGTabBarDynamicSizingEnabled(void) {
	if (sLG_TabBarDynamicSizing) return YES;
	return orig_IGTabBarDynamicSizingEnabled ? orig_IGTabBarDynamicSizingEnabled() : NO;
}
static BOOL hook_IGTabBarEnhancedDynamicSizingEnabled(void) {
	if (sLG_TabBarEnhancedSizing) return YES;
	return orig_IGTabBarEnhancedDynamicSizingEnabled ? orig_IGTabBarEnhancedDynamicSizingEnabled() : NO;
}
static BOOL hook_IGTabBarHomecomingWithFloatingTabEnabled(void) {
	if (sLG_TabBarHomecomingFloating) return YES;
	return orig_IGTabBarHomecomingWithFloatingTabEnabled ? orig_IGTabBarHomecomingWithFloatingTabEnabled() : NO;
}
static NSInteger hook_IGTabBarStyleForLauncherSet(NSInteger set) {
	if (sLG_TabBarStyleGlass) return 1;
	return orig_IGTabBarStyleForLauncherSet ? orig_IGTabBarStyleForLauncherSet(set) : set;
}

static void sciInstallLiquidGlassHooks(void) {
	if (sciAnyButtonOrNavLGFlag()) {
		Class swizzleToggle = objc_getClass("IGLiquidGlassSwizzle.IGLiquidGlassSwizzleToggle");

		if (swizzleToggle) {
			MSHookMessageEx(swizzleToggle, @selector(isEnabled), (IMP)new_swizzleToggle_isEnabled, (IMP *)&orig_swizzleToggle_isEnabled);
		}

		Class expHelper = objc_getClass("IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper");

		if (expHelper) {
			sciHookObjCMethodIfPresent(expHelper, @selector(isEnabled), (IMP)new_expHelper_isEnabled, (IMP *)&orig_expHelper_isEnabled);
			sciHookObjCMethodIfPresent(expHelper, @selector(enabled), (IMP)new_expHelper_enabled, (IMP *)&orig_expHelper_enabled);
			sciHookObjCMethodIfPresent(expHelper, @selector(isHomeFeedHeaderEnabled), (IMP)new_expHelper_isHomeFeed, (IMP *)&orig_expHelper_isHomeFeed);
			sciHookObjCMethodIfPresent(expHelper, @selector(homeFeedHeaderEnabled), (IMP)new_expHelper_homeFeed, (IMP *)&orig_expHelper_homeFeed);
			sciHookObjCMethodIfPresent(expHelper, @selector(glassRenderingOptimizationEnabled), (IMP)new_expHelper_glassRendering, (IMP *)&orig_expHelper_glassRendering);
			sciHookObjCMethodIfPresent(expHelper, @selector(legibilityBlurEnabled), (IMP)new_expHelper_legibilityBlur, (IMP *)&orig_expHelper_legibilityBlur);
			sciHookObjCMethodIfPresent(expHelper, @selector(isProfileSegmentedTabsGlassDisabled), (IMP)new_expHelper_profileTabsNotDisabled, (IMP *)&orig_expHelper_profileTabsDisabled);
			sciHookObjCMethodIfPresent(expHelper, @selector(profileSegmentedTabsGlassDisabled), (IMP)new_expHelper_profileTabsPropNotDisabled, (IMP *)&orig_expHelper_profileTabsDisabledProp);
			sciHookObjCMethodIfPresent(expHelper, @selector(isProfileOtherNavBarHeightMatchSelf), (IMP)new_expHelper_profileNavBar, (IMP *)&orig_expHelper_profileNavBar);
			sciHookObjCMethodIfPresent(expHelper, @selector(profileOtherNavBarHeightMatchSelf), (IMP)new_expHelper_profileNavBarProp, (IMP *)&orig_expHelper_profileNavBarProp);
			sciHookObjCMethodIfPresent(expHelper, @selector(glassBackgroundAlphaDiscreteSteps), (IMP)new_expHelper_glassBackgroundSteps, (IMP *)&orig_expHelper_glassBackgroundSteps);
			sciHookObjCMethodIfPresent(expHelper, @selector(init), (IMP)new_expHelper_init_id, (IMP *)&orig_expHelper_init_id);
			sciHookObjCClassMethodIfPresent(expHelper, @selector(shared), (IMP)new_expHelper_shared, (IMP *)&orig_expHelper_shared);
			if ([expHelper respondsToSelector:@selector(shared)]) {
				id shared = ((id (*)(id, SEL))objc_msgSend)(expHelper, @selector(shared));
				sciApplyLGOverrides(shared);
			}
		}
	}

	if (sciAnyTabBarSurfaceFlag()) {
		rebind_symbols((struct rebinding[]){
			{"IGFloatingTabBarEnabled", (void *)hook_IGFloatingTabBarEnabled, (void **)&orig_IGFloatingTabBarEnabled},
			{"IGTabBarDynamicSizingEnabled", (void *)hook_IGTabBarDynamicSizingEnabled, (void **)&orig_IGTabBarDynamicSizingEnabled},
			{"IGTabBarEnhancedDynamicSizingEnabled", (void *)hook_IGTabBarEnhancedDynamicSizingEnabled, (void **)&orig_IGTabBarEnhancedDynamicSizingEnabled},
			{"IGTabBarHomecomingWithFloatingTabEnabled", (void *)hook_IGTabBarHomecomingWithFloatingTabEnabled, (void **)&orig_IGTabBarHomecomingWithFloatingTabEnabled},
			{"IGTabBarStyleForLauncherSet", (void *)hook_IGTabBarStyleForLauncherSet, (void **)&orig_IGTabBarStyleForLauncherSet},
		}, 5);
	}
}

%ctor {
	SCIRegisterDefaultsOnce();

	BOOL nativeLiquidGlass = SCI_PREF(@"lg_native_enabled");

	// Liquid Glass visual API requires iOS 26+.
	if (@available(iOS 26.0, *)) {
		sLG_InAppNotif         = nativeLiquidGlass || SCI_PREF(@"lg_inapp_notif");
		sLG_Toast              = nativeLiquidGlass || SCI_PREF(@"lg_toast");
		sLG_EaseInOutBlur      = nativeLiquidGlass || SCI_PREF(@"lg_ease_in_out_blur");
		sLG_SwizzleButtons     = nativeLiquidGlass || SCI_PREF(@"lg_swizzle_buttons");
		sLG_NavEnabled         = nativeLiquidGlass || SCI_PREF(@"lg_nav_enabled");
		sLG_HomeFeedHeader     = nativeLiquidGlass || SCI_PREF(@"lg_home_feed_header");
		sLG_GlassRendering     = nativeLiquidGlass || SCI_PREF(@"lg_glass_rendering");
		sLG_GlassBackgroundSteps = nativeLiquidGlass || SCI_PREF(@"lg_glass_background_steps");
		sLG_LegibilityBlur     = nativeLiquidGlass || SCI_PREF(@"lg_legibility_blur");
		sLG_ProfileNavBarMatch = nativeLiquidGlass || SCI_PREF(@"lg_profile_navbar_match");
		sLG_ProfileSegmentedTabs = nativeLiquidGlass || SCI_PREF(@"lg_profile_segmented_tabs_glass");
	}
	// Surface fishhook flags work pre-iOS 26 too.
	sLG_FloatingTabBar         = nativeLiquidGlass || SCI_PREF(@"lg_floating_tab_bar");
	sLG_TabBarDynamicSizing    = SCI_PREF(@"lg_tab_bar_dynamic_sizing");
	sLG_TabBarEnhancedSizing   = SCI_PREF(@"lg_tab_bar_enhanced_sizing");
	sLG_TabBarHomecomingFloating = SCI_PREF(@"lg_tab_bar_homecoming_floating");
	sLG_TabBarStyleGlass       = nativeLiquidGlass || SCI_PREF(@"lg_tab_bar_style_glass");

	%init(SCIAppLifecycleGroup);
	%init(SCIScreenshotBlockGroup);
	%init(SCIHideItemsGroup);
	%init(SCIConfirmActionsGroup);
	%init(SCISafeModeGroup);

	if (sciFlexEnabled()) {%init(SCIFlexGroup);}

	if (sciAnyButtonOrNavLGFlag() || sciAnyTabBarSurfaceFlag()) {
		%init(SCILiquidGlassGroup);
		sciInstallLiquidGlassHooks();
	}
}
