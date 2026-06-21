#import "SCILockGate.h"
#import "SCILockManager.h"
#import "SCILockGroups.h"
#import "SCILockSurfaceGuard.h"
#import "SCILockedSurfaceNavigationController.h"
#import "UI/SCILockPasscodeViewController.h"
#import "../UI/SCIPopupChrome.h"
#import "../UI/SCIUIKit26LiquidGlass.h"
#import "../Localization/SCILocalization.h"

@implementation SCILockGate

+ (UIViewController *)topVC {
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = win.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

+ (void)presentPasscode:(SCILockPasscodeViewController *)pad from:(UIViewController *)presenter {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pad];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    UIViewController *from = presenter ?: [self topVC];
    [from presentViewController:nav animated:YES completion:nil];
}

// Surfaces that live under Settings; a shortcut into one of these must satisfy
// the Settings lock too, otherwise a passcode-protected Settings is bypassable.
static BOOL sciGroupInheritsSettingsLock(NSString *gid) {
    if (!gid.length) return NO;
    if ([gid isEqualToString:SCILockGroupApp]) return NO;
    if ([gid isEqualToString:SCILockGroupSettings]) return NO;
    if ([gid isEqualToString:SCILockGroupMessagesTab]) return NO;
    return YES;
}

+ (void)promptForGroup:(NSString *)groupID
                  from:(UIViewController *)presenter
                  then:(void (^)(void))block {
    SCILockManager *mgr = [SCILockManager shared];
    SCILockGroupInfo *info = SCILockGroupInfoFor(groupID);
    NSString *title = info.displayName.length
        ? [NSString stringWithFormat:SCILocalized(@"Unlock %@"), info.displayName]
        : SCILocalized(@"Unlock");
    SCILockPasscodeViewController *pad = [[SCILockPasscodeViewController alloc]
        initWithTitle:title
             subtitle:SCILocalized(@"Enter your passcode to continue")];
    pad.allowsBiometric = YES;
    pad.allowsCancel = YES;
    pad.completion = ^(BOOL ok) {
        if (!ok) return;
        [mgr markGroupUnlocked:groupID];
        block();
    };
    [self presentPasscode:pad from:presenter];
}

+ (void)runGated:(NSString *)groupID from:(UIViewController *)presenter then:(void (^)(void))block {
    if (!block) return;
    SCILockManager *mgr = [SCILockManager shared];

    void (^proceed)(void) = ^{
        if (![mgr isGroupLocked:groupID]) {
            dispatch_async(dispatch_get_main_queue(), block);
            return;
        }
        [self promptForGroup:groupID from:presenter then:block];
    };

    // forceAuth (not promptForGroup) — verifies without unlocking the Settings session,
    // so a child shortcut auth doesn't silently grant access to Settings itself.
    if (sciGroupInheritsSettingsLock(groupID)
        && [mgr isGroupLocked:SCILockGroupSettings]) {
        SCILockGroupInfo *info = SCILockGroupInfoFor(SCILockGroupSettings);
        NSString *title = info.displayName.length
            ? [NSString stringWithFormat:SCILocalized(@"Unlock %@"), info.displayName]
            : SCILocalized(@"Unlock");
        [self forceAuthWithTitle:title subtitle:nil from:presenter then:proceed];
        return;
    }

    proceed();
}

+ (void)presentLockedVC:(UIViewController *)contentVC
                forGroup:(NSString *)groupID
                    from:(UIViewController *)presenter {
    if (!contentVC) return;
    [self runGated:groupID from:presenter then:^{
        SCILockedSurfaceNavigationController *nav = [[SCILockedSurfaceNavigationController alloc] initWithRootViewController:contentVC];
        nav.lockGroupID = groupID;
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        SCIUIKit26ApplyContainerBackgroundToViewController(nav);
        SCIConfigureNavigationChromeForGlass(contentVC);
        if (!contentVC.navigationItem.leftBarButtonItem
            && !contentVC.navigationItem.leftBarButtonItems.count) {
            UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                       style:UIBarButtonItemStylePlain
                                                                      target:self
                                                                      action:@selector(closeTopMost:)];
            contentVC.navigationItem.leftBarButtonItem = close;
        }
        // Guard attaches to the nav (its view hosts every pushed sub-page) so
        // re-lock can cover inner pages too.
        UIViewController *top = [self topVC];
        [top presentViewController:nav animated:YES completion:nil];
        [SCILockSurfaceGuard attachToVC:nav forGroup:groupID];
    }];
}

+ (void)closeTopMost:(UIBarButtonItem *)sender {
    UIViewController *top = [self topVC];
    [top dismissViewControllerAnimated:YES completion:nil];
}

+ (void)forceAuthWithTitle:(NSString *)title
                   subtitle:(NSString *)subtitle
                       from:(UIViewController *)presenter
                        then:(void (^)(void))block {
    if (!block) return;
    SCILockManager *mgr = [SCILockManager shared];
    if (![mgr hasPasscode]) {
        dispatch_async(dispatch_get_main_queue(), block);
        return;
    }
    SCILockPasscodeViewController *pad = [[SCILockPasscodeViewController alloc]
        initWithTitle:title ?: SCILocalized(@"Confirm passcode")
             subtitle:subtitle ?: SCILocalized(@"Enter your passcode to continue")];
    pad.allowsBiometric = YES;
    pad.allowsCancel = YES;
    pad.completion = ^(BOOL ok) {
        if (ok) block();
    };
    [self presentPasscode:pad from:presenter];
}

@end
