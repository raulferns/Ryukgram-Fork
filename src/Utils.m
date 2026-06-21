#import "Utils.h"
#import "PhotoAlbum.h"
#import "Settings/TweakSettings.h"
#import "UI/SCIPopupChrome.h"
#import "Lock/SCILockGate.h"
#import "Lock/SCILockGroups.h"
#import <objc/runtime.h>

@implementation SCIUtils

static NSDictionary *sciRegisteredDefaultsRef = nil;
static char kSCIQuickLookDelegateKey;
static __weak IGRootViewController *sciCachedIGRootVC = nil;
static NSDictionary<NSString *, NSArray *> *sciCachedTopLevelEntries = nil;

#pragma mark - Prefs

static NSString *const kSCIDisableAllKey = @"sci_disable_all";
static BOOL sciAllDisabled = NO;
static BOOL sciAllDisabledStale = YES;

static inline id SCIPrefValue(NSString *key) {
	if (!key.length) return nil;
	id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
	return value ?: sciRegisteredDefaultsRef[key];
}

// Cached flag so the per-read check stays cheap; invalidated on any defaults write.
static inline BOOL SCIAllTweaksDisabled(void) {
	if (sciAllDisabledStale) {
		id v = SCIPrefValue(kSCIDisableAllKey);
		sciAllDisabled = [v isKindOfClass:NSNumber.class] && [(NSNumber *)v boolValue];
		sciAllDisabledStale = NO;
	}
	return sciAllDisabled;
}

// Keys the kill switch leaves alone: the switch itself, and the IG beta-update nag suppressor.
static inline BOOL SCIKillSwitchExempt(NSString *key) {
	return [key isEqualToString:kSCIDisableAllKey] || [key isEqualToString:@"hide_testflight_nag"];
}

+ (BOOL)allTweakOptionsDisabled {
	return SCIAllTweaksDisabled();
}

+ (BOOL)getBoolPref:(NSString *)key {
	if (SCIAllTweaksDisabled() && !SCIKillSwitchExempt(key)) return NO;
	id v = SCIPrefValue(key);
	if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
	if ([v isKindOfClass:NSString.class]) return [(NSString *)v boolValue];
	return NO;
}

+ (double)getDoublePref:(NSString *)key {
	id v = SCIPrefValue(key);
	if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v doubleValue];
	if ([v isKindOfClass:NSString.class]) return [(NSString *)v doubleValue];
	return 0;
}

+ (NSString *)getStringPref:(NSString *)key {
	id v = SCIPrefValue(key);
	return [v isKindOfClass:NSString.class] ? v : @"";
}

+ (NSDictionary *)getDictPref:(NSString *)key {
	id v = SCIPrefValue(key);
	return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

+ (NSArray *)getArrayPref:(NSString *)key {
	id v = SCIPrefValue(key);
	return [v isKindOfClass:NSArray.class] ? v : @[];
}

+ (void)setPref:(id)value forKey:(NSString *)key {
	if (!key.length) return;
	NSUserDefaults *defs = NSUserDefaults.standardUserDefaults;
	value ? [defs setObject:value forKey:key] : [defs removeObjectForKey:key];
}

+ (NSDictionary<NSString *, id> *)sciRegisteredDefaults {
	return sciRegisteredDefaultsRef ?: @{};
}

+ (void)setSciRegisteredDefaults:(NSDictionary<NSString *, id> *)defaults {
	sciRegisteredDefaultsRef = [defaults copy];
	sciAllDisabledStale = YES;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		[NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
														object:nil queue:nil
													usingBlock:^(__unused NSNotification *n) { sciAllDisabledStale = YES; }];
	});
}

+ (_Bool)liquidGlassEnabledBool:(_Bool)fallback {
	return [self getBoolPref:@"liquid_glass_surfaces"] ?: fallback;
}

#pragma mark - View Presentation

