#import "SCIOptionSheet.h"
#import "../Utils.h"

@interface SCIOptionSheetVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *options;
@property (nonatomic, copy, nullable) NSString *defaultsKey;
@property (nonatomic, copy) NSString *currentValue;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *);
@property (nonatomic, copy, nullable) void (^onPickCommand)(UICommand *command);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SCIUIKit26GlassPanelView *panelView;
@property (nonatomic) BOOL wordmarkMode;
@end

@implementation SCIOptionSheetVC

- (CGFloat)rowHeight {
	return self.wordmarkMode ? 68.0 : UITableViewAutomaticDimension;
}

- (CGFloat)estimatedHeightForOption:(NSDictionary *)opt {
	if (self.wordmarkMode) return 68.0;
	NSString *title = opt[@"title"] ?: opt[@"value"] ?: @"";
	NSString *desc = opt[@"description"] ?: @"";
	CGFloat width = 348.0 - 16.0 - 16.0;
	if (desc.length) width -= 42.0; // checkmark/accessory reserve
	CGRect titleRect = [title boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
									 options:NSStringDrawingUsesLineFragmentOrigin
								attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:19.0 weight:UIFontWeightRegular]}
									 context:nil];
	CGRect descRect = desc.length ? [desc boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
									 options:NSStringDrawingUsesLineFragmentOrigin
								attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]}
									 context:nil] : CGRectZero;
	CGFloat h = 18.0 + ceil(titleRect.size.height) + (desc.length ? 5.0 + ceil(descRect.size.height) : 0.0) + 18.0;
	return MAX(58.0, MIN(h, 124.0));
}

