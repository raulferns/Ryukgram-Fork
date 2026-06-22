#import "SCIUIKit26LiquidGlass.h"
#import "../Utils.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static NSInteger const kSCIUIKit26GlassBackgroundTag = 0x51C126;

static UIColor *SCIUIKit26BorderColor(void);
static UIVisualEffectView *SCIUIKit26EnsureGlassBackground(UIView *view, CGFloat radius, BOOL interactive, BOOL clearStyle, UIColor *tintColor);

static NSInteger const kSCIUIKit26TitleBubbleTag = 0x51C260;

@interface SCIUIKit26TitleBubbleView : UIVisualEffectView
@property (nonatomic, strong) UILabel *label;
- (void)configureWithTitle:(NSString *)title;
@end

@implementation SCIUIKit26TitleBubbleView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithEffect:SCIUIKit26GlassEffect(NO, YES, nil)];
    if (self) {
        self.tag = kSCIUIKit26TitleBubbleTag;
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = 18.0;
        if ([self.layer respondsToSelector:@selector(setCornerCurve:)]) self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _label = [UILabel new];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = UIColor.labelColor;
        _label.adjustsFontForContentSizeCategory = YES;
        _label.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]];
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.86;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.numberOfLines = 1;
        [self.contentView addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_label.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5.0],
            [_label.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14.0],
            [_label.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14.0],
            [_label.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5.0],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:36.0],
        ]];
        [self configureWithTitle:title];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    NSString *title = self.label.text ?: @"";
    CGSize textSize = [title sizeWithAttributes:@{ NSFontAttributeName: self.label.font ?: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold] }];
    CGFloat maxWidth = MIN(UIScreen.mainScreen.bounds.size.width - 132.0, 280.0);
    CGFloat width = MIN(MAX(64.0, ceil(textSize.width) + 28.0), MAX(100.0, maxWidth));
    return CGSizeMake(width, 36.0);
}

- (CGSize)sizeThatFits:(CGSize)size { return self.intrinsicContentSize; }

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.effect = SCIUIKit26GlassEffect(NO, YES, nil);
    self.contentView.backgroundColor = UIColor.clearColor;
}

- (void)configureWithTitle:(NSString *)title {
    self.label.text = title ?: @"";
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

@end

BOOL SCIUIKit26IsAvailable(void) {
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

UIVisualEffect *SCIUIKit26GlassEffect(BOOL clearStyle, BOOL interactive, UIColor *tintColor) {
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        SEL factory = NSSelectorFromString(@"effectWithStyle:");
        if (glassClass && [glassClass respondsToSelector:factory]) {
            id effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, clearStyle ? 1 : 0);
            SEL setInteractive = NSSelectorFromString(@"setInteractive:");
            if (effect && [effect respondsToSelector:setInteractive]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, interactive);
            }
            SEL setTintColor = NSSelectorFromString(@"setTintColor:");
            if (effect && tintColor && [effect respondsToSelector:setTintColor]) {
                ((void (*)(id, SEL, id))objc_msgSend)(effect, setTintColor, tintColor);
            }
            if ([effect isKindOfClass:UIVisualEffect.class]) return (UIVisualEffect *)effect;
        }
    }

    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
}

UIVisualEffect *SCIUIKit26GlassContainerEffect(CGFloat spacing) {
    if (@available(iOS 26.0, *)) {
        Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
        id effect = containerClass ? [[containerClass alloc] init] : nil;
        SEL setSpacing = NSSelectorFromString(@"setSpacing:");
        if (effect && [effect respondsToSelector:setSpacing]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, setSpacing, spacing);
        }
        if ([effect isKindOfClass:UIVisualEffect.class]) return (UIVisualEffect *)effect;
    }
    return nil;
}

UIColor *SCIUIKit26BaseSurfaceColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark ? UIColor.blackColor : UIColor.whiteColor;
    }];
}

UIColor *SCIUIKit26PanelFillColor(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? UIColor.tertiarySystemGroupedBackgroundColor
                : UIColor.secondarySystemGroupedBackgroundColor;
        }];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.10];
}

UIColor *SCIUIKit26SeparatorColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.075]
            : [UIColor colorWithWhite:0.0 alpha:0.06];
    }];
}

