#import "RYGPopupChrome.h"
#import "RYGLiquidGlass.h"
#import "../Features/Theme/RYGTheme.h"

@implementation RYGPopupChrome

+ (UIColor *)backgroundColor {
    return UIColor.systemGroupedBackgroundColor;
}

+ (void)applyBackdropTo:(UIViewController *)vc {
    if (!vc.isViewLoaded) [vc loadViewIfNeeded];
    UIColor *background = [self backgroundColor];
    vc.view.backgroundColor = background;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:UITableView.class] || [view isKindOfClass:UICollectionView.class]) {
            view.backgroundColor = background;
            // Do not put a second material behind every table/collection cell.
            // Navigation/tool chrome is the native Liquid Glass surface.
            continue;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    RYGLiquidGlassApplyToViewController(vc);
}

+ (UINavigationController *)wrap:(UIViewController *)content {
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:content];
    navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    if ([RYGTheme shouldOverrideAppearance]) {
        // A window-level force can hide the actual system style. Pin only the
        // RyukGram container back to the screen's active appearance.
        navigationController.overrideUserInterfaceStyle = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }

    RYGLiquidGlassConfigureNavigationController(navigationController);
    [self applyBackdropTo:content];

    if (!content.navigationItem.leftBarButtonItem && !content.navigationItem.leftBarButtonItems.count) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(closeTopMost:)];
        content.navigationItem.leftBarButtonItem = close;
    }
    return navigationController;
}

+ (void)presentVC:(UIViewController *)content from:(UIViewController *)presenter {
    if (!presenter) presenter = [self topMostController];
    if (!presenter || !content) return;
    UINavigationController *navigationController = [self wrap:content];
    [presenter presentViewController:navigationController animated:YES completion:nil];
}

#pragma mark - Helpers

+ (UIViewController *)topMostController {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;

    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

+ (void)closeTopMost:(__unused UIBarButtonItem *)sender {
    UIViewController *top = [self topMostController];
    [top dismissViewControllerAnimated:YES completion:nil];
}

@end