+ (void)showQuickLookVC:(NSArray<id> *)items {
	if (!items.count) return;

	UIViewController *topVC = topMostController();
	if (!topVC) {
		NSLog(@"[RyukGram] No view controller available to present QuickLook");
		return;
	}

	QLPreviewController *previewController = [QLPreviewController new];
	QuickLookDelegate *quickLookDelegate = [[QuickLookDelegate alloc] initWithPreviewItemURLs:items];

	previewController.dataSource = quickLookDelegate;
	objc_setAssociatedObject(previewController, &kSCIQuickLookDelegateKey, quickLookDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	[topVC presentViewController:previewController animated:YES completion:nil];
}

static UIWindow *sSCIAlertWindow = nil;

static void sciDismissAlertWindow(void) {
	if (!sSCIAlertWindow) return;
	UIWindow *w = sSCIAlertWindow;
	sSCIAlertWindow = nil;
	w.hidden = YES;
	w.rootViewController = nil;
}

+ (void)presentAlertInOwnWindow:(UIAlertController *)alert {
	if (!alert) return;

	UIWindowScene *scene = nil;
	for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
		if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
			scene = (UIWindowScene *)s; break;
		}
	}
	if (!scene) return;

	NSArray<UIAlertAction *> *originals = [alert.actions copy];
	[alert setValue:@[] forKey:@"actions"];
	for (UIAlertAction *orig in originals) {
		void (^realHandler)(UIAlertAction *) = [orig valueForKey:@"handler"];
		[alert addAction:[UIAlertAction actionWithTitle:orig.title style:orig.style
			handler:^(UIAlertAction *a) {
			sciDismissAlertWindow();
			if (realHandler) realHandler(a);
		}]];
	}

	sciDismissAlertWindow();

	UIWindow *win = [[UIWindow alloc] initWithWindowScene:scene];
	win.backgroundColor = UIColor.clearColor;
	win.windowLevel = UIWindowLevelAlert + 1;
	UIViewController *host = [UIViewController new];
	host.view.backgroundColor = UIColor.clearColor;
	win.rootViewController = host;
	[win makeKeyAndVisible];
	sSCIAlertWindow = win;

	[host presentViewController:alert animated:YES completion:nil];
}

+ (void)showShareVC:(id)item {
	if (!item) return;

	UIViewController *topVC = topMostController();
	if (!topVC) {
		NSLog(@"[RyukGram] No view controller available to present share sheet");
		return;
	}

	UIActivityViewController *acVC = [[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];

	if (is_iPad()) {
		acVC.popoverPresentationController.sourceView = topVC.view;
		acVC.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(topVC.view.bounds), CGRectGetMidY(topVC.view.bounds), 1.0, 1.0);
	}

	[SCIPhotoAlbum armWatcherIfEnabled];
	[topVC presentViewController:acVC animated:YES completion:nil];
}

+ (void)showSettingsVC:(UIWindow *)window {
	[SCILockGate presentLockedVC:[SCISettingsViewController new]
	                    forGroup:SCILockGroupSettings
	                        from:window.rootViewController
	                  sourceView:nil];
}

+ (void)showSettingsVCFromSourceView:(UIView *)sourceView {
	UIViewController *presenter = [self nearestViewControllerForView:sourceView] ?: sourceView.window.rootViewController;
	[SCILockGate presentLockedVC:[SCISettingsViewController new]
	                    forGroup:SCILockGroupSettings
	                        from:presenter
	                  sourceView:sourceView];
}