static UIColor *SCIUIKit26CellSelectedFillColor(void) {
    return [UIColor.labelColor colorWithAlphaComponent:0.075];
}

static UIColor *SCIUIKit26CellPressedFillColor(void) {
    return [UIColor.labelColor colorWithAlphaComponent:0.075];
}

static UIColor *SCIUIKit26BorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.12]
            : [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

void SCIUIKit26ApplyContainerBackgroundToViewController(UIViewController *vc) {
    if (!vc || !SCIUIKit26IsAvailable()) return;
    NSInteger glassStyle = 1; // UIContainerBackgroundStyleGlass in the iOS 26 SDK.
    SEL preferred = NSSelectorFromString(@"setPreferredContainerBackgroundStyle:");
    SEL direct = NSSelectorFromString(@"setContainerBackgroundStyle:");
    if ([vc respondsToSelector:preferred]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, preferred, glassStyle);
    } else if ([vc respondsToSelector:direct]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, direct, glassStyle);
    }
}

void SCIUIKit26InstallNavigationTitleBubble(UIViewController *vc) {
    if (!vc || !SCIUIKit26IsAvailable()) return;
    NSString *title = vc.title ?: vc.navigationItem.title;
    if (!title.length) return;

    SCIUIKit26TitleBubbleView *bubble = nil;
    if ([vc.navigationItem.titleView isKindOfClass:SCIUIKit26TitleBubbleView.class]) {
        bubble = (SCIUIKit26TitleBubbleView *)vc.navigationItem.titleView;
    } else {
        bubble = [[SCIUIKit26TitleBubbleView alloc] initWithTitle:title];
        vc.navigationItem.titleView = bubble;
    }
    [bubble configureWithTitle:title];
}

void SCIUIKit26RefreshNavigationTitleBubble(UIViewController *vc) {
    if (!vc || !SCIUIKit26IsAvailable()) return;
    NSString *title = vc.title ?: vc.navigationItem.title;
    if (!title.length) return;
    if ([vc.navigationItem.titleView isKindOfClass:SCIUIKit26TitleBubbleView.class]) {
        [(SCIUIKit26TitleBubbleView *)vc.navigationItem.titleView configureWithTitle:title];
    } else {
        SCIUIKit26InstallNavigationTitleBubble(vc);
    }
}

void SCIConfigureNavigationChromeForGlass(UIViewController *vc) {
    if (!vc) return;
    SCIUIKit26InstallNavigationTitleBubble(vc);

    UINavigationBar *bar = vc.navigationController.navigationBar;
    if (bar) {
        bar.translucent = YES;
        bar.backgroundColor = UIColor.clearColor;
        bar.prefersLargeTitles = NO;
        if (@available(iOS 13.0, *)) {
            UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
            [appearance configureWithTransparentBackground];
            appearance.backgroundColor = UIColor.clearColor;
            appearance.backgroundEffect = nil;
            appearance.shadowColor = UIColor.clearColor;
            NSDictionary *titleAttrs = @{
                NSForegroundColorAttributeName: UIColor.labelColor,
                NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]
            };
            appearance.titleTextAttributes = titleAttrs;
            appearance.buttonAppearance.normal.titleTextAttributes = titleAttrs;
            bar.titleTextAttributes = titleAttrs;
            bar.standardAppearance = appearance;
            bar.scrollEdgeAppearance = appearance;
            bar.compactAppearance = appearance;
            if (@available(iOS 15.0, *)) bar.compactScrollEdgeAppearance = appearance;
        }
    }

    UIToolbar *toolbar = vc.navigationController.toolbar;
    if (toolbar && @available(iOS 13.0, *)) {
        UIToolbarAppearance *appearance = [UIToolbarAppearance new];
        [appearance configureWithTransparentBackground];
        appearance.backgroundColor = UIColor.clearColor;
        appearance.backgroundEffect = nil;
        appearance.shadowColor = UIColor.clearColor;
        toolbar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) toolbar.scrollEdgeAppearance = appearance;
        toolbar.translucent = YES;
        toolbar.backgroundColor = UIColor.clearColor;
    }

    if (vc.tabBarController.tabBar) SCIUIKit26ConfigureTabBar(vc.tabBarController.tabBar);
}

