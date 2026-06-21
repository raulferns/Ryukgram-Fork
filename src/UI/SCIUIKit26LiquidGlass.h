#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SCIUIKit26IsAvailable(void);
UIVisualEffect *_Nullable SCIUIKit26GlassEffect(BOOL clearStyle, BOOL interactive, UIColor *_Nullable tintColor);
UIVisualEffect *_Nullable SCIUIKit26GlassContainerEffect(CGFloat spacing);
UIColor *SCIUIKit26BaseSurfaceColor(void);
UIColor *SCIUIKit26PanelFillColor(void);
UIColor *SCIUIKit26SeparatorColor(void);

void SCIUIKit26ApplyContainerBackgroundToViewController(UIViewController *vc);
void SCIUIKit26ConfigureViewController(UIViewController *vc);
void SCIConfigureNavigationChromeForGlass(UIViewController *vc);
void SCIUIKit26InstallNavigationTitleBubble(UIViewController *vc);
void SCIUIKit26RefreshNavigationTitleBubble(UIViewController *vc);
void SCIUIKit26ConfigureScrollView(UIScrollView *scrollView);
void SCIUIKit26ConfigureTableView(UITableView *tableView);
void SCIUIKit26ConfigureCollectionView(UICollectionView *collectionView);
void SCIUIKit26ConfigureTableCell(UITableViewCell *cell);
void SCIUIKit26ApplyTableCellSelectionTint(UITableViewCell *cell, BOOL selected);
void SCIStyleCollectionCellForGlass(UICollectionViewCell *cell);
void SCIUIKit26ConfigureGlassView(UIView *view, CGFloat radius, BOOL interactive);
void SCIUIKit26ConfigureButton(UIButton *button);
void SCIUIKit26ConfigureSearchBar(UISearchBar *searchBar);
void SCIUIKit26ConfigureSearchNavigationItem(UINavigationItem *navigationItem);
void SCIUIKit26ConfigureSegmentedControl(UISegmentedControl *control);
void SCIUIKit26ConfigureTabBar(UITabBar *tabBar);
void SCIStyleControlForGlass(UIControl *control);

@interface SCIUIKit26GlassPanelView : UIVisualEffectView
@property (nonatomic, assign) CGFloat sciCornerRadius;
@property (nonatomic, assign) BOOL sciGlassInteractive;
@property (nonatomic, assign) BOOL sciGlassClearStyle;
@property (nonatomic, strong, nullable) UIColor *sciGlassTintColor;
- (instancetype)initWithRadius:(CGFloat)radius;
- (void)applyLiquidGlassStyle;
@end

@interface SCIUIKit26SectionHeaderView : UITableViewHeaderFooterView
- (void)configureWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle;
@end

@interface SCIUIKit26ParamCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle badge:(nullable NSString *)badge emphasized:(BOOL)emphasized;
@end

@interface SCIUIKit26FloatingToolbar : SCIUIKit26GlassPanelView
@end

@interface SCIUIKit26SearchBarContainerView : SCIUIKit26GlassPanelView
@property (nonatomic, strong, readonly) UISearchBar *searchBar;
@end

NS_ASSUME_NONNULL_END
