#import "SCIGlassMenuPopup.h"
#import "SCIUIKit26LiquidGlass.h"
#import "../Utils.h"

static UIView *gSCIMenuOverlay = nil;
static void (^gSCIMenuOnPick)(UICommand *) = nil;

#pragma mark - Linha

@interface SCIGlassMenuRow : UIControl
@property (nonatomic, strong) UICommand *command;
@end

@implementation SCIGlassMenuRow
@end

#pragma mark - Overlay (sabe descartar ao tocar fora do painel)

@interface SCIGlassMenuOverlay : UIView
@property (nonatomic, weak) UIView *panel;
@end

@implementation SCIGlassMenuOverlay
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	UITouch *t = touches.anyObject;
	CGPoint p = [t locationInView:self];
	if (self.panel && CGRectContainsPoint(self.panel.frame, p)) return; // toque no painel: ignora
	[SCIGlassMenuPopup dismiss];
}
@end

@implementation SCIGlassMenuPopup

#pragma mark Flatten

+ (NSArray<UICommand *> *)flattenMenu:(UIMenu *)menu {
	NSMutableArray<UICommand *> *out = [NSMutableArray array];
	for (UIMenuElement *el in menu.children) {
		if ([el isKindOfClass:UIMenu.class]) {
			[out addObjectsFromArray:[self flattenMenu:(UIMenu *)el]];
		} else if ([el isKindOfClass:UICommand.class]) {
			[out addObject:(UICommand *)el];
		}
	}
	return out;
}

+ (NSString *)valueForCommand:(UICommand *)cmd {
	NSDictionary *props = [cmd.propertyList isKindOfClass:NSDictionary.class] ? cmd.propertyList : nil;
	NSString *v = [props[@"value"] isKindOfClass:NSString.class] ? props[@"value"] : nil;
	return v ?: (cmd.title ?: @"");
}

#pragma mark Window

+ (UIWindow *)resolveWindowForView:(UIView *)view {
	UIWindow *window = view.window;
	if (window) return window;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		if (scene.activationState != UISceneActivationStateForegroundActive) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) return w;
		}
	}
	return nil;
}

#pragma mark Present