void SCIUIKit26ConfigureViewController(UIViewController *vc) {
    if (!vc) return;
    SCIUIKit26ApplyContainerBackgroundToViewController(vc);
    if (vc.isViewLoaded) {
        vc.view.backgroundColor = SCIUIKit26BaseSurfaceColor();
        vc.view.opaque = YES;
        vc.view.layer.backgroundColor = [SCIUIKit26BaseSurfaceColor() resolvedColorWithTraitCollection:vc.view.traitCollection].CGColor;
    }
    SCIConfigureNavigationChromeForGlass(vc);
    __weak UIViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (strongVC) SCIUIKit26RefreshNavigationTitleBubble(strongVC);
    });
}

static void SCIUIKit26ConfigureScrollEdgeEffect(id edgeEffect, NSInteger style, BOOL hidden) {
    if (!edgeEffect) return;
    SEL setStyle = NSSelectorFromString(@"setStyle:");
    if ([edgeEffect respondsToSelector:setStyle]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(edgeEffect, setStyle, style);
    }
    SEL setHidden = NSSelectorFromString(@"setHidden:");
    if ([edgeEffect respondsToSelector:setHidden]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(edgeEffect, setHidden, hidden);
    }
    SEL igSetHidden = NSSelectorFromString(@"ig_setIsHidden:");
    if ([edgeEffect respondsToSelector:igSetHidden]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(edgeEffect, igSetHidden, hidden);
    }
}

void SCIUIKit26ConfigureScrollView(UIScrollView *scrollView) {
    if (!scrollView) return;
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.opaque = NO;
    if (@available(iOS 11.0, *)) scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;

    if (@available(iOS 26.0, *)) {
        SEL topSel = NSSelectorFromString(@"topEdgeEffect");
        SEL bottomSel = NSSelectorFromString(@"bottomEdgeEffect");
        if ([scrollView respondsToSelector:topSel]) {
            id edge = ((id (*)(id, SEL))objc_msgSend)(scrollView, topSel);
            SCIUIKit26ConfigureScrollEdgeEffect(edge, 0, NO);
        }
        if ([scrollView respondsToSelector:bottomSel]) {
            id edge = ((id (*)(id, SEL))objc_msgSend)(scrollView, bottomSel);
            SCIUIKit26ConfigureScrollEdgeEffect(edge, 0, NO);
        }
    }

    if ([scrollView isKindOfClass:UITableView.class]) {
        UITableView *tableView = (UITableView *)scrollView;
        tableView.backgroundView = nil;
        tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 0.0;
        if (@available(iOS 26.0, *)) {
            SEL setBackgroundEffect = NSSelectorFromString(@"setBackgroundEffect:");
            if ([tableView respondsToSelector:setBackgroundEffect]) {
                ((void (*)(id, SEL, id))objc_msgSend)(tableView, setBackgroundEffect, nil);
            }
        }
    }
}

void SCIUIKit26ConfigureTableView(UITableView *tableView) {
    if (!tableView) return;
    SCIUIKit26ConfigureScrollView(tableView);
    tableView.backgroundColor = UIColor.clearColor;
    tableView.backgroundView = nil;
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tableView.layoutMargins = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
}

void SCIUIKit26ConfigureCollectionView(UICollectionView *collectionView) {
    if (!collectionView) return;
    SCIUIKit26ConfigureScrollView(collectionView);
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.alwaysBounceVertical = YES;
}

void SCIUIKit26ConfigureGlassView(UIView *view, CGFloat radius, BOOL interactive) {
    if (!view) return;
    view.backgroundColor = UIColor.clearColor;
    view.layer.cornerRadius = radius;
    if ([view.layer respondsToSelector:@selector(setCornerCurve:)]) view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    SCIUIKit26EnsureGlassBackground(view, radius, interactive, NO, nil);
}

