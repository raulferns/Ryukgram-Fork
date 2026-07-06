// Speed module — registers a "Speed" section in the Playback menu.
// Applies to every IGVideoView app-wide (reels, feed, profile, DMs).
// Selected rate persists across swipes and app restarts (defaults-backed).

#import "SCIReelsPlaybackMenu.h"
#import "../../../Utils.h"
#import "../../../InstagramHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>

static inline BOOL sciSpeedEnabled(void) {
	return [SCIUtils getBoolPref:@"reels_playback_speed"];
}

static float sciSpeedRate(void) {
	double v = [SCIUtils getDoublePref:@"reels_playback_speed_rate"];
	if (v < 0.5 || v > 2.0) v = 1.0;
	return (float)v;
}

static void sciStoreSpeedRate(float rate) {
	if (rate < 0.5f) rate = 0.5f;
	if (rate > 2.0f) rate = 2.0f;
	[[NSUserDefaults standardUserDefaults] setDouble:rate forKey:@"reels_playback_speed_rate"];
}

static void sciApplyRateOnce(float rate) {
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if (![s isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *win in ((UIWindowScene *)s).windows) {
			NSMutableArray *stack = [@[ win ] mutableCopy];
			while (stack.count) {
				UIView *v = stack.lastObject; [stack removeLastObject];
				if ([NSStringFromClass([v class]) hasSuffix:@"IGVideoView"]) {
					if ([v respondsToSelector:@selector(setPlaybackSpeedWithSpeed:)]) {
						@try {
							((void(*)(id, SEL, float))objc_msgSend)
								(v, @selector(setPlaybackSpeedWithSpeed:), rate);
						} @catch (__unused id e) {}
					}
				}
				[stack addObjectsFromArray:v.subviews];
			}
		}
	}
}

static void sciApplyRateEverywhere(float rate) {
	sciApplyRateOnce(rate);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ sciApplyRateOnce(rate); });
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ sciApplyRateOnce(rate); });
}

#pragma mark - Speed section view

@interface SCIReelsSpeedView : UIView <UIScrollViewDelegate>
@end

@implementation SCIReelsSpeedView {
	UIView *_container;
	UIScrollView *_scroll;
	UIStackView *_row;
	NSArray<UIButton *> *_pills;
	UIButton *_customPill;
	CAGradientLayer *_leftFade;
	CAGradientLayer *_rightFade;
	UIImageView *_leftArrow;
	UIImageView *_rightArrow;
	float _current;
}

