#import "SCIOptionSheet.h"
#import "../Utils.h"

static UIImage *SCIOptionSheetBundleTemplateImage(NSString *name) {
	if (![name isKindOfClass:NSString.class] || name.length == 0) return nil;
	NSBundle *bundle = SCILocalizationBundle();
	UIImage *img = bundle ? [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil] : nil;
	if (!img) img = [UIImage imageNamed:name];
	return img ? [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

static CGRect SCIOptionSheetAlphaBoundsForImage(UIImage *image) {
	CGImageRef cg = image.CGImage;
	if (!cg) return CGRectZero;
	size_t width = CGImageGetWidth(cg);
	size_t height = CGImageGetHeight(cg);
	if (width == 0 || height == 0 || width > 4096 || height > 4096) return CGRectZero;
	size_t bytesPerRow = width * 4;
	NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * height];
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, width, height, 8, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	if (colorSpace) CGColorSpaceRelease(colorSpace);
	if (!ctx) return CGRectZero;
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
	if (!found) return CGRectZero;
	return CGRectMake((CGFloat)minX, (CGFloat)minY, (CGFloat)(maxX - minX + 1), (CGFloat)(maxY - minY + 1));
}

static UIImage *SCIOptionSheetWordmarkPreviewImage(UIImage *image) {
	if (!image) return nil;
	CGRect box = SCIOptionSheetAlphaBoundsForImage(image);
	CGImageRef cg = image.CGImage;
	if (!cg || CGRectIsEmpty(box)) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGFloat pad = 1.0 * MAX(image.scale, 1.0);
	CGRect cropRect = CGRectInset(box, -pad, -pad);
	cropRect.origin.x = MAX(0.0, cropRect.origin.x);
	cropRect.origin.y = MAX(0.0, cropRect.origin.y);
	cropRect.size.width = MIN((CGFloat)CGImageGetWidth(cg) - cropRect.origin.x, cropRect.size.width);
	cropRect.size.height = MIN((CGFloat)CGImageGetHeight(cg) - cropRect.origin.y, cropRect.size.height);
	CGImageRef cropped = CGImageCreateWithImageInRect(cg, cropRect);
	UIImage *trimmed = cropped ? [UIImage imageWithCGImage:cropped scale:image.scale orientation:image.imageOrientation] : image;
	if (cropped) CGImageRelease(cropped);
	CGSize source = trimmed.size;
	if (source.width <= 0.0 || source.height <= 0.0) return [trimmed imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	// Match the visual size of the default wordmark instead of scaling every PNG
	// to its own max height. This keeps the alternate marks from overpowering the row.
	static const CGFloat kPreviewMaxWidth = 82.0;
	static const CGFloat kPreviewMaxHeight = 22.0;
	CGFloat scale = MIN(kPreviewMaxWidth / source.width, kPreviewMaxHeight / source.height);
	if (scale <= 0.0) scale = 1.0;
	CGSize target = CGSizeMake(ceil(source.width * scale), ceil(source.height * scale));
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	fmt.scale = UIScreen.mainScreen.scale;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
	UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
		[trimmed drawInRect:CGRectMake(0.0, 0.0, target.width, target.height)];
	}];
	return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface SCIOptionSheetVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIPopoverPresentationControllerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *options;
@property (nonatomic, copy, nullable) NSString *defaultsKey;
@property (nonatomic, copy) NSString *currentValue;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *);
@property (nonatomic, copy, nullable) void (^onPickCommand)(UICommand *command);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIVisualEffectView *effectView;
@property (nonatomic) BOOL wordmarkMode;
- (CGSize)preferredSheetSize;
@end

@implementation SCIOptionSheetVC

- (CGFloat)rowHeightForWordmark { return 44.0; }

- (CGFloat)estimatedHeightForOption:(NSDictionary *)opt {
	if (self.wordmarkMode) return [self rowHeightForWordmark];
	NSString *title = opt[@"title"] ?: opt[@"value"] ?: @"";
	NSString *desc = opt[@"description"] ?: @"";
	CGFloat width = 292.0;
	CGRect titleRect = [title boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
									 options:NSStringDrawingUsesLineFragmentOrigin
								attributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]}
									 context:nil];
	CGRect descRect = desc.length ? [desc boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
									 options:NSStringDrawingUsesLineFragmentOrigin
								attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]}
									 context:nil] : CGRectZero;
	CGFloat h = 18.0 + ceil(titleRect.size.height) + (desc.length ? 5.0 + ceil(descRect.size.height) : 0.0) + 18.0;
	return MAX(58.0, MIN(h, 124.0));
}

