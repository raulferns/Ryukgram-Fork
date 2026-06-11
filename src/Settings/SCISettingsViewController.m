#import "SCISettingsViewController.h"
#import "SCIWhatsNew.h"
#import "../UI/SCIPopupChrome.h"
#import "SCISearchBarStyler.h"
#import "GlassUI/SCIAdaptiveGlass.h"
#import "../Features/General/SCICacheManager.h"
#import "../Features/Dogfooding/SCIInternalMenusForce.h"
#import "../Features/Dogfooding/SCIAdvancedHooks.h"
#import "../Features/Gating/SCIBulkGatingPresets.h"
#import "../SCIImageCache.h"
#import "../Utils.h"
#import "../Tweak.h"
#import "../UI/SCIColorPicker.h"


static char kSCIRowKey;

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
	SCIApplyGlassBackdropToViewController(self);
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
	SCIStyleTableViewForGlass(self.tableView);
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

- (void)sciClose {
	[self.view endEditing:YES];
	UIViewController *target = self.navigationController ?: self;
	[target dismissViewControllerAnimated:YES completion:nil];
}
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

@interface SCISettingsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
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
			if (row.navSections.count) {
				NSString *childCrumb = sectionCrumb.length ? [NSString stringWithFormat:@"%@ › %@", sectionCrumb, row.title ?: @""] : (row.title ?: @"");
				[out addObjectsFromArray:[self buildSearchIndexFromSections:row.navSections breadcrumb:childCrumb]];
			}
		}
	}
	return out.copy;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.navigationController.navigationBar.prefersLargeTitles = NO;
	SCIApplyGlassBackdropToViewController(self);
	[self setupTableView];
	if (self.isRoot) [self setupRootNavigation];
	NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
	[nc addObserver:self selector:@selector(sciCacheSizeDidUpdate) name:SCICacheSizeDidUpdateNotification object:nil];
	[nc addObserver:self selector:@selector(sciReloadFromNotification) name:@"SCISettingsShouldReload" object:nil];
}

- (void)sciReloadFromNotification {
	CGPoint offset = self.tableView.contentOffset;
	[self.tableView reloadData];
	self.tableView.contentOffset = offset;
}

- (void)setupTableView {
	self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	SCIStyleTableViewForGlass(self.tableView);
	self.tableView.contentInset = UIEdgeInsetsZero;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;
	[self.view addSubview:self.tableView];
}

- (void)setupRootNavigation {
	UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
	sc.searchResultsUpdater = self;
	sc.delegate = self;
	sc.searchBar.delegate = self;
	sc.obscuresBackgroundDuringPresentation = NO;
	sc.searchBar.placeholder = SCILocalized(@"settings.search.placeholder");
	self.searchController = sc;
	self.navigationItem.searchController = sc;
	self.navigationItem.hidesSearchBarWhenScrolling = YES;
	self.definesPresentationContext = ![SCIUtils getBoolPref:@"lg_swizzle_buttons"];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(sciDismissSettings)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:self action:@selector(sciPresentLanguagePicker)];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	SCIApplyGlassBackdropToViewController(self);
	[self.tableView reloadData];
	[self sciStyleSearchBar];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	SCIApplyLiquidGlassToViewTree(self.view);
	if (!self.searchBarStyled) [self sciStyleSearchBar];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.view endEditing:YES];
	if (self.searchController.isActive) self.searchController.active = NO;
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
	self.searchController.searchBar.placeholder = SCILocalized(@"settings.search.placeholder");
	self.sections = [self filteredSections:[SCITweakSettings sections]];
	self.searchIndex = [self buildSearchIndexFromSections:self.sections breadcrumb:@""];
	[self.tableView reloadData];
	[NSNotificationCenter.defaultCenter postNotificationName:@"SCILanguageDidChange" object:nil];
}

#pragma mark - Events

