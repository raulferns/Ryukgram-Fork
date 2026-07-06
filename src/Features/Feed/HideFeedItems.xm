#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>

static inline BOOL sciHideAds(NSString *surface) {
	return [SCIUtils getBoolPref:@"hide_ads"] && [SCIUtils getBoolPref:[@"hide_ads_" stringByAppendingString:surface]];
}

static inline BOOL sciKind(id obj, Class cls) {
	return cls && [obj isKindOfClass:cls];
}

// Swift-ified — only the mangled name is registered with the runtime.
static Class sciInFeedStoriesTrayCls(void) {
	static Class cls;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cls = objc_getClass("_TtC15IGInFeedStories24IGInFeedStoriesTrayModel") ?: objc_getClass("IGInFeedStoriesTrayModel");
	});
	return cls;
}

static NSArray *removeItemsInList(NSArray *list, BOOL isFeed, BOOL hideAds) {
	if (![list isKindOfClass:NSArray.class] || !list.count) return list;

	BOOL hideMetaAI = isFeed && [SCIUtils getBoolPref:@"hide_meta_ai"];
	BOOL noSuggestedPost = isFeed && [SCIUtils getBoolPref:@"no_suggested_post"];
	BOOL noSuggestedReels = isFeed && [SCIUtils getBoolPref:@"no_suggested_reels"];
	BOOL noSuggestedAccount = [SCIUtils getBoolPref:@"no_suggested_account"];
	BOOL noSuggestedThreads = [SCIUtils getBoolPref:@"no_suggested_threads"];
	BOOL hideStoriesTray = isFeed && [SCIUtils getBoolPref:@"hide_stories_tray"];
	BOOL hideEntireFeed = isFeed && [SCIUtils getBoolPref:@"hide_entire_feed"];

	NSMutableArray *filtered = nil;

	for (id obj in list) {
		BOOL remove = NO;

		// Meta AI in-feed unit ("Try free AI creation tools"). Ivar read — no public getter.
		if (hideMetaAI && [obj isKindOfClass:%c(IGBloksFeedUnitModel)]) {
			static Ivar iv;
			static dispatch_once_t once;
			dispatch_once(&once, ^{
				iv = class_getInstanceVariable(%c(IGBloksFeedUnitModel), "_viewStateItemType");
			});
			if (iv) {
				NSInteger t = *(NSInteger *)((char *)(__bridge void *)obj + ivar_getOffset(iv));
				remove = (t == 251);
			}
		}

		// Suggested posts
		if (!remove && noSuggestedPost) {
			if (([obj isKindOfClass:%c(IGMedia)] && [((IGMedia *)obj).explorePostInFeed isEqual:@YES])
				|| ([obj isKindOfClass:%c(IGFeedGroupHeaderViewModel)] && [[obj title] isEqualToString:@"Suggested Posts"])) remove = YES;
		}

		// Mid-feed stories carousel (suggested / expiring-soon / highlights unit)
		if (!remove && (noSuggestedPost || hideStoriesTray || hideEntireFeed) && sciKind(obj, sciInFeedStoriesTrayCls()))
			remove = YES;

		// Suggested reels carousel
		if (!remove && noSuggestedReels && [obj isKindOfClass:%c(IGFeedScrollableClipsModel)]) remove = YES;

		// Suggested accounts
		if (!remove && noSuggestedAccount) {
			if (([obj isKindOfClass:%c(IGHScrollAYMFModel)]) || [obj isKindOfClass:%c(IGSuggestedUserInReelsModel)]) remove = YES;
		}

		// Suggested threads posts
		if (!remove && noSuggestedThreads) {
			if ((isFeed && ([obj isKindOfClass:%c(IGBloksFeedUnitModel)] || [obj isKindOfClass:objc_getClass("IGThreadsInFeedModels.IGThreadsInFeedModel")]))
				|| [obj isKindOfClass:%c(IGSundialNetegoItem)]) remove = YES;
		}

		// Story tray
		if (!remove && hideStoriesTray && [obj isKindOfClass:%c(IGStoryDataController)]) remove = YES;

		// Hide entire feed
		if (!remove && hideEntireFeed) {
			if ([obj isKindOfClass:%c(IGPostCreationManager)] || [obj isKindOfClass:%c(IGMedia)]
				|| [obj isKindOfClass:%c(IGEndOfFeedDemarcatorModel)] || [obj isKindOfClass:%c(IGSpinnerLabelViewModel)]) remove = YES;
		}

		// Ads
		if (!remove && hideAds) {
			if (([obj isKindOfClass:%c(IGFeedItem)] && ([obj isSponsored] || [obj isSponsoredApp]))
				|| ([obj isKindOfClass:%c(IGDiscoveryGridItem)] && [[obj model] isKindOfClass:%c(IGAdItem)])
				|| [obj isKindOfClass:%c(IGAdItem)]) remove = YES;
		}

		if (remove) {
			if (!filtered) {
				filtered = [NSMutableArray arrayWithCapacity:list.count];
				NSUInteger idx = [list indexOfObjectIdenticalTo:obj];
				if (idx) [filtered addObjectsFromArray:[list subarrayWithRange:NSMakeRange(0, idx)]];
			}
			continue;
		}

		if (filtered) [filtered addObject:obj];
	}

	return filtered ? filtered.copy : list;
}

