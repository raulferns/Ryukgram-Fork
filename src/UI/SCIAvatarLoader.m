#import "SCIAvatarLoader.h"
#import "../SCIImageCache.h"
#import "../Features/StoriesAndMessages/SCIDirectUserResolver.h"
#import "../Features/StoriesAndMessages/SCIDirectThreadInfo.h"
#import "../Networking/SCIInstagramAPI.h"
#import "../Utils.h"

NSString *const SCIAvatarLoadedNotification = @"SCIAvatarLoadedNotification";

static NSCache<NSString *, UIImage *> *sciAvatarCache(void) {
	static NSCache *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = [NSCache new];
		cache.countLimit = 150;
	});
	return cache;
}

static NSMutableSet<NSString *> *sciAvatarLoading(void) {
	static NSMutableSet *set;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ set = [NSMutableSet new]; });
	return set;
}

// 48pt gray disc + glyph so it sits in the cell like a real profile picture.
static UIImage *sciAvatarPlaceholder(BOOL group) {
	BOOL dark = UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
	static NSMutableDictionary<NSString *, UIImage *> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });

	NSString *key = [NSString stringWithFormat:@"%d-%d", group, dark];
	UIImage *img = cache[key];
	if (img) return img;

	CGSize size = CGSizeMake(48.0, 48.0);
	UIGraphicsImageRendererFormat *fmt = UIGraphicsImageRendererFormat.preferredFormat;
	fmt.opaque = NO;

	UIImage *glyph = [UIImage systemImageNamed:group ? @"person.2.fill" : @"person.fill"
							 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium]];
	UIColor *disc = dark ? [UIColor colorWithWhite:0.25 alpha:1] : [UIColor colorWithWhite:0.78 alpha:1];
	UIColor *tint = dark ? [UIColor colorWithWhite:0.55 alpha:1] : UIColor.whiteColor;

	img = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt] imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
		[disc setFill];
		[[UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, size}] fill];

		UIImage *tinted = [glyph imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
		CGSize gs = tinted.size;
		[tinted drawInRect:CGRectMake((size.width - gs.width) / 2.0, (size.height - gs.height) / 2.0, gs.width, gs.height)];
	}];

	if (img) cache[key] = img;
	return img;
}

static UIImage *sciRoundedAvatar(UIImage *src) {
	if (!src) return nil;

	CGSize size = CGSizeMake(48.0, 48.0);
	UIGraphicsImageRendererFormat *fmt = UIGraphicsImageRendererFormat.preferredFormat;
	fmt.opaque = NO;

	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt] imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
		[[UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, size}] addClip];
		[src drawInRect:(CGRect){CGPointZero, size}];
	}];
}

static NSString *sciAvatarText(id v) {
	return [v isKindOfClass:NSString.class] ? v : @"";
}

// pk/thread → backfilled pic URL. Memory-only; the image itself disk-caches.
static NSMutableDictionary<NSString *, NSString *> *sciPKURLCache(void) {
	static NSMutableDictionary *map;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ map = [NSMutableDictionary new]; });
	return map;
}

static void sciBackfillPicForPK(NSString *pk) {
	static NSMutableSet<NSString *> *inflight;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ inflight = [NSMutableSet new]; });

	@synchronized (inflight) {
		if ([inflight containsObject:pk]) return;
		[inflight addObject:pk];
	}

	[SCIInstagramAPI sendRequestWithMethod:@"GET"
									  path:[NSString stringWithFormat:@"users/%@/info/", pk]
									  body:nil
								completion:^(NSDictionary *resp, NSError *error) {
		@synchronized (inflight) { [inflight removeObject:pk]; }

		NSDictionary *user = [resp[@"user"] isKindOfClass:NSDictionary.class] ? resp[@"user"] : nil;
		NSString *pic = sciAvatarText(user[@"profile_pic_url"]);
		if (!pic.length) return;

		@synchronized (sciPKURLCache()) { sciPKURLCache()[pk] = pic; }
		dispatch_async(dispatch_get_main_queue(), ^{
			[NSNotificationCenter.defaultCenter postNotificationName:SCIAvatarLoadedNotification object:nil];
		});
	}];
}

// thread_image ships as a URL string, a url/uri dict, or a media dict with
// image_versions2.candidates depending on IG version.
static NSString *sciImageURLFromThreadImage(id ti) {
	if ([ti isKindOfClass:NSString.class]) return (NSString *)ti;
	if (![ti isKindOfClass:NSDictionary.class]) return nil;

	NSDictionary *d = ti;
	NSString *url = sciAvatarText(d[@"url"]);
	if (!url.length) url = sciAvatarText(d[@"uri"]);
	if (url.length) return url;

	NSDictionary *iv2 = [d[@"image_versions2"] isKindOfClass:NSDictionary.class] ? d[@"image_versions2"] : nil;
	NSArray *candidates = [iv2[@"candidates"] isKindOfClass:NSArray.class] ? iv2[@"candidates"] : nil;
	NSDictionary *best = nil;
	for (NSDictionary *c in candidates) {
		if (![c isKindOfClass:NSDictionary.class]) continue;
		if (!best || [c[@"width"] doubleValue] > [best[@"width"] doubleValue]) best = c;
	}
	return sciAvatarText(best[@"url"]);
}