- (CGSize)panelSize {
	CGFloat width = self.wordmarkMode ? 330.0 : 348.0;
	CGFloat rows = 0.0;
	for (NSDictionary *opt in self.options) rows += [self estimatedHeightForOption:opt];
	if (rows <= 0.0) rows = 72.0;
	CGFloat maxHeight = MIN(UIScreen.mainScreen.bounds.size.height - 160.0, 560.0);
	CGFloat height = MIN(MAX(96.0, rows + 16.0), MAX(220.0, maxHeight));
	return CGSizeMake(width, height);
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);
	self.view.backgroundColor = UIColor.clearColor;

	UIControl *dismissLayer = [UIControl new];
	dismissLayer.translatesAutoresizingMaskIntoConstraints = NO;
	dismissLayer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.10];
	[dismissLayer addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:dismissLayer];

	self.panelView = [[SCIUIKit26GlassPanelView alloc] initWithRadius:24.0];
	self.panelView.translatesAutoresizingMaskIntoConstraints = NO;
	self.panelView.sciGlassClearStyle = YES;
	self.panelView.sciGlassInteractive = YES;
	[self.panelView applyLiquidGlassStyle];
	[self.view addSubview:self.panelView];

	self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	self.tableView.backgroundColor = UIColor.clearColor;
	self.tableView.opaque = NO;
	self.tableView.separatorColor = SCIUIKit26SeparatorColor();
	self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 18.0, 0.0, 18.0);
	self.tableView.rowHeight = [self rowHeight];
	self.tableView.estimatedRowHeight = self.wordmarkMode ? 68.0 : 82.0;
	self.tableView.alwaysBounceVertical = !self.wordmarkMode;
	self.tableView.showsVerticalScrollIndicator = !self.wordmarkMode && self.options.count > 4;
	[self.panelView.contentView addSubview:self.tableView];

	CGSize size = [self panelSize];
	[NSLayoutConstraint activateConstraints:@[
		[dismissLayer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[dismissLayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[dismissLayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[dismissLayer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[self.panelView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[self.panelView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
		[self.panelView.widthAnchor constraintEqualToConstant:size.width],
		[self.panelView.heightAnchor constraintEqualToConstant:size.height],

		[self.tableView.topAnchor constraintEqualToAnchor:self.panelView.contentView.topAnchor constant:8.0],
		[self.tableView.leadingAnchor constraintEqualToAnchor:self.panelView.contentView.leadingAnchor constant:8.0],
		[self.tableView.trailingAnchor constraintEqualToAnchor:self.panelView.contentView.trailingAnchor constant:-8.0],
		[self.tableView.bottomAnchor constraintEqualToAnchor:self.panelView.contentView.bottomAnchor constant:-8.0],
	]];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.options.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return self.wordmarkMode ? 68.0 : [self estimatedHeightForOption:self.options[(NSUInteger)indexPath.row]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"opt"];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"opt"];
	SCIUIKit26ConfigureTableCell(cell);

	NSDictionary *opt = self.options[(NSUInteger)indexPath.row];
	cell.backgroundColor = UIColor.clearColor;
	cell.contentView.backgroundColor = UIColor.clearColor;
	cell.tintColor = [UIColor systemBlueColor];
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	NSString *value = opt[@"value"] ?: @"";
	NSString *key = opt[@"defaultsKey"] ?: self.defaultsKey;
	NSString *current = key.length ? ([[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"") : self.currentValue;
	BOOL selected = [value isEqualToString:current];
	UIImage *image = [opt[@"image"] isKindOfClass:UIImage.class] ? opt[@"image"] : nil;

	UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
	if (self.wordmarkMode && image) {
		cfg.text = @"";
		cfg.secondaryText = nil;
		cfg.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		cfg.imageProperties.tintColor = UIColor.labelColor;
		cfg.imageProperties.maximumSize = CGSizeMake(210.0, 46.0);
		cfg.imageToTextPadding = 0.0;
	} else {
		cfg.text = opt[@"title"] ?: opt[@"value"];
		cfg.textProperties.color = UIColor.labelColor;
		cfg.textProperties.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightRegular];
		cfg.textProperties.numberOfLines = 0;
		NSString *desc = opt[@"description"];
		cfg.secondaryText = desc.length ? desc : nil;
		cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
		cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
		cfg.secondaryTextProperties.numberOfLines = 0;
		cfg.textToSecondaryTextVerticalPadding = 5.0;
		cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);
		if (image) {
			cfg.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
			cfg.imageProperties.tintColor = UIColor.labelColor;
			cfg.imageProperties.maximumSize = CGSizeMake(32.0, 32.0);
			cfg.imageToTextPadding = 14.0;
		}
	}
	cell.contentConfiguration = cfg;
	cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSDictionary *opt = self.options[(NSUInteger)indexPath.row];
	UICommand *command = opt[@"command"];
	if (command && self.onPickCommand) {
		self.onPickCommand(command);
	} else {
		NSString *value = opt[@"value"] ?: @"";
		NSString *key = opt[@"defaultsKey"] ?: self.defaultsKey;
		self.currentValue = value;
		if (key.length) [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];
		if (self.onChange) self.onChange(value);
	}
	UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	[fb impactOccurred];
	[self dismissSelf];
}

@end

@implementation SCIOptionSheet

+ (NSArray<NSDictionary *> *)optionsFromMenu:(UIMenu *)menu prefix:(NSString *)prefix {
	NSMutableArray *out = [NSMutableArray array];
	for (UIMenuElement *el in menu.children) {
		if ([el isKindOfClass:UIMenu.class]) {
			UIMenu *sub = (UIMenu *)el;
			NSString *p = sub.title.length ? (prefix.length ? [NSString stringWithFormat:@"%@ — %@", prefix, sub.title] : sub.title) : prefix;
			[out addObjectsFromArray:[self optionsFromMenu:sub prefix:p]];
			continue;
		}
		if (![el isKindOfClass:UICommand.class]) continue;
		UICommand *cmd = (UICommand *)el;
		NSDictionary *props = [cmd.propertyList isKindOfClass:NSDictionary.class] ? cmd.propertyList : nil;
		NSString *value = props[@"value"] ?: cmd.title ?: @"";
		NSMutableDictionary *opt = [NSMutableDictionary dictionary];
		opt[@"title"] = prefix.length ? [NSString stringWithFormat:@"%@ — %@", prefix, cmd.title ?: @""] : (cmd.title ?: @"");
		opt[@"value"] = value;
		if (props[@"defaultsKey"]) opt[@"defaultsKey"] = props[@"defaultsKey"];
		if (cmd.image) opt[@"image"] = cmd.image;
		opt[@"command"] = cmd;
		[out addObject:opt];
	}
	return out.copy;
}

+ (BOOL)optionsAreWordmark:(NSArray<NSDictionary *> *)options fallbackKey:(NSString *)fallbackKey {
	if ([fallbackKey isEqualToString:@"sci_ig_wordmark_variant"]) return YES;
	for (NSDictionary *opt in options) {
		NSString *key = opt[@"defaultsKey"] ?: fallbackKey;
		if ([key isEqualToString:@"sci_ig_wordmark_variant"]) return YES;
	}
	return NO;
}

+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title defaultsKey:(NSString *)defaultsKey options:(NSArray<NSDictionary<NSString *,NSString *> *> *)options onChange:(void (^)(NSString *))onChange {
	if (!presenter || !options.count) return;
	SCIOptionSheetVC *vc = [SCIOptionSheetVC new];
	vc.options = options;
	vc.defaultsKey = defaultsKey;
	vc.currentValue = defaultsKey.length ? ([[NSUserDefaults standardUserDefaults] stringForKey:defaultsKey] ?: @"") : @"";
	vc.wordmarkMode = [self optionsAreWordmark:options fallbackKey:defaultsKey];
	vc.onChange = onChange;
	[self presentSheetVC:vc from:presenter];
}

+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title menu:(UIMenu *)menu onPick:(void (^)(UICommand *command))onPick {
	NSArray *options = [self optionsFromMenu:menu prefix:nil];
	if (!presenter || !options.count) return;
	SCIOptionSheetVC *vc = [SCIOptionSheetVC new];
	vc.options = options;
	vc.wordmarkMode = [self optionsAreWordmark:options fallbackKey:nil];
	vc.onPickCommand = onPick;
	[self presentSheetVC:vc from:presenter];
}

+ (void)presentSheetVC:(SCIOptionSheetVC *)vc from:(UIViewController *)presenter {
	vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
	vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
	[presenter presentViewController:vc animated:YES completion:nil];
}

@end
