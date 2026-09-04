#import <substrate.h>
#import "InstagramHeaders.h"
#import "Tweak.h"
#import "Utils.h"
#import "RYGDefaults.h"
#import "Features/General/RYGCacheManager.h"
#import "Features/General/RYGChangelog.h"
#import "RYGTempFiles.h"
#import "RYGAccountRegistry.h"
#import "RYGFileLog.h"
#import "Lock/RYGLockManager.h"
#import "Lock/RYGLockGroups.h"
#import "Features/HiddenChats/RYGHiddenChats.h"
#import "Features/DeletedMessages/RYGDeletedMessagesCapture.h"
#import "Features/FollowRequests/RYGFollowRequestTracker.h"
#import "Features/General/RYGMessagesOnlySchedule.h"
#import "Settings/RYGDonatePrompt.h"
#import "Debug/RYGFastRuntimeBrowserViewController.h"
#import "UI/RYGPopupChrome.h"
#include "../modules/fishhook/fishhook.h"
#import <objc/runtime.h>
#import <objc/message.h>

#define RYG_PREF(key) [RYGUtils getBoolPref:key]
#define RYG_SCREENSHOT_BLOCKED RYG_PREF(@"remove_screenshot_alert")

NSString *RYGVersionString = @"v1.3.4";
BOOL dmVisualMsgsViewedButtonEnabled = false;

static BOOL sLGButtons = NO;
static BOOL sLGSurfaces = NO;
static BOOL sLGForceOff = NO;
static BOOL sLGProgressiveBlur = NO;
static BOOL sRYGConfirmActionInFlight = NO;

@interface RYGScrollEdgeEffectProxy : NSObject
@end

static BOOL sRYGRuntimeBrowserPresentationPending;
static const void *kRYGRuntimeBrowserGestureKey = &kRYGRuntimeBrowserGestureKey;

static void rygPresentRuntimeBrowser(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (sRYGRuntimeBrowserPresentationPending) return;
		UIViewController *top = topMostController();
		if (!top) return;
		UIViewController *visible = [top isKindOfClass:UINavigationController.class]
			? ((UINavigationController *)top).visibleViewController : top;
		if ([visible isKindOfClass:RYGFastRuntimeBrowserViewController.class]) return;
		sRYGRuntimeBrowserPresentationPending = YES;
		[RYGPopupChrome presentVC:[RYGFastRuntimeBrowserViewController new] from:top];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			sRYGRuntimeBrowserPresentationPending = NO;
		});
	});
}

@interface RYGRuntimeBrowserGestureTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation RYGRuntimeBrowserGestureTarget
+ (instancetype)shared {
	static RYGRuntimeBrowserGestureTarget *target;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ target = [RYGRuntimeBrowserGestureTarget new]; });
	return target;
}
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
	if (recognizer.state == UIGestureRecognizerStateBegan && RYG_PREF(@"flex_instagram")) {
		rygPresentRuntimeBrowser();
	}
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
	shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	(void)gestureRecognizer;
	(void)otherGestureRecognizer;
	return YES;
}
@end

static void rygInstallRuntimeBrowserGestureOnWindow(UIWindow *window) {
	if (!window || objc_getAssociatedObject(window, kRYGRuntimeBrowserGestureKey)) return;
	UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc]
		initWithTarget:RYGRuntimeBrowserGestureTarget.shared action:@selector(handleLongPress:)];
	recognizer.minimumPressDuration = 1.0;
	recognizer.numberOfTouchesRequired = 5;
	recognizer.delegate = RYGRuntimeBrowserGestureTarget.shared;
	recognizer.cancelsTouchesInView = NO;
	recognizer.delaysTouchesBegan = NO;
	recognizer.delaysTouchesEnded = NO;
	[window addGestureRecognizer:recognizer];
	objc_setAssociatedObject(window, kRYGRuntimeBrowserGestureKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void rygInstallRuntimeBrowserGestures(void) {
	if (!RYG_PREF(@"flex_instagram")) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
		if (@available(iOS 13.0, *)) {
			for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
				if ([scene isKindOfClass:UIWindowScene.class]) {
					[windows addObjectsFromArray:((UIWindowScene *)scene).windows];
				}
			}
		}
		[windows addObjectsFromArray:UIApplication.sharedApplication.windows ?: @[]];
		for (UIWindow *window in windows) rygInstallRuntimeBrowserGestureOnWindow(window);
	});
}