// Group avatar: live direct cache first (no API call), then the thread API.
static void sciBackfillGroupAvatarForThread(NSString *tid) {
	static NSMutableSet<NSString *> *inflight;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ inflight = [NSMutableSet new]; });

	@synchronized (inflight) {
		if ([inflight containsObject:tid]) return;
		[inflight addObject:tid];
	}

	void (^finish)(NSString *) = ^(NSString *pic) {
		@synchronized (inflight) { [inflight removeObject:tid]; }
		if (!pic.length) return;
		@synchronized (sciPKURLCache()) { sciPKURLCache()[[@"t:" stringByAppendingString:tid]] = pic; }
		dispatch_async(dispatch_get_main_queue(), ^{
			[NSNotificationCenter.defaultCenter postNotificationName:SCIAvatarLoadedNotification object:nil];
		});
	};

	NSString *owner = [SCIUtils currentUserPK];
	[SCIDirectThreadInfo fetchThreadId:tid ownerPK:owner completion:^(id thread) {
		NSDictionary *gi = thread ? [SCIDirectThreadInfo groupInfoForThread:thread viewerPK:owner] : nil;
		NSString *img = [gi[@"image"] isKindOfClass:NSString.class] ? gi[@"image"] : nil;
		if (img.length) { finish(img); return; }

		[SCIInstagramAPI sendRequestWithMethod:@"GET"
										  path:[NSString stringWithFormat:@"direct_v2/threads/%@/", tid]
										  body:nil
									completion:^(NSDictionary *resp, __unused NSError *error) {
			NSDictionary *t = [resp[@"thread"] isKindOfClass:NSDictionary.class] ? resp[@"thread"] : nil;
			NSString *pic = [t[@"thread_avatar_url"] isKindOfClass:NSString.class] ? t[@"thread_avatar_url"] : nil;
			if (!pic.length) pic = sciImageURLFromThreadImage(t[@"thread_image"]);
			finish(pic);
		}];
	}];
}

static NSDictionary *sciSingleUser(NSDictionary *e) {
	NSArray *users = [e[@"users"] isKindOfClass:NSArray.class] ? e[@"users"] : @[];
	return users.count == 1 && [users.firstObject isKindOfClass:NSDictionary.class] ? users.firstObject : nil;
}

static NSString *sciAvatarURLForEntry(NSDictionary *e) {
	NSString *url = sciAvatarText(e[@"avatarURL"]);
	if (url.length) return url;

	url = sciAvatarText(e[@"profilePicURL"]);
	if (url.length) return url;

	if ([e[@"isGroup"] boolValue]) {
		NSString *tid = sciAvatarText(e[@"threadId"]);
		if (!tid.length) return @"";

		@synchronized (sciPKURLCache()) {
			NSString *cached = sciPKURLCache()[[@"t:" stringByAppendingString:tid]];
			if (cached.length) return cached;
		}

		sciBackfillGroupAvatarForThread(tid);
		return @"";
	}

	NSDictionary *u = sciSingleUser(e);
	url = sciAvatarText(u[@"profilePicURL"]);
	if (url.length) return url;

	NSString *pk = sciAvatarText(e[@"pk"]);
	if (!pk.length) pk = sciAvatarText(u[@"pk"]);
	if (!pk.length) {
		NSArray *users = [e[@"users"] isKindOfClass:NSArray.class] ? e[@"users"] : @[];
		for (NSDictionary *cand in users) {
			if ([cand isKindOfClass:NSDictionary.class] && sciAvatarText(cand[@"pk"]).length) { pk = sciAvatarText(cand[@"pk"]); break; }
		}
	}
	if (!pk.length) return @"";

	@synchronized (sciPKURLCache()) {
		NSString *cached = sciPKURLCache()[pk];
		if (cached.length) return cached;
	}

	NSString *resolved = sciDirectUserResolverProfilePicURLStringForPK(pk);
	if (resolved.length) return resolved;

	sciBackfillPicForPK(pk);
	return @"";
}

@implementation SCIAvatarLoader

+ (UIImage *)avatarForEntry:(NSDictionary *)entry {
	BOOL group = [entry[@"isGroup"] boolValue];
	return [self avatarForURLString:sciAvatarURLForEntry(entry) group:group];
}

+ (UIImage *)avatarForURLString:(NSString *)urlString group:(BOOL)group {
	if (!urlString.length) return sciAvatarPlaceholder(group);

	UIImage *cached = [sciAvatarCache() objectForKey:urlString];
	if (cached) return cached;

	NSURL *url = [NSURL URLWithString:urlString];
	if (!url) return sciAvatarPlaceholder(group);

	@synchronized (sciAvatarLoading()) {
		if ([sciAvatarLoading() containsObject:urlString]) return sciAvatarPlaceholder(group);
		[sciAvatarLoading() addObject:urlString];
	}

	// Cache key drops the query string — CDN signatures rotate, the asset path doesn't.
	[SCIImageCache loadImageFromURL:url cacheKey:(url.path.length ? url.path : nil) completion:^(UIImage *image) {
		UIImage *rounded = sciRoundedAvatar(image);
		if (rounded) [sciAvatarCache() setObject:rounded forKey:urlString];

		@synchronized (sciAvatarLoading()) {
			[sciAvatarLoading() removeObject:urlString];
		}

		if (rounded) {
			[NSNotificationCenter.defaultCenter postNotificationName:SCIAvatarLoadedNotification object:nil];
		}
	}];

	return sciAvatarPlaceholder(group);
}

@end