// Open settings at a named top-level entry. Entry becomes the nav root with
// Close — no settings-root underneath. Falls back to full root when missing.
+ (void)showSettingsVC:(UIWindow *)window atTopLevelEntry:(NSString *)entryTitle {
	UIViewController *rootController = window.rootViewController;
	while (rootController.presentedViewController) rootController = rootController.presentedViewController;

	if (!sciCachedTopLevelEntries) {
		NSMutableDictionary *map = [NSMutableDictionary new];

		for (NSDictionary *section in [SCITweakSettings sections]) {
			for (SCISetting *row in section[@"rows"]) {
				if (row.type == SCITableCellNavigation && row.title.length && row.navSections)
					map[row.title] = row.navSections;
			}
		}

		sciCachedTopLevelEntries = [map copy];
	}

	NSArray *targetNavSections = entryTitle.length ? sciCachedTopLevelEntries[entryTitle] : nil;
	UIViewController *navRoot = nil;

	if (targetNavSections) {
		SCISettingsViewController *child = [[SCISettingsViewController alloc] initWithTitle:entryTitle sections:targetNavSections reduceMargin:NO];
		child.title = entryTitle;
		child.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:child action:@selector(sciDismissSettings)];
		navRoot = child;
	} else {
		navRoot = [SCISettingsViewController new];
	}

	[SCILockGate presentLockedVC:navRoot forGroup:SCILockGroupSettings from:rootController];
}

#pragma mark - Colours

+ (UIColor *)SCIColor_Primary {
	return [UIColor colorWithRed:0/255.0 green:152/255.0 blue:254/255.0 alpha:1.0];
}

static UIColor *SCIDynIGColor(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db) {
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
		BOOL dark = tc.userInterfaceStyle == UIUserInterfaceStyleDark;
		return [UIColor colorWithRed:(dark ? dr : lr) / 255.0 green:(dark ? dg : lg) / 255.0 blue:(dark ? db : lb) / 255.0 alpha:1.0];
	}];
}

+ (UIColor *)SCIColor_InstagramBackground { return SCIDynIGColor(255,255,255, 11,16,20); }
+ (UIColor *)SCIColor_InstagramSecondaryBackground { return SCIDynIGColor(240,241,245, 42,48,55); }
+ (UIColor *)SCIColor_InstagramTertiaryBackground { return SCIDynIGColor(232,234,238, 58,64,72); }
+ (UIColor *)SCIColor_InstagramGroupedBackground { return [self SCIColor_InstagramBackground]; }
+ (UIColor *)SCIColor_InstagramPrimaryText { return SCIDynIGColor(15,20,25, 244,247,251); }
+ (UIColor *)SCIColor_InstagramSecondaryText { return SCIDynIGColor(99,108,118, 177,185,194); }
+ (UIColor *)SCIColor_InstagramTertiaryText { return SCIDynIGColor(130,138,147, 130,138,147); }
+ (UIColor *)SCIColor_InstagramSeparator { return SCIDynIGColor(220,223,228, 52,59,67); }
+ (UIColor *)SCIColor_InstagramFavorite { return [UIColor colorWithRed:255/255.0 green:48/255.0 blue:64/255.0 alpha:1.0]; }
+ (UIColor *)SCIColor_InstagramDestructive { return [UIColor colorWithRed:237/255.0 green:73/255.0 blue:86/255.0 alpha:1.0]; }
+ (UIColor *)SCIColor_InstagramPressedBackground { return SCIDynIGColor(232,233,238, 51,60,69); }

#pragma mark - Errors

+ (NSError *)errorWithDescription:(NSString *)errorDesc {
	return [self errorWithDescription:errorDesc code:1];
}

+ (NSError *)errorWithDescription:(NSString *)errorDesc code:(NSInteger)errorCode {
	return [NSError errorWithDomain:@"com.socuul.scinsta" code:errorCode userInfo:@{ NSLocalizedDescriptionKey: errorDesc ?: @"" }];
}

+ (void)showErrorHUDWithDescription:(NSString *)errorDesc {
	[self showErrorHUDWithDescription:errorDesc dismissAfterDelay:4.0];
}

+ (void)showErrorHUDWithDescription:(NSString *)errorDesc dismissAfterDelay:(CGFloat)dismissDelay {
	(void)dismissDelay;
	[[SCINotificationCenter shared] notifyError:SCI_NOTIF_ACTION_ERROR title:errorDesc message:nil];
}

