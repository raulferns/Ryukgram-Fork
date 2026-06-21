#import "SCIChatBgPerImageSheet.h"
#import "SCIChatBackgroundManager.h"
#import "../../UI/SCIPopupChrome.h"
#import "../../UI/SCIColorPickerSheet.h"
#import "../../Utils.h"

typedef NS_ENUM(NSInteger, SCIRow) {
	SCIRowOpacity,
	SCIRowBlur,
	SCIRowDim,
	SCIRowAutoBubble,
	SCIRowBubbleSides,
	SCIRowGradient,
	SCIRowGradientDir,
	SCIRowBubbleColor,
	SCIRowTextColor,
	SCIRowReset,
};

static NSString *const kCell = @"cell";

@interface SCIChatBgPerImageSheet () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *asset;
@property (nonatomic, strong) UIImageView *preview;
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSNumber *> *rows;
@end

@implementation SCIChatBgPerImageSheet

- (instancetype)initWithAsset:(NSString *)asset {
	if ((self = [super init])) {
		_asset = [asset copy];
		self.title = SCILocalized(@"Image Settings");
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);
	SCIUIKit26ConfigureTableView(self.tableView);

	self.view.backgroundColor = SCIUIKit26BaseSurfaceColor();
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:SCILocalized(@"Done") style:UIBarButtonItemStyleDone target:self action:@selector(done)];

	_preview = [UIImageView new];
	_preview.contentMode = UIViewContentModeScaleAspectFill;
	_preview.clipsToBounds = YES;
	_preview.layer.cornerRadius = 16;
	_preview.layer.cornerCurve = kCACornerCurveContinuous;
	_preview.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_preview];

	_dimView = [UIView new];
	_dimView.backgroundColor = UIColor.blackColor;
	_dimView.userInteractionEnabled = NO;
	_dimView.translatesAutoresizingMaskIntoConstraints = NO;
	[_preview addSubview:_dimView];

	_tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
	_tableView.dataSource = self;
	SCIUIKit26ConfigureTableView(_tableView);
	_tableView.delegate = self;
	_tableView.contentInset = UIEdgeInsetsZero;
	_tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
	_tableView.translatesAutoresizingMaskIntoConstraints = NO;
	[_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kCell];
	[self.view addSubview:_tableView];

	[NSLayoutConstraint activateConstraints:@[
		[_preview.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
		[_preview.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[_preview.widthAnchor constraintEqualToConstant:210],
		[_preview.heightAnchor constraintEqualToConstant:294],

		[_dimView.topAnchor constraintEqualToAnchor:_preview.topAnchor],
		[_dimView.leadingAnchor constraintEqualToAnchor:_preview.leadingAnchor],
		[_dimView.trailingAnchor constraintEqualToAnchor:_preview.trailingAnchor],
		[_dimView.bottomAnchor constraintEqualToAnchor:_preview.bottomAnchor],

		[_tableView.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:12],
		[_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];

	[self rebuildRows];
	[self renderPreview];
}

- (void)rebuildRows {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	NSMutableArray *rows = [@[@(SCIRowOpacity), @(SCIRowBlur), @(SCIRowDim), @(SCIRowAutoBubble)] mutableCopy];
	if ([m autoBubbleEnabledForAsset:self.asset]) {
		[rows addObjectsFromArray:@[@(SCIRowBubbleSides), @(SCIRowGradient)]];
		if ([m bubbleGradientForAsset:self.asset]) [rows addObject:@(SCIRowGradientDir)];
		[rows addObjectsFromArray:@[@(SCIRowBubbleColor), @(SCIRowTextColor)]];
	}
	[rows addObject:@(SCIRowReset)];
	self.rows = rows;
}

- (void)dealloc {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renderPreview) object:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)prev {
	[super traitCollectionDidChange:prev];
	if (prev.userInterfaceStyle != self.traitCollection.userInterfaceStyle) [self renderPreview];
}

- (BOOL)isDark {
	return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

- (void)done {
	[self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)renderPreview {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renderPreview) object:nil];

	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	self.preview.image = [m processedImageForAsset:self.asset darkAppearance:self.isDark];
	self.preview.alpha = [m effectiveOpacityForAsset:self.asset];
	self.preview.backgroundColor = self.isDark ? UIColor.blackColor : UIColor.whiteColor;
	self.dimView.alpha = self.isDark ? [m effectiveDimForAsset:self.asset] : 0;
}

- (void)quickPreview {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	self.preview.alpha = [m effectiveOpacityForAsset:self.asset];
	self.dimView.alpha = self.isDark ? [m effectiveDimForAsset:self.asset] : 0;
}

- (void)renderPreviewSoon {
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renderPreview) object:nil];
	[self performSelector:@selector(renderPreview) withObject:nil afterDelay:0.08];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
	return self.rows.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
	return SCILocalized(@"Reset sets opacity to 1.0, blur to 0, dim to 0.");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:kCell forIndexPath:ip];
	SCIUIKit26ConfigureTableCell(cell);
	cell.accessoryView = nil;
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	cell.imageView.image = nil;

	NSInteger tag = self.rows[ip.row].integerValue;
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];

	if (tag == SCIRowReset) {
		cell.textLabel.text = SCILocalized(@"Reset");
		cell.textLabel.textColor = UIColor.systemRedColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		return cell;
	}

	if (tag == SCIRowAutoBubble) {
		cell.textLabel.text = SCILocalized(@"Auto bubble color");
		cell.textLabel.textColor = UIColor.labelColor;

		UISwitch *sw = [UISwitch new];
		sw.on = [m autoBubbleEnabledForAsset:self.asset];
		sw.onTintColor = [SCIUtils SCIColor_Primary];
		[sw addTarget:self action:@selector(autoBubbleToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		return cell;
	}

	if (tag == SCIRowBubbleSides) {
		cell.textLabel.text = SCILocalized(@"Apply to");

		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
			SCILocalized(@"Other"), SCILocalized(@"Me"), SCILocalized(@"Both")
		]];
		seg.selectedSegmentIndex = [m bubbleSidesForAsset:self.asset];
		seg.selectedSegmentTintColor = [SCIUtils SCIColor_Primary];
		[seg addTarget:self action:@selector(sidesChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = seg;
		cell.textLabel.textColor = UIColor.labelColor;
		return cell;
	}

	if (tag == SCIRowGradient) {
		cell.textLabel.text = SCILocalized(@"Gradient");
		cell.textLabel.textColor = UIColor.labelColor;

		UISwitch *sw = [UISwitch new];
		sw.on = [m bubbleGradientForAsset:self.asset];
		sw.onTintColor = [SCIUtils SCIColor_Primary];
		[sw addTarget:self action:@selector(gradientToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		return cell;
	}

	if (tag == SCIRowGradientDir) {
		cell.textLabel.text = SCILocalized(@"Direction");

		UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
			SCILocalized(@"Vertical"), SCILocalized(@"Horizontal"), SCILocalized(@"Diagonal")
		]];
		seg.selectedSegmentIndex = [m bubbleGradientDirectionForAsset:self.asset];
		seg.selectedSegmentTintColor = [SCIUtils SCIColor_Primary];
		[seg addTarget:self action:@selector(gradientDirChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = seg;
		cell.textLabel.textColor = UIColor.labelColor;
		return cell;
	}

	if (tag == SCIRowBubbleColor) {
		cell.textLabel.text = SCILocalized(@"Bubble color");
		cell.textLabel.textColor = UIColor.labelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

		NSArray<UIColor *> *colors = [m bubbleColorsForAsset:self.asset];
		if (colors.count) {
			cell.imageView.image = [self swatchForColors:colors];
			cell.imageView.layer.cornerRadius = 5;
			cell.imageView.clipsToBounds = YES;
		}
		return cell;
	}

	if (tag == SCIRowTextColor) {
		cell.textLabel.text = SCILocalized(@"Text color");
		cell.textLabel.textColor = UIColor.labelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

		UIColor *textColor = [m autoBubbleTextColorForAsset:self.asset];
		if (textColor) {
			cell.imageView.image = [self swatchForColors:@[textColor]];
			cell.imageView.layer.cornerRadius = 5;
			cell.imageView.clipsToBounds = YES;
		}
		return cell;
	}

	UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 170, 31)];
	slider.tintColor = [SCIUtils SCIColor_Primary];
	slider.tag = tag;
	[slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
	[slider addTarget:self action:@selector(sliderDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

	if (tag == SCIRowOpacity) {
		cell.textLabel.text = SCILocalized(@"Opacity");
		slider.minimumValue = 0.1;
		slider.maximumValue = 1.0;
		slider.value = [m effectiveOpacityForAsset:self.asset];
	} else if (tag == SCIRowBlur) {
		cell.textLabel.text = SCILocalized(@"Blur");
		slider.minimumValue = 0;
		slider.maximumValue = 30;
		slider.value = [m effectiveBlurForAsset:self.asset];
	} else {
		cell.textLabel.text = SCILocalized(@"Dim in dark mode");
		slider.minimumValue = 0;
		slider.maximumValue = 0.85;
		slider.value = [m effectiveDimForAsset:self.asset];
	}

	cell.textLabel.textColor = UIColor.labelColor;
	cell.accessoryView = slider;
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	NSInteger tag = self.rows[ip.row].integerValue;

	if (tag == SCIRowReset) {
		[[SCIChatBackgroundManager shared] resetSettingsForAsset:self.asset];
		[self rebuildRows];
		[self renderPreview];
		[self.tableView reloadData];
	} else if (tag == SCIRowBubbleColor) {
		[self editBubbleColor];
	} else if (tag == SCIRowTextColor) {
		[self editTextColor];
	}
}

#pragma mark - Slider

- (void)sliderChanged:(UISlider *)s {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];

	if (s.tag == SCIRowOpacity) {
		[m setOpacity:s.value forAsset:self.asset];
		[self quickPreview];
	} else if (s.tag == SCIRowBlur) {
		[m setBlur:s.value forAsset:self.asset];
		[self renderPreviewSoon];
	} else {
		[m setDim:s.value forAsset:self.asset];
		[self quickPreview];
	}
}

- (void)sliderDone:(UISlider *)s {
	if (s.tag == SCIRowBlur) [self renderPreview];
}

- (void)autoBubbleToggled:(UISwitch *)sw {
	[[SCIChatBackgroundManager shared] setAutoBubble:sw.on forAsset:self.asset];
	[self rebuildRows];
	[self.tableView reloadData];
}

- (void)sidesChanged:(UISegmentedControl *)seg {
	[[SCIChatBackgroundManager shared] setBubbleSides:(SCIBubbleSides)seg.selectedSegmentIndex forAsset:self.asset];
}

- (void)gradientToggled:(UISwitch *)sw {
	[[SCIChatBackgroundManager shared] setBubbleGradient:sw.on forAsset:self.asset];
	[self rebuildRows];
	[self.tableView reloadData];
}

- (void)gradientDirChanged:(UISegmentedControl *)seg {
	[[SCIChatBackgroundManager shared] setBubbleGradientDirection:(SCIBubbleGradientDirection)seg.selectedSegmentIndex forAsset:self.asset];
}

- (void)editBubbleColor {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	NSString *capturedAsset = self.asset;
	NSArray<UIColor *> *colors = [m bubbleColorsForAsset:capturedAsset];
	BOOL gradient = [m bubbleGradientForAsset:capturedAsset];

	SCIColorPickerSheet *picker = [SCIColorPickerSheet sheetWithMode:gradient ? SCIColorPickerSheetModeGradient : SCIColorPickerSheetModeSolid
														 startColor:colors.firstObject ?: UIColor.systemBlueColor
														   endColor:gradient ? (colors.count > 1 ? colors.lastObject : nil) : nil
													   applyHandler:^(SCIColorPickerSheetMode mode, UIColor *primary, UIColor *secondary) {
		NSArray<UIColor *> *picked = (mode == SCIColorPickerSheetModeGradient && secondary) ? @[primary, secondary] : @[primary];
		[m setBubbleColorOverride:picked forAsset:capturedAsset];
		[self.tableView reloadData];
	}];
	[picker presentFromViewController:self];
}

- (void)editTextColor {
	SCIChatBackgroundManager *m = [SCIChatBackgroundManager shared];
	NSString *capturedAsset = self.asset;

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SCILocalized(@"Text color") message:nil preferredStyle:UIAlertControllerStyleActionSheet];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Automatic (contrast)") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *_) {
		[m setBubbleTextColorOverride:nil forAsset:capturedAsset];
		[self.tableView reloadData];
	}]];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Choose color…") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *_) {
		UIColor *start = [m bubbleTextColorOverrideForAsset:capturedAsset] ?: [m autoBubbleTextColorForAsset:capturedAsset] ?: UIColor.whiteColor;
		SCIColorPickerSheet *picker = [SCIColorPickerSheet sheetWithMode:SCIColorPickerSheetModeSolid
															 startColor:start
															   endColor:nil
														   applyHandler:^(__unused SCIColorPickerSheetMode mode, UIColor *primary, __unused UIColor *secondary) {
			[m setBubbleTextColorOverride:primary forAsset:capturedAsset];
			[self.tableView reloadData];
		}];
		[picker presentFromViewController:self];
	}]];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

	UITableViewCell *cell = nil;
	NSInteger idx = [self.rows indexOfObject:@(SCIRowTextColor)];
	if (idx != NSNotFound) cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0]];
	sheet.popoverPresentationController.sourceView = cell ?: self.view;
	sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;

	[self presentViewController:sheet animated:YES completion:nil];
}

- (UIImage *)swatchForColors:(NSArray<UIColor *> *)colors {
	CGSize size = CGSizeMake(26, 26);
	UIGraphicsImageRendererFormat *fmt = UIGraphicsImageRendererFormat.preferredFormat;
	fmt.opaque = NO;
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:5];
		[path addClip];
		if (colors.count >= 2) {
			CGFloat locs[2] = {0, 1};
			NSArray *cgs = @[(id)[colors[0] CGColor], (id)[colors[1] CGColor]];
			CGGradientRef grad = CGGradientCreateWithColors(CGColorSpaceCreateDeviceRGB(), (__bridge CFArrayRef)cgs, locs);
			CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
			CGGradientRelease(grad);
		} else {
			[colors.firstObject ?: UIColor.clearColor setFill];
			[path fill];
		}
	}];
}

@end
