#import "RYGLiquidGlass.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

static const void *kRYGGlassButtonConfiguredKey = &kRYGGlassButtonConfiguredKey;
static const void *kRYGGlassButtonDeferredFitKey = &kRYGGlassButtonDeferredFitKey;
static const void *kRYGGeneratedTitleViewKey = &kRYGGeneratedTitleViewKey;

static NSString *RYGDefiningImagePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info = {0};
        if (dladdr((const void *)&RYGIsOwnedViewController, &info) && info.dli_fname) {
            path = [[[[NSString alloc] initWithUTF8String:info.dli_fname]
                stringByResolvingSymlinksInPath] stringByStandardizingPath];
        }
    });
    return path;
}

static BOOL RYGClassNameIsOwned(Class cls) {
    NSString *name = cls ? NSStringFromClass(cls) : @"";
    if ([name hasPrefix:@"RYG"] || [name hasPrefix:@"_RYG"]) return YES;
    const char *rawImage = cls ? class_getImageName(cls) : NULL;
    if (!rawImage) return NO;
    NSString *classImage = [[[[NSString alloc] initWithUTF8String:rawImage]
        stringByResolvingSymlinksInPath] stringByStandardizingPath];
    return classImage.length && [classImage isEqualToString:RYGDefiningImagePath()];
}

static BOOL RYGControllerTreeIsOwned(UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 8) return NO;
    if (RYGClassNameIsOwned(controller.class)) return YES;
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigationController = (UINavigationController *)controller;
        UIViewController *candidate = navigationController.visibleViewController ?: navigationController.viewControllers.firstObject;
        return candidate != controller && RYGControllerTreeIsOwned(candidate, depth + 1);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *candidate = ((UITabBarController *)controller).selectedViewController;
        return candidate != controller && RYGControllerTreeIsOwned(candidate, depth + 1);
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (child != controller && RYGControllerTreeIsOwned(child, depth + 1)) return YES;
    }
    return NO;
}

BOOL RYGIsOwnedViewController(UIViewController *controller) {
    return RYGControllerTreeIsOwned(controller, 0);
}

BOOL RYGLiquidGlassIsAvailable(void) {
    if (@available(iOS 26.0, *)) {
        return ![RYGUtils getBoolPref:@"liquid_glass_force_off"];
    }
    return NO;
}

UIVisualEffectView *RYGLiquidGlassView(BOOL interactive,
                                       BOOL clearStyle,
                                       UIColor *tintColor) {
    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) {
        if (RYGLiquidGlassIsAvailable()) {
            UIGlassEffect *glass = [UIGlassEffect effectWithStyle:
                clearStyle ? UIGlassEffectStyleClear : UIGlassEffectStyleRegular];
            glass.interactive = interactive;
            glass.tintColor = tintColor;
            effect = glass;
        }
    }
    if (!effect && !UIAccessibilityIsReduceTransparencyEnabled()) {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    }

    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:effect];
    // Glass backgrounds must never swallow interaction intended for the content
    // above them. Interactive UIGlassEffect still reacts through the containing
    // control; the effect view itself remains a passive background surface.
    view.userInteractionEnabled = NO;
    if (!effect) view.backgroundColor = tintColor ?: UIColor.secondarySystemBackgroundColor;
    return view;
}

void RYGLiquidGlassSetTint(UIVisualEffectView *view, UIColor *tintColor) {
    if (!view) return;
    if (@available(iOS 26.0, *)) {
        if ([view.effect isKindOfClass:UIGlassEffect.class]) {
            ((UIGlassEffect *)view.effect).tintColor = tintColor;
            view.backgroundColor = UIColor.clearColor;
            return;
        }
    }
    view.backgroundColor = tintColor ?: UIColor.clearColor;
}