#pragma mark - Runtime Cache

static Ivar SCICachedIvarForClass(Class cls, const char *name) {
	if (!cls || !name) return NULL;

	static NSMutableDictionary<NSString *, NSValue *> *cache;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		cache = [NSMutableDictionary new];
	});

	NSString *key = [NSString stringWithFormat:@"%s:%@", name, NSStringFromClass(cls)];

	@synchronized (cache) {
		NSValue *cached = cache[key];
		if (cached) return cached.pointerValue;
	}

	Ivar ivar = NULL;
	for (Class c = cls; c && !ivar; c = class_getSuperclass(c))
		ivar = class_getInstanceVariable(c, name);

	@synchronized (cache) {
		cache[key] = [NSValue valueWithPointer:ivar];
	}

	return ivar;
}

#pragma mark - Media

+ (NSDictionary *)fieldCacheForObject:(id)obj {
	if (!obj) return nil;
	if ([obj isKindOfClass:NSDictionary.class]) return obj;

	Ivar ivar = SCICachedIvarForClass([obj class], "_fieldCache");
	if (!ivar) return nil;

	@try {
		id v = object_getIvar(obj, ivar);
		return [v isKindOfClass:NSDictionary.class] ? v : nil;
	} @catch (__unused id e) {
		return nil;
	}
}

+ (id)fieldCacheValue:(id)obj forKey:(NSString *)key {
	if (!key.length) return nil;
	id value = [self fieldCacheForObject:obj][key];
	return [value isKindOfClass:NSNull.class] ? nil : value;
}

// Local alias used by older callers in this file.
static id sciFieldCacheValue(id obj, NSString *key) {
	return [SCIUtils fieldCacheValue:obj forKey:key];
}

static NSURL *SCIURLFromString(NSString *string) {
	if (![string isKindOfClass:NSString.class] || !string.length) return nil;
	if (![string hasPrefix:@"http"] && ![string hasPrefix:@"file:"]) return nil;
	return [NSURL URLWithString:string];
}

// Repost wrappers have no video/image versions — real media nests under
// repost_media / reshared_media / reposted_post (sometimes inside
// repost_info / media_or_ad). Returns the inner media or nil.
static id sciUnwrapRepostInnerMedia(id media) {
	if (!media) return nil;
	NSDictionary *fc = [SCIUtils fieldCacheForObject:media];
	if (![fc isKindOfClass:NSDictionary.class] || !fc.count) return nil;

	static NSArray<NSString *> *known;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		known = @[@"repost_media", @"reshared_media", @"reposted_post",
				  @"repost", @"repost_info", @"media_or_ad"];
	});

	id (^pick)(id) = ^id(id node) {
		if (!node || [node isKindOfClass:NSNull.class]) return nil;
		if ([node isKindOfClass:NSDictionary.class]) {
			NSDictionary *d = node;
			id nested = d[@"media"] ?: d[@"reposted_post"] ?: d[@"repost_media"] ?: d[@"reshared_media"];
			if (nested && ![nested isKindOfClass:NSNull.class]) node = nested;
		}
		NSDictionary *innerFc = [SCIUtils fieldCacheForObject:node];
		if ([innerFc isKindOfClass:NSDictionary.class] &&
			(innerFc[@"video_versions"] || innerFc[@"image_versions2"])) {
			return node;
		}
		return nil;
	};

	for (NSString *key in known) {
		id node = pick(fc[key]);
		if (node) return node;
	}

	for (NSString *key in fc) {
		if ([key isEqualToString:@"video_versions"] || [key isEqualToString:@"image_versions2"]) continue;
		id v = fc[key];
		if (!v || [v isKindOfClass:NSNull.class] || [v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) continue;
		id node = pick(v);
		if (node) return node;
	}

	return nil;
}

