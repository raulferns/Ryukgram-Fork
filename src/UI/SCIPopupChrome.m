#import "SCIPopupChrome.h"
#import "../Features/Theme/SCITheme.h"

@implementation SCIPopupChrome

+ (UIColor *)backgroundColor {
    return SCIUIKit26BaseSurfaceColor();
}

+ (void)applyBackdropTo:(UIViewController *)vc {
    if (!vc.isViewLoaded) [vc loadViewIfNeeded];
    SCIUIKit26ConfigureViewController(vc);
    vc.view.backgroundColor = [self backgroundColor];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) {
            SCIUIKit26ConfigureTableView((UITableView *)v);
            continue;
        }
        if ([v isKindOfClass:[UICollectionView class]]) {
            SCIUIKit26ConfigureCollectionView((UICollectionView *)v);
            continue;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

+ (UINavigationController *)wrap:(UIViewController *)content {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:content];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    if ([SCITheme shouldOverrideAppearance]) {
        // Window-level force masks the real system style — pin ours back to it.
        nav.overrideUserInterfaceStyle = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    [self applyBackdropTo:content];
    SCIConfigureNavigationChromeForGlass(content);
    SCIUIKit26InstallNavigationTitleBubble(content);
    if (!content.navigationItem.leftBarButtonItem
        && !content.navigationItem.leftBarButtonItems.count) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(closeTopMost:)];
        content.navigationItem.leftBarButtonItem = close;
    }
    return nav;
}

+ (void)presentVC:(UIViewController *)content from:(UIViewController *)presenter {
    if (!presenter) presenter = [self topMostController];
    if (!presenter || !content) return;
    UINavigationController *nav = [self wrap:content];
    [presenter presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Helpers

+ (UIViewController *)topMostController {
    UIWindow *key = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) key = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

+ (void)closeTopMost:(UIBarButtonItem *)sender {
    UIViewController *top = [self topMostController];
    [top dismissViewControllerAnimated:YES completion:nil];
}

@end