static NSArray *removeShortFeedSpinner(NSArray *list) {
	if (list.count > 5) return list;

	NSMutableArray *filtered = nil;
	for (id obj in list) {
		if ([obj isKindOfClass:%c(IGSpinnerLabelViewModel)]) {
			if (!filtered) {
				filtered = [NSMutableArray arrayWithCapacity:list.count];
				NSUInteger idx = [list indexOfObjectIdenticalTo:obj];
				if (idx) [filtered addObjectsFromArray:[list subarrayWithRange:NSMakeRange(0, idx)]];
			}
			continue;
		}
		if (filtered) [filtered addObject:obj];
	}

	return filtered ? filtered.copy : list;
}

%hook IGMainFeedListAdapterDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *sciOrig = %orig;
	return removeShortFeedSpinner(removeItemsInList(sciOrig, YES, sciHideAds(@"feed")));
}
%end

// Doom-scroll windowing — limit reels around the entry media instead of just chopping the head.
// Entry pk is read from the data source's `initialState.initialVideo` (per-tap fresh) so profile / explore
// / DM entries window around the tapped reel rather than truncating it out and falling back to index 0.

static NSString *sciMediaPk(id media) {
	if (![media respondsToSelector:@selector(pk)]) return nil;
	id pk = ((id (*)(id, SEL))objc_msgSend)(media, @selector(pk));
	return [pk isKindOfClass:NSString.class] ? pk : nil;
}

static id sciReadIvar(id obj, const char *name) {
	if (!obj) return nil;
	Ivar iv = class_getInstanceVariable([obj class], name);
	return iv ? object_getIvar(obj, iv) : nil;
}

static NSString *sciEntryMediaPk(id dataSource) {
	id state = sciReadIvar(dataSource, "initialState") ?: sciReadIvar(sciReadIvar(dataSource, "delegate"), "_initialState");
	if (![state respondsToSelector:@selector(initialVideo)]) return nil;

	id media = ((id (*)(id, SEL))objc_msgSend)(state, @selector(initialVideo));
	return sciMediaPk(media);
}

static NSArray *sciSundialFilterAndLimit(id dataSource, NSArray *list) {
	NSArray *filtered = removeItemsInList(list, NO, sciHideAds(@"reels"));

	if (![SCIUtils getBoolPref:@"prevent_doom_scrolling"]) return filtered;

	NSUInteger limit = (NSUInteger)[SCIUtils getDoublePref:@"doom_scrolling_reel_count"];
	if (!limit || filtered.count <= limit) return filtered;

	NSString *entryPk = sciEntryMediaPk(dataSource);
	if (!entryPk.length)
		return [filtered subarrayWithRange:NSMakeRange(0, MIN(limit, filtered.count))];

	NSInteger entryIdx = NSNotFound;

	for (NSUInteger i = 0; i < filtered.count; i++) {
		id obj = filtered[i];

		if ([sciMediaPk(obj) isEqualToString:entryPk]) {
			entryIdx = (NSInteger)i;
			break;
		}
	}

	// Tapped reel not in list yet — return as-is so IG keeps fetching until it lands.
	if (entryIdx == NSNotFound) return filtered;

	NSUInteger start = (NSUInteger)entryIdx;
	NSUInteger count = MIN(limit, filtered.count - start);

	return [filtered subarrayWithRange:NSMakeRange(start, count)];
}

%hook IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *sciOrig = %orig;
	return sciSundialFilterAndLimit(self, sciOrig);
}
%end