void SCIUIKit26ConfigureButton(UIButton *button) {
    if (!button) return;
    button.backgroundColor = UIColor.clearColor;
    button.layer.backgroundColor = UIColor.clearColor.CGColor;
    button.tintColor = [SCIUtils SCIColor_Primary];

    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = nil;
        if (@available(iOS 26.0, *)) {
            Class cls = UIButtonConfiguration.class;
            SEL plainGlass = NSSelectorFromString(@"glassButtonConfiguration");
            SEL clearGlass = NSSelectorFromString(@"clearGlassButtonConfiguration");
            if ([cls respondsToSelector:plainGlass]) {
                cfg = ((id (*)(id, SEL))objc_msgSend)(cls, plainGlass);
            } else if ([cls respondsToSelector:clearGlass]) {
                cfg = ((id (*)(id, SEL))objc_msgSend)(cls, clearGlass);
            }
        }
        if (!cfg) cfg = button.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
        cfg.background.backgroundColor = UIColor.clearColor;
        cfg.baseForegroundColor = [SCIUtils SCIColor_Primary];
        button.configuration = cfg;
    }
}

void SCIStyleControlForGlass(UIControl *control) {
    if (!control) return;
    if ([control isKindOfClass:UIButton.class]) {
        SCIUIKit26ConfigureButton((UIButton *)control);
    } else if ([control isKindOfClass:UISegmentedControl.class]) {
        SCIUIKit26ConfigureSegmentedControl((UISegmentedControl *)control);
    } else {
        control.backgroundColor = UIColor.clearColor;
    }
}

void SCIUIKit26ConfigureSearchBar(UISearchBar *searchBar) {
    if (!searchBar) return;
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = nil;
    searchBar.barTintColor = nil;
    searchBar.backgroundColor = UIColor.clearColor;
    searchBar.translucent = YES;

    UITextField *field = searchBar.searchTextField;
    if (!field) return;
    field.textColor = UIColor.labelColor;
    field.tintColor = [SCIUtils SCIColor_Primary];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.background = nil;
    field.disabledBackground = nil;
    field.backgroundColor = nil;
    field.layer.backgroundColor = nil;
    field.layer.cornerRadius = 0.0;
    field.layer.borderWidth = 0.0;
    field.layer.masksToBounds = NO;
    field.clipsToBounds = NO;
    field.leftView.tintColor = UIColor.secondaryLabelColor;
    field.rightView.tintColor = UIColor.secondaryLabelColor;

    NSString *placeholder = field.attributedPlaceholder.string ?: field.placeholder ?: @"";
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor
    }];
}

void SCIUIKit26ConfigureSearchNavigationItem(UINavigationItem *navigationItem) {
    if (!navigationItem) return;
    navigationItem.hidesSearchBarWhenScrolling = YES;
    UISearchController *searchController = navigationItem.searchController;
    if (searchController) {
        searchController.obscuresBackgroundDuringPresentation = NO;
        SCIUIKit26ConfigureSearchBar(searchController.searchBar);
    }
    if (@available(iOS 26.0, *)) {
        SEL allowsExternal = NSSelectorFromString(@"setSearchBarPlacementAllowsExternalIntegration:");
        if ([navigationItem respondsToSelector:allowsExternal]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(navigationItem, allowsExternal, YES);
        }
        SEL setPreferred = NSSelectorFromString(@"setPreferredSearchBarPlacement:");
        if ([navigationItem respondsToSelector:setPreferred]) {
            // 1 is UINavigationItemSearchBarPlacementIntegrated on iOS 26.
            // Do not force IntegratedButton here: it creates a bottom floating search surface.
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(navigationItem, setPreferred, 1);
        }
    }
}

void SCIUIKit26ConfigureSegmentedControl(UISegmentedControl *control) {
    if (!control) return;
    control.backgroundColor = UIColor.clearColor;
    control.selectedSegmentTintColor = SCIUIKit26IsAvailable() ? nil : [UIColor.labelColor colorWithAlphaComponent:0.12];
    NSDictionary *normal = @{ NSForegroundColorAttributeName: UIColor.secondaryLabelColor };
    NSDictionary *selected = @{ NSForegroundColorAttributeName: UIColor.labelColor, NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] };
    [control setTitleTextAttributes:normal forState:UIControlStateNormal];
    [control setTitleTextAttributes:selected forState:UIControlStateSelected];
}

void SCIUIKit26ConfigureTabBar(UITabBar *tabBar) {
    if (!tabBar) return;
    tabBar.translucent = YES;
    tabBar.backgroundColor = UIColor.clearColor;
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *appearance = [UITabBarAppearance new];
        [appearance configureWithTransparentBackground];
        appearance.backgroundColor = UIColor.clearColor;
        appearance.backgroundEffect = nil;
        appearance.shadowColor = UIColor.clearColor;
        tabBar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) tabBar.scrollEdgeAppearance = appearance;
    }
}