static void rygConfigureRuntimeBrowserShortcuts(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
		if (RYG_PREF(@"flex_instagram")) {
			[center addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
				rygInstallRuntimeBrowserGestureOnWindow([note.object isKindOfClass:UIWindow.class] ? note.object : nil);
			}];
			rygInstallRuntimeBrowserGestures();
		}
		if (RYG_PREF(@"flex_app_start") || RYG_PREF(@"flex_instagram")) {
			[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
				rygInstallRuntimeBrowserGestures();
				if (RYG_PREF(@"flex_app_start")) rygPresentRuntimeBrowser();
			}];
		}
		if (RYG_PREF(@"flex_app_launch")) {
			[center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					rygPresentRuntimeBrowser();
				});
			}];
		}
	});
}

static BOOL rygShouldHideMetaAIRecipient(id obj) {
	return RYG_PREF(@"hide_meta_ai") && ([[obj recipient] threadName] && [[[obj recipient] threadName] isEqualToString:@"Meta AI"]);
}

static BOOL rygStringEquals(NSString *a, NSString *b) {
	return a && [a isEqualToString:b];
}

static NSString *rygSafeValue(id obj, NSString *key) {
	@try { return [obj valueForKey:key]; } @catch (__unused id e) { return nil; }
}



// MARK: - App lifecycle

%group RYGAppLifecycleGroup

static BOOL sDidShowSettings;

%hook IGInstagramAppDelegate
- (_Bool)application:(UIApplication *)application willFinishLaunchingWithOptions:(id)arg2 {
	[[NSUserDefaults standardUserDefaults] setValue:@(sLGButtons) forKey:@"instagram.override.project.lucent.navigation"];
	return %orig;
}
- (_Bool)application:(UIApplication *)application didFinishLaunchingWithOptions:(id)arg2 {
	BOOL result = %orig;
	[RYGTempFiles sweepLeftovers];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RYGFileLogExportToDocuments(); });
	rygDMUpdateKeepAlive();
	[[RYGFollowRequestTracker shared] refreshFromPrefs];
	[[RYGMessagesOnlySchedule shared] start];
		[RYGCacheManager runAutoClearIfDue];
		[RYGDonatePrompt noteAppLaunch];
		rygInstallRuntimeBrowserGestures();
		return result;
}
- (void)applicationDidEnterBackground:(id)arg1 {
	%orig;
	[RYGCacheManager runAutoClearIfDue];
	[[RYGLockManager shared] applyBackgroundInvalidation];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RYGFileLogExportToDocuments(); });
}

%end

%hook IGTabBarController
- (void)viewDidAppear:(BOOL)animated {
	%orig;

	[RYGAccountRegistry noteCurrentAccount];

	static dispatch_once_t once;
	dispatch_once(&once, ^{[RYGChangelog presentIfNewFromWindow:self.view.window];});

	if (sDidShowSettings) return;

	BOOL firstRun = ![[[NSUserDefaults standardUserDefaults] objectForKey:@"RyukGramFirstRun"] isEqualToString:RYGVersionString];
	if (!firstRun && !RYG_PREF(@"tweak_settings_app_launch")) return;

	sDidShowSettings = YES;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (!topMostController().presentedViewController) {
			[RYGUtils showSettingsVC:self.view.window];
		}
	});
}

%end

%end

// MARK: - Liquid glass

%group RYGLiquidGlassGroup

