#import "SCISettingsViewController.h"
#import "SCIWhatsNew.h"
#import "../Features/Gating/SCIBulkGatingPresets.h"
#import "../UI/SCIPopupChrome.h"
#import "SCISearchBarStyler.h"
#import "../Features/General/SCICacheManager.h"
#import "../SCIImageCache.h"
#import "../Tweak.h"
#import "../UI/SCIColorPicker.h"
#import "../UI/SCIOptionSheet.h"

static char kSCIRowKey;

static const CGFloat kSCISettingsStandardIconBox = 23.0;


static BOOL SCIMenuContainsDefaultsKey(UIMenu *menu, NSString *defaultsKey) {
	if (!menu || !defaultsKey.length) return NO;
	for (UIMenuElement *el in menu.children) {
		if ([el isKindOfClass:UIMenu.class]) {
			if (SCIMenuContainsDefaultsKey((UIMenu *)el, defaultsKey)) return YES;
			continue;
		}
		if (![el isKindOfClass:UICommand.class]) continue;
		NSDictionary *props = [((UICommand *)el).propertyList isKindOfClass:NSDictionary.class] ? ((UICommand *)el).propertyList : nil;
		if ([props[@"defaultsKey"] isEqualToString:defaultsKey]) return YES;
	}
	return NO;
}


static NSString *SCISettingsWordmarkDisplayTitleForValue(NSString *value, NSString *fallback) {
	if ([value isEqualToString:@"off"]) return SCILocalized(@"Default");
	if ([value isEqualToString:@"1a"]) return SCILocalized(@"Wordmark 1");
	if ([value isEqualToString:@"1a_alt"]) return SCILocalized(@"Wordmark 1A");
	if ([value isEqualToString:@"1b"]) return SCILocalized(@"Wordmark 2");
	if ([value isEqualToString:@"1b_alt"]) return SCILocalized(@"Wordmark 2A");
	return fallback ?: @"";
}

static NSString *SCISettingsWordmarkImageNameForValue(NSString *value) {
	NSString *v = value.length ? value : @"off";
	if ([v isEqualToString:@"1a"]) return @"instagram-wordmark-1a";
	if ([v isEqualToString:@"1a_alt"]) return @"instagram-wordmark-1a-alt";
	if ([v isEqualToString:@"1b"]) return @"instagram-wordmark-1b";
	if ([v isEqualToString:@"1b_alt"]) return @"instagram-wordmark-1b-alt";
	return @"instagram-wordmark-default";
}

static UIImage *SCISettingsBundleImageNamed(NSString *name) {
	NSBundle *bundle = SCILocalizationBundle();
	UIImage *img = bundle ? [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil] : nil;
	if (!img) img = [UIImage imageNamed:name];
	return img;
}

static UIImage *SCISettingsTrimTransparentTemplateImage(UIImage *image) {
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

static BOOL SCISettingsScanSelectedMenuTitle(UIMenu *menu, NSString **firstTitle, NSString **matchedTitle) {
	if (!menu || (matchedTitle && (*matchedTitle).length)) return YES;
	for (UIMenuElement *el in menu.children) {
		if ([el isKindOfClass:UIMenu.class]) {
			SCISettingsScanSelectedMenuTitle((UIMenu *)el, firstTitle, matchedTitle);
			if (matchedTitle && (*matchedTitle).length) return YES;
			continue;
		}
		if (![el isKindOfClass:UICommand.class]) continue;
		UICommand *cmd = (UICommand *)el;
		if (firstTitle && !(*firstTitle).length && cmd.title.length) *firstTitle = cmd.title;
		if (cmd.state == UIMenuElementStateOn && cmd.title.length) {
			if (matchedTitle) *matchedTitle = cmd.title;
			return YES;
		}
		NSDictionary *props = [cmd.propertyList isKindOfClass:NSDictionary.class] ? cmd.propertyList : nil;
		NSString *key = [props[@"defaultsKey"] isKindOfClass:NSString.class] ? props[@"defaultsKey"] : nil;
		NSString *value = [props[@"value"] isKindOfClass:NSString.class] ? props[@"value"] : nil;
		if (!key.length || !value.length) continue;
		id raw = [NSUserDefaults.standardUserDefaults objectForKey:key];
		NSString *saved = [raw isKindOfClass:NSString.class] ? raw : nil;
		if (!saved.length) saved = @"default";
		if ([value isEqualToString:saved]) {
			if (matchedTitle) *matchedTitle = cmd.title ?: @"";
			return YES;
		}
	}
	return NO;
}

static NSString *SCISettingsSelectedMenuTitle(UIMenu *menu) {
	NSString *firstTitle = nil;
	NSString *matchedTitle = nil;
	SCISettingsScanSelectedMenuTitle(menu, &firstTitle, &matchedTitle);
	if (matchedTitle.length) return matchedTitle;
	if (firstTitle.length) return firstTitle;
	return SCILocalized(@"Default");
}

static UIImage *SCISettingsScaledTemplateBundleImage(NSString *name, CGSize maxSize) {
	UIImage *img = SCISettingsBundleImageNamed(name);
	if (!img) return nil;
	img = SCISettingsTrimTransparentTemplateImage(img);
	CGSize size = img.size;
	if (size.width <= 0.0 || size.height <= 0.0) return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
	CGFloat ratio = MIN(maxSize.width / size.width, maxSize.height / size.height);
	if (ratio <= 0.0) ratio = 1.0;
	CGSize target = CGSizeMake(floor(size.width * ratio), floor(size.height * ratio));
	CGRect rect = CGRectMake((maxSize.width - target.width) * 0.5, (maxSize.height - target.height) * 0.5, target.width, target.height);
	UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
	fmt.opaque = NO;
	fmt.scale = UIScreen.mainScreen.scale;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:maxSize format:fmt];
	UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
		[img drawInRect:rect];
	}];
	return [scaled imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Language Picker

@interface SCILanguagePickerViewController : UITableViewController
@property (nonatomic, copy) void (^onPick)(NSString *code);
@end

@interface SCILanguagePickerViewController ()
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *languages;
@property (nonatomic, copy) NSString *currentCode;
@end

@implementation SCILanguagePickerViewController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_languages = SCIAvailableLanguages();
		_currentCode = [NSUserDefaults.standardUserDefaults stringForKey:SCILanguagePrefKey] ?: @"system";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = SCILocalized(@"settings.language.title");
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(sciClose)];
	UIColor *bg = [SCIPopupChrome backgroundColor];
	self.view.backgroundColor = bg;
	self.tableView.backgroundColor = bg;
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"lang"];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	NSInteger idx = [self sciActiveIndex];
	if (idx != NSNotFound) [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
}

