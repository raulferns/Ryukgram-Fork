// Recolors Direct message bubbles per background (incoming / outgoing / both). Each bubble
// resolves its own thread from its thread VC so styling never leaks across recycled cells.

#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import "SCIChatBackgroundManager.h"
#import "SCIChatBgThreadPickerVC.h"
#import "SCIChatBgIvars.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <QuartzCore/QuartzCore.h>

static const void *kSCIOrigBgKey = &kSCIOrigBgKey;
static const void *kSCIOurGradientKey = &kSCIOurGradientKey;
static const void *kSCIApplyingKey = &kSCIApplyingKey;
static const void *kSCIOrigTextColorKey = &kSCIOrigTextColorKey;
static const void *kSCIAppliedTextColorKey = &kSCIAppliedTextColorKey;
static const void *kSCITextApplyingKey = &kSCITextApplyingKey;
static const void *kSCISurfaceSolidKey = &kSCISurfaceSolidKey;
static const void *kSCIAudioOrigTintKey = &kSCIAudioOrigTintKey;
static const void *kSCIAudioOrigBgKey = &kSCIAudioOrigBgKey;

static void sciRestoreTextInside(UIView *view);
static void sciRestoreParentTextColor(UIView *view);
static void sciRestoreGradientSurface(UIView *gv);
static BOOL sciIsInsideAudioBubble(UIView *view);
static void sciRecolorAudioChrome(UIView *audioRoot, UIColor *color, BOOL apply);

// Visible bubbles, re-applied when colors/sides change in-chat.
static NSHashTable<UIView *> *sciLiveBubbles(void) {
	static NSHashTable *t;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
	return t;
}

// Per-view thread resolution (cached on the thread VC) so recycled cells never carry a
// previous chat's background into a new one.
static const void *kSCIVCThreadIDKey = &kSCIVCThreadIDKey;

static UIViewController *sciThreadVCForView(UIView *view) {
	static Class tc;
	if (!tc) tc = NSClassFromString(@"IGDirectThreadViewController");
	if (!tc) return nil;

	for (UIResponder *r = view; r; r = r.nextResponder) {
		if ([r isKindOfClass:tc]) return (UIViewController *)r;
	}
	return nil;
}

static NSString *sciThreadIDForView(UIView *view) {
	id vc = sciThreadVCForView(view);
	if (!vc) return nil;

	NSString *cached = objc_getAssociatedObject(vc, kSCIVCThreadIDKey);
	if (cached.length) return cached;

	id session = SCIBgIvarValue(vc, "_threadSession");
	NSString *tid = SCIBgReadTidFromContainer(SCIBgFindThreadKey(session));
	if (tid.length) objc_setAssociatedObject(vc, kSCIVCThreadIDKey, tid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return tid;
}

static NSString *sciBubbleAssetForView(UIView *view) {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	if (![m isEnabled]) return nil;

	NSString *tid = sciThreadIDForView(view);
	if (!tid.length) return nil;

	NSString *asset = [m resolvedAssetForThreadID:tid];
	if (!asset.length) return nil;

	return [m autoBubbleEnabledForAsset:asset] ? asset : nil;
}

static BOOL sciSideAllowedForAsset(NSString *asset, BOOL outgoing) {
	SCIBubbleSides sides = asset ? [[SCIChatBackgroundManager shared] bubbleSidesForAsset:asset] : SCIBubbleSidesIncoming;
	if (sides == SCIBubbleSidesBoth) return YES;
	return outgoing ? (sides == SCIBubbleSidesOutgoing) : (sides == SCIBubbleSidesIncoming);
}

static SCIBubbleGradientDirection sciGradientDirectionForAsset(NSString *asset) {
	return asset ? [[SCIChatBackgroundManager shared] bubbleGradientDirectionForAsset:asset] : SCIBubbleGradientDirectionDiagonal;
}

static BOOL sciColorVisible(UIColor *color) {
	return color && CGColorGetAlpha(color.CGColor) > 0.05;
}

static BOOL sciIsOutgoingBubble(UIView *view) {
	UIWindow *win = view.window;
	if (!win) return NO;

	CGRect f = [view convertRect:view.bounds toView:win];
	CGFloat left = CGRectGetMinX(f);
	CGFloat right = CGRectGetWidth(win.bounds) - CGRectGetMaxX(f);

	return right + 2.0 < left;
}

static void sciEachSubview(UIView *view, void (^block)(UIView *sub)) {
	if (!view || !block) return;

	for (UIView *sub in view.subviews) {
		block(sub);
		sciEachSubview(sub, block);
	}
}

static Class sciIGGradientViewClass(void) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGGradientView");
	return c;
}