+ (NSString *)fullCount:(long long)n {
	if (n <= 0) return @"0";
	static NSNumberFormatter *f; static dispatch_once_t once;
	dispatch_once(&once, ^{
		f = [NSNumberFormatter new];
		f.numberStyle = NSNumberFormatterDecimalStyle;
		f.usesGroupingSeparator = YES;
	});
	return [f stringFromNumber:@(n)] ?: @"0";
}

+ (NSString *)shortCount:(long long)n {
	if (n < 0) n = 0;
	if (n < 1000) return [NSString stringWithFormat:@"%lld", n];
	if (n < 1000000) {
		double k = floor(n / 100.0) / 10.0;
		if (k >= 100) return [NSString stringWithFormat:@"%.0fK", k];
		return [NSString stringWithFormat:@"%.1fK", k];
	}
	if (n < 1000000000) {
		double m = floor(n / 100000.0) / 10.0;
		if (m >= 100) return [NSString stringWithFormat:@"%.0fM", m];
		return [NSString stringWithFormat:@"%.1fM", m];
	}
	double b = floor(n / 100000000.0) / 10.0;
	if (b >= 100) return [NSString stringWithFormat:@"%.0fB", b];
	return [NSString stringWithFormat:@"%.1fB", b];
}

+ (NSString *)igStyleCount:(long long)n {
	if (n < 10000) return [self fullCount:n];
	NSString *s = [self shortCount:n];
	// Trim a trailing ".0" before the K/M/B suffix — "10.0K" → "10K".
	if (s.length >= 4) {
		NSString *suffix = [s substringFromIndex:s.length - 1];
		NSString *body = [s substringToIndex:s.length - 1];
		if ([body hasSuffix:@".0"]) {
			s = [[body substringToIndex:body.length - 2] stringByAppendingString:suffix];
		}
	}
	return s;
}

+ (NSString *)formatCount:(long long)n shortened:(BOOL)shortened {
	return shortened ? [self shortCount:n] : [self fullCount:n];
}

+ (NSURL *)getPhotoUrl:(IGPhoto *)photo {
	if (!photo) return nil;

	@try {
		if ([photo respondsToSelector:@selector(imageURLForWidth:)]) {
			NSURL *url = [photo imageURLForWidth:100000.0];
			if (url) return url;
		}
	} @catch (__unused NSException *e) {}

	return nil;
}

+ (NSURL *)getPhotoUrlForMedia:(IGMedia *)media {
	if (!media) return nil;

	// fieldCache first — IGPhoto selectors crash on newer IG builds.
	@try {
		NSDictionary *imageVersions = sciFieldCacheValue(media, @"image_versions2");
		NSArray *candidates = [imageVersions isKindOfClass:NSDictionary.class] ? imageVersions[@"candidates"] : nil;

		if ([candidates isKindOfClass:NSArray.class] && candidates.count) {
			NSDictionary *best = nil;
			NSInteger bestWidth = -1;

			for (NSDictionary *candidate in candidates) {
				if (![candidate isKindOfClass:NSDictionary.class]) continue;

				NSInteger width = [candidate[@"width"] integerValue];
				if (width > bestWidth) {
					bestWidth = width;
					best = candidate;
				}
			}

			NSURL *url = SCIURLFromString(best[@"url"] ?: [candidates.firstObject objectForKey:@"url"]);
			if (url) return url;
		}
	} @catch (__unused NSException *e) {}

	@try {
		if ([media isKindOfClass:NSDictionary.class] == NO && [media respondsToSelector:@selector(photo)])
			return [self getPhotoUrl:media.photo];
	} @catch (__unused NSException *e) {}

	id inner = sciUnwrapRepostInnerMedia(media);
	if (inner && inner != media) return [self getPhotoUrlForMedia:(IGMedia *)inner];

	return nil;
}