- (NSInteger)sciActiveIndex {
	for (NSUInteger i = 0; i < self.languages.count; i++)
		if ([(self.languages[i][@"code"] ?: @"system") isEqualToString:self.currentCode]) return (NSInteger)i;
	return NSNotFound;
}

- (void)sciClose { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? (NSInteger)self.languages.count : 1; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"lang" forIndexPath:ip];
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.detailTextLabel.text = nil;
	cell.textLabel.textColor = UIColor.labelColor;
	cell.textLabel.font = [UIFont systemFontOfSize:17.0];
	cell.imageView.image = nil;
	cell.tintColor = UIColor.systemBlueColor;

	if (ip.section == 0) {
		NSDictionary *lang = self.languages[ip.row];
		NSString *code = lang[@"code"] ?: @"system";
		NSString *native = [code isEqualToString:@"system"] ? SCILocalized(@"settings.language.system") : (lang[@"native"] ?: code);
		NSString *english = nil;
		if (![code isEqualToString:@"system"] && ![code isEqualToString:@"en"]) {
			NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en"];
			english = [en localizedStringForLocaleIdentifier:code] ?: [en localizedStringForLanguageCode:code];
			if (english.length) english = [[[english substringToIndex:1] uppercaseString] stringByAppendingString:[english substringFromIndex:1]];
			if ([english isEqualToString:native]) english = nil;
		}
		cell.textLabel.text = english.length ? [NSString stringWithFormat:@"%@  ·  %@", native, english] : native;
		if ([code isEqualToString:self.currentCode]) {
			cell.accessoryType = UITableViewCellAccessoryCheckmark;
			cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
		}
	} else {
		cell.textLabel.text = SCILocalized(@"settings.language.help_translate");
		cell.textLabel.textColor = UIColor.systemPinkColor;
		cell.imageView.image = [UIImage systemImageNamed:@"heart.fill"];
		cell.imageView.tintColor = UIColor.systemPinkColor;
	}
	return cell;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
	return s == 0 ? [NSString stringWithFormat:@"%@  ·  %lu", SCILocalized(@"settings.language.available"), (unsigned long)self.languages.count] : nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 0) {
		NSString *code = self.languages[ip.row][@"code"] ?: @"system";
		void (^pick)(NSString *) = self.onPick;
		[self dismissViewControllerAnimated:YES completion:^{ if (pick) pick(code); }];
	} else {
		NSURL *url = [NSURL URLWithString:SCIRepoTranslateURL];
		if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
	}
}

@end

#pragma mark - Settings View Controller

@interface SCISettingsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UISearchControllerDelegate>
@property (nonatomic, strong, readwrite) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, copy) NSArray<NSDictionary *> *searchIndex;
@property (nonatomic, copy) NSArray<NSDictionary *> *searchResults;
@property (nonatomic, assign) BOOL reduceMargin;
@property (nonatomic, assign) BOOL isRoot;
@property (nonatomic, assign) BOOL searchBarStyled;
@end