%hook IGDSLauncherConfig
- (_Bool)isLiquidGlassInAppNotificationEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassToastEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassToastPeekEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassIconBarButtonEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassNavigationContentStylePinningEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassEaseInOutBlurEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
- (_Bool)isLiquidGlassCGContextBlurEnabled {
	if (sLGForceOff) return NO;
	if (sLGButtons) return YES;
	return %orig;
}
%end

%end

// MARK: - Progressive blur (iOS 26+ scroll-edge effect)

%group RYGProgressiveBlurGroup
%hook RYGScrollEdgeEffectProxy
+ (void)hide {}
- (BOOL)ig_isHidden {return NO;}
- (void)ig_setIsHidden:(BOOL)hidden {
	hidden = NO;
	%orig;
}
%end
%end

// MARK: - Screenshot blocking

%group RYGScreenshotBlockGroup
%hook IGStoryViewerContainerView
- (void)setShouldBlockScreenshot:(BOOL)arg1 viewModel:(id)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end
%hook IGDirectVisualMessageViewerSession
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	if (RYG_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end
%hook IGDirectVisualMessageReplayService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	if (RYG_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end
%hook IGDirectVisualMessageReportService
- (id)visualMessageViewerController:(id)arg1 didDetectScreenshotForVisualMessage:(id)arg2 atIndex:(NSInteger)arg3 {
	RYGProbeOnce(@"hook.ssblock.vmreport", @"IGDirectVisualMessageReportService fired (legacy)");
	if (RYG_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end

%hook IGDirectVisualMessageScreenshotSafetyLogger
- (id)initWithUserSession:(id)arg1 entryPoint:(NSInteger)arg2 {
	RYGProbeOnce(@"hook.ssblock.safetylogger", @"IGDirectVisualMessageScreenshotSafetyLogger fired (current)");
	if (!RYG_SCREENSHOT_BLOCKED) return %orig;
	return nil;
}

%end

%hook IGScreenshotObserver
- (id)initForController:(id)arg1 {
	RYGProbeOnce(@"hook.ssblock.observer", @"IGScreenshotObserver fired (current)");
	if (RYG_SCREENSHOT_BLOCKED) return nil;
	return %orig;
}
%end

%hook IGScreenshotObserverDelegate
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	RYGProbeOnce(@"hook.ssblock.observerdelegate", @"IGScreenshotObserverDelegate fired (legacy)");
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end

%hook IGDirectMediaViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end

%hook IGStoryViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end

%hook IGSundialFeedViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end

%hook IGDirectVisualMessageViewerController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end

%hook _TtC27IGDirectMediaViewerKitSwift33IGDirectMediaViewerViewController
- (void)screenshotObserverDidSeeScreenshotTaken:(id)arg1 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
- (void)screenshotObserverDidSeeActiveScreenCapture:(id)arg1 event:(NSInteger)arg2 {
	if (RYG_SCREENSHOT_BLOCKED) return;
	%orig;
}
%end
%end

// MARK: - Hide / filter UI items

%group RYGHideItemsGroup

%hook IGDirectInboxSearchListAdapterDataSource

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig;
	BOOL hideMeta = RYG_PREF(@"hide_meta_ai");
	BOOL hideChats = RYG_PREF(@"no_suggested_chats");

	if (!hideMeta && !hideChats) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		BOOL hide = NO;

		if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) {
			NSString *uid = rygSafeValue(obj, @"uniqueIdentifier");
			NSString *title = rygSafeValue(obj, @"labelTitle");
			hide = (hideChats && rygStringEquals(uid, @"channels")) || (hideMeta && (rygStringEquals(title, @"Ask Meta AI") || rygStringEquals(title, @"AI")));
		} else if ([obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsPillsSectionViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptViewModel)] || [obj isKindOfClass:%c(IGDirectInboxSearchAIAgentsSuggestedPromptLoggingViewModel)]) {
			hide = hideMeta;
		} else if ([obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {
			hide = (hideChats && [[obj recipient] isBroadcastChannel]) || (hideMeta && (([obj sectionType] == 20) || ([obj sectionType] == 18) || rygStringEquals([[obj recipient] threadName], @"Meta AI")));
		}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}

%end

%hook IGDirectThreadCreationViewController

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig;
	BOOL hideMeta = RYG_PREF(@"hide_meta_ai"), hideUsers = RYG_PREF(@"no_suggested_users");
	if (!hideMeta && !hideUsers) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
	for (id obj in items) {
		BOOL hide = NO;

		if (hideMeta && [obj isKindOfClass:%c(IGDirectCreateChatCellViewModel)]) {hide = rygStringEquals(rygSafeValue(obj, @"title"), @"AI chats");
		} else if (hideMeta && [obj isKindOfClass:%c(IGDirectRecipientCellViewModel)]) {hide = rygStringEquals([[obj recipient] threadName], @"Meta AI");
		} else if (hideUsers && [obj isKindOfClass:%c(IGContactInvitesSearchUpsellViewModel)]) {hide = YES;}

		if (!hide) [out addObject:obj];
	}

	return out.copy;
}

%end

%hook _TtC34IGDirectInboxListAdapterDataSource34IGDirectInboxListAdapterDataSource

- (id)objectsForListAdapter:(id)arg1 {
	NSArray *items = %orig;
	BOOL hideUsers = RYG_PREF(@"no_suggested_users"), hideNotes = RYG_PREF(@"hide_notes_tray");
	BOOL hideLockedChats = RYG_PREF(@"lock_chats_hide_from_inbox")
		&& [[RYGLockManager shared] isGroupLocked:RYGLockGroupChats];
	NSArray<NSString *> *lockedIDs = hideLockedChats ? [[RYGLockManager shared] lockedChatIDs] : nil;
	NSArray<NSString *> *hiddenIDs = [RYGHiddenChats allThreadIDs];
	BOOL hasHiddenChats = hiddenIDs.count > 0 && ![RYGHiddenChats revealed];

	if (!hideUsers && !hideNotes && !hideLockedChats && !hasHiddenChats) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
	for (id obj in items) {
		BOOL hide = NO;

		if ([obj isKindOfClass:%c(IGDirectInboxHeaderCellViewModel)]) {
			NSString *title = [obj title];
			hide = hideUsers && (rygStringEquals(title, @"Suggestions") || [title hasPrefix:@"Accounts to"]);
		} else if ([obj isKindOfClass:%c(IGDirectInboxSuggestedThreadCellViewModel)]) {hide = hideUsers;
		} else if ([obj isKindOfClass:%c(IGDiscoverPeopleItemConfiguration)] || [obj isKindOfClass:%c(IGDiscoverPeopleConnectionItemConfiguration)]) {hide = hideUsers;
		} else if ([obj isKindOfClass:NSClassFromString(@"_TtC28IGDirectNotesViewModelsSwift29IGDirectNotesTrayRowViewModel")]) {hide = hideNotes;
		} else if ([obj isKindOfClass:%c(IGDirectInboxThreadCellViewModel)]) {
			NSString *tid = rygSafeValue(obj, @"threadId");
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
	NSArray *items = %orig;
	BOOL hideMeta = RYG_PREF(@"hide_meta_ai");
	BOOL hideUsers = RYG_PREF(@"no_suggested_users");

	if (!hideMeta && !hideUsers) return items;

	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		BOOL hide = NO;

		if (hideMeta) {
			if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) hide = rygStringEquals(rygSafeValue(obj, @"labelTitle"), @"Ask Meta AI");
			else if ([obj isKindOfClass:%c(IGSearchNullStateUpsellViewModel)] || [obj isKindOfClass:%c(IGSearchResultNestedGroupViewModel)]) hide = YES;
			else if ([obj isKindOfClass:(NSClassFromString(@"_TtC18IGSearchViewModels23IGSearchResultViewModel") ?: NSClassFromString(@"IGSearchResultViewModel"))]) hide = ([obj itemType] == 6) || rygStringEquals([[obj title] string], @"meta.ai");
		}

		if (!hide && hideUsers) {
			if ([obj isKindOfClass:%c(IGLabelItemViewModel)]) hide = rygStringEquals(rygSafeValue(obj, @"labelTitle"), @"Suggested for you");
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
	BOOL hideMeta = RYG_PREF(@"hide_meta_ai");
	NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];

	for (id obj in items) {
		NSString *title = rygSafeValue(obj, @"title");
		BOOL hide = hideMeta && (rygStringEquals(title, @"AI images") || rygStringEquals(title, @"Meta AI"));

		if (!hide) [out addObject:obj];
	}

	extern NSArray *rygAppendStoryEntriesToIGDSMenu(NSArray *);
	NSArray *finalItems = rygAppendStoryEntriesToIGDSMenu(out.copy);

	return %orig(finalItems, edr, headerLabelText);
}

%end

%end

// MARK: - Confirm / button behavior

static void rygRunConfirmedAction(dispatch_block_t action, NSString *title) {
	if (!action) return;
	[RYGUtils showConfirmation:^{
		sRYGConfirmActionInFlight = YES;
		@try { action(); }
		@finally { sRYGConfirmActionInFlight = NO; }
	} title:title];
}

%group RYGConfirmActionsGroup

%hook IGFeedItemUFICell

- (void)UFIButtonBarDidTapOnLike:(id)arg1 {
	if (!RYG_PREF(@"like_confirm") || sRYGConfirmActionInFlight) {
		%orig;
		return;
	}
	id target = self;
	SEL selector = _cmd;
	id argument = arg1;
	rygRunConfirmedAction(^{
		((void (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
	}, RYGLocalized(@"Confirm like: Posts"));
}

- (void)UFIButtonBarDidTapOnRepost:(id)arg1 {
	if (!RYG_PREF(@"repost_confirm") || sRYGConfirmActionInFlight) {
		%orig;
		return;
	}
	id target = self;
	SEL selector = _cmd;
	id argument = arg1;
	rygRunConfirmedAction(^{
		((void (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
	}, RYGLocalized(@"Confirm repost"));
}

- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 {
	if (!RYG_PREF(@"repost_confirm")) {
		%orig;
		return;
	}
}

- (void)UFIButtonBarDidLongPressOnRepost:(id)arg1 withGestureRecognizer:(id)arg2 {
	if (!RYG_PREF(@"repost_confirm")) {
		%orig;
		return;
	}
}

%end

%hook IGUFIInteractionCountsView
- (void)updateUFIWithButtonsConfig:(id)config interactionCountProvider:(id)provider {
	%orig;
	if (!RYG_PREF(@"hide_feed_repost")) return;
	Ivar rv = class_getInstanceVariable(object_getClass(self), "_repostView");
	Ivar uv = class_getInstanceVariable(object_getClass(self), "_undoRepostButton");
	if (rv) [object_getIvar((id)self, rv) setHidden:YES];
	if (uv) [object_getIvar((id)self, uv) setHidden:YES];
}
%end

%hook _TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI
- (void)didLongPressLikeButton:(id)arg1 {
	if (!RYG_PREF(@"like_confirm_reels")) {
		%orig;
		return;
	}
}
- (void)didTapRepostButton {
	if (RYG_PREF(@"hide_reels_repost")) return;
	if (!RYG_PREF(@"repost_confirm") || sRYGConfirmActionInFlight) {
		%orig;
		return;
	}
	id target = self;
	SEL selector = _cmd;
	rygRunConfirmedAction(^{
		((void (*)(id, SEL))objc_msgSend)(target, selector);
	}, RYGLocalized(@"Confirm repost"));
}

- (void)didLongPressRepostButton:(id)arg1 {
	if (RYG_PREF(@"hide_reels_repost") || RYG_PREF(@"repost_confirm")) return;
	%orig;
}
%end

%hook IGSundialViewerUFIViewModel
- (BOOL)shouldShowRepostButton {
	if (RYG_PREF(@"hide_reels_repost")) return NO;
	return %orig;
}
%end
%end

// MARK: - Safe mode

%group RYGSafeModeGroup

%hook IGSafeModeChecker

- (id)initWithInstacrashCounterProvider:(void *)provider crashThreshold:(unsigned long long)threshold {
	if (RYG_PREF(@"disable_safe_mode")) return nil;
	return %orig;
}

- (unsigned long long)crashCount {
	if (RYG_PREF(@"disable_safe_mode")) return 0;
	return %orig;
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

#define RYG_BOOL_FISHHOOK(name) static BOOL hook_##name(void) {return !sLGForceOff;}

RYG_BOOL_FISHHOOK(IGFloatingTabBarEnabled)
RYG_BOOL_FISHHOOK(IGTabBarDynamicSizingEnabled)
RYG_BOOL_FISHHOOK(IGTabBarEnhancedDynamicSizingEnabled)
RYG_BOOL_FISHHOOK(IGTabBarHomecomingWithFloatingTabEnabled)

// style 0 = classic tab bar, 1 = floating/liquid glass
static NSInteger hook_IGTabBarStyleForLauncherSet(NSInteger set) {
	return sLGForceOff ? 0 : 1;
}

static void rygInstallLiquidGlassHooks(void) {
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
	RYGMigrateLegacyDefaults();
	RYGMigrateActivityModes();
	RYGRegisterDefaultsOnce();
	rygConfigureRuntimeBrowserShortcuts();

	sLGForceOff = RYG_PREF(@"liquid_glass_force_off");

	if (@available(iOS 19.0, *)) {
		sLGButtons = !sLGForceOff && RYG_PREF(@"liquid_glass_buttons");
	}

	sLGSurfaces = !sLGForceOff && RYG_PREF(@"liquid_glass_surfaces");

	if (@available(iOS 26.0, *)) {
		sLGProgressiveBlur = RYG_PREF(@"liquid_glass_progressive_blur") && objc_getClass("UIScrollEdgeEffect") != nil;
	}

	%init(RYGAppLifecycleGroup);
	%init(RYGScreenshotBlockGroup,
		IGDirectVisualMessageViewerSession = NSClassFromString(@"_TtC34IGDirectVisualMessageViewerSession34IGDirectVisualMessageViewerSession") ?: NSClassFromString(@"IGDirectVisualMessageViewerSession"),
		IGDirectVisualMessageReplayService = NSClassFromString(@"_TtC31IGDirectVisualMessageServiceKit34IGDirectVisualMessageReplayService") ?: NSClassFromString(@"IGDirectVisualMessageReplayService"),
		IGDirectMediaViewerViewController = NSClassFromString(@"_TtC27IGDirectMediaViewerKitSwift33IGDirectMediaViewerViewController") ?: NSClassFromString(@"IGDirectMediaViewerViewController"));
	%init(RYGHideItemsGroup,
		IGSearchListKitDataSource = NSClassFromString(@"_TtC15IGGenericSearch25IGSearchListKitDataSource") ?: NSClassFromString(@"IGSearchListKitDataSource"));
	%init(RYGConfirmActionsGroup);
	%init(RYGSafeModeGroup);

	if (sLGButtons || sLGSurfaces || sLGForceOff) {
		%init(RYGLiquidGlassGroup);
		rygInstallLiquidGlassHooks();
	}

	if (sLGProgressiveBlur) {
		%init(RYGProgressiveBlurGroup,
			RYGScrollEdgeEffectProxy = objc_getClass("UIScrollEdgeEffect"));
	}
}