static Class sciIGDirectGradientViewClass(void) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGDirectGradientView");
	return c;
}

static BOOL sciIsIGGradientView(UIView *view) {
	Class c = sciIGGradientViewClass();
	return c && [view isKindOfClass:c];
}

static BOOL sciIsIGDirectGradientView(UIView *view) {
	Class c = sciIGDirectGradientViewClass();
	return c && [view isKindOfClass:c];
}

static BOOL sciIsAnyGradientView(UIView *view) {
	return sciIsIGGradientView(view) || sciIsIGDirectGradientView(view);
}

static Class sciIGBubbleViewClass(void) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGDirectMessageBubbleView");
	return c;
}

// Normal messages use IGDirectMessageBubbleView; replies use IGDirectContextReplyBubbleView.
static UIView *sciEnclosingBubble(UIView *view) {
	Class c = sciIGBubbleViewClass();
	for (UIView *v = view; v; v = v.superview) {
		if (c && [v isKindOfClass:c]) return v;
		if ([NSStringFromClass(v.class) containsString:@"ContextReplyBubble"]) return v;
	}
	return nil;
}

static BOOL sciHasNativeGradient(UIView *view) {
	__block BOOL found = NO;

	sciEachSubview(view, ^(UIView *sub) {
		if (!found && sciIsIGGradientView(sub)) found = YES;
	});

	return found;
}

static void sciHideNativeGradients(UIView *view, BOOL hidden) {
	sciEachSubview(view, ^(UIView *sub) {
		if (sciIsIGGradientView(sub)) sub.hidden = hidden;
	});
}

static BOOL sciHasNestedBubbleView(UIView *view) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGDirectMessageBubbleView");

	__block BOOL found = NO;

	sciEachSubview(view, ^(UIView *sub) {
		if (!found && c && sub != view && [sub isKindOfClass:c]) found = YES;
	});

	return found;
}

// The composer reply bar and replied-to status header — left native.
static BOOL sciIsInsideQuotedReply(UIView *view) {
	for (UIView *v = view; v; v = v.superview) {
		NSString *name = NSStringFromClass([v class]);

		if ([name containsString:@"ReplyBar"]) return YES;
		if ([name containsString:@"RepliedToStatus"]) return YES;
	}

	return NO;
}

// In a reply cell the replied-to preview and the reply share the same class chain; the
// preview sits in the top half. Skip anything centered there.
static BOOL sciIsRepliedToPreview(UIView *view) {
	UIView *cell = nil;
	for (UIView *v = view; v; v = v.superview) {
		if ([NSStringFromClass(v.class) containsString:@"QuotedReplyMessageCell"]) { cell = v; break; }
	}
	if (!cell || CGRectIsEmpty(view.bounds) || CGRectGetHeight(cell.bounds) < 1.0) return NO;

	CGRect f = [view convertRect:view.bounds toView:cell];
	return CGRectGetMidY(f) < CGRectGetHeight(cell.bounds) * 0.5;
}

static BOOL sciIsSafeBubbleTarget(UIView *view, BOOL forceTextBubble) {
	if (!view.window) return NO;
	if (CGRectIsEmpty(view.bounds)) return NO;

	if (!forceTextBubble && sciIsInsideQuotedReply(view)) return NO;

	CGRect f = [view convertRect:view.bounds toView:view.window];
	CGFloat screenW = CGRectGetWidth(view.window.bounds);
	CGFloat width = CGRectGetWidth(f);
	CGFloat height = CGRectGetHeight(f);

	if (width < 8.0 || height < 8.0) return NO;
	if (!forceTextBubble && width > screenW * 0.86) return NO;
	if (!forceTextBubble && sciHasNestedBubbleView(view)) return NO;
	if (view.layer.cornerRadius < 4.0 && !sciHasNativeGradient(view)) return NO;

	return YES;
}

