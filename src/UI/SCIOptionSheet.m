#import "SCIOptionSheet.h"
#import "../Utils.h"

static UIImage *SCIOptionSheetBundleTemplateImage(NSString *name) {
	if (![name isKindOfClass:NSString.class] || name.length == 0) return nil;
	NSBundle *bundle = SCILocalizationBundle();
	UIImage *img = bundle ? [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil] : nil;
	return img ? [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

static UIImage *SCIOptionSheetTrimTransparentTemplateImage(UIImage *image) {
	if (!image) return nil;
	CGImageRef cg = image.CGImage;
	if (!cg) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	size_t width = CGImageGetWidth(cg);
	size_t height = CGImageGetHeight(cg);
	if (width == 0 || height == 0 || width > 4096 || height > 4096) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	size_t bytesPerRow = width * 4;
	NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * height];
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, width, height, 8, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	if (colorSpace) CGColorSpaceRelease(colorSpace);
	if (!ctx) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg);
	CGContextRelease(ctx);
	const UInt8 *bytes = (const UInt8 *)data.bytes;
	size_t minX = width, minY = height, maxX = 0, maxY = 0;
	BOOL found = NO;
	for (size_t y = 0; y < height; y++) {
		const UInt8 *row = bytes + y * bytesPerRow;
		for (size_t x = 0; x < width; x++) {
			UInt8 alpha = row[x * 4 + 3];
			if (alpha <= 8) continue;
			found = YES;
			if (x < minX) minX = x;
			if (y < minY) minY = y;
			if (x > maxX) maxX = x;
			if (y > maxY) maxY = y;
		}
	}
	if (!found) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGFloat pad = 2.0 * MAX(image.scale, 1.0);
	CGFloat originX = MAX(0.0, (CGFloat)minX - pad);
	CGFloat originY = MAX(0.0, (CGFloat)minY - pad);
	CGFloat endX = MIN((CGFloat)width, (CGFloat)maxX + 1.0 + pad);
	CGFloat endY = MIN((CGFloat)height, (CGFloat)maxY + 1.0 + pad);
	CGRect cropRect = CGRectMake(originX, originY, MAX(1.0, endX - originX), MAX(1.0, endY - originY));
	if (CGRectEqualToRect(cropRect, CGRectMake(0, 0, width, height))) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGImageRef cropped = CGImageCreateWithImageInRect(cg, cropRect);
	if (!cropped) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	UIImage *trimmed = [UIImage imageWithCGImage:cropped scale:image.scale orientation:image.imageOrientation];
	CGImageRelease(cropped);
	return [trimmed imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}



static UIImage *SCIOptionSheetWordmarkPreviewImage(UIImage *image) {
	UIImage *trimmed = SCIOptionSheetTrimTransparentTemplateImage(image);
	if (!trimmed) return nil;
	CGSize source = trimmed.size;
	if (source.width <= 0.0 || source.height <= 0.0) return trimmed;
	static const CGFloat kPreviewWidth = 94.0;
	static const CGFloat kPreviewMaxHeight = 23.0;
	CGFloat scale = kPreviewWidth / source.width;
	CGSize target = CGSizeMake(kPreviewWidth, ceil(source.height * scale));
	if (target.height > kPreviewMaxHeight) {
		scale = kPreviewMaxHeight / source.height;
		target = CGSizeMake(ceil(source.width * scale), kPreviewMaxHeight);
	}
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	fmt.scale = UIScreen.mainScreen.scale;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
	UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
		[trimmed drawInRect:CGRectMake(0.0, 0.0, target.width, target.height)];
	}];
	return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIView *SCIOptionSheetSelectedGlassBackgroundView(CGFloat radius) {
	SCIUIKit26GlassPanelView *bg = [[SCIUIKit26GlassPanelView alloc] initWithRadius:radius];
	bg.sciGlassClearStyle = YES;
	bg.sciGlassInteractive = YES;
	bg.sciGlassTintColor = [UIColor.labelColor colorWithAlphaComponent:0.10];
	[bg applyLiquidGlassStyle];
	bg.contentView.backgroundColor = UIColor.clearColor;
	bg.backgroundColor = UIColor.clearColor;
	return bg;
}