+ (NSURL *)getVideoUrl:(IGVideo *)video {
	if (!video) return nil;

	@try {
		if ([video respondsToSelector:@selector(sortedVideoURLsBySize)]) {
			NSArray<NSDictionary *> *sorted = [video sortedVideoURLsBySize];
			NSURL *url = SCIURLFromString([sorted.firstObject isKindOfClass:NSDictionary.class] ? sorted.firstObject[@"url"] : nil);
			if (url) return url;
		}
	} @catch (__unused NSException *e) {}

	@try {
		if ([video respondsToSelector:@selector(allVideoURLs)]) {
			id set = [video allVideoURLs];
			id obj = [set respondsToSelector:@selector(anyObject)] ? [set anyObject] : nil;

			if ([obj isKindOfClass:NSURL.class])
				return SCIURLFromString([(NSURL *)obj absoluteString]);

			if ([obj isKindOfClass:NSString.class])
				return SCIURLFromString(obj);
		}
	} @catch (__unused NSException *e) {}

	return nil;
}

+ (NSURL *)getVideoUrlForMedia:(IGMedia *)media {
	if (!media) return nil;

	// fieldCache first — IGVideo selectors crash on newer IG builds.
	@try {
		NSArray *versions = sciFieldCacheValue(media, @"video_versions");

		if ([versions isKindOfClass:NSArray.class] && versions.count) {
			NSDictionary *best = nil;
			NSInteger bestType = -1;

			for (NSDictionary *version in versions) {
				if (![version isKindOfClass:NSDictionary.class]) continue;

				NSInteger type = [version[@"type"] integerValue];
				if (type > bestType) {
					bestType = type;
					best = version;
				}
			}

			NSURL *url = SCIURLFromString(best[@"url"] ?: [versions.firstObject objectForKey:@"url"]);
			if (url) return url;
		}
	} @catch (__unused NSException *e) {}

	@try {
		if ([media isKindOfClass:NSDictionary.class] == NO && [media respondsToSelector:@selector(video)])
			return [self getVideoUrl:media.video];
	} @catch (__unused NSException *e) {}

	id inner = sciUnwrapRepostInnerMedia(media);
	if (inner && inner != media) return [self getVideoUrlForMedia:(IGMedia *)inner];

	return nil;
}

#pragma mark - View Controllers

+ (UIViewController *)viewControllerForView:(UIView *)view {
	if (!view || ![view respondsToSelector:NSSelectorFromString(@"viewDelegate")]) return nil;

	@try {
		id vc = [view valueForKey:@"viewDelegate"];
		return [vc isKindOfClass:UIViewController.class] ? vc : nil;
	} @catch (__unused NSException *e) {
		return nil;
	}
}

+ (UIViewController *)viewControllerForAncestralView:(UIView *)view {
	if (!view || ![view respondsToSelector:NSSelectorFromString(@"_viewControllerForAncestor")]) return nil;

	@try {
		id vc = [view valueForKey:@"_viewControllerForAncestor"];
		return [vc isKindOfClass:UIViewController.class] ? vc : nil;
	} @catch (__unused NSException *e) {
		return nil;
	}
}

+ (UIViewController *)nearestViewControllerForView:(UIView *)view {
	return [self viewControllerForView:view] ?: [self viewControllerForAncestralView:view];
}

#pragma mark - Functions

+ (NSString *)IGVersionString {
	return NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
}

static UIWindow *SCIActiveWindow(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;

		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (window.isKeyWindow) return window;
		}
	}

	return UIApplication.sharedApplication.keyWindow;
}

+ (BOOL)isNotch {
	return SCIActiveWindow().safeAreaInsets.bottom > 0;
}

+ (BOOL)existingLongPressGestureRecognizerForView:(UIView *)view {
	for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
		if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class])
			return YES;
	}

	return NO;
}

#pragma mark - Alerts

static UIAlertController *SCIAlert(NSString *title, NSString *message) {
	return [UIAlertController alertControllerWithTitle:title message:message ?: SCILocalized(@"Are you sure?") preferredStyle:UIAlertControllerStyleAlert];
}

