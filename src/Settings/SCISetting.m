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

// MARK: - + dynamicCellWithTitle

+ (instancetype)dynamicCellWithTitle:(NSString *)title
							subtitle:(NSString *)subtitle
								icon:(nullable SCISymbol *)icon
							dynamicTitle:(NSString *(^)(void))dynamicTitle
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellDynamic];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.dynamicTitle = dynamicTitle;

	return setting;
}

// MARK: - + toggleCellWithTitle

+ (instancetype)toggleCellWithTitle:(NSString *)title
						  subtitle:(NSString *)subtitle
							  icon:(nullable SCISymbol *)icon
						   defaultsKey:(NSString *)defaultsKey
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellToggle];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;

	return setting;
}

// MARK: - + textCellWithTitle

+ (instancetype)textCellWithTitle:(NSString *)title
						subtitle:(NSString *)subtitle
							icon:(nullable SCISymbol *)icon
						defaultsKey:(NSString *)defaultsKey
						placeholder:(NSString *)placeholder
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellText];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;
	setting.placeholder = placeholder;

	return setting;
}

// MARK: - + linkCellWithTitle

+ (instancetype)linkCellWithTitle:(NSString *)title
						subtitle:(NSString *)subtitle
							icon:(nullable SCISymbol *)icon
								URL:(NSURL *)URL
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellLink];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.URL = URL;

	return setting;
}

// MARK: - + actionCellWithTitle

+ (instancetype)actionCellWithTitle:(NSString *)title
						  subtitle:(NSString *)subtitle
							  icon:(nullable SCISymbol *)icon
							action:(void (^)(void))action
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellAction];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.action = action;

	return setting;
}

// MARK: - + commandCellWithTitle

+ (instancetype)commandCellWithTitle:(NSString *)title
						   subtitle:(NSString *)subtitle
							   icon:(nullable SCISymbol *)icon
							  command:(SCICommand *)command
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellCommand];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.command = command;

	return setting;
}

// MARK: - + menuCellWithTitle

+ (instancetype)menuCellWithTitle:(NSString *)title
						subtitle:(NSString *)subtitle
							icon:(nullable SCISymbol *)icon
						defaultsKey:(NSString *)defaultsKey
						menuProvider:(SCISettingMenuProvider)menuProvider
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellMenu];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;
	setting.menuProvider = menuProvider;

	return setting;
}

// MARK: - + menuCellWithTitle (static)

+ (instancetype)menuCellWithTitle:(NSString *)title
						subtitle:(NSString *)subtitle
							icon:(nullable SCISymbol *)icon
						defaultsKey:(NSString *)defaultsKey
						menuItems:(NSArray<NSDictionary *> *)menuItems
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellMenu];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;
	setting.menuItems = menuItems;

	return setting;
}

// MARK: - + sliderCellWithTitle

+ (instancetype)sliderCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
							 icon:(nullable SCISymbol *)icon
						  defaultsKey:(NSString *)defaultsKey
							  minValue:(CGFloat)minValue
							  maxValue:(CGFloat)maxValue
							 stepValue:(CGFloat)stepValue
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellSlider];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;
	setting.minValue = minValue;
	setting.maxValue = maxValue;
	setting.stepValue = stepValue;

	return setting;
}

// MARK: - + colorCellWithTitle

+ (instancetype)colorCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
							 icon:(nullable SCISymbol *)icon
						  defaultsKey:(NSString *)defaultsKey
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellColor];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;

	return setting;
}

// MARK: - + multiValueCellWithTitle

+ (instancetype)multiValueCellWithTitle:(NSString *)title
							 subtitle:(NSString *)subtitle
								 icon:(nullable SCISymbol *)icon
							  defaultsKey:(NSString *)defaultsKey
								values:(NSArray<NSDictionary *> *)values
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellMultiValue];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.defaultsKey = defaultsKey;
	setting.values = values;

	return setting;
}

// MARK: - + customCellWithTitle

+ (instancetype)customCellWithTitle:(NSString *)title
						 subtitle:(NSString *)subtitle
							 icon:(nullable SCISymbol *)icon
						customClass:(Class)customClass
{
	SCISetting *setting = [[self alloc] initWithType:SCITableCellCustom];

	setting.title = title;
	setting.subtitle = subtitle;
	setting.icon = icon;
	setting.customClass = customClass;

	return setting;
}

// MARK: - - menu

- (UIMenu *)menu {
	if (self.menuProvider) {
		return self.menuProvider();
	}

	if (self.menuItems) {
		NSMutableArray<UIMenuElement *> *elements = [NSMutableArray array];

		for (NSDictionary *props in self.menuItems) {
			NSString *title = props[@"title"];
			NSString *subtitle = props[@"subtitle"];
			NSString *imageName = props[@"imageName"];
			NSString *defaultsKey = props[@"defaultsKey"];
			id value = props[@"value"];
			BOOL isWordmarkCommand = SCIIsWordmarkMenuCommand(props);

			UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:imageName] identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
				if (defaultsKey) {
					[SCIUtils setPref:value forKey:defaultsKey];
				}

				if (isWordmarkCommand) {
					NSString *displayTitle = SCIWordmarkDisplayTitleForValue(value, title);
					[[NSNotificationCenter defaultCenter] postNotificationName:@"SCIWordmarkVariantDidChangeNotification"
																object:nil
															  userInfo:@{ @"title": displayTitle }];
				}

				if (props[@"handler"]) {
					void (^handler)(void) = props[@"handler"];
					handler();
				}
			}];

			if ([value isEqual:[SCIUtils getPref:defaultsKey]]) {
				action.state = UIMenuElementStateOn;
			}

			[elements addObject:action];
		}

		return [UIMenu menuWithChildren:elements];
	}

	return nil;
}

// MARK: - - uncachedMenu

- (UIMenu *)uncachedMenu {
	if (self.menuProvider) {
		UIDeferredMenuElement *deferred = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> * _Nonnull)) {
			UIMenu *menu = self.menuProvider();
			completion(menu.children);
		}];

		return [UIMenu menuWithChildren:@[deferred]];
	}

	return nil;
}

@end