@implementation SCISettingsViewController

- (instancetype)init {
	return [self initWithTitle:[SCITweakSettings title] sections:[SCITweakSettings sections] reduceMargin:YES];
}

- (instancetype)initWithTitle:(NSString *)title sections:(NSArray *)sections reduceMargin:(BOOL)reduceMargin {
	if (!(self = [super init])) return nil;
	self.title = title;
	self.reduceMargin = reduceMargin;
	self.isRoot = reduceMargin;
	self.sections = [self filteredSections:sections];
	self.searchResults = @[];
	if (self.isRoot) self.searchIndex = [self buildSearchIndexFromSections:self.sections breadcrumb:@""];
	return self;
}

- (instancetype)initWithTitle:(NSString *)title {
	return [self initWithTitle:title sections:@[] reduceMargin:NO];
}

- (void)applySettingSections:(NSArray *)sections {
	self.sections = [self filteredSections:sections];
	[self.tableView reloadData];
}

- (void)rebuildSections {}

+ (NSDictionary *)sectionWithHeader:(NSString *)header footer:(NSString *)footer rows:(NSArray<SCISetting *> *)rows {
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	if (header) d[@"header"] = header;
	if (footer) d[@"footer"] = footer;
	d[@"rows"] = rows ?: @[];
	return d.copy;
}

- (NSArray<NSDictionary *> *)sciSearchableSettingsEntries {
	if (!self.sections.count) [self rebuildSections];
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *section in self.sections) {
		if (![section isKindOfClass:NSDictionary.class]) continue;
		NSString *header = section[@"header"] ?: @"";
		for (SCISetting *row in section[@"rows"]) {
			if (![row isKindOfClass:SCISetting.class] || row.type == SCITableCellCustom) continue;
			NSString *title = row.dynamicTitle ? row.dynamicTitle() : row.title;
			id child = row.navViewController;
			BOOL childSearchable = [child conformsToProtocol:@protocol(SCISettingsSearchable)];

			if (title.length) {
				NSString *sub = (row.dynamicSubtitle ? row.dynamicSubtitle() : row.subtitle) ?: @"";
				NSMutableDictionary *e = [@{ @"title": title, @"subtitle": sub, @"section": header } mutableCopy];
				if (childSearchable) e[@"target"] = child;
				[out addObject:e];
			}

			if (childSearchable) {
				NSString *prefix = title.length ? (header.length ? [NSString stringWithFormat:@"%@ › %@", header, title] : title) : header;
				for (NSDictionary *ce in [(id<SCISettingsSearchable>)child sciSearchableSettingsEntries]) {
					NSMutableDictionary *e = ce.mutableCopy;
					NSString *cs = ce[@"section"] ?: @"";
					e[@"section"] = cs.length ? (prefix.length ? [NSString stringWithFormat:@"%@ › %@", prefix, cs] : cs) : prefix;
					if (!e[@"target"]) e[@"target"] = child;
					[out addObject:e];
				}
			}
		}
	}
	return out;
}

- (NSArray *)filteredSections:(NSArray *)sections {
	NSMutableArray *out = [NSMutableArray array];
	NSString *ver = [SCIUtils IGVersionString];
	for (NSDictionary *section in sections) {
		if (![section isKindOfClass:NSDictionary.class]) continue;
		NSString *header = section[@"header"] ?: @"";
		NSString *footer = section[@"footer"] ?: @"";
		if ([header hasPrefix:@"_"] && [footer hasPrefix:@"_"] && ![ver isEqualToString:@"0.0.0"]) continue;
		if ([header isEqualToString:@"Experimental"] && ![ver hasSuffix:@"-dev"]) continue;
		[out addObject:section];
	}
	return out.copy;
}