%hook _TtC13IGSundialFeed23IGSundialFeedDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *sciOrig = %orig;
	return sciSundialFilterAndLimit(self, sciOrig);
}
%end

%hook IGContextualFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	return sciHideAds(@"feed") ? removeItemsInList(list, NO, YES) : list;
}
%end

%hook IGVideoFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	return sciHideAds(@"feed") ? removeItemsInList(list, NO, YES) : list;
}
%end

%hook IGChainingFeedViewController
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	return sciHideAds(@"feed") ? removeItemsInList(list, NO, YES) : list;
}
%end

%hook IGStoryAdPool
- (id)initWithUserSession:(id)arg1 {
	return sciHideAds(@"stories") ? nil : %orig;
}
%end

%hook IGStoryAdsManager
- (id)initWithUserSession:(id)arg1 storyViewerLoggingContext:(id)arg2 storyFullscreenSectionLoggingContext:(id)arg3 viewController:(id)arg4 {
	return sciHideAds(@"stories") ? nil : %orig;
}
%end

%hook IGStoryAdsFetcher
- (id)initWithUserSession:(id)arg1 delegate:(id)arg2 {
	return sciHideAds(@"stories") ? nil : %orig;
}
%end

// IG 148.0
%hook IGStoryAdsResponseParser
- (id)parsedObjectFromResponse:(id)arg1 {
	return sciHideAds(@"stories") ? nil : %orig;
}

- (id)initWithReelStore:(id)arg1 {
	return sciHideAds(@"stories") ? nil : %orig;
}
%end

%hook IGStoryAdsOptInTextView
- (id)initWithBrandedContentStyledString:(id)arg1 sponsoredPostLabel:(id)arg2 {
	return sciHideAds(@"stories") ? nil : %orig;
}
%end

%hook IGSundialAdsResponseParser
- (id)parsedObjectFromResponse:(id)arg1 {
	return sciHideAds(@"reels") ? nil : %orig;
}

- (id)initWithMediaStore:(id)arg1 userStore:(id)arg2 {
	return sciHideAds(@"reels") ? nil : %orig;
}
%end

// "Sponsored" posts on discover / search
%hook IGExploreListKitDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	return sciHideAds(@"explore") ? removeItemsInList(list, NO, YES) : list;
}
%end

%hook _TtC28IGExploreViewControllerSwift26IGExploreListKitDataSource
- (NSArray *)objectsForListAdapter:(id)arg1 {
	NSArray *list = %orig;
	return sciHideAds(@"explore") ? removeItemsInList(list, NO, YES) : list;
}
%end

// Shopping carousel in reel comments
%hook _TtC35IGCommentThreadCommerceCarouselPill31IGCommentThreadCommerceCarousel
- (id)initWithFrame:(CGRect)frame pillText:(id)text pillStyle:(NSInteger)style {
	return sciHideAds(@"shopping") ? nil : %orig(frame, text, style);
}
%end

// Suggested search / shopping on reels
%hook _TtC27IGShoppableEverythingCommon23IGRapEntrypointResolver
- (id)initWithLauncherSet:(id)arg1 {
	return sciHideAds(@"shopping") ? nil : %orig(arg1);
}
%end

%hook _TtC32IGSundialOrganicCTAContainerView32IGSundialOrganicCTAContainerView
- (void)didMoveToWindow {
	%orig;
	if (self.window && sciHideAds(@"shopping")) [self removeFromSuperview];
}
%end

// "Suggested for you" label at end of feed
%hook IGEndOfFeedDemarcatorCellTopOfFeed
- (void)configureWithViewConfig:(id)arg1 {
	%orig;
	if (![SCIUtils getBoolPref:@"no_suggested_post"]) return;

	UILabel *_titleLabel = MSHookIvar<UILabel *>(self, "_titleLabel");
	if (_titleLabel) _titleLabel.text = @"";
}
%end

%ctor {
	%init(IGContextualFeedViewController = NSClassFromString(@"_TtC30IGContextualFeedViewController30IGContextualFeedViewController") ?: NSClassFromString(@"IGContextualFeedViewController"),
	      IGChainingFeedViewController = NSClassFromString(@"_TtC18IGPostChainingFeed28IGChainingFeedViewController") ?: NSClassFromString(@"IGChainingFeedViewController"),
	      IGStoryAdsOptInTextView = NSClassFromString(@"_TtC12IGStoryAdsUI23IGStoryAdsOptInTextView") ?: NSClassFromString(@"IGStoryAdsOptInTextView"));
}