void SCIUIKit26ConfigureTableCell(UITableViewCell *cell) {
    if (!cell) return;
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.preservesSuperviewLayoutMargins = YES;

    UIView *selected = [UIView new];
    selected.backgroundColor = SCIUIKit26CellPressedFillColor();
    selected.layer.cornerRadius = 0.0;
    if ([selected.layer respondsToSelector:@selector(setCornerCurve:)]) selected.layer.cornerCurve = kCACornerCurveContinuous;
    selected.clipsToBounds = YES;
    cell.selectedBackgroundView = selected;

    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = [UIBackgroundConfiguration listGroupedCellConfiguration];
        bg.backgroundColor = SCIUIKit26PanelFillColor();
        bg.visualEffect = nil;
        bg.strokeColor = UIColor.clearColor;
        bg.strokeWidth = 0.0;
        cell.backgroundConfiguration = bg;
        cell.backgroundView = nil;
    } else {
        SCIUIKit26EnsureGlassBackground(cell.contentView, 12.0, YES, YES, nil);
    }
}

void SCIUIKit26ApplyTableCellSelectionTint(UITableViewCell *cell, BOOL selected) {
    if (!cell) return;
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = cell.backgroundConfiguration ?: [UIBackgroundConfiguration listGroupedCellConfiguration];
        bg.backgroundColor = selected ? SCIUIKit26CellSelectedFillColor() : SCIUIKit26PanelFillColor();
        bg.visualEffect = nil;
        bg.strokeColor = UIColor.clearColor;
        bg.strokeWidth = 0.0;
        cell.backgroundConfiguration = bg;
    } else {
        cell.contentView.backgroundColor = selected ? SCIUIKit26CellSelectedFillColor() : UIColor.clearColor;
    }
}

void SCIStyleCollectionCellForGlass(UICollectionViewCell *cell) {
    if (!cell) return;
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.selectedBackgroundView = [UIView new];
    cell.selectedBackgroundView.backgroundColor = SCIUIKit26CellPressedFillColor();
    if (SCIUIKit26IsAvailable()) {
        if (!cell.backgroundView) {
            UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:SCIUIKit26GlassEffect(NO, YES, nil)];
            glass.layer.cornerRadius = 18.0;
            if ([glass.layer respondsToSelector:@selector(setCornerCurve:)]) glass.layer.cornerCurve = kCACornerCurveContinuous;
            glass.clipsToBounds = YES;
            cell.backgroundView = glass;
        } else {
            SCIUIKit26ConfigureGlassView(cell.backgroundView, 18.0, YES);
        }
    }
}

static UIVisualEffectView *SCIUIKit26EnsureGlassBackground(UIView *view, CGFloat radius, BOOL interactive, BOOL clearStyle, UIColor *tintColor) {
    if (!view) return nil;
    UIVisualEffect *effect = SCIUIKit26GlassEffect(clearStyle, interactive, tintColor);
    if (!effect) return nil;

    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        effectView.effect = effect;
        effectView.backgroundColor = UIColor.clearColor;
        effectView.contentView.backgroundColor = UIColor.clearColor;
        effectView.layer.cornerRadius = radius;
        if ([effectView.layer respondsToSelector:@selector(setCornerCurve:)]) effectView.layer.cornerCurve = kCACornerCurveContinuous;
        effectView.layer.masksToBounds = YES;
        effectView.clipsToBounds = YES;
        return effectView;
    }

    UIVisualEffectView *glass = (UIVisualEffectView *)[view viewWithTag:kSCIUIKit26GlassBackgroundTag];
    if (![glass isKindOfClass:UIVisualEffectView.class]) {
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.tag = kSCIUIKit26GlassBackgroundTag;
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [view insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.topAnchor constraintEqualToAnchor:view.topAnchor],
            [glass.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
    } else {
        glass.effect = effect;
    }

    glass.backgroundColor = UIColor.clearColor;
    glass.contentView.backgroundColor = UIColor.clearColor;
    glass.layer.cornerRadius = radius;
    if ([glass.layer respondsToSelector:@selector(setCornerCurve:)]) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    view.backgroundColor = UIColor.clearColor;
    view.layer.cornerRadius = radius;
    if ([view.layer respondsToSelector:@selector(setCornerCurve:)]) view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    return glass;
}

