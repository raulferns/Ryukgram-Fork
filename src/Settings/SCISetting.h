#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SCISymbol.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCITableCell) {
        SCITableCellStatic,
    SCITableCellCustom,
        SCITableCellLink,
        SCITableCellSwitch,
        SCITableCellStepper,
        SCITableCellButton,
        SCITableCellMenu,
        SCITableCellNavigation,
        SCITableCellColor,
};

@interface SCISetting : NSObject

@property (nonatomic, readonly) SCITableCell type;

@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *subtitle;

@property (nonatomic, strong, nullable) SCISymbol *icon;
/// Pre-rendered icon, used instead of  when set.
@property (nonatomic, strong, nullable) UIImage *iconImage;
@property (nonatomic, strong) NSString *defaultsKey;

@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURL *imageUrl;
@property (nonatomic, copy, nullable) NSString *bundleImageName;

@property (nonatomic) BOOL requiresRestart;
@property (nonatomic) BOOL hidesDisclosureIndicator;
@property (nonatomic) BOOL disabled;

/// What's-new dot identifier for keyless rows; pref rows derive it from defaultsKey.
@property (nonatomic, copy, nullable) NSString *whatsNewID;

@property (nonatomic) double min;
@property (nonatomic) double max;
@property (nonatomic) double step;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *singularLabel;

@property (nonatomic, copy) void (^action)(void);

/// Color cell fallback when the defaults key is unset/invalid.
@property (nonatomic, strong, nullable) UIColor *defaultColor;

@property (nonatomic, strong) UIMenu *baseMenu;

@property (nonatomic, copy, nullable) NSString *(^dynamicTitle)(void);
@property (nonatomic, copy, nullable) NSString *(^dynamicSubtitle)(void);

/// For hook-driven switch cells: dynamically provides current ON/OFF state
/// instead of reading from defaultsKey. Re-evaluated on each cell render.
@property (nonatomic, copy, nullable) BOOL (^dynamicSwitchValue)(void);

/// For hook-driven switch cells: called when the UISwitch is toggled.
/// When set, the default defaultsKey write is skipped — the block owns all state.
@property (nonatomic, copy, nullable) void (^onSwitchChange)(BOOL isOn);

/// Custom cell: provider builds it;  (>0) fixes the row height.
@property (nonatomic) CGFloat customHeight;
@property (nonatomic, copy, nullable) UITableViewCell *(^customCellProvider)(UITableView *tableView, NSIndexPath *indexPath);

/// Optional trailing label for a static cell. Rendered right-aligned; pairs
/// with `subtitle` (which still renders beneath the title) when both are set.
@property (nonatomic, copy, nullable) NSString *valueText;

/// Dynamic valueText resolver — re-evaluated per cell render so the displayed
/// value stays in sync with prefs that change mid-screen.
@property (nonatomic, copy, nullable) NSString *(^dynamicValueText)(void);

/// Optional override for the title text color. Primarily useful for giving
/// action-style button cells the same tint as link cells.
@property (nonatomic, strong, nullable) UIColor *titleColor;

@property (nonatomic, strong) NSArray *navSections;
@property (nonatomic, strong) UIViewController *navViewController;

+ (instancetype)staticCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                               icon:(nullable SCISymbol *)icon;

+ (instancetype)linkCellWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                             icon:(nullable SCISymbol *)icon
                              url:(NSString *)url;

+ (instancetype)linkCellWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                         imageUrl:(NSString *)imageUrl
                              url:(NSString *)url;

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                        defaultsKey:(NSString *)defaultsKey;

+ (instancetype)switchCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                        defaultsKey:(NSString *)defaultsKey
                    requiresRestart:(BOOL)requiresRestart;

/// Hook-driven switch: no defaultsKey storage. State read via getValue, toggle via onToggle.
/// The block pair owns all persistence (e.g. via SCIGatingCatalog setRuntimeBoolOverride).
+ (instancetype)hookSwitchCellWithTitle:(NSString *)title
                               subtitle:(NSString *)subtitle
                                   icon:(nullable SCISymbol *)icon
                               getValue:(BOOL (^)(void))getValue
                               onToggle:(void (^)(BOOL isOn))onToggle;

+ (instancetype)stepperCellWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                         defaultsKey:(NSString *)defaultsKey
                                 min:(double)min
                                 max:(double)max
                                step:(double)step
                               label:(NSString *)label
                       singularLabel:(NSString *)singularLabel;

+ (instancetype)buttonCellWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                               icon:(nullable SCISymbol *)icon
                             action:(void (^)(void))action;

+ (instancetype)menuCellWithTitle:(NSString *)title
                         subtitle:(NSString *)subtitle
                             menu:(UIMenu *)menu;

+ (instancetype)colorCellWithTitle:(NSString *)title
                          subtitle:(NSString *)subtitle
                       defaultsKey:(NSString *)defaultsKey
                      defaultColor:(nullable UIColor *)defaultColor;

+ (instancetype)navigationCellWithTitle:(NSString *)title
                               subtitle:(NSString *)subtitle
                                   icon:(nullable SCISymbol *)icon
                            navSections:(NSArray *)navSections;

+ (instancetype)navigationCellWithTitle:(NSString *)title
                               subtitle:(NSString *)subtitle
                                   icon:(nullable SCISymbol *)icon
                         viewController:(UIViewController *)viewController;


# pragma mark - Instance methods

- (UIMenu *)menuForButton:(UIButton *)button;


+ (instancetype)customCellWithHeight:(CGFloat)height
                             provider:(UITableViewCell *(^)(UITableView *tableView, NSIndexPath *indexPath))provider;

@end

NS_ASSUME_NONNULL_END
