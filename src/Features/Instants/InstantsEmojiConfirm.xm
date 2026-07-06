// Confirm before sending a quick-reaction emoji on an Instant. The reaction
// buttons (`IGBouncyTextButton`) are standard UIControls; their `didTapToReact:`
// action is fired via `sendAction:to:forEvent:` per registered target. We
// gate that one selector — the analytics target goes straight through.
//
// Gate: instants_emoji_reaction_confirm

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../../Utils.h"

// IGBouncyTextButton declared in InstagramHeaders.h

static BOOL sciIsLikelyEmoji(NSString *t) {
    if (t.length == 0 || t.length > 16) return NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return NO;
    }
    return YES;
}

static BOOL sciResponderHasQuickSnap(UIResponder *r) {
    while (r) {
        if ([NSStringFromClass([r class]) rangeOfString:@"QuickSnap"].location != NSNotFound) return YES;
        r = r.nextResponder;
    }
    return NO;
}

static NSString *sciButtonText(UIControl *btn) {
    if (!btn) return nil;
    @try {
        id v = [btn valueForKey:@"text"];
        if ([v isKindOfClass:[NSString class]]) return v;
    } @catch (__unused id e) {}
    return btn.accessibilityLabel ?: nil;
}

%hook IGBouncyTextButton

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (!sel_isEqual(action, @selector(didTapToReact:))) {
    	%orig;
    	return;
    }
    if (![SCIUtils getBoolPref:@"instants_emoji_reaction_confirm"]) {
    	%orig;
    	return;
    }
    if (!sciIsLikelyEmoji(sciButtonText((UIControl *)self))) {
    	%orig;
    	return;
    }
    if (!sciResponderHasQuickSnap(self)) {
    	%orig;
    	return;
    }

    [SCIUtils showConfirmation:^{
    	%orig;
    }
                         title:SCILocalized(@"Confirm Instants emoji reaction")];
}

%end