static CAGradientLayer *sciGradientLayer(UIView *view) {
	CAGradientLayer *layer = objc_getAssociatedObject(view, kSCIOurGradientKey);
	if (layer) return layer;

	layer = [CAGradientLayer layer];
	objc_setAssociatedObject(view, kSCIOurGradientKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return layer;
}

static void sciRemoveGradient(UIView *view) {
	CAGradientLayer *layer = objc_getAssociatedObject(view, kSCIOurGradientKey);
	if (!layer) return;

	[layer removeFromSuperlayer];
	objc_setAssociatedObject(view, kSCIOurGradientKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Undo only a recolor we painted; untouched surfaces are left alone.
static void sciRestoreGradientSurface(UIView *gv) {
	BOOL touched = objc_getAssociatedObject(gv, kSCIOurGradientKey) || objc_getAssociatedObject(gv, kSCISurfaceSolidKey);
	if (!touched) return;

	sciRemoveGradient(gv);
	objc_setAssociatedObject(gv, kSCISurfaceSolidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	sciHideNativeGradients(gv, NO);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	gv.layer.backgroundColor = nil;
	[CATransaction commit];
}

static void sciRestoreBubble(UIView *view) {
	sciRemoveGradient(view);
	sciHideNativeGradients(view, NO);

	sciEachSubview(view, ^(UIView *sub) {
		if (sciIsAnyGradientView(sub)) sciRestoreGradientSurface(sub);
	});

	if (sciIsInsideAudioBubble(view)) sciRecolorAudioChrome(view, nil, NO);

	sciRestoreTextInside(view);
	sciRestoreParentTextColor(view);

	UIColor *orig = objc_getAssociatedObject(view, kSCIOrigBgKey);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

	view.layer.backgroundColor = orig ? orig.CGColor : nil;

	[CATransaction commit];
}

static void sciApplySolid(UIView *view, UIColor *color) {
	sciRemoveGradient(view);
	sciHideNativeGradients(view, YES);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

	view.layer.backgroundColor = color.CGColor;

	[CATransaction commit];
}

static void sciGradientPoints(SCIBubbleGradientDirection dir, CGPoint *start, CGPoint *end) {
	switch (dir) {
		case SCIBubbleGradientDirectionHorizontal: *start = CGPointMake(0.0, 0.5); *end = CGPointMake(1.0, 0.5); break;
		case SCIBubbleGradientDirectionVertical:   *start = CGPointMake(0.5, 0.0); *end = CGPointMake(0.5, 1.0); break;
		default:                                   *start = CGPointMake(0.0, 0.0); *end = CGPointMake(1.0, 1.0); break;
	}
}

static void sciApplyLayerGradient(UIView *view, UIColor *first, UIColor *second, SCIBubbleGradientDirection dir) {
	CAGradientLayer *layer = sciGradientLayer(view);

	if (layer.superlayer != view.layer) {
		[view.layer insertSublayer:layer atIndex:0];
	}

	CGPoint start, end;
	sciGradientPoints(dir, &start, &end);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];

	view.layer.backgroundColor = nil;
	layer.frame = view.bounds;
	layer.cornerRadius = view.layer.cornerRadius;
	layer.maskedCorners = view.layer.maskedCorners;
	layer.startPoint = start;
	layer.endPoint = end;
	layer.colors = @[
		(__bridge id)first.CGColor,
		(__bridge id)second.CGColor
	];

	[CATransaction commit];
}

static void sciApplyGradientSurface(UIView *gv);

// Outermost gradient surfaces in a bubble: IGDirectGradientView wrappers, plus any standalone
// IGGradientView not already owned by one (avoids double-painting the inner view).
static NSArray<UIView *> *sciGradientSurfaces(UIView *root) {
	NSMutableArray<UIView *> *outer = [NSMutableArray array];
	NSMutableArray<UIView *> *inner = [NSMutableArray array];

	sciEachSubview(root, ^(UIView *sub) {
		if (sciIsIGDirectGradientView(sub)) [outer addObject:sub];
		else if (sciIsIGGradientView(sub)) [inner addObject:sub];
	});

	if (!outer.count) return inner;

	for (UIView *g in inner) {
		BOOL wrapped = NO;
		for (UIView *o in outer) {
			for (UIView *p = g; p; p = p.superview) {
				if (p == o) { wrapped = YES; break; }
			}
			if (wrapped) break;
		}
		if (!wrapped) [outer addObject:g];
	}

	return outer;
}

static BOOL sciLooksLikeBubble(UIView *view, BOOL forceTextBubble) {
	if (!sciIsSafeBubbleTarget(view, forceTextBubble)) return NO;

	// A bubble we gave a gradient layer has a nil background by design — keep maintaining it.
	if (objc_getAssociatedObject(view, kSCIOurGradientKey)) return YES;

	UIColor *orig = objc_getAssociatedObject(view, kSCIOrigBgKey);
	if (sciColorVisible(orig)) return YES;
	if (sciHasNativeGradient(view)) return YES;

	CGColorRef bg = view.layer.backgroundColor;
	return bg && CGColorGetAlpha(bg) > 0.05;
}

static NSString *sciTextFromCoreTextView(id textView) {
	if (!textView || ![textView respondsToSelector:@selector(styledString)]) return nil;

	id ss = ((id (*)(id, SEL))objc_msgSend)(textView, @selector(styledString));
	if (!ss || ![ss respondsToSelector:@selector(attributedString)]) return nil;

	NSAttributedString *as = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(ss, @selector(attributedString));
	return as.string;
}

static BOOL sciStringHasLettersOrNumbers(NSString *s) {
	if (!s.length) return NO;

	NSCharacterSet *set = [NSCharacterSet alphanumericCharacterSet];
	return [s rangeOfCharacterFromSet:set].location != NSNotFound;
}

static BOOL sciStringContainsEmoji(NSString *s) {
	__block BOOL found = NO;

	[s enumerateSubstringsInRange:NSMakeRange(0, s.length)
		options:NSStringEnumerationByComposedCharacterSequences
		usingBlock:^(NSString *sub, __unused NSRange r, __unused NSRange er, BOOL *stop) {
			unichar c = [sub characterAtIndex:0];
			// Surrogate pairs + the BMP symbol/dingbat/arrow blocks cover common emoji.
			if ((c >= 0xD800 && c <= 0xDBFF) || (c >= 0x2190 && c <= 0x2BFF) || c == 0x203C || c == 0x2049) {
				found = YES;
				*stop = YES;
			}
		}];

	return found;
}

static BOOL sciStringLooksEmojiOnly(NSString *s) {
	if (!s.length) return NO;

	NSString *trim = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (!trim.length) return NO;

	// Only the bubble-less emoji style is skipped; punctuation-only text ("...") still colors.
	return !sciStringHasLettersOrNumbers(trim) && sciStringContainsEmoji(trim);
}

static BOOL sciBubbleLooksEmojiOnly(UIView *bubble) {
	static Class textClass;
	if (!textClass) textClass = NSClassFromString(@"IGCoreTextView");

	__block BOOL foundText = NO;
	__block BOOL emojiOnly = NO;

	sciEachSubview(bubble, ^(UIView *sub) {
		if (foundText || !textClass || ![sub isKindOfClass:textClass]) return;

		NSString *text = sciTextFromCoreTextView((id)sub);
		if (!text.length) return;

		foundText = YES;
		emojiOnly = sciStringLooksEmojiOnly(text);
	});

	UIView *parent = nil;
	static Class textBubbleClass;
	if (!textBubbleClass) textBubbleClass = NSClassFromString(@"IGDirectTextMessageBubbleView");

	for (UIView *v = bubble.superview; v; v = v.superview) {
		if (textBubbleClass && [v isKindOfClass:textBubbleClass]) {
			parent = v;
			break;
		}
	}

	if (!foundText && parent && [parent respondsToSelector:@selector(textView)]) {
		id tv = ((id (*)(id, SEL))objc_msgSend)(parent, @selector(textView));
		NSString *text = sciTextFromCoreTextView(tv);

		foundText = text.length > 0;
		emojiOnly = sciStringLooksEmojiOnly(text);
	}

	return foundText && emojiOnly;
}

static void sciRecolorTextView(id textView, UIColor *color) {
	if (!textView || !color) return;
	if (![textView respondsToSelector:@selector(styledString)]) return;
	if (![textView respondsToSelector:@selector(setStyledString:)]) return;

	IGStyledString *ss = ((IGStyledString *(*)(id, SEL))objc_msgSend)(textView, @selector(styledString));
	NSAttributedString *as = ss.attributedString;
	NSUInteger len = as.length;

	if (!len) return;

	UIColor *cur = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
	if (cur && [cur isEqual:color]) return;

	// NSNull marks "IG set no explicit color" (e.g. white outgoing text) so restore is faithful.
	if (!objc_getAssociatedObject(textView, kSCIOrigTextColorKey)) {
		objc_setAssociatedObject(textView, kSCIOrigTextColorKey, cur ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	[ss setColor:color range:NSMakeRange(0, len)];
	((void (*)(id, SEL, id))objc_msgSend)(textView, @selector(setStyledString:), ss);
	objc_setAssociatedObject(textView, kSCIAppliedTextColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sciRestoreTextView(id textView) {
	id orig = objc_getAssociatedObject(textView, kSCIOrigTextColorKey);
	if (!orig) return;

	UIColor *applied = objc_getAssociatedObject(textView, kSCIAppliedTextColorKey);

	objc_setAssociatedObject(textView, kSCIOrigTextColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(textView, kSCIAppliedTextColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	if (![textView respondsToSelector:@selector(styledString)] || ![textView respondsToSelector:@selector(setStyledString:)]) return;

	IGStyledString *ss = ((IGStyledString *(*)(id, SEL))objc_msgSend)(textView, @selector(styledString));
	NSAttributedString *as = ss.attributedString;
	NSUInteger len = as.length;
	if (!len) return;

	// If IG already re-styled this recycled view, don't clobber its fresh color.
	UIColor *now = [as attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
	if (applied && now && ![now isEqual:applied]) return;

	if (![orig isKindOfClass:UIColor.class]) return;

	[ss setColor:(UIColor *)orig range:NSMakeRange(0, len)];
	((void (*)(id, SEL, id))objc_msgSend)(textView, @selector(setStyledString:), ss);
}

static void sciRecolorTextInside(UIView *view, UIColor *color) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGCoreTextView");

	sciEachSubview(view, ^(UIView *sub) {
		if (c && [sub isKindOfClass:c] && !sciIsInsideQuotedReply(sub) && !sciIsRepliedToPreview(sub))
			sciRecolorTextView((id)sub, color);
	});
}

static void sciRestoreTextInside(UIView *view) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGCoreTextView");

	sciEachSubview(view, ^(UIView *sub) {
		if (c && [sub isKindOfClass:c]) sciRestoreTextView((id)sub);
	});
}

static UIView *sciParentTextBubble(UIView *view) {
	static Class c;
	if (!c) c = NSClassFromString(@"IGDirectTextMessageBubbleView");

	for (UIView *v = view.superview; v; v = v.superview) {
		if (c && [v isKindOfClass:c]) return v;
	}

	return nil;
}

static BOOL sciIsBubbleInsideTextBubble(UIView *bubble, UIView *textBubble) {
	if (!bubble || !textBubble) return NO;

	for (UIView *v = bubble.superview; v; v = v.superview) {
		if (v == textBubble) return YES;
	}

	return NO;
}

static void sciRecolorParentTextBubble(UIView *bubble, UIColor *color) {
	UIView *parent = sciParentTextBubble(bubble);
	if (!parent || !color) return;

	if ([parent respondsToSelector:@selector(textView)]) {
		id tv = ((id (*)(id, SEL))objc_msgSend)(parent, @selector(textView));
		sciRecolorTextView(tv, color);
	}

	if ([parent respondsToSelector:@selector(secondaryTextView)]) {
		id tv = ((id (*)(id, SEL))objc_msgSend)(parent, @selector(secondaryTextView));
		sciRecolorTextView(tv, color);
	}
}

static void sciRestoreParentTextColor(UIView *bubble) {
	UIView *parent = sciParentTextBubble(bubble);
	if (!parent) return;

	if ([parent respondsToSelector:@selector(textView)]) {
		sciRestoreTextView(((id (*)(id, SEL))objc_msgSend)(parent, @selector(textView)));
	}

	if ([parent respondsToSelector:@selector(secondaryTextView)]) {
		sciRestoreTextView(((id (*)(id, SEL))objc_msgSend)(parent, @selector(secondaryTextView)));
	}
}

static BOOL sciIsInsideAudioBubble(UIView *view) {
	for (UIView *v = view; v; v = v.superview) {
		if ([NSStringFromClass(v.class) containsString:@"AudioMessageBubble"]) return YES;
	}
	return NO;
}

static void sciSetAudioTint(UIView *v, UIColor *color, BOOL apply) {
	if (apply) {
		if (!objc_getAssociatedObject(v, kSCIAudioOrigTintKey))
			objc_setAssociatedObject(v, kSCIAudioOrigTintKey, v.tintColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		v.tintColor = color;
	} else {
		id orig = objc_getAssociatedObject(v, kSCIAudioOrigTintKey);
		if (!orig) return;
		v.tintColor = [orig isKindOfClass:UIColor.class] ? orig : nil;
		objc_setAssociatedObject(v, kSCIAudioOrigTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

// Recolor voice-note chrome to the text color: waveform (IGAudioWaveformView tintColor),
// duration label, and play-button circle (IGDirectGradientView backgroundColor).
static void sciRecolorAudioChrome(UIView *audioRoot, UIColor *color, BOOL apply) {
	if (!color && apply) return;

	sciEachSubview(audioRoot, ^(UIView *sub) {
		NSString *cls = NSStringFromClass(sub.class);

		if ([cls containsString:@"AudioWaveform"]) {
			sciSetAudioTint(sub, color, apply);
			sciEachSubview(sub, ^(UIView *iv) {
				if ([iv isKindOfClass:UIImageView.class]) sciSetAudioTint(iv, color, apply);
			});
		} else if ([sub isKindOfClass:UILabel.class]) {
			UILabel *lbl = (UILabel *)sub;
			if (apply) {
				if (!objc_getAssociatedObject(lbl, kSCIAudioOrigBgKey))
					objc_setAssociatedObject(lbl, kSCIAudioOrigBgKey, lbl.textColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				lbl.textColor = color;
			} else {
				id orig = objc_getAssociatedObject(lbl, kSCIAudioOrigBgKey);
				if (orig) {
					lbl.textColor = [orig isKindOfClass:UIColor.class] ? orig : nil;
					objc_setAssociatedObject(lbl, kSCIAudioOrigBgKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				}
			}
		} else if (sciIsIGDirectGradientView(sub)) {
			if (apply) {
				if (!objc_getAssociatedObject(sub, kSCIAudioOrigBgKey))
					objc_setAssociatedObject(sub, kSCIAudioOrigBgKey, sub.backgroundColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				sub.backgroundColor = color;
			} else {
				id orig = objc_getAssociatedObject(sub, kSCIAudioOrigBgKey);
				if (orig) {
					sub.backgroundColor = [orig isKindOfClass:UIColor.class] ? orig : nil;
					objc_setAssociatedObject(sub, kSCIAudioOrigBgKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				}
			}
		}
	});
}

// Only text, audio and reply bubbles are recolored; media / shared / disappearing bubbles
// keep their native look (tinting them hides play icons or half-colors attachments).
static BOOL sciBubbleIsColorableType(UIView *bubble) {
	if (sciParentTextBubble(bubble)) return YES;
	if (sciIsInsideAudioBubble(bubble)) return YES;

	for (UIView *v = bubble; v; v = v.superview) {
		if ([NSStringFromClass(v.class) containsString:@"ContextReplyBubble"]) return YES;
	}
	return NO;
}

// Shared eligibility for the text + gradient-surface paths.
static BOOL sciBubbleEligibleForRecolor(UIView *bubble, NSString *asset) {
	if (!bubble || !bubble.window) return NO;
	if (!sciBubbleIsColorableType(bubble)) return NO;
	if (!sciSideAllowedForAsset(asset, sciIsOutgoingBubble(bubble))) return NO;
	if (sciIsInsideQuotedReply(bubble)) return NO;
	if (sciIsRepliedToPreview(bubble)) return NO;
	if (sciBubbleLooksEmojiOnly(bubble)) return NO;
	return YES;
}

// Recolor/restore one text view from its own bubble + thread. Driven by the setStyledString:
// hook so the color re-applies whenever IG (re)sets the text.
static void sciHandleTextView(UIView *tv) {
	if (objc_getAssociatedObject(tv, kSCITextApplyingKey)) return;

	UIView *bubble = sciEnclosingBubble(tv) ?: sciParentTextBubble(tv);
	NSString *asset = bubble ? sciBubbleAssetForView(bubble) : nil;

	if (bubble && asset && sciBubbleEligibleForRecolor(bubble, asset)) {
		UIColor *color = [[SCIChatBackgroundManager shared] autoBubbleTextColorForAsset:asset];
		objc_setAssociatedObject(tv, kSCITextApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		sciRecolorTextView((id)tv, color);
		objc_setAssociatedObject(tv, kSCITextApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	} else {
		sciRestoreTextView((id)tv);
	}
}

static void sciApplyGradientSurface(UIView *gv) {
	if (!gv || objc_getAssociatedObject(gv, kSCIApplyingKey)) return;

	// In an audio message the gradient views are the play button + waveform — handled by
	// sciRecolorAudioChrome, not here.
	if (sciIsInsideAudioBubble(gv)) { sciRestoreGradientSurface(gv); return; }

	UIView *bubble = sciEnclosingBubble(gv);
	NSString *asset = sciBubbleAssetForView(bubble ?: gv);
	NSArray<UIColor *> *colors = asset ? [[SCIChatBackgroundManager shared] bubbleColorsForAsset:asset] : nil;

	if (!bubble || !colors.count || !sciBubbleEligibleForRecolor(bubble, asset)) {
		sciRestoreGradientSurface(gv);
		return;
	}

	objc_setAssociatedObject(gv, kSCIApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	// Suppress IG's gradient (live colors or a pre-rendered image), then paint ours.
	sciHideNativeGradients(gv, YES);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	gv.layer.contents = nil;
	[CATransaction commit];

	if (colors.count > 1) {
		objc_setAssociatedObject(gv, kSCISurfaceSolidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		sciApplyLayerGradient(gv, colors[0], colors[1], sciGradientDirectionForAsset(asset));
	} else {
		sciRemoveGradient(gv);
		objc_setAssociatedObject(gv, kSCISurfaceSolidKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		gv.layer.backgroundColor = colors[0].CGColor;
		[CATransaction commit];
	}

	objc_setAssociatedObject(gv, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sciApplyBubbleFallback(UIView *view, BOOL forceTextBubble) {
	if (!view || objc_getAssociatedObject(view, kSCIApplyingKey)) return;

	BOOL outgoing = sciIsOutgoingBubble(view);

	objc_setAssociatedObject(view, kSCIApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	NSString *asset = sciBubbleAssetForView(view);

	if (!asset) {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	// Forced callers (text bubble, event bubble) are already known-colorable.
	if (!forceTextBubble && !sciBubbleIsColorableType(view)) {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	// Side not chosen for this background → leave native.
	if (!sciSideAllowedForAsset(asset, outgoing)) {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	// Replied-to preview (top of a reply cell) is the quoted message — leave native.
	if (sciIsRepliedToPreview(view)) {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	if (!forceTextBubble && sciIsInsideQuotedReply(view)) {
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	if (!sciLooksLikeBubble(view, forceTextBubble)) {
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	// Emoji-only messages keep IG's transparent look.
	if (sciBubbleLooksEmojiOnly(view)) {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	NSArray<UIColor *> *colors = [[SCIChatBackgroundManager shared] bubbleColorsForAsset:asset];

	// Audio: only paint the bubble's own background; surfaces are the play button/waveform.
	BOOL audio = sciIsInsideAudioBubble(view);
	NSArray<UIView *> *surfaces = audio ? @[] : sciGradientSurfaces(view);

	if (colors.count > 1) {
		if (surfaces.count) {
			// The surface owns the fill; paint it and keep the bubble itself clear.
			for (UIView *s in surfaces) sciApplyGradientSurface(s);
			sciRemoveGradient(view);

			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			view.layer.backgroundColor = nil;
			[CATransaction commit];
		} else {
			if (!audio) sciHideNativeGradients(view, YES);
			sciApplyLayerGradient(view, colors[0], colors[1], sciGradientDirectionForAsset(asset));
		}
	} else if (colors.count == 1) {
		if (audio) {
			sciRemoveGradient(view);
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			view.layer.backgroundColor = colors[0].CGColor;
			[CATransaction commit];
		} else {
			sciApplySolid(view, colors[0]);
			for (UIView *s in surfaces) sciApplyGradientSurface(s);
		}
	} else {
		sciRestoreBubble(view);
		objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return;
	}

	UIColor *textColor = [[SCIChatBackgroundManager shared] autoBubbleTextColorForAsset:asset];

	sciRecolorTextInside(view, textColor);
	sciRecolorParentTextBubble(view, textColor);

	if (audio) sciRecolorAudioChrome(view, textColor, YES);

	objc_setAssociatedObject(view, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sciApplyInnerBubbleFromTextBubble(UIView *view) {
	if (!view || ![view respondsToSelector:@selector(bubbleView)]) return;

	UIView *bubble = ((UIView *(*)(id, SEL))objc_msgSend)(view, @selector(bubbleView));
	if (!bubble) return;

	if (!sciIsBubbleInsideTextBubble(bubble, view) && bubble.superview != view) return;

	sciApplyBubbleFallback(bubble, YES);
}

%hook IGDirectMessageBubbleView

- (void)setBackgroundColor:(UIColor *)color {
	%orig;

	if (!objc_getAssociatedObject(self, kSCIApplyingKey)) {
		objc_setAssociatedObject(self, kSCIOrigBgKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	[sciLiveBubbles() addObject:self];
	sciApplyBubbleFallback((UIView *)self, NO);
}

- (void)layoutSubviews {
	%orig;
	[sciLiveBubbles() addObject:self];
	sciApplyBubbleFallback((UIView *)self, NO);
}

%end

%hook IGDirectTextMessageBubbleView

- (void)layoutSubviews {
	%orig;
	sciApplyInnerBubbleFromTextBubble((UIView *)self);
}

- (void)_applyBubbleStyleFromViewModel:(id)model {
	%orig;
	sciApplyInnerBubbleFromTextBubble((UIView *)self);
}

%end

// Recolor the moment text is (re)set, so first-load and scroll-in messages never get missed.
%hook IGCoreTextView

- (void)setStyledString:(id)styledString {
	%orig;
	sciHandleTextView((UIView *)self);
}

%end

// Theme gradient re-renders here after layout — re-assert so our color wins (animated themes).
%hook IGDirectGradientView

- (void)layoutSubviews {
	%orig;
	sciApplyGradientSurface((UIView *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
	%orig;
	sciApplyGradientSurface((UIView *)self);
}

%end

%hook IGGradientView

- (void)layoutSubviews {
	%orig;

	// An IGDirectGradientView ancestor already paints + hides us.
	for (UIView *v = self.superview; v; v = v.superview) {
		if (sciIsIGDirectGradientView(v)) return;
	}

	sciApplyGradientSurface((UIView *)self);
}

%end

// Call / event messages (e.g. missed calls) use their own Swift bubble — route its layout
// through the same per-view apply.
static void (*orig_sciEventBubbleLayout)(id, SEL);
static void new_sciEventBubbleLayout(id self, SEL _cmd) {
	orig_sciEventBubbleLayout(self, _cmd);
	[sciLiveBubbles() addObject:(UIView *)self];
	sciApplyBubbleFallback((UIView *)self, YES);
}

static void sciHookEventBubble(NSString *mangled, NSString *bare) {
	Class cls = NSClassFromString(mangled);
	if (!cls) cls = NSClassFromString(bare);
	if (!cls) return;

	MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)new_sciEventBubbleLayout, (IMP *)&orig_sciEventBubbleLayout);
}

%ctor {
	if (![SCIUtils getBoolPref:SCIPrefChatBackgroundEnabled]) return;
	%init;

	sciHookEventBubble(@"_TtC31IGDirectVideoCallEventMessageUI32IGDirectVideoCallEventBubbleView", @"IGDirectVideoCallEventBubbleView");

	[NSNotificationCenter.defaultCenter addObserverForName:SCIChatBackgroundDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *_) {
		for (UIView *bubble in [sciLiveBubbles() allObjects]) {
			objc_setAssociatedObject(bubble, kSCIApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[bubble setNeedsLayout];
			sciApplyBubbleFallback(bubble, NO);
		}
	}];
}