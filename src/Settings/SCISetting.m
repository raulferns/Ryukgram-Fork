#import "SCISetting.h"

@interface SCISetting ()

@property (nonatomic, readwrite) SCITableCell type;

- (instancetype)initWithType:(SCITableCell)type NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

static BOOL SCIIsWordmarkMenuCommand(NSDictionary *props) {
	return [props[@"defaultsKey"] isEqualToString:@"sci_ig_wordmark_variant"];
}

static NSString *SCIWordmarkDisplayTitleForValue(NSString *value, NSString *fallback) {
	if ([value isEqualToString:@"off"]) return SCILocalized(@"Default");
	if ([value isEqualToString:@"1a"]) return SCILocalized(@"Wordmark 1");
	if ([value isEqualToString:@"1a_alt"]) return SCILocalized(@"Wordmark 1A");
	if ([value isEqualToString:@"1b"]) return SCILocalized(@"Wordmark 2");
	if ([value isEqualToString:@"1b_alt"]) return SCILocalized(@"Wordmark 2A");
	return fallback ?: @"";
}

///

@implementation SCISetting

// MARK: - - initWithType

- (instancetype)initWithType:(SCITableCell)type {
	self = [super init];

	if (self) {
		self.type = type;
	}

	return self;
}


// MARK: - + staticCellWithTitle

+ (instancetype)staticCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
							   icon:(nullable SCISymbol *)icon
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellStatic];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;

	return setting;
}

// MARK: - + linkCellWithTitle

+ (instancetype)linkCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
							 icon:(nullable SCISymbol *)icon
							  url:(NSString *)url
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellLink];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.url = [NSURL URLWithString:url];

	return setting;
}

+ (instancetype)linkCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
						 imageUrl:(NSString *)imageUrl
							  url:(NSString *)url
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellLink];

	setting.title = title;
	setting.subtitle = subtitle;

	setting.imageUrl = [NSURL URLWithString:imageUrl];
	setting.url = [NSURL URLWithString:url];

	return setting;
}

// MARK: - + switchCellWithTitle

+ (instancetype)switchCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
						defaultsKey:(NSString *)defaultsKey
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellSwitch];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.defaultsKey = defaultsKey;

	return setting;
}

+ (instancetype)switchCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
						defaultsKey:(NSString *)defaultsKey
					requiresRestart:(BOOL)requiresRestart
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellSwitch];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.defaultsKey = defaultsKey;
	setting.requiresRestart = requiresRestart;

	return setting;
}

+ (instancetype)switchCellWithTitle:(NSString *)title
						   subtitle:(nullable NSString *)subtitle
							  value:(BOOL (^)(void))value
							 action:(void (^)(BOOL on))action
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellSwitch];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.switchValueProvider = value;
	setting.switchAction = action;

	return setting;
}

+ (instancetype)customCellWithHeight:(CGFloat)height
							provider:(UITableViewCell *(^)(UITableView *tableView, NSIndexPath *indexPath))provider
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellCustom];

	setting.customHeight = height;
	setting.customCellProvider = provider;

	return setting;
}

// MARK: - + stepperCellWithTitle

+ (instancetype)stepperCellWithTitle:(NSString *)title
							subtitle:(NSString *)subtitle
						 defaultsKey:(NSString *)defaultsKey
								 min:(double)min
								 max:(double)max
								step:(double)step
							   label:(NSString *)label
					   singularLabel:(NSString *)singularLabel
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellStepper];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.defaultsKey = defaultsKey;

	setting.min = min;
	setting.max = max;
	setting.step = step;
	setting.label = label;
	setting.singularLabel = singularLabel;

	return setting;
}

// MARK: - + buttonCellWithTitle

+ (instancetype)buttonCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
							   icon:(nullable SCISymbol *)icon
							 action:(void (^)(void))action
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellButton];

	setting.title = title;
	setting.subtitle = subtitle;

	setting.icon = icon;
	setting.action = action;

	return setting;
}

// MARK: - + colorCellWithTitle

+ (instancetype)colorCellWithTitle:(NSString *)title
						  subtitle:(NSString *)subtitle
					   defaultsKey:(NSString *)defaultsKey
					  defaultColor:(nullable UIColor *)defaultColor
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellColor];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.defaultsKey = defaultsKey;
	setting.defaultColor = defaultColor;

	return setting;
}