static void SCIPresentAlert(UIAlertController *alert, UIViewController *host) {
	if (!alert) return;

	if (!is_iPad()) {
		[SCIUtils presentAlertInOwnWindow:alert];
		return;
	}

	host = host ?: topMostController();
	if (!host) return;

	[host presentViewController:alert animated:YES completion:nil];
}

+ (BOOL)showConfirmation:(void(^)(void))okHandler title:(NSString *)title {
	UIAlertController *alert = SCIAlert(title, nil);

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Yes") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
		if (okHandler) okHandler();
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"No!") style:UIAlertActionStyleCancel handler:nil]];

	SCIPresentAlert(alert, nil);
	return NO;
}

+ (BOOL)showConfirmation:(void(^)(void))okHandler cancelHandler:(void(^)(void))cancelHandler title:(NSString *)title {
	UIAlertController *alert = SCIAlert(title, nil);

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Yes") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
		if (okHandler) okHandler();
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"No!") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
		if (cancelHandler) cancelHandler();
	}]];

	SCIPresentAlert(alert, nil);
	return NO;
}

+ (BOOL)showConfirmation:(void(^)(void))okHandler {
	return [self showConfirmation:okHandler title:nil];
}

+ (BOOL)showConfirmation:(void(^)(void))okHandler cancelHandler:(void(^)(void))cancelHandler {
	return [self showConfirmation:okHandler cancelHandler:cancelHandler title:nil];
}

+ (void)confirmIfNeeded:(BOOL)gated
                  title:(NSString *)title
                message:(NSString *)message
           confirmTitle:(NSString *)confirmTitle
                   from:(UIViewController *)presenter
              onConfirm:(void(^)(void))onConfirm
               onCancel:(void(^)(void))onCancel {
	if (!gated) {
		if (onConfirm) onConfirm();
		return;
	}

	UIViewController *host = presenter ?: topMostController();
	if (!host) {
		if (onConfirm) onConfirm();
		return;
	}

	UIAlertController *alert = SCIAlert(title, message);

	[alert addAction:[UIAlertAction actionWithTitle:(confirmTitle ?: SCILocalized(@"Yes")) style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *_) {
		if (onConfirm) onConfirm();
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *_) {
		if (onCancel) onCancel();
	}]];

	SCIPresentAlert(alert, host);
}

+ (void)showRestartConfirmation {
	[self showRestartConfirmationWithTitle:SCILocalized(@"Restart required") message:SCILocalized(@"You must restart the app to apply this change")];
}

+ (void)showRestartConfirmationWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = SCIAlert(title, message);

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Restart") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
		exit(0);
	}]];

	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Later") style:UIAlertActionStyleCancel handler:nil]];
	SCIPresentAlert(alert, nil);
}

#pragma mark - Toasts

+ (void)showToastForDuration:(double)duration title:(NSString *)title {
	[self showToastForDuration:duration title:title subtitle:nil];
}

+ (void)showToastForDuration:(double)duration title:(NSString *)title subtitle:(NSString *)subtitle {
	[[SCINotificationCenter shared] notifyAction:SCI_NOTIF_GENERIC
	                                       title:title
	                                    subtitle:subtitle
	                                        icon:nil
	                                        tone:SCINotificationToneInfo
	                                    duration:duration];
}