@implementation SCIUIKit26GlassPanelView

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithEffect:SCIUIKit26GlassEffect(NO, NO, nil)];
    if (self) {
        _sciCornerRadius = radius;
        [self applyLiquidGlassStyle];
    }
    return self;
}

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect ?: SCIUIKit26GlassEffect(NO, NO, nil)];
    if (self) {
        _sciCornerRadius = 22.0;
        [self applyLiquidGlassStyle];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyLiquidGlassStyle];
}

- (void)setSciGlassInteractive:(BOOL)sciGlassInteractive {
    _sciGlassInteractive = sciGlassInteractive;
    [self applyLiquidGlassStyle];
}

- (void)setSciGlassClearStyle:(BOOL)sciGlassClearStyle {
    _sciGlassClearStyle = sciGlassClearStyle;
    [self applyLiquidGlassStyle];
}

- (void)setSciGlassTintColor:(UIColor *)sciGlassTintColor {
    _sciGlassTintColor = sciGlassTintColor;
    [self applyLiquidGlassStyle];
}

- (void)applyLiquidGlassStyle {
    self.effect = SCIUIKit26GlassEffect(self.sciGlassClearStyle, self.sciGlassInteractive, self.sciGlassTintColor);
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = self.sciGlassClearStyle ? UIColor.clearColor : SCIUIKit26PanelFillColor();
    self.layer.cornerRadius = self.sciCornerRadius;
    if ([self.layer respondsToSelector:@selector(setCornerCurve:)]) self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.clipsToBounds = YES;
    self.layer.borderWidth = SCIUIKit26IsAvailable() ? 0.0 : 0.7;
    self.layer.borderColor = SCIUIKit26IsAvailable() ? UIColor.clearColor.CGColor : SCIUIKit26BorderColor().CGColor;
}

@end

@interface SCIUIKit26SectionHeaderView ()
@property (nonatomic, strong) SCIUIKit26GlassPanelView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation SCIUIKit26SectionHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        self.contentView.backgroundColor = UIColor.clearColor;
        _panel = [[SCIUIKit26GlassPanelView alloc] initWithRadius:16.0];
        _panel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_panel];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _subtitleLabel.textColor = UIColor.secondaryLabelColor;
        _subtitleLabel.numberOfLines = 2;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 2.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_panel.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [_panel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
            [_panel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
            [_panel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
            [_panel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
            [stack.topAnchor constraintEqualToAnchor:_panel.contentView.topAnchor constant:10.0],
            [stack.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor constant:14.0],
            [stack.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor constant:-14.0],
            [stack.bottomAnchor constraintEqualToAnchor:_panel.contentView.bottomAnchor constant:-10.0],
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self.titleLabel.text = title ?: @"";
    self.subtitleLabel.text = subtitle ?: @"";
    self.subtitleLabel.hidden = subtitle.length == 0;
}

@end

@interface SCIUIKit26ParamCell ()
@property (nonatomic, strong) SCIUIKit26GlassPanelView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@end

@implementation SCIUIKit26ParamCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = SCIUIKit26CellPressedFillColor();

        _panel = [[SCIUIKit26GlassPanelView alloc] initWithRadius:18.0];
        _panel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_panel];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.numberOfLines = 2;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _subtitleLabel.textColor = UIColor.secondaryLabelColor;
        _subtitleLabel.numberOfLines = 4;
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _badgeLabel = [UILabel new];
        _badgeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        _badgeLabel.textColor = UIColor.labelColor;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
        _badgeLabel.layer.cornerRadius = 10.0;
        if ([_badgeLabel.layer respondsToSelector:@selector(setCornerCurve:)]) _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 4.0;
        textStack.translatesAutoresizingMaskIntoConstraints = NO;

        [_panel.contentView addSubview:textStack];
        [_panel.contentView addSubview:_badgeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_panel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5.0],
            [_panel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14.0],
            [_panel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14.0],
            [_panel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5.0],
            [textStack.topAnchor constraintEqualToAnchor:_panel.contentView.topAnchor constant:12.0],
            [textStack.leadingAnchor constraintEqualToAnchor:_panel.contentView.leadingAnchor constant:14.0],
            [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_badgeLabel.leadingAnchor constant:-10.0],
            [textStack.bottomAnchor constraintEqualToAnchor:_panel.contentView.bottomAnchor constant:-12.0],
            [_badgeLabel.trailingAnchor constraintEqualToAnchor:_panel.contentView.trailingAnchor constant:-12.0],
            [_badgeLabel.centerYAnchor constraintEqualToAnchor:_panel.contentView.centerYAnchor],
            [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:48.0],
            [_badgeLabel.heightAnchor constraintEqualToConstant:22.0],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self configureWithTitle:@"" subtitle:@"" badge:nil emphasized:NO];
}

- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle badge:(NSString *)badge emphasized:(BOOL)emphasized {
    self.titleLabel.text = title ?: @"";
    self.subtitleLabel.text = subtitle ?: @"";
    self.badgeLabel.text = badge ?: @"";
    self.badgeLabel.hidden = badge.length == 0;
    self.titleLabel.font = emphasized ? [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] : [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.panel.sciGlassTintColor = emphasized ? [[SCIUtils SCIColor_Primary] colorWithAlphaComponent:0.18] : nil;
    self.panel.contentView.backgroundColor = emphasized ? [[SCIUtils SCIColor_Primary] colorWithAlphaComponent:0.18] : SCIUIKit26PanelFillColor();
    self.badgeLabel.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:emphasized ? 0.12 : 0.08];
}

@end

@interface SCIUIKit26FloatingToolbar ()
@property (nonatomic, strong) UIButton *captureButton;
@end

@implementation SCIUIKit26FloatingToolbar

static UIButton *SCIUIKit26ToolbarButton(NSString *title, NSString *symbol, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
        cfg.title = title;
        cfg.image = [UIImage systemImageNamed:symbol];
        cfg.imagePadding = 5.0;
        cfg.buttonSize = UIButtonConfigurationSizeSmall;
        cfg.background.backgroundColor = UIColor.clearColor;
        cfg.background.visualEffect = SCIUIKit26GlassEffect(YES, YES, nil);
        button.configuration = cfg;
    } else {
        [button setTitle:title forState:UIControlStateNormal];
    }
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithTarget:(id)target refresh:(SEL)refresh clear:(SEL)clear export:(SEL)export toggleCapture:(SEL)toggleCapture {
    self = [super initWithRadius:24.0];
    if (self) {
        self.sciGlassClearStyle = NO;
        self.sciGlassInteractive = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        UIButton *refreshButton = SCIUIKit26ToolbarButton(@"Refresh", @"arrow.clockwise", target, refresh);
        UIButton *exportButton = SCIUIKit26ToolbarButton(@"Export", @"square.and.arrow.up", target, export);
        UIButton *clearButton = SCIUIKit26ToolbarButton(@"Clear", @"trash", target, clear);
        _captureButton = SCIUIKit26ToolbarButton(@"Capture", @"dot.radiowaves.left.and.right", target, toggleCapture);
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[refreshButton, exportButton, clearButton, _captureButton]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 4.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
            [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10.0],
            [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10.0],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        ]];
    }
    return self;
}

- (void)setCaptureEnabled:(BOOL)enabled {
    NSString *title = enabled ? @"Capture ON" : @"Capture OFF";
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *cfg = self.captureButton.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
        cfg.title = title;
        cfg.baseForegroundColor = enabled ? [SCIUtils SCIColor_Primary] : UIColor.secondaryLabelColor;
        self.captureButton.configuration = cfg;
    } else {
        [self.captureButton setTitle:title forState:UIControlStateNormal];
    }
}

@end

@interface SCIUIKit26SearchBarContainerView ()
@property (nonatomic, strong, readwrite) UISearchBar *searchBar;
@end

@implementation SCIUIKit26SearchBarContainerView

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithRadius:radius];
    if (self) [self commonInit];
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self commonInit];
    return self;
}

- (void)commonInit {
    self.sciCornerRadius = 22.0;
    self.sciGlassInteractive = YES;
    [self applyLiquidGlassStyle];
    _searchBar = [UISearchBar new];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_searchBar];
    SCIUIKit26ConfigureSearchBar(_searchBar);
    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:2.0],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4.0],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4.0],
        [_searchBar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-2.0],
    ]];
}

@end
