#import <substrate.h>
#import <objc/runtime.h>
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

static BOOL sLGButtons = NO;
static BOOL sLGSurfaces = NO;
static BOOL sLGForceOff = NO;
static BOOL sLGProgressiveBlur = NO;

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
	[[NSUserDefaults standardUserDefaults] setValue:@(sLGButtons) forKey:@"instagram.override.project.lucent.navigation"];
	return %orig;
}
- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)arg2 {
	BOOL result = %orig;
	[SCITempFiles sweepLeftovers];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SCIFileLogExportToDocuments(); });
	sciDMUpdateKeepAlive();
	return result;
}
- (void)applicationDidEnterBackground:(id)arg1 {
	%orig;
	[SCICacheManager runAutoClearIfDue];
	[[SCILockManager shared] applyBackgroundInvalidation];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SCIFileLogExportToDocuments(); });
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

// NOTE: os getters BOOL de IGDSLauncherConfig (isLiquidGlass*) foram CONSOLIDADOS
// em src/Features/Gating/SCIIGDSLauncherConfigHook.x. Havia dois %hook
// IGDSLauncherConfig (aqui e lá); como dezenas de getters compartilham o mesmo
// IMP, os dois grupos colidiam na cadeia de %orig e o toggle do Dev não surtia
// efeito. Agora há um único %hook no projeto. As prefs do menu Interface
// (liquid_glass_buttons / liquid_glass_force_off) são lidas por aquele hook.
// O %group SCILiquidGlassGroup foi removido (ficaria vazio); os hooks de runtime
// LG (tab bar/surfaces) são instalados por sciInstallLiquidGlassHooks().

// MARK: - Progressive blur (iOS 26+ scroll-edge effect)
// Keep iOS 26-only UIKit classes runtime-resolved. The host app uses SDK 26.2
// with minOS 16.3, so direct Logos hooks against UIScrollEdgeEffect emit
// compile-time UIScrollEdgeEffect* declarations and fail availability checks.

static void (*orig_scrollEdge_ig_setIsHidden)(id, SEL, BOOL) = NULL;

static void sci_scrollEdge_hide(Class self __unused, SEL _cmd __unused) {
}

static BOOL sci_scrollEdge_ig_isHidden(id self __unused, SEL _cmd __unused) {
	return NO;
}

static void sci_scrollEdge_ig_setIsHidden(id self, SEL _cmd, BOOL hidden __unused) {
	if (orig_scrollEdge_ig_setIsHidden) {
		orig_scrollEdge_ig_setIsHidden(self, _cmd, NO);
	}
}

static void sciInstallProgressiveBlurHooks(void) {
	Class cls = NSClassFromString(@"UIScrollEdgeEffect");
	if (!cls) return;

	Class meta = object_getClass(cls);
	if (meta && class_getClassMethod(cls, @selector(hide))) {
		MSHookMessageEx(meta, @selector(hide), (IMP)sci_scrollEdge_hide, NULL);
	}

	if (class_getInstanceMethod(cls, @selector(ig_isHidden))) {
		MSHookMessageEx(cls, @selector(ig_isHidden), (IMP)sci_scrollEdge_ig_isHidden, NULL);
	}

	if (class_getInstanceMethod(cls, @selector(ig_setIsHidden:))) {
		MSHookMessageEx(cls, @selector(ig_setIsHidden:), (IMP)sci_scrollEdge_ig_setIsHidden, (IMP *)&orig_scrollEdge_ig_setIsHidden);
	}
}

// MARK: - Debug / bug report blocking

%group SCIDebugBlockGroup
%hook IGWindow
- (void)showDebugMenu {}
%end

%hook IGBugReportUploader
- (id)initWithNetworker:(id)arg1 pandoGraphQLService:(id)arg2 analyticsLogger:(id)arg3 userDefaults:(id)arg4 launcherSetProvider:(id)arg5 shouldPersistLastBugReportId:(id)arg6 {return nil;}
%end
%end

// MARK: - Screenshot blocking