- (CGSize)preferredSheetSize {
	CGFloat width = self.wordmarkMode ? 260.0 : 328.0;
	CGFloat rows = 0.0;
	for (NSDictionary *opt in self.options) rows += [self estimatedHeightForOption:opt];
	if (rows <= 0.0) rows = 72.0;
	CGFloat inset = self.wordmarkMode ? 12.0 : 16.0;
	CGFloat maxHeight = MIN(UIScreen.mainScreen.bounds.size.height - 180.0, self.wordmarkMode ? 260.0 : 520.0);
	CGFloat height = MIN(MAX(self.wordmarkMode ? 160.0 : 128.0, rows + inset), maxHeight);
	return CGSizeMake(width, height);
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.clearColor;
	self.view.opaque = NO;
	SCIUIKit26ApplyContainerBackgroundToViewController(self);
	self.preferredContentSize = [self preferredSheetSize];

	self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
	self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
	self.tableView.separatorColor = SCIUIKit26SeparatorColor();
	self.tableView.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
	self.tableView.rowHeight = self.wordmarkMode ? [self rowHeightForWordmark] : UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = self.wordmarkMode ? [self rowHeightForWordmark] : 58.0;
	self.tableView.alwaysBounceVertical = NO;
	self.tableView.showsVerticalScrollIndicator = NO;
	if (@available(iOS 11.0, *)) self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	[self.view addSubview:self.tableView];

	[NSLayoutConstraint activateConstraints:@[
		[self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.options.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return self.wordmarkMode ? [self rowHeightForWordmark] : [self estimatedHeightForOption:self.options[(NSUInteger)indexPath.row]];
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
			SCIUIKit26ConfigureTableCell(cell);
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
			cell.preservesSuperviewLayoutMargins = NO;
			cell.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 6.0, 0.0, 6.0);

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
			check.tintColor = [UIColor systemBlueColor];
			[cell.contentView addSubview:check];

			[NSLayoutConstraint activateConstraints:@[
				[check.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
				[check.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
				[check.widthAnchor constraintEqualToConstant:13.0],
				[check.heightAnchor constraintEqualToConstant:13.0],
				[preview.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
				[preview.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-4.0],
				[preview.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
				[preview.widthAnchor constraintEqualToConstant:82.0],
				[preview.heightAnchor constraintEqualToConstant:22.0],
			]];
		}
		cell.contentConfiguration = nil;
		SCIUIKit26ConfigureTableCell(cell);
		UIImageView *preview = (UIImageView *)[cell.contentView viewWithTag:9001];
		preview.image = SCIOptionSheetWordmarkPreviewImage(image);
		preview.tintColor = UIColor.labelColor;
		UIImageView *check = (UIImageView *)[cell.contentView viewWithTag:9002];
		check.hidden = !selected;
		SCIUIKit26ApplyTableCellSelectionTint(cell, selected);
		return cell;
	}

	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"opt"];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"opt"];
	SCIUIKit26ConfigureTableCell(cell);
	cell.tintColor = [UIColor systemBlueColor];
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
	cfg.text = opt[@"title"] ?: opt[@"value"];
	cfg.textProperties.color = UIColor.labelColor;
	cfg.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	cfg.textProperties.numberOfLines = 1;
	NSString *desc = opt[@"description"];
	cfg.secondaryText = desc.length ? desc : nil;
	cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
	cfg.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	cfg.secondaryTextProperties.numberOfLines = 2;
	cfg.textToSecondaryTextVerticalPadding = 5.0;
	cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(9.0, 16.0, 9.0, 16.0);
	if (image) {
		cfg.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		cfg.imageProperties.tintColor = UIColor.labelColor;
		cfg.imageProperties.maximumSize = CGSizeMake(23.0, 23.0);
		cfg.imageToTextPadding = 14.0;
	}
	cell.contentConfiguration = cfg;
	cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	SCIUIKit26ApplyTableCellSelectionTint(cell, selected);
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
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
	return UIModalPresentationNone;
}

- (BOOL)popoverPresentationControllerShouldDismissPopover:(UIPopoverPresentationController *)popoverPresentationController {
	return YES;
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
		if (props[@"wordmarkImageName"]) opt[@"wordmarkImageName"] = props[@"wordmarkImageName"];
		opt[@"command"] = cmd;
		[out addObject:opt];
	}
	return out.copy;
}

+ (BOOL)optionsAreWordmark:(NSArray<NSDictionary *> *)options fallbackKey:(NSString *)fallbackKey {
	(void)options;
	(void)fallbackKey;
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
	[self presentSheetVC:vc from:presenter sourceView:nil];
}

+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title menu:(UIMenu *)menu onPick:(void (^)(UICommand *command))onPick {
	NSArray *options = [self optionsFromMenu:menu prefix:nil];
	if (!presenter || !options.count) return;
	SCIOptionSheetVC *vc = [SCIOptionSheetVC new];
	vc.options = options;
	vc.title = title;
	vc.wordmarkMode = [self optionsAreWordmark:options fallbackKey:nil];
	vc.onPickCommand = onPick;
	[self presentSheetVC:vc from:presenter sourceView:nil];
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
	vc.modalPresentationStyle = UIModalPresentationPopover;
	vc.preferredContentSize = [vc preferredSheetSize];
	UIPopoverPresentationController *popover = vc.popoverPresentationController;
	UIView *anchor = sourceView ?: presenter.view;
	popover.sourceView = anchor;
	popover.sourceRect = anchor ? anchor.bounds : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
	popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
	popover.delegate = vc;
	popover.backgroundColor = UIColor.clearColor;
	[presenter presentViewController:vc animated:YES completion:nil];
}

@end
