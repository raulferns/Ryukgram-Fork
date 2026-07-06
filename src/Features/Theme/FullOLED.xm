// Replace IG near-black surfaces with pure black under OLED mode.
// RyukGram surfaces are exempt — they keep the stock iOS appearance.

#import "../../Utils.h"
#import "SCITheme.h"

static NSArray *SCIFlatOLEDColors(NSArray *colors) {
	if (!colors.count) return nil;

	for (id raw in colors) {
		if (![SCITheme cgColorIsNearBlack:(__bridge CGColorRef)raw]) return nil;
	}

	id black = (__bridge id)[SCITheme backgroundColor].CGColor;
	NSMutableArray *flat = [NSMutableArray arrayWithCapacity:colors.count];

	for (NSUInteger i = 0; i < colors.count; i++) {
		[flat addObject:black];
	}

	return flat;
}

// IG surfaces whose grey matches page-background values but must stay grey
// (buttons, search fields, Notes bubbles). Matched on the view + its ancestors.
static NSArray<NSString *> *SCIOLEDKeepGreyClasses(void) {
	static NSArray *names;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ names = @[@"NotesIconic", @"IGSearchBar", @"IGProfilePhotoView", @"IGShortenableTextButton", @"BKBloksFlexboxView", @"IGMediaThumbnailView"]; });
	return names;
}

static BOOL SCIColorIsDynamic(UIColor *color) {
	return [NSStringFromClass([color class]) containsString:@"Dynamic"];
}

static BOOL SCIOLEDKeepGrey(UIView *view) {
	NSArray<NSString *> *keep = SCIOLEDKeepGreyClasses();
	for (UIView *v = view; v; v = v.superview) {
		NSString *cls = NSStringFromClass([v class]);
		for (NSString *needle in keep) {
			if ([cls containsString:needle]) return YES;
		}
	}
	return NO;
}

// Views are often colored before joining a hierarchy — no responder chain yet to
// prove RyukGram ownership. Stash the color and undo the flatten on attach.
static const void *kSCIFlattenedOriginalKey = &kSCIFlattenedOriginalKey;

%group OLEDRecolorGroup

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
	if (!color) {
		%orig;
		return;
	}

	// Only dynamic colors read light at set-time; static ones resolve to themselves,
	// so skip the trait resolve on the hot path.
	UIColor *resolved = SCIColorIsDynamic(color) ? [color resolvedColorWithTraitCollection:self.traitCollection] : color;

	if ([SCITheme colorIsDarkSurface:resolved] && !SCIOLEDKeepGrey(self)) {
		if ([SCITheme isTweakSurface:self]) {
			%orig;
			return;
		}
		objc_setAssociatedObject(self, kSCIFlattenedOriginalKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		%orig([SCITheme backgroundColor]);
		return;
	}

	objc_setAssociatedObject(self, kSCIFlattenedOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	%orig;
}

- (void)didMoveToWindow {
	%orig;
	if (!self.window) return;

	UIColor *original = objc_getAssociatedObject(self, kSCIFlattenedOriginalKey);
	if (!original) return;

	objc_setAssociatedObject(self, kSCIFlattenedOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	if ([SCITheme isTweakSurface:self]) {
		// Re-enters the hook; chain now proves ownership.
		self.backgroundColor = original;
	}
}

%end

%hook CAGradientLayer

- (void)setColors:(NSArray *)colors {
	NSArray *flat = SCIFlatOLEDColors(colors);
	%orig(flat ?: colors);
}

%end

%end

%ctor {
	[SCITheme migrateLegacyPrefs];

	if ([SCITheme shouldRecolor]) {
		%init(OLEDRecolorGroup);
	}
}
