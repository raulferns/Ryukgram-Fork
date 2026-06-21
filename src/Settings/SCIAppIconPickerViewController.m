#import "SCIAppIconPickerViewController.h"
#import "../Utils.h"
#import "../UI/SCIPopupChrome.h"

static NSString *const SCISelectedAppIconNameKey = @"SCISelectedAppIconName";
static NSString *const SCIPrimaryAppIconKey = @"__primary__";

@interface SCIAppIconPickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSDictionary *> *icons;
@property (nonatomic, copy) NSString *selectedIconKey;
@end

@implementation SCIAppIconPickerViewController

+ (void)presentIconPicker {
	UIViewController *top = topMostController();
	if (!top) return;

	SCIAppIconPickerViewController *vc = [SCIAppIconPickerViewController new];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
	nav.modalPresentationStyle = UIModalPresentationPageSheet;

	if (@available(iOS 15.0, *)) {
		nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
		nav.sheetPresentationController.prefersGrabberVisible = YES;
	}

	[top presentViewController:nav animated:YES completion:nil];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);

	self.title = SCILocalized(@"App Icon");
	self.view.backgroundColor = SCIUIKit26BaseSurfaceColor();

	NSString *saved = [SCIUtils getStringPref:SCISelectedAppIconNameKey];
	NSString *current = UIApplication.sharedApplication.alternateIconName;
	self.selectedIconKey = saved.length ? saved : (current.length ? current : SCIPrimaryAppIconKey);

	[self loadIconsFromInfoPlist];
	[self setupNavigation];
	[self setupTableView];
}

- (void)setupNavigation {
	self.navigationController.navigationBar.prefersLargeTitles = NO;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeTapped)];
}

- (void)setupTableView {
	self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	self.tableView.rowHeight = 76.0;
	self.tableView.contentInset = UIEdgeInsetsZero;
	self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;

	[self.view addSubview:self.tableView];
}

- (void)loadIconsFromInfoPlist {
	NSMutableArray *items = [NSMutableArray array];
	NSDictionary *bundleIcons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
	NSDictionary *primary = bundleIcons[@"CFBundlePrimaryIcon"];

	[items addObject:@{
		@"key": SCIPrimaryAppIconKey,
		@"title": SCILocalized(@"Default"),
		@"files": primary[@"CFBundleIconFiles"] ?: @[]
	}];

	NSDictionary *alternates = bundleIcons[@"CFBundleAlternateIcons"];
	NSArray *keys = [alternates.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

	for (NSString *key in keys) {
		NSDictionary *info = alternates[key];
		if (!key.length || ![info isKindOfClass:NSDictionary.class]) continue;

		[items addObject:@{
			@"key": key,
			@"title": key,
			@"files": info[@"CFBundleIconFiles"] ?: @[]
		}];
	}

	self.icons = items.copy;
}

- (UIImage *)imageFromIconFiles:(NSArray *)files {
	if (![files isKindOfClass:NSArray.class]) return [self fallbackIconImage];

	for (NSString *file in files.reverseObjectEnumerator) {
		if (![file isKindOfClass:NSString.class] || !file.length) continue;

		for (NSString *scale in @[@"@3x", @"@2x", @""]) {
			NSString *name = [file stringByAppendingString:scale];

			for (NSString *ext in @[@"png", @"jpg", @"jpeg"]) {
				NSString *path = [NSBundle.mainBundle pathForResource:name ofType:ext];
				if (!path.length) continue;

				UIImage *image = [UIImage imageWithContentsOfFile:path];
				if (image && image.CGImage) return image;
			}
		}
	}

	return [self fallbackIconImage];
}

- (UIImage *)fallbackIconImage {
	CGSize size = CGSizeMake(48.0, 48.0);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);

	UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:11.0];
	[[SCIUtils SCIColor_Primary] setFill];
	[path fill];

	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();

	return image;
}

- (UIImage *)imageForIcon:(NSDictionary *)icon {
	return [self imageFromIconFiles:icon[@"files"]];
}

- (void)closeTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveSelectedKey:(NSString *)key {
	[SCIUtils setPref:key forKey:SCISelectedAppIconNameKey];
}

- (void)selectIconAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.row >= (NSInteger)self.icons.count) return;

	NSString *key = self.icons[indexPath.row][@"key"] ?: @"";
	if (!key.length) return;

	if (![UIApplication.sharedApplication supportsAlternateIcons]) {
		[SCIUtils showErrorHUDWithDescription:SCILocalized(@"Alternate icons are not supported")];
		return;
	}

	BOOL primary = [key isEqualToString:SCIPrimaryAppIconKey];
	NSString *iconName = primary ? nil : key;
	NSString *previousKey = self.selectedIconKey;

	self.selectedIconKey = key;
	[self saveSelectedKey:key];
	[self.tableView reloadData];

	__weak typeof(self) weakSelf = self;

	[UIApplication.sharedApplication setAlternateIconName:iconName completionHandler:^(NSError *error) {
		if (!error) return;

		dispatch_async(dispatch_get_main_queue(), ^{
			__strong typeof(weakSelf) self = weakSelf;
			if (!self) return;

			self.selectedIconKey = previousKey;
			[self saveSelectedKey:previousKey];
			[self.tableView reloadData];
			[SCIUtils showErrorHUDWithDescription:error.localizedDescription ?: SCILocalized(@"Failed to change icon")];
		});
	}];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return self.icons.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return SCILocalized(@"Choose Icon");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return SCILocalized(@"The selected icon will be saved and shown here the next time you open this page.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	static NSString *identifier = @"SCIAppIconPickerCell";

	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
	SCIUIKit26ConfigureTableCell(cell);

	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		cell.backgroundColor = SCIUIKit26PanelFillColor();
	}

	NSDictionary *icon = self.icons[indexPath.row];
	NSString *key = icon[@"key"] ?: @"";
	BOOL selected = [key isEqualToString:self.selectedIconKey];

	UIListContentConfiguration *config = cell.defaultContentConfiguration;
	config.text = icon[@"title"] ?: key;
	config.textProperties.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
	config.secondaryText = selected ? SCILocalized(@"Selected") : SCILocalized(@"Tap to apply");
	config.secondaryTextProperties.color = selected ? [SCIUtils SCIColor_Primary] : UIColor.secondaryLabelColor;
	config.image = [self imageForIcon:icon];
	config.imageProperties.maximumSize = CGSizeMake(48.0, 48.0);
	config.imageProperties.cornerRadius = 11.0;
	config.imageToTextPadding = 14.0;

	cell.contentConfiguration = config;
	cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	cell.tintColor = [SCIUtils SCIColor_Primary];

	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[self selectIconAtIndexPath:indexPath];
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