- (NSArray<NSDictionary *> *)buildSearchIndexFromSections:(NSArray *)sections breadcrumb:(NSString *)breadcrumb {
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *section in sections) {
		if (![section isKindOfClass:NSDictionary.class]) continue;
		NSString *header = section[@"header"] ?: @"";
		NSArray *rows = section[@"rows"];
		NSString *sectionCrumb = breadcrumb.length && header.length ? [NSString stringWithFormat:@"%@ › %@", breadcrumb, header] : (header ?: breadcrumb);
		for (SCISetting *row in rows) {
			if (![row isKindOfClass:SCISetting.class]) continue;
			[out addObject:@{
				@"setting": row,
				@"breadcrumb": sectionCrumb ?: @"",
				@"haystack": [NSString stringWithFormat:@"%@ %@ %@", row.title ?: @"", row.subtitle ?: @"", sectionCrumb ?: @""]
			}];
			NSString *childCrumb = sectionCrumb.length ? [NSString stringWithFormat:@"%@ › %@", sectionCrumb, row.title ?: @""] : (row.title ?: @"");
			if (row.navSections.count) {
				[out addObjectsFromArray:[self buildSearchIndexFromSections:row.navSections breadcrumb:childCrumb]];
			} else if ([row.navViewController conformsToProtocol:@protocol(SCISettingsSearchable)]) {
				for (NSDictionary *child in [(id<SCISettingsSearchable>)row.navViewController sciSearchableSettingsEntries]) {
					NSString *title = child[@"title"] ?: @"";
					NSString *sub = child[@"subtitle"] ?: @"";
					NSString *sec = child[@"section"] ?: @"";
					UIViewController *target = child[@"target"] ?: row.navViewController;
					NSString *entryCrumb = sec.length ? [NSString stringWithFormat:@"%@ › %@", childCrumb, sec] : childCrumb;
					SCISetting *proxy = [SCISetting navigationCellWithTitle:title subtitle:@"" icon:row.icon viewController:target];
					[out addObject:@{
						@"setting": proxy,
						@"breadcrumb": entryCrumb,
						@"haystack": [NSString stringWithFormat:@"%@ %@ %@", title, sub, entryCrumb]
					}];
				}
			}
		}
	}
	return out.copy;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationController.navigationBar.prefersLargeTitles = NO;
	SCIUIKit26ConfigureViewController(self);
	self.view.backgroundColor = [SCIPopupChrome backgroundColor];
	[self setupTableView];
	if (self.isRoot) [self setupRootNavigation];
	SCIUIKit26InstallNavigationTitleBubble(self);
	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserver:self selector:@selector(sciCacheSizeDidUpdate) name:SCICacheSizeDidUpdateNotification object:nil];
	[nc addObserver:self selector:@selector(sciReloadFromNotification) name:@"SCISettingsShouldReload" object:nil];
}

- (void)sciReloadFromNotification {
	CGPoint offset = self.tableView.contentOffset;
	if (self.isRoot) self.sections = [self filteredSections:[SCITweakSettings sections]];
	[self.tableView reloadData];
	self.tableView.contentOffset = offset;
}

- (void)setupTableView {
	self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 52.0;
	self.tableView.contentInset = UIEdgeInsetsZero;
	self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
	if (@available(iOS 11.0, *)) self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	[self.view addSubview:self.tableView];
}

- (void)setupRootNavigation {
	UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
	sc.searchResultsUpdater = self;
	sc.delegate = self;
	sc.obscuresBackgroundDuringPresentation = NO;
	sc.searchBar.placeholder = SCILocalized(@"settings.search.placeholder");
	self.searchController = sc;
	self.navigationItem.searchController = sc;
	SCIUIKit26ConfigureSearchNavigationItem(self.navigationItem);
	self.definesPresentationContext = ![SCIUtils getBoolPref:@"liquid_glass_buttons"];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(sciDismissSettings)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:self action:@selector(sciPresentLanguagePicker)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	SCIConfigureNavigationChromeForGlass(self);
	SCIUIKit26RefreshNavigationTitleBubble(self);
	if (self.isRoot) self.sections = [self filteredSections:[SCITweakSettings sections]];
	[self.tableView reloadData];
	[self sciStyleSearchBar];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	if (!self.searchBarStyled) [self sciStyleSearchBar];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	if (![SCIUtils getBoolPref:@"liquid_glass_buttons"] && self.searchController.isActive) self.searchController.active = NO;
	if (self.isRoot) [self sciShowFirstRunAlertIfNeeded];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark - Language

- (void)sciPresentLanguagePicker {
	SCILanguagePickerViewController *picker = [SCILanguagePickerViewController new];
	__weak typeof(self) weakSelf = self;
	picker.onPick = ^(NSString *code) {
		NSString *prev = [NSUserDefaults.standardUserDefaults stringForKey:SCILanguagePrefKey] ?: @"system";
		if ([prev isEqualToString:code]) return;
		[NSUserDefaults.standardUserDefaults setObject:code forKey:SCILanguagePrefKey];
		SCILocalizationReset();
		[weakSelf sciApplyLanguageChange];
		[SCIUtils showRestartConfirmationWithTitle:SCILocalized(@"settings.language.restart.title") message:SCILocalized(@"settings.language.restart.message")];
	};
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
	nav.modalPresentationStyle = UIModalPresentationPageSheet;
	if (@available(iOS 15.0, *)) {
		UISheetPresentationController *sheet = nav.sheetPresentationController;
		sheet.detents = @[UISheetPresentationControllerDetent.largeDetent, UISheetPresentationControllerDetent.mediumDetent];
		sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
		sheet.prefersGrabberVisible = YES;
		sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
	}
	[self presentViewController:nav animated:YES completion:nil];
}

- (void)sciApplyLanguageChange {
	self.title = SCILocalized(@"settings.title");
	SCIUIKit26RefreshNavigationTitleBubble(self);
	self.searchController.searchBar.placeholder = SCILocalized(@"settings.search.placeholder");
	self.sections = [self filteredSections:[SCITweakSettings sections]];
	self.searchIndex = [self buildSearchIndexFromSections:self.sections breadcrumb:@""];
	[self.tableView reloadData];
	[NSNotificationCenter.defaultCenter postNotificationName:@"SCILanguageDidChange" object:nil];
}

#pragma mark - Events

- (void)sciDismissSettings { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)sciCacheSizeDidUpdate { [self.tableView reloadData]; }

- (void)sciStyleSearchBar {
	if (!self.searchController.searchBar) return;
	[SCISearchBarStyler styleSearchBar:self.searchController.searchBar];
	self.searchBarStyled = YES;
}

- (void)willPresentSearchController:(UISearchController *)sc { self.searchBarStyled = NO; [self sciStyleSearchBar]; }

- (void)didPresentSearchController:(UISearchController *)sc {
	self.searchBarStyled = NO;
	[self sciStyleSearchBar];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		self.searchBarStyled = NO;
		[self sciStyleSearchBar];
	});
}