- (instancetype)init {
	if ((self = [super initWithFrame:CGRectZero])) {
		self.translatesAutoresizingMaskIntoConstraints = NO;
		_current = sciSpeedRate();

		_container = [UIView new];
		_container.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:_container];

		_scroll = [UIScrollView new];
		_scroll.translatesAutoresizingMaskIntoConstraints = NO;
		_scroll.showsHorizontalScrollIndicator = NO;
		_scroll.contentInset = UIEdgeInsetsMake(0, 14, 0, 14);
		_scroll.delegate = self;
		[_container addSubview:_scroll];

		_row = [UIStackView new];
		_row.translatesAutoresizingMaskIntoConstraints = NO;
		_row.axis = UILayoutConstraintAxisHorizontal;
		_row.spacing = 6;
		_row.alignment = UIStackViewAlignmentCenter;
		[_scroll addSubview:_row];

		NSArray<NSNumber *> *rates = @[ @0.5f, @0.75f, @1.0f, @1.25f, @1.5f, @2.0f ];
		NSMutableArray<UIButton *> *pills = [NSMutableArray array];
		for (NSNumber *r in rates) {
			UIButton *pill = [self _pillWithRate:r.floatValue];
			[_row addArrangedSubview:pill];
			[pills addObject:pill];
		}
		_pills = pills;

		_customPill = [UIButton buttonWithType:UIButtonTypeCustom];
		_customPill.translatesAutoresizingMaskIntoConstraints = NO;
		[_customPill setTitle:SCILocalized(@"Custom") forState:UIControlStateNormal];
		_customPill.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
		_customPill.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
		_customPill.layer.cornerRadius = 16;
		_customPill.layer.cornerCurve = kCACornerCurveContinuous;
		_customPill.layer.borderWidth = 1;
		_customPill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
		[_customPill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
		[_customPill addTarget:self action:@selector(_onCustomTap) forControlEvents:UIControlEventTouchUpInside];
		[_customPill.heightAnchor constraintEqualToConstant:32].active = YES;
		[_row addArrangedSubview:_customPill];

		[self _refreshPills];

		_leftFade = [CAGradientLayer layer];
		_leftFade.colors = @[ (id)[UIColor colorWithWhite:0.08 alpha:1.0].CGColor,
							  (id)[UIColor colorWithWhite:0.08 alpha:0.0].CGColor ];
		_leftFade.startPoint = CGPointMake(0, 0.5);
		_leftFade.endPoint = CGPointMake(1, 0.5);
		_leftFade.opacity = 0;
		[_container.layer addSublayer:_leftFade];

		_rightFade = [CAGradientLayer layer];
		_rightFade.colors = @[ (id)[UIColor colorWithWhite:0.08 alpha:0.0].CGColor,
							   (id)[UIColor colorWithWhite:0.08 alpha:1.0].CGColor ];
		_rightFade.startPoint = CGPointMake(0, 0.5);
		_rightFade.endPoint = CGPointMake(1, 0.5);
		_rightFade.opacity = 1;
		[_container.layer addSublayer:_rightFade];

		UIImageSymbolConfiguration *arrCfg = [UIImageSymbolConfiguration
			configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
		_leftArrow = [[UIImageView alloc] initWithImage:
			[UIImage systemImageNamed:@"chevron.left" withConfiguration:arrCfg]];
		_leftArrow.translatesAutoresizingMaskIntoConstraints = NO;
		_leftArrow.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
		_leftArrow.alpha = 0;
		_leftArrow.contentMode = UIViewContentModeCenter;
		[_container addSubview:_leftArrow];

		_rightArrow = [[UIImageView alloc] initWithImage:
			[UIImage systemImageNamed:@"chevron.right" withConfiguration:arrCfg]];
		_rightArrow.translatesAutoresizingMaskIntoConstraints = NO;
		_rightArrow.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
		_rightArrow.alpha = 1;
		_rightArrow.contentMode = UIViewContentModeCenter;
		[_container addSubview:_rightArrow];

		[NSLayoutConstraint activateConstraints:@[
			[_container.topAnchor constraintEqualToAnchor:self.topAnchor],
			[_container.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[_container.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[_container.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[_container.heightAnchor constraintEqualToConstant:40],

			[_scroll.leadingAnchor constraintEqualToAnchor:_container.leadingAnchor],
			[_scroll.trailingAnchor constraintEqualToAnchor:_container.trailingAnchor],
			[_scroll.topAnchor constraintEqualToAnchor:_container.topAnchor],
			[_scroll.bottomAnchor constraintEqualToAnchor:_container.bottomAnchor],

			[_row.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
			[_row.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
			[_row.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor],
			[_row.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor],
			[_row.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],

			[_leftArrow.leadingAnchor constraintEqualToAnchor:_container.leadingAnchor constant:4],
			[_leftArrow.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
			[_leftArrow.widthAnchor constraintEqualToConstant:18],
			[_leftArrow.heightAnchor constraintEqualToConstant:32],

			[_rightArrow.trailingAnchor constraintEqualToAnchor:_container.trailingAnchor constant:-4],
			[_rightArrow.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
			[_rightArrow.widthAnchor constraintEqualToConstant:18],
			[_rightArrow.heightAnchor constraintEqualToConstant:32],
		]];
	}
	return self;
}

- (UIButton *)_pillWithRate:(float)v {
	UIButton *p = [UIButton buttonWithType:UIButtonTypeCustom];
	p.translatesAutoresizingMaskIntoConstraints = NO;
	NSString *t = (v == (int)v) ? [NSString stringWithFormat:@"%d×", (int)v]
								: [NSString stringWithFormat:@"%g×", v];
	[p setTitle:t forState:UIControlStateNormal];
	p.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
	p.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
	p.layer.cornerRadius = 16;
	p.layer.cornerCurve = kCACornerCurveContinuous;
	p.tag = (NSInteger)(v * 100);
	[p addTarget:self action:@selector(_onPillTap:) forControlEvents:UIControlEventTouchUpInside];
	[p.heightAnchor constraintEqualToConstant:32].active = YES;
	return p;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat fadeW = 22;
	CGRect b = _container.bounds;
	_leftFade.frame = CGRectMake(0, 0, fadeW, b.size.height);
	_rightFade.frame = CGRectMake(b.size.width - fadeW, 0, fadeW, b.size.height);
	[self _updateFades];
}

- (void)_updateFades {
	CGFloat ox = _scroll.contentOffset.x + _scroll.contentInset.left;
	CGFloat maxX = _scroll.contentSize.width + _scroll.contentInset.left
				 + _scroll.contentInset.right - _scroll.bounds.size.width;
	BOOL canLeft = ox > 4;
	BOOL canRight = ox < (maxX - 4);
	_leftFade.opacity = canLeft ? 1.0 : 0.0;
	_rightFade.opacity = canRight ? 1.0 : 0.0;
	[UIView animateWithDuration:0.18 animations:^{
		_leftArrow.alpha = canLeft ? 1.0 : 0.0;
		_rightArrow.alpha = canRight ? 1.0 : 0.0;
	}];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView { [self _updateFades]; }

- (void)_refreshPills {
	BOOL anyPreset = NO;
	for (UIButton *p in _pills) {
		float v = (float)p.tag / 100.0f;
		BOOL sel = fabsf(v - _current) < 0.01f;
		if (sel) anyPreset = YES;
		p.backgroundColor = sel ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.10];
		[p setTitleColor:sel ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
	}
	BOOL customSel = !anyPreset;
	_customPill.backgroundColor = customSel ? [UIColor whiteColor] : [UIColor clearColor];
	_customPill.layer.borderColor = customSel ? [UIColor whiteColor].CGColor
											  : [UIColor colorWithWhite:1 alpha:0.30].CGColor;
	[_customPill setTitleColor:customSel ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
	if (customSel) {
		[_customPill setTitle:[NSString stringWithFormat:@"%g×", _current] forState:UIControlStateNormal];
	} else {
		[_customPill setTitle:SCILocalized(@"Custom") forState:UIControlStateNormal];
	}
}

- (void)_apply:(float)v {
	_current = v;
	sciStoreSpeedRate(v);
	sciApplyRateEverywhere(v);
	[self _refreshPills];
	UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	[h impactOccurred];
}

- (void)_onPillTap:(UIButton *)sender {
	[self _apply:(float)sender.tag / 100.0f];
}

- (void)_onCustomTap {
	UIViewController *presenter = nil;
	for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
		if (![s isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)s).windows) {
			if (w.isKeyWindow) { presenter = w.rootViewController; break; }
		}
		if (presenter) break;
	}
	while (presenter.presentedViewController) presenter = presenter.presentedViewController;
	if (!presenter) return;

	UIAlertController *ac = [UIAlertController
		alertControllerWithTitle:SCILocalized(@"Custom speed")
						 message:SCILocalized(@"Enter a value between 0.5 and 2.0")
				  preferredStyle:UIAlertControllerStyleAlert];
	[ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.keyboardType = UIKeyboardTypeDecimalPad;
		tf.placeholder = SCILocalized(@"e.g. 1.75");
		tf.text = [NSString stringWithFormat:@"%.2f", _current];
		tf.clearButtonMode = UITextFieldViewModeAlways;
	}];
	__weak SCIReelsSpeedView *ws = self;
	[ac addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Apply")
										   style:UIAlertActionStyleDefault
										 handler:^(UIAlertAction *a) {
		float v = ac.textFields.firstObject.text.floatValue;
		if (v < 0.5f) v = 0.5f;
		if (v > 2.0f) v = 2.0f;
		[ws _apply:v];
	}]];
	[ac addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
	[presenter presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - Module registration + speed hook

%ctor {
	[SCIReelsPlaybackMenu registerModuleWithID:@"speed"
		isOn:^BOOL { return sciSpeedEnabled(); }
		buildSection:^UIView *{
			return [[SCIReelsPlaybackSection alloc] initWithTitle:SCILocalized(@"Speed")
														 content:[SCIReelsSpeedView new]];
		}];
}

// Apply our rate on the IGVideoView itself. setPlaybackSpeedWithSpeed: is the
// rate setter; calling it is idempotent.
static void sciApplyRateToSelf(id view) {
	if (!sciSpeedEnabled()) return;
	float rate = sciSpeedRate();
	if (fabsf(rate - 1.0f) < 0.001f) return;
	if (![view respondsToSelector:@selector(setPlaybackSpeedWithSpeed:)]) return;
	@try {
		((void(*)(id, SEL, float))objc_msgSend)
			(view, @selector(setPlaybackSpeedWithSpeed:), rate);
	} @catch (__unused id e) {}
}

// IGVideoView is the player delegate for every IG video surface (reels, feed,
// profile, DMs). IG starts new videos at 1× without calling setPlaybackSpeed,
// so re-apply our rate on each play-lifecycle callback. setPlaybackSpeedWithSpeed:
// is also overridden so IG's own resets land on our rate.
%hook _TtC11IGVideoView11IGVideoView

- (void)setPlaybackSpeedWithSpeed:(float)speed {
	if (sciSpeedEnabled()) {
		float ours = sciSpeedRate();
		if (ours > 0 && fabsf(ours - 1.0f) > 0.001f) {
			%orig(ours);
			return;
		}
	}
	%orig(speed);
}

- (void)videoPlayerDidInitialPlay:(id)player {
	%orig;
	sciApplyRateToSelf(self);
}
- (void)videoPlayerDidReadyToDisplay:(id)player {
	%orig;
	sciApplyRateToSelf(self);
}
- (void)videoPlayerDidFinishPrepare:(id)player {
	%orig;
	sciApplyRateToSelf(self);
}
- (void)videoPlayerDidUnpause:(id)player {
	%orig;
	sciApplyRateToSelf(self);
}

%end
