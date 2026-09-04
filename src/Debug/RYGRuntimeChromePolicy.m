#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../UI/RYGLiquidGlass.h"

/*
 * Navigation chrome policy for Ryukgram-owned controllers.
 *
 * UIButtonConfiguration may wrap a navigation title when the bar also owns
 * back/apply/refresh items. The previous title pill therefore became a tall,
 * two-line capsule. Keep title views intrinsic and single-line; UIKit remains
 * responsible for the available width and truncation, so no fixed width is
 * introduced here.
 */

static const void *kRYGRuntimeCompactTitleKey = &kRYGRuntimeCompactTitleKey;

static NSString *RYGRuntimeShortImageTitle(NSString *path) {
    if (!path.length) return nil;
    NSString *standard = path.stringByStandardizingPath;
    NSString *exec = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if ([standard isEqualToString:exec]) return @"Instagram";
    NSString *last = path.lastPathComponent ?: @"";
    if ([last.lowercaseString containsString:@"fbsharedframework"]) return @"FBSharedFramework";
    if ([last hasSuffix:@".framework"]) return [last stringByDeletingPathExtension];
    return last.length ? last : nil;
}

static void RYGPolishNavigationTitle(UIViewController *controller) {
    if (!controller || !RYGIsOwnedViewController(controller)) return;

    NSString *className = NSStringFromClass(controller.class) ?: @"";
    if ([className isEqualToString:@"RYGPortedRuntimeImageViewController"]) {
        NSString *path = nil;
        @try { path = [controller valueForKey:@"imagePath"]; }
        @catch (__unused NSException *exception) { path = nil; }
        NSString *shortTitle = RYGRuntimeShortImageTitle(path);
        if (shortTitle.length && ![controller.title isEqualToString:shortTitle]) {
            controller.title = shortTitle;
            controller.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(shortTitle);
        }
    }

    UIView *titleView = controller.navigationItem.titleView;
    if (![titleView isKindOfClass:UIButton.class]) return;
    UIButton *button = (UIButton *)titleView;
    NSString *title = button.accessibilityLabel ?: controller.title ?: @"";
    NSString *previous = objc_getAssociatedObject(button, kRYGRuntimeCompactTitleKey);
    if ([previous isEqualToString:title] && button.titleLabel.numberOfLines == 1) return;

    button.titleLabel.numberOfLines = 1;
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.72;
    [button setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = button.configuration;
        if (configuration) {
            configuration.titleLineBreakMode = NSLineBreakByTruncatingMiddle;
            button.configuration = configuration;
        }
    }

    [button invalidateIntrinsicContentSize];
    [button sizeToFit];
    objc_setAssociatedObject(button, kRYGRuntimeCompactTitleKey, title ?: @"",
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@interface UIViewController (RYGRuntimeChromePolicy)
- (void)ryg_runtimeChrome_viewDidLayoutSubviews;
@end

@implementation UIViewController (RYGRuntimeChromePolicy)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(viewDidLayoutSubviews));
        Method replacement = class_getInstanceMethod(self, @selector(ryg_runtimeChrome_viewDidLayoutSubviews));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ryg_runtimeChrome_viewDidLayoutSubviews {
    [self ryg_runtimeChrome_viewDidLayoutSubviews];
    RYGPolishNavigationTitle(self);
}

@end