- (void)sciShowFirstRunAlertIfNeeded {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if ([[d objectForKey:@"SCInstaFirstRun"] isEqualToString:SCIVersionString]) return;
	[d setObject:SCIVersionString forKey:@"SCInstaFirstRun"];
	UIViewController *presenter = self.presentingViewController;
	if (!presenter) return;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:SCILocalized(@"settings.firstrun.title") message:SCILocalized(@"settings.firstrun.message") preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"settings.firstrun.ok") style:UIAlertActionStyleDefault handler:nil]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Search

- (BOOL)isSearching { return self.searchController.isActive && self.searchController.searchBar.text.length > 0; }

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
	NSString *q = sc.searchBar.text ?: @"";
	if (!q.length) { self.searchResults = @[]; [self.tableView reloadData]; return; }
	NSMutableArray *out = [NSMutableArray array];
	NSStringCompareOptions opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
	for (NSDictionary *entry in self.searchIndex)
		if ([(entry[@"haystack"] ?: @"") rangeOfString:q options:opts].location != NSNotFound) [out addObject:entry];
	self.searchResults = out.copy;
	[self.tableView reloadData];
}

- (SCISetting *)settingForIndexPath:(NSIndexPath *)ip breadcrumbOut:(NSString **)outCrumb {
	if ([self isSearching]) {
		if (ip.row >= (NSInteger)self.searchResults.count) return nil;
		NSDictionary *entry = self.searchResults[ip.row];
		if (outCrumb) *outCrumb = entry[@"breadcrumb"];
		return entry[@"setting"];
	}
	if (ip.section >= (NSInteger)self.sections.count) return nil;
	NSArray *rows = self.sections[ip.section][@"rows"];
	return ip.row >= (NSInteger)rows.count ? nil : rows[ip.row];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return [self isSearching] ? 1 : self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [self isSearching] ? self.searchResults.count : [self.sections[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return [self isSearching] ? nil : self.sections[s][@"footer"]; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
	if ([self isSearching]) {
		NSUInteger c = self.searchResults.count;
		if (!c) return SCILocalized(@"No results");
		return [NSString stringWithFormat:SCILocalized(c == 1 ? @"settings.results.one" : @"settings.results.many"), (unsigned long)c];
	}
	return self.sections[s][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSString *breadcrumb = nil;
	SCISetting *row = [self settingForIndexPath:ip breadcrumbOut:&breadcrumb];
	if (!row) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

	if (row.type == SCITableCellCustom && row.customCellProvider && ![self isSearching])
		return row.customCellProvider(tv, ip);

	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	SCIUIKit26ConfigureTableCell(cell);
	UIListContentConfiguration *config = cell.defaultContentConfiguration;
	cell.accessoryView = nil;
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	cell.contentView.alpha = row.disabled ? 0.4 : 1.0;

	config.text = row.dynamicTitle ? row.dynamicTitle() : row.title;
	config.textProperties.color = row.titleColor ?: UIColor.labelColor;
	config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	config.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);

	NSString *rowSubtitle = row.dynamicSubtitle ? row.dynamicSubtitle() : row.subtitle;
	NSString *subtitle = ([self isSearching] && breadcrumb.length) ? breadcrumb : rowSubtitle;
	if (subtitle.length) {
		config.secondaryText = subtitle;
		config.textToSecondaryTextVerticalPadding = 4.5;
	}

	[self configureIconForRow:row config:config indexPath:ip tableView:tv];
	config = [self configuredContent:config forCell:cell row:row indexPath:ip];
	cell.contentConfiguration = config;
	if (![self isSearching] && [self rowHasWhatsNew:row]) [self addWhatsNewDotToCell:cell];
	return cell;
}

- (BOOL)rowHasWhatsNew:(SCISetting *)row {
	if ([SCIWhatsNew isUnseen:[SCIWhatsNew identifierForRow:row]]) return YES;
	return row.navSections.count && [SCIWhatsNew sectionsHaveUnseen:row.navSections];
}

- (void)addWhatsNewDotToCell:(UITableViewCell *)cell {
	UIView *dot = [UIView new];
	dot.translatesAutoresizingMaskIntoConstraints = NO;
	dot.backgroundColor = UIColor.systemBlueColor;
	dot.layer.cornerRadius = 3.5;
	[cell.contentView addSubview:dot];
	[NSLayoutConstraint activateConstraints:@[
		[dot.widthAnchor constraintEqualToConstant:7.0],
		[dot.heightAnchor constraintEqualToConstant:7.0],
		[dot.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
		[dot.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:5.0],
	]];
}

- (void)configureIconForRow:(SCISetting *)row config:(UIListContentConfiguration *)config indexPath:(NSIndexPath *)ip tableView:(UITableView *)tv {
	if (row.iconImage) {
		config.image = [row.iconImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		config.imageProperties.tintColor = UIColor.labelColor;

		// Match the rest of the tweak: settings icons sit on the standard
		// UIListContentConfiguration image rail. Asset-backed icons are capped
		// to the same visual box as SCISymbol/Apply/Reset rows; no negative
		// margins and no per-row left offsets.
		config.imageProperties.maximumSize = CGSizeMake(kSCISettingsStandardIconBox, kSCISettingsStandardIconBox);
	}
	if (row.icon) {
		config.image = [row.icon image];
		config.imageProperties.tintColor = row.icon.color;
		config.imageProperties.maximumSize = CGSizeMake(kSCISettingsStandardIconBox, kSCISettingsStandardIconBox);
	}
	if (row.imageUrl) {
		config.imageToTextPadding = 14.0;
		[self loadImageFromURL:row.imageUrl atIndexPath:ip forTableView:tv];
	}
	if (row.bundleImageName.length) {
		UIImage *img = [UIImage imageNamed:row.bundleImageName inBundle:SCILocalizationBundle() compatibleWithTraitCollection:nil];
		if (!img) return;
		config.image = img;
		config.imageProperties.maximumSize = CGSizeMake(45.0, 45.0);
		config.imageProperties.cornerRadius = 10.0;
		config.imageToTextPadding = 14.0;
	}
}

- (UILabel *)valueLabel:(NSString *)text {
	UILabel *l = UILabel.new;
	l.text = text;
	l.font = [UIFont systemFontOfSize:16.0];
	l.textColor = UIColor.secondaryLabelColor;
	[l sizeToFit];
	return l;
}

- (UIListContentConfiguration *)configuredContent:(UIListContentConfiguration *)config forCell:(UITableViewCell *)cell row:(SCISetting *)row indexPath:(NSIndexPath *)ip {
	switch (row.type) {
		case SCITableCellStatic: {
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			if (row.valueText.length && ![self isSearching]) cell.accessoryView = [self valueLabel:row.valueText];
			break;
		}
		case SCITableCellLink: {
			config.textProperties.color = UIColor.systemBlueColor;
			config.textProperties.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
			UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"safari"]];
			icon.tintColor = UIColor.systemGray3Color;
			cell.accessoryView = icon;
			break;
		}
		case SCITableCellSwitch: {
			UISwitch *t = UISwitch.new;
			BOOL on = row.switchValueProvider ? row.switchValueProvider() : [NSUserDefaults.standardUserDefaults boolForKey:row.defaultsKey];
			t.on = row.disabled ? NO : on;
			t.onTintColor = [SCIUtils SCIColor_Primary];
			t.enabled = !row.disabled;
			objc_setAssociatedObject(t, &kSCIRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[t addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryView = t;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		}
		case SCITableCellStepper: {
			UIStepper *s = UIStepper.new;
			s.minimumValue = row.min;
			s.maximumValue = row.max;
			s.stepValue = row.step;
			s.value = [NSUserDefaults.standardUserDefaults doubleForKey:row.defaultsKey];
			objc_setAssociatedObject(s, &kSCIRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[s addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
			if (row.subtitle.length) config.secondaryText = [self formatString:row.subtitle withValue:s.value label:row.label singularLabel:row.singularLabel];
			cell.accessoryView = s;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		}
		case SCITableCellButton:
		case SCITableCellNavigation: {
			NSString *valueText = row.dynamicValueText ? row.dynamicValueText() : row.valueText;
			if (valueText.length && ![self isSearching]) cell.accessoryView = [self valueLabel:valueText];
			else if (!row.hidesDisclosureIndicator) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		}
		case SCITableCellMenu: {
			UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
			b.enabled = !row.disabled;
			b.titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
			b.titleLabel.numberOfLines = 1;
			b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
			b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
			SCIUIKit26ConfigureButton(b);
			UIMenu *resolvedMenu = [row menuForButton:b];
			BOOL isWordmarkMenu = SCIMenuContainsDefaultsKey(resolvedMenu, @"sci_ig_wordmark_variant");
			NSString *selectedTitle = SCISettingsSelectedMenuTitle(resolvedMenu);
			UIButtonConfiguration *bc = b.configuration ?: UIButtonConfiguration.plainButtonConfiguration;
			bc.contentInsets = isWordmarkMenu ? NSDirectionalEdgeInsetsMake(7.0, 10.0, 7.0, 10.0) : NSDirectionalEdgeInsetsMake(7.0, 11.0, 7.0, 11.0);
			bc.titleLineBreakMode = NSLineBreakByTruncatingTail;
			if (isWordmarkMenu) {
				NSString *variant = [NSUserDefaults.standardUserDefaults stringForKey:@"sci_ig_wordmark_variant"] ?: @"off";
				bc.title = nil;
				bc.image = SCISettingsScaledTemplateBundleImage(SCISettingsWordmarkImageNameForValue(variant), CGSizeMake(82.0, 22.0));
				bc.imagePlacement = NSDirectionalRectEdgeLeading;
				b.accessibilityLabel = SCISettingsWordmarkDisplayTitleForValue(variant, SCILocalized(@"Default"));
			} else {
				bc.title = selectedTitle.length ? selectedTitle : SCILocalized(@"Default");
				bc.image = nil;
			}
			b.configuration = bc;
			b.menu = resolvedMenu;
			b.showsMenuAsPrimaryAction = YES;
			if (@available(iOS 15.0, *)) b.changesSelectionAsPrimaryAction = YES;
			[b sizeToFit];
			cell.accessoryView = b;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		}

		case SCITableCellColor:
			cell.accessoryView = [SCIColorPicker swatchViewForKey:row.defaultsKey defaultColor:row.defaultColor];
			break;
		case SCITableCellCustom:
			break;
	}
	return config;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
	if ([self isSearching]) return UITableViewAutomaticDimension;
	SCISetting *row = [self settingForIndexPath:ip breadcrumbOut:NULL];
	if (row.type == SCITableCellCustom && row.customHeight > 0) return row.customHeight;
	return UITableViewAutomaticDimension;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
	if ([self isSearching]) return;
	SCISetting *row = [self settingForIndexPath:ip breadcrumbOut:NULL];
	// Clears this row's own dot once seen; a nav cell's bubble-up dot is separate.
	if (row) [SCIWhatsNew markSeen:[SCIWhatsNew identifierForRow:row]];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	SCISetting *row = [self settingForIndexPath:ip breadcrumbOut:NULL];
	if (!row || row.disabled) { [tv deselectRowAtIndexPath:ip animated:YES]; return; }
	switch (row.type) {
		case SCITableCellLink: if (row.url) [UIApplication.sharedApplication openURL:row.url options:@{} completionHandler:nil]; break;
		case SCITableCellButton: if (row.action) row.action(); break;
		case SCITableCellColor: [self presentColorPickerForRow:row indexPath:ip]; break;
		case SCITableCellNavigation: [self pushNavigationForRow:row]; break;
		default: break;
	}
	[tv deselectRowAtIndexPath:ip animated:YES];
}

- (void)presentColorPickerForRow:(SCISetting *)row indexPath:(NSIndexPath *)ip {
	__weak typeof(self) weakSelf = self;
	[SCIColorPicker presentFrom:self title:row.title defaultsKey:row.defaultsKey defaultColor:row.defaultColor onChange:^(__unused UIColor *color) {
		__strong typeof(weakSelf) self = weakSelf;
		if (!self) return;
		[self.tableView cellForRowAtIndexPath:ip].accessoryView = [SCIColorPicker swatchViewForKey:row.defaultsKey defaultColor:row.defaultColor];
	}];
}

- (void)pushNavigationForRow:(SCISetting *)row {
	if (row.navSections.count) {
		[self.navigationController pushViewController:[[SCISettingsViewController alloc] initWithTitle:row.title sections:row.navSections reduceMargin:NO] animated:YES];
		return;
	}
	if (row.navViewController) [self.navigationController pushViewController:row.navViewController animated:YES];
}

#pragma mark - Actions

- (void)switchChanged:(UISwitch *)sender {
	SCISetting *row = objc_getAssociatedObject(sender, &kSCIRowKey);
	if (row.switchAction) { row.switchAction(sender.isOn); return; }
	if (!row.defaultsKey.length) return;
	[NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:row.defaultsKey];
	if (row.requiresRestart) [SCIUtils showRestartConfirmation];
	if ([row.defaultsKey isEqualToString:@"hide_suggested_stories"])
		[NSNotificationCenter.defaultCenter postNotificationName:@"SCISuggestedStoriesReload" object:nil];
	if ([row.defaultsKey isEqualToString:@"show_fake_location_map_button"])
		[NSNotificationCenter.defaultCenter postNotificationName:@"SCIFakeLocationMapBtnPrefChanged" object:nil];
	if ([row.defaultsKey isEqualToString:@"adv_encoding_enabled"]) {
		self.sections = [SCITweakSettings rebuildAdvancedEncodingSlotInSections:self.sections];
		[self sciReloadFromNotification];
	}
}

- (void)stepperChanged:(UIStepper *)sender {
	SCISetting *row = objc_getAssociatedObject(sender, &kSCIRowKey);
	if (!row.defaultsKey.length) return;
	[NSUserDefaults.standardUserDefaults setDouble:sender.value forKey:row.defaultsKey];
	[self reloadCellForView:sender animated:NO];
}

- (void)menuButtonTapped:(UIButton *)sender {
	SCISetting *row = objc_getAssociatedObject(sender, &kSCIRowKey);
	if (!row || !row.baseMenu) return;
	UIMenu *menu = [row menuForButton:sender];
	__weak typeof(self) weakSelf = self;
	[SCIOptionSheet presentFrom:self title:row.title menu:menu sourceView:sender onPick:^(UICommand *command) {
		__strong typeof(weakSelf) self = weakSelf;
		if (!self || !command) return;
		[self menuChanged:command];
	}];
}

- (void)menuChanged:(UICommand *)command {
	NSDictionary *props = [command.propertyList isKindOfClass:NSDictionary.class] ? command.propertyList : nil;
	NSString *key = props[@"defaultsKey"];
	id value = props[@"value"];
	if (key.length && value) [NSUserDefaults.standardUserDefaults setValue:value forKey:key];
	if ([key isEqualToString:@"sci_ig_wordmark_variant"] || [key isEqualToString:@"sci_ig_wordmark_mode"])
		[SCIBulkGatingPresets applyIGWordmarkMode:[value isKindOfClass:NSString.class] ? value : @"off"];
	[self sciReloadFromNotification];

	NSString *pickerKey = props[@"presentColorPickerForKey"];
	if (pickerKey.length) {
		__weak typeof(self) weakSelf = self;
		[SCIColorPicker presentFrom:self title:command.title defaultsKey:pickerKey defaultColor:UIColor.blackColor onChange:^(__unused UIColor *color) {
			[weakSelf sciReloadFromNotification];
		}];
	}
	if ([props[@"requiresRestart"] boolValue]) [SCIUtils showRestartConfirmation];
}

#pragma mark - Helpers

- (NSString *)formatString:(NSString *)template withValue:(double)value label:(NSString *)label singularLabel:(NSString *)singularLabel {
	if (fabs(value) < 0.00001) value = 0.0;
	NSString *unit = fabs(value - 1.0) < 0.00001 ? singularLabel : label;
	static NSNumberFormatter *f;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ f = NSNumberFormatter.new; f.numberStyle = NSNumberFormatterDecimalStyle; f.minimumFractionDigits = 0; });
	f.maximumFractionDigits = [SCIUtils decimalPlacesInDouble:value];
	return [NSString stringWithFormat:template, [f stringFromNumber:@(value)] ?: @"0", unit ?: @""];
}

- (void)reloadCellForView:(UIView *)view animated:(BOOL)animated {
	UIView *cur = view;
	while (cur && ![cur isKindOfClass:UITableViewCell.class]) cur = cur.superview;
	if (!cur) return;
	NSIndexPath *ip = [self.tableView indexPathForCell:(UITableViewCell *)cur];
	if (ip) [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:animated ? UITableViewRowAnimationAutomatic : UITableViewRowAnimationNone];
}

- (void)reloadCellForView:(UIView *)view { [self reloadCellForView:view animated:NO]; }

- (void)loadImageFromURL:(NSURL *)url atIndexPath:(NSIndexPath *)ip forTableView:(UITableView *)tv {
	if (!url) return;
	[SCIImageCache loadImageFromURL:url completion:^(UIImage *image) {
		if (!image) return;
		dispatch_async(dispatch_get_main_queue(), ^{
			UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
			if (!cell) return;
			UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
			config.image = image;
			config.imageProperties.maximumSize = CGSizeMake(45.0, 45.0);
			config.imageProperties.cornerRadius = 22.5;
			config.imageToTextPadding = 14.0;
			cell.contentConfiguration = config;
		});
	}];
}

@end