- (void)sciDismissSettings {
	[self.view endEditing:YES];
	UINavigationController *nav = self.navigationController;
	if (nav && nav.viewControllers.count > 1) {
		[nav popViewControllerAnimated:YES];
		return;
	}
	UIViewController *target = nav ?: self;
	[target dismissViewControllerAnimated:YES completion:nil];
}
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

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
	[self.view endEditing:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
	[searchBar resignFirstResponder];
	[self.view endEditing:YES];
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

	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	if (SCIIsIOS26OrNewer()) {
		SCIStyleCellForGlass(cell);
	}
	UIListContentConfiguration *config = cell.defaultContentConfiguration;
	cell.accessoryView = nil;
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	cell.contentView.alpha = row.disabled ? 0.4 : 1.0;

	config.text = row.dynamicTitle ? row.dynamicTitle() : row.title;
	config.textProperties.color = row.titleColor ?: UIColor.labelColor;

	NSString *subtitle = ([self isSearching] && breadcrumb.length) ? breadcrumb : (row.dynamicSubtitle ? row.dynamicSubtitle() : row.subtitle);
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
	if (row.icon) {
		config.image = [row.icon image];
		config.imageProperties.tintColor = row.icon.color;
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
			t.on = row.disabled ? NO : (row.dynamicSwitchValue ? row.dynamicSwitchValue() : [SCIUtils getBoolPref:row.defaultsKey]);
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
			s.value = [SCIUtils getDoublePref:row.defaultsKey];
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
			else cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			break;
		}
		case SCITableCellMenu: {
			UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
			[b setTitle:@"•••" forState:UIControlStateNormal];
			b.menu = [row menuForButton:b];
			b.showsMenuAsPrimaryAction = YES;
			b.enabled = !row.disabled;
			b.titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightMedium];
			UIButtonConfiguration *bc = b.configuration ?: ({
				UIButtonConfiguration *fallback;
				if (@available(iOS 26.0, *)) fallback = UIButtonConfiguration.plainButtonConfiguration;
				else fallback = UIButtonConfiguration.plainButtonConfiguration;
				fallback;
			});
			bc.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);
			b.configuration = bc;
			[b sizeToFit];
			cell.accessoryView = b;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;
		}
		case SCITableCellColor:
			cell.accessoryView = [SCIColorPicker swatchViewForKey:row.defaultsKey defaultColor:row.defaultColor];
			break;
	}
	return config;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
	if ([self isSearching]) return;
	SCISetting *row = [self settingForIndexPath:ip breadcrumbOut:NULL];
	// Clears this row's own dot once seen; a nav cell's bubble-up dot is separate.
	if (row) [SCIWhatsNew markSeen:[SCIWhatsNew identifierForRow:row]];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[self.view endEditing:YES];
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

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	[self.view endEditing:YES];
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
	if (row.onSwitchChange) {
		row.onSwitchChange(sender.isOn);
		[self reloadCellForView:sender animated:NO];
		return;
	}
	if (!row.defaultsKey.length) return;
	[SCIUtils setPref:@(sender.isOn) forKey:row.defaultsKey];
	SCIAdvancedHooksApplyForChangedKey(row.defaultsKey, sender.isOn);
	if (row.requiresRestart) [SCIUtils showRestartConfirmation];
	if ([row.defaultsKey isEqualToString:@"hide_suggested_stories"])
		[NSNotificationCenter.defaultCenter postNotificationName:@"SCISuggestedStoriesReload" object:nil];
	if ([row.defaultsKey isEqualToString:@"show_fake_location_map_button"])
		[NSNotificationCenter.defaultCenter postNotificationName:@"SCIFakeLocationMapBtnPrefChanged" object:nil];
	if ([row.defaultsKey isEqualToString:@"adv_encoding_enabled"]) {
		self.sections = [SCITweakSettings rebuildAdvancedEncodingSlotInSections:self.sections];
		[self sciReloadFromNotification];
	}
	// Advanced hooks follow the same local pattern as the rest of the tweak:
	// persist the toggle, then apply only the changed hook path for this session.
	// No global post-launch replay and no duplicate installer calls here.
}

- (void)stepperChanged:(UIStepper *)sender {
	SCISetting *row = objc_getAssociatedObject(sender, &kSCIRowKey);
	if (!row.defaultsKey.length) return;
	[SCIUtils setPref:@(sender.value) forKey:row.defaultsKey];
	[self reloadCellForView:sender animated:NO];
}

- (void)menuChanged:(UICommand *)command {
	NSDictionary *props = [command.propertyList isKindOfClass:NSDictionary.class] ? command.propertyList : nil;
	NSString *key = props[@"defaultsKey"];
	id value = props[@"value"];
	if (key.length && value) [SCIUtils setPref:value forKey:key];
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
	if (ip) [self.tableView reloadData];
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