# pragma mark + menuCellWithTitle

+ (instancetype)menuCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
							 menu:(UIMenu *)menu
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellMenu];

	setting.title = title;
	setting.subtitle = subtitle;

	setting.baseMenu = menu;

	return setting;
}

// MARK: - + navigationCellWithTitle

+ (instancetype)navigationCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
							   icon:(nullable SCISymbol *)icon
							navSections:(NSArray *)navSections
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellNavigation];

	setting.title = title;
	setting.subtitle = subtitle;

	setting.icon = icon;
	setting.navSections = navSections;

	return setting;
}

+ (instancetype)navigationCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
							   icon:(nullable SCISymbol *)icon
					 viewController:(UIViewController *)viewController
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellNavigation];

	setting.title = title;
	setting.subtitle = subtitle;

	setting.icon = icon;
	setting.navViewController = viewController;

	return setting;
}


// MARK: -  Instance methods

- (UIMenu *)menuForButton:(UIButton *)button {
	return [self submenuForButton:button submenu:self.baseMenu];
}

- (UIMenu *)submenuForButton:(UIButton *)button submenu:(UIMenu*)submenu {
	NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

	for (id obj in submenu.children) {
		// Handle recursive submenus
		if ([obj isKindOfClass:[UIMenu class]]) {
			[children addObject:[self submenuForButton:button submenu:(UIMenu *)obj]];
			continue;
		}
		else if (![obj isKindOfClass:[UICommand class]]) {
			continue;
		}

		UICommand *child = obj;
		NSDictionary *props = [child.propertyList isKindOfClass:NSDictionary.class] ? child.propertyList : nil;
		NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:props[@"defaultsKey"]];
		NSString *value = [props[@"value"] isKindOfClass:NSString.class] ? props[@"value"] : nil;
		BOOL isWordmark = SCIIsWordmarkMenuCommand(props);
		NSString *displayTitle = isWordmark ? SCIWordmarkDisplayTitleForValue(value, child.title) : child.title;
		// Icon-only wordmark rows: a single space (not @"") keeps a stable text
		// baseline so the selected row still lays out its image next to the
		// checkmark instead of collapsing it away.
		NSString *menuTitle = isWordmark ? @" " : (child.title ?: @"");

		UICommand *command = [UICommand commandWithTitle:menuTitle
										   image:child.image
									  action:child.action
								propertyList:child.propertyList];

		if (value.length && [value isEqualToString:saved]) {
			command.state = UIMenuElementStateOn;

			if (![props[@"noTitle"] boolValue]) {
				[button setImage:nil forState:UIControlStateNormal];
				[button setTitle:displayTitle forState:UIControlStateNormal];
				button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
				button.titleLabel.numberOfLines = 1;
				if (button.configuration) {
					UIButtonConfiguration *cfg = button.configuration;
					cfg.title = displayTitle;
					cfg.image = nil;
					cfg.titleLineBreakMode = NSLineBreakByTruncatingTail;
					button.configuration = cfg;
				}
			}
		}
		else {
			command.state = UIMenuElementStateOff;
		}

		[children addObject:command];
	}

	// iOS 26 morphing menus draw native separators between *inline sections*, not
	// between flat actions. Wrap each leaf command in its own single-item inline
	// group so the system renders a divider between every option (no manual
	// drawing). Nested submenus are already grouped, so we keep them as-is.
	NSMutableArray<UIMenuElement *> *sectioned = [NSMutableArray arrayWithCapacity:children.count];
	for (UIMenuElement *element in children) {
		if ([element isKindOfClass:UICommand.class]) {
			[sectioned addObject:[UIMenu menuWithTitle:@""
												 image:nil
											identifier:nil
											   options:UIMenuOptionsDisplayInline
											  children:@[element]]];
		} else {
			[sectioned addObject:element];
		}
	}

	UIMenuOptions options = submenu.options;
	if (@available(iOS 15.0, *)) options |= UIMenuOptionsSingleSelection;
	return [UIMenu menuWithTitle:submenu.title image:nil identifier:nil options:options children:sectioned];
}

@end
