#import "../../InstagramHeaders.h"
#import "../../Settings/SCISettingsViewController.h"
#import <objc/runtime.h>
#import <substrate.h>

// Hold the profile "more" button to open tweak settings. IG 432 moved
// IGBadgedNavigationButton into a Swift module, so hook it at runtime.
static void (*orig_badgedNav_didMoveToWindow)(UIView *, SEL);

static void sci_badgedNavSettingsLongPress(UIView *self, SEL _cmd, UILongPressGestureRecognizer *sender) {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [SCIUtils showSettingsVCFromSourceView:self];
}

static void new_badgedNav_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_badgedNav_didMoveToWindow(self, _cmd);

    if ([self.accessibilityIdentifier isEqualToString:@"profile-more-button"] &&
        self.gestureRecognizers.count == 0) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(sci_badgedNavSettingsLongPress:)];
        [self addGestureRecognizer:longPress];
    }
}

// Hold the home tab (inbox tab in messages-only mode) to open tweak settings.
%hook IGTabBarButton
- (void)didMoveToSuperview {
    %orig;

    BOOL msgOnly = [SCIUtils getBoolPref:@"messages_only"];
    NSString *target = msgOnly ? @"direct-inbox-tab" : @"mainfeed-tab";
    if (![self.accessibilityIdentifier isEqualToString:target]) return;

    if ([SCIUtils getBoolPref:@"settings_shortcut"]) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.3;
        for (UIGestureRecognizer *existing in self.gestureRecognizers) {
            [existing requireGestureRecognizerToFail:longPress];
        }
        [self addGestureRecognizer:longPress];
    }
}
%new - (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [SCIUtils showSettingsVCFromSourceView:self];
}
%end

%ctor {
    %init;

    Class cls = NSClassFromString(@"_TtC19IGProfileNavigation24IGBadgedNavigationButton");
    if (!cls) cls = objc_getClass("IGBadgedNavigationButton");
    if (!cls) return;

    class_addMethod(cls, @selector(sci_badgedNavSettingsLongPress:),
                    (IMP)sci_badgedNavSettingsLongPress, "v@:@");
    MSHookMessageEx(cls, @selector(didMoveToWindow),
                    (IMP)new_badgedNav_didMoveToWindow,
                    (IMP *)&orig_badgedNav_didMoveToWindow);
}