+ (void)presentMenu:(UIMenu *)menu
       currentValue:(NSString *)currentValue
           wordmark:(BOOL)wordmark
         sourceView:(UIView *)sourceView
             onPick:(void (^)(UICommand *))onPick {
	if (!menu || !sourceView) return;
	UIWindow *window = [self resolveWindowForView:sourceView];
	if (!window) return;

	NSArray<UICommand *> *commands = [self flattenMenu:menu];
	if (commands.count == 0) return;

	[self dismiss];
	gSCIMenuOnPick = [onPick copy];

	NSString *current = currentValue.length ? [currentValue copy] : nil;
	if (current.length == 0) {
		NSString *dkey = nil;
		for (UICommand *cmd in commands) {
			NSDictionary *props = [cmd.propertyList isKindOfClass:NSDictionary.class] ? cmd.propertyList : nil;
			NSString *k = [props[@"defaultsKey"] isKindOfClass:NSString.class] ? props[@"defaultsKey"] : nil;
			if (k.length) { dkey = k; break; }
		}
		if (dkey.length) current = [[NSUserDefaults standardUserDefaults] stringForKey:dkey];
	}
	if (current.length == 0) current = wordmark ? @"off" : @"";

	const CGFloat hPad = 16.0;
	const CGFloat checkW = 28.0;
	const CGFloat rowH = wordmark ? 58.0 : 46.0;
	const CGFloat hair = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);

	// Largura do painel.
	CGFloat panelW;
	if (wordmark) {
		panelW = 236.0;
	} else {
		CGFloat maxTitle = 0.0;
		UIFont *f = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
		for (UICommand *cmd in commands) {
			NSString *title = cmd.title ?: @"";
			CGFloat w = [title sizeWithAttributes:@{NSFontAttributeName:f}].width;
			if (w > maxTitle) maxTitle = w;
		}
		panelW = ceil(maxTitle) + checkW + hPad * 2.0 + 6.0;
		panelW = MAX(208.0, MIN(panelW, 300.0));
	}

	// Conteúdo (rows) num scroll view.
	CGFloat contentH = rowH * commands.count;
	UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, contentH)];
	content.backgroundColor = UIColor.clearColor;

	for (NSUInteger i = 0; i < commands.count; i++) {
		UICommand *cmd = commands[i];
		NSString *value = [self valueForCommand:cmd];
		BOOL selected = [value isEqualToString:current];
		CGFloat y = rowH * i;

		SCIGlassMenuRow *row = [[SCIGlassMenuRow alloc] initWithFrame:CGRectMake(0, y, panelW, rowH)];
		row.command = cmd;
		row.backgroundColor = selected ? [UIColor colorWithWhite:1.0 alpha:0.12] : UIColor.clearColor;
		[row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

		// Checkmark (coluna leading).
		if (selected) {
			UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
			check.tintColor = [SCIUtils SCIColor_Primary] ?: UIColor.labelColor;
			check.contentMode = UIViewContentModeScaleAspectFit;
			check.frame = CGRectMake(hPad, (rowH - 15.0) / 2.0, checkW - 8.0, 15.0);
			[row addSubview:check];
		}

		CGFloat bodyX = hPad + checkW;
		CGFloat bodyW = panelW - bodyX - hPad;

		if (wordmark && cmd.image) {
			UIImage *img = [cmd.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
			CGFloat maxH = 34.0;
			CGSize is = img.size;
			CGFloat scale = (is.width > 0 && is.height > 0) ? MIN(bodyW / is.width, maxH / is.height) : 1.0;
			if (scale <= 0) scale = 1.0;
			CGSize tgt = CGSizeMake(floor(is.width * scale), floor(is.height * scale));
			UIImageView *iv = [[UIImageView alloc] initWithImage:img];
			iv.tintColor = UIColor.labelColor;
			iv.contentMode = UIViewContentModeScaleAspectFit;
			iv.frame = CGRectMake(bodyX, (rowH - tgt.height) / 2.0, tgt.width, tgt.height);
			[row addSubview:iv];
		} else {
			UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(bodyX, 0, bodyW, rowH)];
			label.text = cmd.title ?: @"";
			label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
			label.textColor = UIColor.labelColor;
			label.lineBreakMode = NSLineBreakByTruncatingTail;
			[row addSubview:label];
		}

		// Separador (entre linhas, alinhado ao conteúdo).
		if (i + 1 < commands.count) {
			UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(bodyX, rowH - hair, panelW - bodyX, hair)];
			sep.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.45];
			sep.userInteractionEnabled = NO;
			[row addSubview:sep];
		}

		[content addSubview:row];
	}

	// Painel glass.
	CGFloat maxPanelH = MIN(window.bounds.size.height * 0.6, 440.0);
	CGFloat panelH = MIN(contentH, maxPanelH);

	SCIUIKit26GlassPanelView *panel = [[SCIUIKit26GlassPanelView alloc] initWithRadius:18.0];
	panel.sciGlassInteractive = NO;

	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
	scroll.contentSize = CGSizeMake(panelW, contentH);
	scroll.showsVerticalScrollIndicator = (contentH > panelH);
	scroll.alwaysBounceVertical = (contentH > panelH);
	scroll.backgroundColor = UIColor.clearColor;
	[scroll addSubview:content];
	[panel.contentView addSubview:scroll];

	// Posicionamento ancorado ao sourceView.
	CGRect src = [sourceView convertRect:sourceView.bounds toView:window];
	UIEdgeInsets safe = window.safeAreaInsets;
	const CGFloat margin = 8.0;

	CGFloat px = src.origin.x + src.size.width - panelW; // alinha borda direita ao botão
	px = MAX(safe.left + margin, MIN(px, window.bounds.size.width - safe.right - margin - panelW));

	CGFloat belowY = CGRectGetMaxY(src) + 6.0;
	CGFloat py;
	if (belowY + panelH <= window.bounds.size.height - safe.bottom - margin) {
		py = belowY; // abaixo do botão
	} else {
		CGFloat aboveY = src.origin.y - 6.0 - panelH;
		if (aboveY >= safe.top + margin) {
			py = aboveY; // acima do botão
		} else {
			py = safe.top + margin; // não cabe: cola no topo seguro
			panelH = MIN(panelH, window.bounds.size.height - safe.bottom - margin - py);
			scroll.frame = CGRectMake(0, 0, panelW, panelH);
			scroll.showsVerticalScrollIndicator = YES;
			scroll.alwaysBounceVertical = YES;
		}
	}
	panel.frame = CGRectMake(floor(px), floor(py), panelW, panelH);

	// Overlay.
	SCIGlassMenuOverlay *overlay = [[SCIGlassMenuOverlay alloc] initWithFrame:window.bounds];
	overlay.backgroundColor = UIColor.clearColor;
	overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	overlay.panel = panel;
	[overlay addSubview:panel];
	[window addSubview:overlay];
	gSCIMenuOverlay = overlay;

	// Animação de entrada.
	overlay.alpha = 0.0;
	panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
	[UIView animateWithDuration:0.18 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
		overlay.alpha = 1.0;
		panel.transform = CGAffineTransformIdentity;
	} completion:nil];

	UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
	[fb selectionChanged];
}

+ (void)rowTapped:(SCIGlassMenuRow *)row {
	UICommand *cmd = row.command;
	void (^cb)(UICommand *) = gSCIMenuOnPick;
	UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	[fb impactOccurred];
	[self dismiss];
	if (cb && cmd) cb(cmd);
}

+ (void)dismiss {
	UIView *overlay = gSCIMenuOverlay;
	gSCIMenuOverlay = nil;
	gSCIMenuOnPick = nil;
	if (!overlay) return;
	[UIView animateWithDuration:0.14 animations:^{
		overlay.alpha = 0.0;
	} completion:^(BOOL finished) {
		[overlay removeFromSuperview];
	}];
}

@end
