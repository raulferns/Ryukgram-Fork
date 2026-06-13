#import "../../Utils.h"
#import "../../InstagramHeaders.h"

static UIView *SCIQuickSnapStackInView(UIView *view) {
	if (!view) return nil;
	if ([NSStringFromClass(view.class) containsString:@"IGQuickSnapImmersiveViewerAnimatingSnapStackView"])
		return view;
	for (UIView *subview in view.subviews) {
		UIView *found = SCIQuickSnapStackInView(subview);
		if (found) return found;
	}
	return nil;
}

static UIView *SCIFindQuickSnapStack(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			UIView *stack = SCIQuickSnapStackInView(window);
			if (stack) return stack;
		}
	}
	return nil;
}

// A reaction fires no gesture — advance with a synthetic right-third tap (forward).
static void SCIAutoAdvanceInstant(void) {
	if (![SCIUtils getBoolPref:@"instant_auto_advance_reaction"]) return;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UIView *stack = SCIFindQuickSnapStack();
		if (!stack) return;
		CGPoint loc = CGPointMake(CGRectGetWidth(stack.bounds) * 0.85, CGRectGetMidY(stack.bounds));
		SCIDriveInstantAdvanceForStack(stack, loc);
	});
}

// Heart/like tap is on the interactions view, not the consumption controller.
%hook _TtC42IGQuickSnapImmersiveViewerInteractionsView42IGQuickSnapImmersiveViewerInteractionsView

- (void)didTapToReact:(id)sender {
	%orig;
	SCIAutoAdvanceInstant();
}

%end

// Emoji-tray reactions route through the consumption controller's delegate.
%hook _TtC34IGQuickSnapConsumptionInteractions44IGQuickSnapConsumptionInteractionsController

- (void)emojiPickerTrayViewController:(id)controller didSelectEmoji:(id)emoji fromEmojiView:(id)view fromSearch:(_Bool)search {
	%orig;
	SCIAutoAdvanceInstant();
}

%end