static void RYGPrepareAdaptiveMenu(UIMenu *menu) {
    if (!menu) return;

    // UIKit owns menu geometry. Automatic sizing is deliberately used instead
    // of medium/large element sizes or a popover preferredContentSize so short
    // menus are not forced into the wide cards that older RyukGram builds used.
    if (@available(iOS 17.0, *)) {
        menu.preferredElementSize = UIMenuElementSizeAutomatic;
    }
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIMenu.class]) RYGPrepareAdaptiveMenu((UIMenu *)element);
    }
}

static UIButtonConfiguration *RYGGlassConfigurationForButton(UIButton *button,
                                                              BOOL prominent) API_AVAILABLE(ios(26.0)) {
    UIButtonConfiguration *old = button.configuration;
    UIButtonConfiguration *glass = prominent
        ? [UIButtonConfiguration prominentGlassButtonConfiguration]
        : [UIButtonConfiguration glassButtonConfiguration];

    glass.title = old.title ?: [button titleForState:UIControlStateNormal];
    glass.attributedTitle = old.attributedTitle;
    glass.subtitle = old.subtitle;
    glass.attributedSubtitle = old.attributedSubtitle;
    glass.image = old.image ?: [button imageForState:UIControlStateNormal];
    glass.imagePlacement = old ? old.imagePlacement : NSDirectionalRectEdgeLeading;
    glass.imagePadding = old ? old.imagePadding : 6.0;
    glass.titlePadding = old.titlePadding;
    if (old) glass.cornerStyle = old.cornerStyle;

    BOOL menuSource = button.showsMenuAsPrimaryAction || button.menu != nil;
    glass.baseForegroundColor = old.baseForegroundColor ?: (menuSource ? UIColor.labelColor : button.tintColor);
    if (menuSource) {
        [glass setDefaultContentInsets];
    } else if (old) {
        glass.contentInsets = old.contentInsets;
    }
    return glass;
}

static void RYGFitFrameManagedMenuButton(UIButton *button) {
    if (!button) return;
    [button invalidateIntrinsicContentSize];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // Auto Layout owns constrained buttons. accessoryView/menu buttons created
    // with explicit frames instead follow their intrinsic content size.
    if (!button.translatesAutoresizingMaskIntoConstraints) return;
    [button sizeToFit];
    CGSize intrinsic = button.intrinsicContentSize;
    CGRect frame = button.frame;
    if (intrinsic.width > 0.0 && isfinite(intrinsic.width)) frame.size.width = ceil(intrinsic.width);
    if (intrinsic.height > 0.0 && isfinite(intrinsic.height)) frame.size.height = ceil(intrinsic.height);
    button.frame = frame;
}