static IGRootViewController *sciFindIGRootVC(void) {
	if (sciCachedIGRootVC && sciCachedIGRootVC.view.window)
		return sciCachedIGRootVC;

	Class rootCls = NSClassFromString(@"IGRootViewController");
	if (!rootCls) return nil;

	NSMutableArray<UIViewController *> *queue = [NSMutableArray new];

	UIViewController *activeRoot = SCIActiveWindow().rootViewController;
	if (activeRoot) [queue addObject:activeRoot];

	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			UIViewController *r = w.rootViewController;
			if (r && r != activeRoot) [queue addObject:r];
		}
	}

	if (!queue.count) return nil;

	for (NSUInteger i = 0; i < queue.count; i++) {
		UIViewController *vc = queue[i];

		if ([vc isKindOfClass:rootCls]) {
			sciCachedIGRootVC = (IGRootViewController *)vc;
			return sciCachedIGRootVC;
		}

		if (vc.presentedViewController)
			[queue addObject:vc.presentedViewController];

		if (vc.childViewControllers.count)
			[queue addObjectsFromArray:vc.childViewControllers];
	}

	return nil;
}

+ (void)showIGNativeToastForDuration:(double)duration title:(NSString *)title subtitle:(NSString *)subtitle {
	[self showIGNativeToastForDuration:duration title:title subtitle:subtitle onTap:nil];
}

+ (void)showIGNativeToastForDuration:(double)duration title:(NSString *)title subtitle:(NSString *)subtitle onTap:(void (^)(void))onTap {
	IGActionableConfirmationToastPresenter *toastPresenter = [sciFindIGRootVC() toastPresenter];
	if (!toastPresenter) return;

	Class modelClass = NSClassFromString(@"IGActionableConfirmationToastViewModel");
	if (!modelClass) return;

	IGActionableConfirmationToastViewModel *model = [modelClass new];
	[model setValue:title forKey:@"text_annotatedTitleText"];
	[model setValue:subtitle forKey:@"text_annotatedSubtitleText"];

	[toastPresenter hideAlert];
	[toastPresenter showAlertWithViewModel:model isAnimated:YES animationDuration:duration presentationPriority:0 tapActionBlock:[onTap copy] presentedHandler:nil dismissedHandler:nil];
}

#pragma mark - Math

+ (NSUInteger)decimalPlacesInDouble:(double)value {
	static NSNumberFormatter *formatter;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		formatter = [NSNumberFormatter new];
		formatter.numberStyle = NSNumberFormatterDecimalStyle;
		formatter.maximumFractionDigits = 15;
		formatter.minimumFractionDigits = 0;
		formatter.decimalSeparator = @".";
	});

	@synchronized (formatter) {
		NSString *stringValue = [formatter stringFromNumber:@(value)];
		NSRange decimalRange = [stringValue rangeOfString:formatter.decimalSeparator];

		if (decimalRange.location == NSNotFound)
			return 0;

		return stringValue.length - (decimalRange.location + decimalRange.length);
	}
}

#pragma mark - Ivars

+ (id)getIvarForObj:(id)obj name:(const char *)name {
	if (!obj || !name) return nil;

	Ivar ivar = SCICachedIvarForClass(object_getClass(obj), name);
	if (!ivar) return nil;

	return object_getIvar(obj, ivar);
}

+ (void)setIvarForObj:(id)obj name:(const char *)name value:(id)value {
	if (!obj || !name) return;

	Ivar ivar = SCICachedIvarForClass(object_getClass(obj), name);
	if (!ivar) return;

	object_setIvarWithStrongDefault(obj, ivar, value);
}

+ (id)activeUserSession {
	// account quick switch needs the live session each
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;

		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			@try {
				id session = [window valueForKey:@"userSession"];
				if (session) return session;
			} @catch (__unused id e) {}
		}
	}

	return nil;
}

+ (NSString *)pkFromIGUser:(id)user {
	if (!user) return nil;

	Ivar pkIvar = SCICachedIvarForClass([user class], "_pk");
	if (!pkIvar) return nil;

	id pk = object_getIvar(user, pkIvar);
	return pk ? [pk description] : nil;
}

+ (NSString *)currentUserPK {
	id session = [self activeUserSession];
	if (!session) return nil;

	@try {
		id user = [session valueForKey:@"user"];
		return [self pkFromIGUser:user];
	} @catch (__unused id e) {
		return nil;
	}
}

@end