%group SCIScreenshotBlockGroup
%hook IGStoryViewerContainerView
- (void)setShouldBlockScreenshot:(BOOL)arg1 viewModel:(id)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
%end
%hook IGDirectVisualMessageViewerSession
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	if (SCI_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end
%hook IGDirectVisualMessageReplayService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	if (SCI_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end
%hook IGDirectVisualMessageReportService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	if (SCI_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end

%hook IGDirectVisualMessageScreenshotSafetyLogger
- (id)initWithUserSession:(id)arg1 entryPoint:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) return %orig;
	return nil;
}

%end

%hook IGScreenshotObserver
- (id)initForController:(id)arg1 {
	if (SCI_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end

%hook IGScreenshotObserverDelegate
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
%end

%hook IGDirectMediaViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
%end

%hook IGStoryViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
%end

%hook IGSundialFeedViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
%end

%hook IGDirectVisualMessageViewerController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (!SCI_SCREENSHOT_BLOCKED) {
		%orig;
	}
}
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
			else if ([obj isKindOfClass:(NSClassFromString(@"_TtC18IGSearchViewModels23IGSearchResultViewModel") ?: NSClassFromString(@"IGSearchResultViewModel"))]) hide = ([obj itemType] == 6) || sciStringEquals([[obj title] string], @"meta.ai");
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

%hook IGDSMenu

- (id)initWithMenuItems:(NSArray<IGDSMenuItem *> *)items edr:(BOOL)edr headerLabelText:(id)headerLabelText {
	BOOL hideMeta = SCI_PREF(@"hide_meta_ai");
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		NSString *title = sciSafeValue(obj, @"title");
		BOOL hide = hideMeta && (sciStringEquals(title, @"AI images") || sciStringEquals(title, @"Meta AI"));

		if (!hide) [out addObject:obj];
	}

	extern NSArray *sciAppendStoryEntriesToIGDSMenu(NSArray *);
	NSArray *finalItems = sciAppendStoryEntriesToIGDSMenu(out.copy);

	return %orig(finalItems, edr, headerLabelText);
}

%end

%end

// MARK: - Confirm / button behavior

%group SCIConfirmActionsGroup

%hook IGFeedItemUFICell

- (void)UFIButtonBarDidTapOnLike:(id)arg1 {
	if (!SCI_PREF(@"like_confirm")) return %orig;
	[SCIUtils showConfirmation:^{
		%orig;
	} title:SCILocalized(@"Confirm like: Posts")];
}

- (void)UFIButtonBarDidTapOnRepost:(id)arg1 {
	if (!SCI_PREF(@"repost_confirm")) return %orig;
	[SCIUtils showConfirmation:^{
		%orig;
	} title:SCILocalized(@"Confirm repost")];
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
	[SCIUtils showConfirmation:^{
		%orig;
	} title:SCILocalized(@"Confirm like: Reels")];
}
- (void)_didLongPressLikeButton:(id)arg1 {
	if (!SCI_PREF(@"like_confirm_reels")) return %orig;
}
- (void)_didTapRepostButton {
	if (SCI_PREF(@"hide_reels_repost")) return;
	if (!SCI_PREF(@"repost_confirm")) return %orig;
	[SCIUtils showConfirmation:^{
		%orig;
	} title:SCILocalized(@"Confirm repost")];
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
static BOOL (*orig_expHelper_isHomeFeed)(id, SEL) = NULL;

static BOOL new_swizzleToggle_isEnabled(id self, SEL _cmd) {return !sLGForceOff;}
static BOOL new_expHelper_isEnabled(id self, SEL _cmd) {return !sLGForceOff;}
static BOOL new_expHelper_isHomeFeed(id self, SEL _cmd) {return !sLGForceOff;}

static BOOL (*orig_IGFloatingTabBarEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarDynamicSizingEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarEnhancedDynamicSizingEnabled)(void) = NULL;
static BOOL (*orig_IGTabBarHomecomingWithFloatingTabEnabled)(void) = NULL;
static NSInteger (*orig_IGTabBarStyleForLauncherSet)(NSInteger) = NULL;

#define SCI_BOOL_FISHHOOK(name) static BOOL hook_##name(void) {return !sLGForceOff;}

SCI_BOOL_FISHHOOK(IGFloatingTabBarEnabled)
SCI_BOOL_FISHHOOK(IGTabBarDynamicSizingEnabled)
SCI_BOOL_FISHHOOK(IGTabBarEnhancedDynamicSizingEnabled)
SCI_BOOL_FISHHOOK(IGTabBarHomecomingWithFloatingTabEnabled)

// style 0 = classic tab bar, 1 = floating/liquid glass
static NSInteger hook_IGTabBarStyleForLauncherSet(NSInteger set) {
	return sLGForceOff ? 0 : 1;
}

static void sciInstallLiquidGlassHooks(void) {
	if (sLGButtons || sLGForceOff) {
		Class swizzleToggle = objc_getClass("IGLiquidGlassSwizzle.IGLiquidGlassSwizzleToggle");

		if (swizzleToggle) {
			MSHookMessageEx(swizzleToggle, @selector(isEnabled), (IMP)new_swizzleToggle_isEnabled, (IMP *)&orig_swizzleToggle_isEnabled);
		}

		Class expHelper = objc_getClass("IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper");

		if (expHelper) {
			MSHookMessageEx(expHelper, @selector(isEnabled), (IMP)new_expHelper_isEnabled, (IMP *)&orig_expHelper_isEnabled);
			MSHookMessageEx(expHelper, @selector(isHomeFeedHeaderEnabled), (IMP)new_expHelper_isHomeFeed, (IMP *)&orig_expHelper_isHomeFeed);
		}
	}

	if (sLGSurfaces || sLGForceOff) {
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

	// Conformidade: o menu Dev>IGDSLauncher segue o MESMO padrão do resto da
	// tweak. As prefs do Dev de LiquidGlass alimentam as MESMAS static BOOLs que
	// o mecanismo real (sciInstallLiquidGlassHooks) consome. Assim, ligar
	// LiquidGlass no Dev dispara o mesmo ponto de decisão validado no binário:
	// os símbolos C IGTabBarStyleForLauncherSet/IGFloatingTabBarEnabled (FBShared,
	// importados pelo exec) + IGLiquidGlassSwizzleToggle.isEnabled. Os getters de
	// IGDSLauncherConfig sozinhos NÃO ligam o LiquidGlass (são config/telemetria).
	BOOL devLG  = SCI_PREF(@"sci_igds_liquidglass") || SCI_PREF(@"sci_igds_launcher_all") || SCI_PREF(@"sci_apply_liquidglass");

	sLGForceOff = SCI_PREF(@"liquid_glass_force_off");

	if (@available(iOS 19.0, *)) {
		sLGButtons = !sLGForceOff && (SCI_PREF(@"liquid_glass_buttons") || devLG);
	}

	sLGSurfaces = !sLGForceOff && (SCI_PREF(@"liquid_glass_surfaces") || devLG);

	if (@available(iOS 26.0, *)) {
		sLGProgressiveBlur = SCI_PREF(@"liquid_glass_progressive_blur") && objc_getClass("UIScrollEdgeEffect") != nil;
	}

	%init(SCIAppLifecycleGroup);
	%init(SCIDebugBlockGroup);
	%init(SCIScreenshotBlockGroup,
		IGDirectVisualMessageViewerSession = NSClassFromString(@"_TtC34IGDirectVisualMessageViewerSession34IGDirectVisualMessageViewerSession") ?: NSClassFromString(@"IGDirectVisualMessageViewerSession"),
		IGDirectVisualMessageReplayService = NSClassFromString(@"_TtC31IGDirectVisualMessageServiceKit34IGDirectVisualMessageReplayService") ?: NSClassFromString(@"IGDirectVisualMessageReplayService"),
		IGDirectMediaViewerViewController = NSClassFromString(@"_TtC27IGDirectMediaViewerKitSwift33IGDirectMediaViewerViewController") ?: NSClassFromString(@"IGDirectMediaViewerViewController"));
	%init(SCIHideItemsGroup,
		IGSearchListKitDataSource = NSClassFromString(@"_TtC15IGGenericSearch25IGSearchListKitDataSource") ?: NSClassFromString(@"IGSearchListKitDataSource"));
	%init(SCIConfirmActionsGroup);
	%init(SCISafeModeGroup);

	if (sciFlexEnabled()) {%init(SCIFlexGroup);}

	if (sLGButtons || sLGSurfaces || sLGForceOff) {
		// %init(SCILiquidGlassGroup) removido: os getters de IGDSLauncherConfig
		// agora vivem só em SCIIGDSLauncherConfigHook.x (fonte única). Aqui ficam
		// apenas os hooks de runtime de tab bar/surfaces.
		sciInstallLiquidGlassHooks();
	}

	if (sLGProgressiveBlur) {
		sciInstallProgressiveBlurHooks();
	}
}
