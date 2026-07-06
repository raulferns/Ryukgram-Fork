#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../../Utils.h"
#import "../../InstagramHeaders.h"

// Hold-to-record fires a different selector and passes through.
%hook _TtC34IGQuickSnapCameraControlController28IGQuickSnapCameraControlView

- (void)captureButtonDidReleaseBeforeExpandingFinished {
    if (![SCIUtils getBoolPref:@"instants_capture_confirm"]) {
    	%orig;
    	return;
    }
    [SCIUtils showConfirmation:^{
    	%orig;
    }
                         title:SCILocalized(@"Confirm Instants capture")];
}

%end

// IG 433 moved tap-to-advance into a child tapController with no callable advance
// method (Swift-internal). To advance ourselves we re-enter -didPressWithGestureRecognizer:
// with a stand-in recognizer reading state Ended, seeding pressStartLocation so IG
// treats it as a tap, not a swipe.
@interface SCIInstantAdvanceGR : UILongPressGestureRecognizer
@property (nonatomic, assign) CGPoint sciLoc;
@property (nonatomic, weak) UIView *sciView;
@end
@implementation SCIInstantAdvanceGR
- (UIGestureRecognizerState)state { return UIGestureRecognizerStateEnded; }
- (CGPoint)locationInView:(UIView *)view { return self.sciLoc; }
- (UIView *)view { return self.sciView; }
@end

static id SCITapControllerForStack(UIView *stack) {
    if (!stack) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(stack), "tapController");
    return iv ? object_getIvar(stack, iv) : nil;
}

extern "C" void SCIDriveInstantAdvanceForStack(UIView *stack, CGPoint loc) {
    id tc = SCITapControllerForStack(stack);
    if (!tc) return;
    Ivar psl = class_getInstanceVariable(object_getClass(tc), "pressStartLocation");
    if (psl) *(CGPoint *)((char *)(__bridge void *)tc + ivar_getOffset(psl)) = loc;
    SCIInstantAdvanceGR *gr = [SCIInstantAdvanceGR new];
    gr.sciLoc = loc;
    gr.sciView = stack;
    SEL sel = @selector(didPressWithGestureRecognizer:);
    if ([tc respondsToSelector:sel])
        ((void (*)(id, SEL, id))objc_msgSend)(tc, sel, gr);
}

%hook _TtC39IGQuickSnapImmersiveViewerSnapStackView61IGQuickSnapImmersiveViewerAnimatingSnapStackViewTapController

- (void)didPressWithGestureRecognizer:(UIGestureRecognizer *)gr {
    // our synthetic re-entry (post-confirm / auto-advance) — run IG's advance as-is
    if ([gr isKindOfClass:[SCIInstantAdvanceGR class]]) {
    	%orig;
    	return;
    }

    if (![SCIUtils getBoolPref:@"instants_advance_confirm"]) {
    	%orig;
    	return;
    }
    if (gr.state != UIGestureRecognizerStateEnded) {
    	%orig;
    	return;
    }
    // Began records pressStartLocation

    UIView *stack = gr.view;
    Ivar psl = class_getInstanceVariable(object_getClass(self), "pressStartLocation");
    CGPoint start = psl ? *(CGPoint *)((char *)(__bridge void *)self + ivar_getOffset(psl)) : CGPointZero;
    CGPoint loc = [gr locationInView:stack];
    CGFloat dx = loc.x - start.x, dy = loc.y - start.y;
    if ((dx * dx + dy * dy) > (12.0 * 12.0)) {
    	%orig;
    	return;
    }
    // travelled => swipe, pass through

    [SCIUtils showConfirmation:^{
        SCIDriveInstantAdvanceForStack(stack, loc);
    } title:SCILocalized(@"Confirm switching Instant")];
    // suppress %orig — advance only fires once confirmed
}

%end