static void RYGSynchronizeGlassButton(UIButton *button, BOOL prominent) {
    if (!button) return;

    BOOL menuSource = button.showsMenuAsPrimaryAction || button.menu != nil;
    if (menuSource && button.menu) RYGPrepareAdaptiveMenu(button.menu);

    if (@available(iOS 26.0, *)) {
        if (RYGLiquidGlassIsAvailable()) {
            NSString *title = button.configuration.title ?: [button titleForState:UIControlStateNormal] ?: @"";
            NSString *stateKey = [NSString stringWithFormat:@"%d:%d:%@", prominent, menuSource, title];
            NSString *configured = objc_getAssociatedObject(button, kRYGGlassButtonConfiguredKey);
            if (![configured isEqualToString:stateKey]) {
                button.backgroundColor = UIColor.clearColor;
                if (menuSource) button.tintColor = UIColor.labelColor;
                button.configuration = RYGGlassConfigurationForButton(button, prominent);
                objc_setAssociatedObject(button,
                                         kRYGGlassButtonConfiguredKey,
                                         stateKey,
                                         OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        }
    }

    if (menuSource) RYGFitFrameManagedMenuButton(button);
}

void RYGLiquidGlassConfigureButton(UIButton *button, BOOL prominent) {
    if (!button) return;
    RYGSynchronizeGlassButton(button, prominent);

    BOOL menuSource = button.showsMenuAsPrimaryAction || button.menu != nil;
    if (!menuSource || !button.translatesAutoresizingMaskIntoConstraints) return;

    // A number of RyukGram cells assign the final title after building the
    // accessory button. Re-fit once at the end of the run loop so the closed
    // capsule never keeps the stale, truncated frame.
    if (![objc_getAssociatedObject(button, kRYGGlassButtonDeferredFitKey) boolValue]) {
        objc_setAssociatedObject(button,
                                 kRYGGlassButtonDeferredFitKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIButton *weakButton = button;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIButton *strongButton = weakButton;
            if (!strongButton) return;
            objc_setAssociatedObject(strongButton,
                                     kRYGGlassButtonDeferredFitKey,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RYGSynchronizeGlassButton(strongButton, prominent);
        });
    }
}

UIView *RYGLiquidGlassNavigationTitleView(NSString *title) {
    UILabel *label = [UILabel new];
    label.text = title ?: @"";
    label.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.78;
    label.accessibilityLabel = title;
    [label sizeToFit];
    objc_setAssociatedObject(label, kRYGGeneratedTitleViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return label;
}

void RYGLiquidGlassConfigureNavigationController(UINavigationController *navigationController) {
    if (!navigationController) return;
    navigationController.navigationBar.translucent = YES;
    navigationController.toolbar.translucent = YES;
    navigationController.navigationBar.prefersLargeTitles = NO;
    navigationController.navigationBar.tintColor = UIColor.labelColor;

    // With SDK 26.5, UINavigationBar/UIBarButtonItem render the public native
    // Liquid Glass chrome themselves. Do not install a second blur/glass
    // background or a custom title capsule on top of that system surface.
    if (@available(iOS 26.0, *)) {
        return;
    }

    // Older systems retain their standard UIKit material. Keeping the default
    // appearance also respects the user's light/dark and accessibility choices.
}

static void RYGUseNativeNavigationTitle(UIViewController *controller) {
    if (!controller) return;
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UIView *titleView = controller.navigationItem.titleView;
    if (titleView && [objc_getAssociatedObject(titleView, kRYGGeneratedTitleViewKey) boolValue]) {
        controller.navigationItem.titleView = nil;
    }
}

static BOOL RYGViewLivesInsideContentCell(UIView *view) {
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITableViewCell.class] ||
            [ancestor isKindOfClass:UICollectionViewCell.class]) return YES;
    }
    return NO;
}

static void RYGStyleOwnedControls(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];

        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            BOOL menuSource = button.showsMenuAsPrimaryAction || button.menu != nil;
            if (menuSource || !RYGViewLivesInsideContentCell(button)) {
                RYGLiquidGlassConfigureButton(button, NO);
            }
        }
        for (UIView *subview in view.subviews) [pending addObject:subview];
    }
}

void RYGLiquidGlassApplyToViewController(UIViewController *controller) {
    if (!RYGIsOwnedViewController(controller)) return;

    UIViewController *content = controller;
    UINavigationController *navigationController = nil;
    if ([controller isKindOfClass:UINavigationController.class]) {
        navigationController = (UINavigationController *)controller;
        content = navigationController.visibleViewController ?: controller;
    } else {
        navigationController = controller.navigationController;
    }

    if (navigationController) RYGLiquidGlassConfigureNavigationController(navigationController);
    RYGUseNativeNavigationTitle(content);

    if (content.isViewLoaded) {
        if ([content isKindOfClass:UITableViewController.class]) {
            UITableView *table = ((UITableViewController *)content).tableView;
            table.backgroundColor = UIColor.systemGroupedBackgroundColor;
            content.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
        } else if (!content.view.backgroundColor) {
            content.view.backgroundColor = UIColor.systemBackgroundColor;
        }
        RYGStyleOwnedControls(content.view);
    }
}