static CGFloat SCIClamp(CGFloat value, CGFloat minValue, CGFloat maxValue) {
	return MAX(minValue, MIN(value, maxValue));
}

@interface SCIOptionSheetVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *options;
@property (nonatomic, copy, nullable) NSString *defaultsKey;
@property (nonatomic, copy) NSString *currentValue;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *);
@property (nonatomic, copy, nullable) void (^onPickCommand)(UICommand *command);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) SCIUIKit26GlassPanelView *panelView;
@property (nonatomic, weak, nullable) UIView *sourceView;
@property (nonatomic) CGPoint sourceCenter;
@property (nonatomic) BOOL hasSourceCenter;
@property (nonatomic) BOOL wordmarkMode;
@end


@implementation SCIOptionSheetVC

- (CGFloat)rowHeight {
	return self.wordmarkMode ? 34.0 : UITableViewAutomaticDimension;
}

- (CGFloat)estimatedHeightForOption:(NSDictionary *)opt {
	if (self.wordmarkMode) return 34.0;
	NSString *title = opt[@"title"] ?: opt[@"value"] ?: @"";
	NSString *desc = opt[@"description"] ?: @"";
	CGFloat width = 328.0 - 16.0 - 16.0;
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
	CGFloat width = self.wordmarkMode ? 142.0 : 328.0;
	CGFloat rows = 0.0;
	for (NSDictionary *opt in self.options) rows += [self estimatedHeightForOption:opt];
	if (rows <= 0.0) rows = 72.0;
	CGFloat maxHeight = MIN(UIScreen.mainScreen.bounds.size.height - 240.0, self.wordmarkMode ? 178.0 : 640.0);
	CGFloat height = MIN(MAX(self.wordmarkMode ? 58.0 : 128.0, rows + 10.0), MAX(self.wordmarkMode ? 112.0 : 280.0, maxHeight));
	return CGSizeMake(width, height);
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);
	self.view.backgroundColor = UIColor.clearColor;

	self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
	self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	self.tableView.backgroundColor = UIColor.clearColor;
	self.tableView.opaque = NO;
	self.tableView.separatorColor = SCIUIKit26SeparatorColor();
	self.tableView.separatorInset = UIEdgeInsetsMake(0.0, self.wordmarkMode ? 14.0 : 18.0, 0.0, self.wordmarkMode ? 14.0 : 18.0);
	self.tableView.rowHeight = [self rowHeight];
	self.tableView.estimatedRowHeight = self.wordmarkMode ? 34.0 : 82.0;
	self.tableView.alwaysBounceVertical = !self.wordmarkMode;
	self.tableView.showsVerticalScrollIndicator = !self.wordmarkMode && self.options.count > 4;
	self.tableView.backgroundColor = UIColor.clearColor;
	self.tableView.opaque = NO;
	if (self.wordmarkMode) {
		self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
		self.tableView.separatorColor = SCIUIKit26SeparatorColor();
	}

	UIControl *dismissLayer = [UIControl new];
	dismissLayer.translatesAutoresizingMaskIntoConstraints = NO;
	dismissLayer.backgroundColor = UIColor.clearColor;
	[dismissLayer addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:dismissLayer];

	self.panelView = [[SCIUIKit26GlassPanelView alloc] initWithRadius:24.0];
	self.panelView.translatesAutoresizingMaskIntoConstraints = NO;
	self.panelView.sciGlassClearStyle = YES;
	self.panelView.sciGlassInteractive = YES;
	[self.panelView applyLiquidGlassStyle];
	[self.view addSubview:self.panelView];
	[self.panelView.contentView addSubview:self.tableView];

	CGSize size = [self panelSize];
	[NSLayoutConstraint activateConstraints:@[
		[dismissLayer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[dismissLayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[dismissLayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[dismissLayer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[self.panelView.centerXAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:[self panelCenterXForSize:size]],
		[self.panelView.centerYAnchor constraintEqualToAnchor:self.view.topAnchor constant:[self panelCenterYForSize:size]],
		[self.panelView.widthAnchor constraintEqualToConstant:size.width],
		[self.panelView.heightAnchor constraintEqualToConstant:size.height],

		[self.tableView.topAnchor constraintEqualToAnchor:self.panelView.contentView.topAnchor constant:(self.wordmarkMode ? 4.0 : 8.0)],
		[self.tableView.leadingAnchor constraintEqualToAnchor:self.panelView.contentView.leadingAnchor constant:(self.wordmarkMode ? 4.0 : 8.0)],
		[self.tableView.trailingAnchor constraintEqualToAnchor:self.panelView.contentView.trailingAnchor constant:-(self.wordmarkMode ? 4.0 : 8.0)],
		[self.tableView.bottomAnchor constraintEqualToAnchor:self.panelView.contentView.bottomAnchor constant:-(self.wordmarkMode ? 4.0 : 8.0)],
	]];
}


- (CGPoint)sourceCenterInView {
	if (self.hasSourceCenter) return self.sourceCenter;
	return CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

- (CGFloat)panelCenterXForSize:(CGSize)size {
	CGFloat safeLeft = self.view.safeAreaInsets.left + 18.0 + size.width * 0.5;
	CGFloat safeRight = CGRectGetWidth(self.view.bounds) - self.view.safeAreaInsets.right - 18.0 - size.width * 0.5;
	return SCIClamp([self sourceCenterInView].x, safeLeft, MAX(safeLeft, safeRight));
}

- (CGFloat)panelCenterYForSize:(CGSize)size {
	CGFloat safeTop = self.view.safeAreaInsets.top + 18.0 + size.height * 0.5;
	CGFloat safeBottom = CGRectGetHeight(self.view.bounds) - self.view.safeAreaInsets.bottom - 18.0 - size.height * 0.5;
	CGFloat y = [self sourceCenterInView].y;
	if (self.wordmarkMode) y += 2.0;
	return SCIClamp(y, safeTop, MAX(safeTop, safeBottom));
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
	[super traitCollectionDidChange:previousTraitCollection];
	if (self.wordmarkMode) [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.options.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return self.wordmarkMode ? 36.0 : [self estimatedHeightForOption:self.options[(NSUInteger)indexPath.row]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	NSDictionary *opt = self.options[(NSUInteger)indexPath.row];
	NSString *value = opt[@"value"] ?: @"";
	NSString *key = opt[@"defaultsKey"] ?: self.defaultsKey;
	NSString *current = key.length ? ([[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"") : self.currentValue;
	if (self.wordmarkMode && current.length == 0) current = @"off";
	BOOL selected = [value isEqualToString:current];
	UIImage *image = [opt[@"image"] isKindOfClass:UIImage.class] ? opt[@"image"] : nil;
	NSString *wordmarkImageName = [opt[@"wordmarkImageName"] isKindOfClass:NSString.class] ? opt[@"wordmarkImageName"] : nil;
	if (self.wordmarkMode && wordmarkImageName.length) image = SCIOptionSheetBundleTemplateImage(wordmarkImageName);

	if (self.wordmarkMode && image) {
		UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"wordmarkOpt"];
		if (!cell) {
			cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"wordmarkOpt"];
			cell.backgroundColor = UIColor.clearColor;
			cell.contentView.backgroundColor = UIColor.clearColor;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			cell.preservesSuperviewLayoutMargins = YES;
			cell.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 8.0, 0.0, 8.0);
			if (@available(iOS 14.0, *)) {
				cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
			}

			UIImageView *preview = [[UIImageView alloc] initWithFrame:CGRectZero];
			preview.tag = 9001;
			preview.translatesAutoresizingMaskIntoConstraints = NO;
			preview.contentMode = UIViewContentModeScaleAspectFit;
			preview.backgroundColor = UIColor.clearColor;
			preview.opaque = NO;
			preview.tintColor = UIColor.labelColor;
			[cell.contentView addSubview:preview];

			UIImageView *check = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
			check.tag = 9002;
			check.translatesAutoresizingMaskIntoConstraints = NO;
			check.contentMode = UIViewContentModeScaleAspectFit;
			check.tintColor = UIColor.labelColor;
			[cell.contentView addSubview:check];

			[NSLayoutConstraint activateConstraints:@[
				[check.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor constant:-1.0],
				[check.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
				[check.widthAnchor constraintEqualToConstant:14.0],
				[check.heightAnchor constraintEqualToConstant:14.0],

				[preview.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor constant:-7.0],
				[preview.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
				[preview.widthAnchor constraintEqualToConstant:96.0],
				[preview.heightAnchor constraintEqualToConstant:24.0],
			]];
		}

		cell.contentConfiguration = nil;
		cell.backgroundColor = UIColor.clearColor;
		cell.contentView.backgroundColor = UIColor.clearColor;
		cell.tintColor = UIColor.labelColor;
		cell.accessoryType = UITableViewCellAccessoryNone;
		if (@available(iOS 14.0, *)) {
			cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
		}
		cell.backgroundView = nil;
		cell.selectedBackgroundView = SCIOptionSheetSelectedGlassBackgroundView(10.0);
		UIImageView *preview = (UIImageView *)[cell.contentView viewWithTag:9001];
		preview.image = SCIOptionSheetWordmarkPreviewImage(image);
		preview.tintColor = UIColor.labelColor;
		UIImageView *check = (UIImageView *)[cell.contentView viewWithTag:9002];
		check.hidden = !selected;
		check.tintColor = UIColor.labelColor;
		return cell;
	}

	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"opt"];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"opt"];
	if (@available(iOS 14.0, *)) cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
	cell.backgroundView = nil;
	cell.selectedBackgroundView = SCIOptionSheetSelectedGlassBackgroundView(14.0);

	cell.backgroundColor = UIColor.clearColor;
	cell.contentView.backgroundColor = UIColor.clearColor;
	cell.tintColor = [UIColor systemBlueColor];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
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


@interface SCIOptionSheet ()
+ (void)presentSheetVC:(SCIOptionSheetVC *)vc from:(UIViewController *)presenter;
+ (void)presentSheetVC:(SCIOptionSheetVC *)vc from:(UIViewController *)presenter sourceView:(UIView * _Nullable)sourceView;
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
		if (props[@"wordmarkImageName"]) opt[@"wordmarkImageName"] = props[@"wordmarkImageName"];
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
	vc.title = title;
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
	vc.title = title;
	vc.wordmarkMode = [self optionsAreWordmark:options fallbackKey:nil];
	vc.onPickCommand = onPick;
	[self presentSheetVC:vc from:presenter];
}


+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title menu:(UIMenu *)menu sourceView:(UIView *)sourceView onPick:(void (^)(UICommand *command))onPick {
	NSArray *options = [self optionsFromMenu:menu prefix:nil];
	if (!presenter || !options.count) return;
	SCIOptionSheetVC *vc = [SCIOptionSheetVC new];
	vc.options = options;
	vc.title = title;
	vc.wordmarkMode = [self optionsAreWordmark:options fallbackKey:nil];
	vc.onPickCommand = onPick;
	[self presentSheetVC:vc from:presenter sourceView:sourceView];
}

+ (void)presentSheetVC:(SCIOptionSheetVC *)vc from:(UIViewController *)presenter sourceView:(UIView *)sourceView {
	vc.sourceView = sourceView;
	if (sourceView && sourceView.superview && presenter.view) {
		CGRect r = [sourceView.superview convertRect:sourceView.frame toView:presenter.view];
		vc.sourceCenter = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
		vc.hasSourceCenter = YES;
	}
	vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
	[presenter presentViewController:vc animated:NO completion:nil];
}

+ (void)presentSheetVC:(SCIOptionSheetVC *)vc from:(UIViewController *)presenter {
	[self presentSheetVC:vc from:presenter sourceView:nil];
}

@end
