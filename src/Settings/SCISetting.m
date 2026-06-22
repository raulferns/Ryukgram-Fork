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


static NSString *SCIWordmarkImageNameForValue(NSString *value) {
	NSString *v = value.length ? value : @"off";
	if ([v isEqualToString:@"1a"]) return @"instagram-wordmark-1a";
	if ([v isEqualToString:@"1a_alt"]) return @"instagram-wordmark-1a-alt";
	if ([v isEqualToString:@"1b"]) return @"instagram-wordmark-1b";
	if ([v isEqualToString:@"1b_alt"]) return @"instagram-wordmark-1b-alt";
	return @"instagram-wordmark-default";
}

static UIImage *SCIWordmarkTemplateImageNamed(NSString *name) {
	if (!name.length) return nil;
	NSBundle *bundle = SCILocalizationBundle();
	UIImage *img = bundle ? [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil] : nil;
	if (!img) img = [UIImage imageNamed:name];
	return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *SCIWordmarkCanvasImage(UIImage *image) {
	if (!image) return nil;
	CGSize canvas = CGSizeMake(82.0, 22.0);
	CGSize source = image.size;
	if (source.width <= 0.0 || source.height <= 0.0) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGFloat scale = MIN(canvas.width / source.width, canvas.height / source.height);
	CGSize target = CGSizeMake(floor(source.width * scale), floor(source.height * scale));
	CGRect rect = CGRectMake((canvas.width - target.width) * 0.5, (canvas.height - target.height) * 0.5, target.width, target.height);
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	fmt.scale = UIScreen.mainScreen.scale;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
	UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
		[image drawInRect:rect];
	}];
	return [rendered imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
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
		if ([obj isKindOfClass:[UIMenu class]]) {
			[children addObject:[self submenuForButton:button submenu:(UIMenu *)obj]];
			continue;
		}
		if (![obj isKindOfClass:[UICommand class]]) continue;

		UICommand *child = obj;
		NSDictionary *props = [child.propertyList isKindOfClass:NSDictionary.class] ? child.propertyList : nil;
		NSString *key = [props[@"defaultsKey"] isKindOfClass:NSString.class] ? props[@"defaultsKey"] : nil;
		NSString *saved = key.length ? [[NSUserDefaults standardUserDefaults] stringForKey:key] : nil;
		NSString *value = [props[@"value"] isKindOfClass:NSString.class] ? props[@"value"] : nil;
		BOOL isWordmark = SCIIsWordmarkMenuCommand(props);

		UIImage *image = child.image;
		NSString *menuTitle = child.title ?: @"";
		if (isWordmark) {
			NSString *imageName = [props[@"wordmarkImageName"] isKindOfClass:NSString.class] ? props[@"wordmarkImageName"] : SCIWordmarkImageNameForValue(value);
			image = SCIWordmarkCanvasImage(SCIWordmarkTemplateImageNamed(imageName));
			menuTitle = @"";
		}

		UICommand *command = [UICommand commandWithTitle:menuTitle
									   image:image
								  action:child.action
							propertyList:child.propertyList];
		if ([command respondsToSelector:@selector(setDiscoverabilityTitle:)]) {
			command.discoverabilityTitle = isWordmark ? SCIWordmarkDisplayTitleForValue(value, child.title) : child.discoverabilityTitle;
		}

		if (value.length && [value isEqualToString:saved]) {
			if (isWordmark) {
				UIImage *selectedImage = image ?: SCIWordmarkCanvasImage(SCIWordmarkTemplateImageNamed(SCIWordmarkImageNameForValue(value)));
				[button setTitle:nil forState:UIControlStateNormal];
				[button setImage:selectedImage forState:UIControlStateNormal];
				button.accessibilityLabel = SCIWordmarkDisplayTitleForValue(value, child.title);
				if (button.configuration) {
					UIButtonConfiguration *cfg = button.configuration;
					cfg.title = nil;
					cfg.image = selectedImage;
					cfg.imagePlacement = NSDirectionalRectEdgeLeading;
					button.configuration = cfg;
				}
			} else if (![props[@"noTitle"] boolValue]) {
				NSString *displayTitle = child.title ?: @"";
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
		[children addObject:command];
	}

	UIMenuOptions options = submenu.options;
	return [UIMenu menuWithTitle:submenu.title ?: @"" image:submenu.image identifier:submenu.identifier options:options children:children];
}

@end
