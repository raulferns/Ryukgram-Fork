#import "SCITabBarOrderViewController.h"
#import "../UI/SCIIcon.h"
#import "../UI/SCIPopupChrome.h"
#import "../Utils.h"

static NSArray<NSDictionary *> *sciTabCatalog(void) {
	// Mirrors IG's stock bar order; SHARE (create) last — most builds don't show it.
	return @[
		@{@"key": @"FEED",    @"title": @"Feed",     @"icon": @"ig_icon_home_pano_prism_outline_24",        @"sfFallback": @"house",              @"hidePref": @"hide_feed_tab"},
		@{@"key": @"CLIPS",   @"title": @"Reels",    @"icon": @"ig_icon_reels_pano_prism_outline_24",       @"sfFallback": @"play.rectangle",     @"hidePref": @"hide_reels_tab"},
		@{@"key": @"DIRECT",  @"title": @"Messages", @"icon": @"ig_icon_direct_prism_outline_24",           @"sfFallback": @"paperplane",         @"hidePref": @"hide_messages_tab"},
		@{@"key": @"SEARCH",  @"title": @"Explore",  @"icon": @"ig_icon_search_pano_outline_24",            @"sfFallback": @"magnifyingglass",    @"hidePref": @"hide_explore_tab"},
		@{@"key": @"PROFILE", @"title": @"Profile",  @"icon": @"ig_icon_user_circle_pano_prism_outline_24", @"sfFallback": @"person.crop.circle", @"hidePref": @"hide_profile_tab"},
		@{@"key": @"SHARE",   @"title": @"Create",   @"icon": @"ig_icon_add_pano_outline_24",               @"sfFallback": @"plus.app",           @"hidePref": @"hide_create_tab"},
	];
}

static NSDictionary *sciTabEntryForKey(NSString *key) {
	for (NSDictionary *entry in sciTabCatalog())
		if ([entry[@"key"] isEqualToString:key]) return entry;
	return nil;
}

@interface SCITabBarOrderViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *orderedKeys;
@end

@implementation SCITabBarOrderViewController

- (instancetype)init {
	if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
	self.title = SCILocalized(@"Icon order");
	[self loadOrder];
	return self;
}

- (void)loadOrder {
	NSMutableArray *keys = [NSMutableArray array];
	for (NSString *key in [[SCIUtils getStringPref:@"nav_tab_order"] componentsSeparatedByString:@","])
		if (sciTabEntryForKey(key) && ![keys containsObject:key]) [keys addObject:key];
	for (NSDictionary *entry in sciTabCatalog())
		if (![keys containsObject:entry[@"key"]]) [keys addObject:entry[@"key"]];
	self.orderedKeys = keys;
}

- (void)saveOrder {
	[SCIUtils setPref:[self.orderedKeys componentsJoinedByString:@","] forKey:@"nav_tab_order"];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	UIColor *bg = [SCIPopupChrome backgroundColor] ?: UIColor.systemGroupedBackgroundColor;
	self.view.backgroundColor = bg;
	self.tableView.backgroundColor = bg;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
	return s == 0 ? (NSInteger)self.orderedKeys.count : 1;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
	if (s == 0) return SCILocalized(@"Drag the ≡ handle to reorder tabs. Toggle a tab off to hide it from the bottom navigation bar.");
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

	if (ip.section == 1) {
		UIListContentConfiguration *config = cell.defaultContentConfiguration;
		config.text = SCILocalized(@"Restart Instagram to apply changes");
		config.textProperties.color = [SCIUtils SCIColor_Primary];
		config.image = [SCIIcon sfImageNamed:@"arrow.clockwise" pointSize:18];
		config.imageProperties.tintColor = [SCIUtils SCIColor_Primary];
		config.imageToTextPadding = 14.0;
		cell.contentConfiguration = config;
		return cell;
	}

	if (ip.section == 2) {
		UIListContentConfiguration *config = cell.defaultContentConfiguration;
		config.text = SCILocalized(@"Reset to defaults");
		config.textProperties.color = UIColor.systemRedColor;
		config.image = [SCIIcon imageNamed:@"bcn_arrow-ccw_outline_24" pointSize:18 weight:UIImageSymbolWeightRegular] ?: [UIImage systemImageNamed:@"arrow.counterclockwise"];
		config.imageProperties.tintColor = UIColor.systemRedColor;
		config.imageToTextPadding = 14.0;
		cell.contentConfiguration = config;
		return cell;
	}

	NSDictionary *entry = sciTabEntryForKey(self.orderedKeys[ip.row]);
	[self installRowOnCell:cell entry:entry];
	return cell;
}

- (void)installRowOnCell:(UITableViewCell *)cell entry:(NSDictionary *)entry {
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	cell.shouldIndentWhileEditing = NO;

	UIImageView *icon = [[UIImageView alloc] initWithImage:[SCIIcon imageNamed:entry[@"icon"] pointSize:18] ?: [UIImage systemImageNamed:entry[@"sfFallback"]]];
	icon.translatesAutoresizingMaskIntoConstraints = NO;
	icon.tintColor = UIColor.labelColor;
	icon.contentMode = UIViewContentModeCenter;

	UILabel *label = UILabel.new;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.text = SCILocalized(entry[@"title"]);
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	label.textColor = UIColor.labelColor;
	label.numberOfLines = 1;

	UISwitch *sw = UISwitch.new;
	sw.translatesAutoresizingMaskIntoConstraints = NO;
	sw.on = ![SCIUtils getBoolPref:entry[@"hidePref"]];
	sw.onTintColor = [SCIUtils SCIColor_Primary];
	sw.accessibilityIdentifier = entry[@"hidePref"];
	[sw addTarget:self action:@selector(tabToggleChanged:) forControlEvents:UIControlEventValueChanged];

	UIView *cv = cell.contentView;
	[cv addSubview:icon];
	[cv addSubview:label];
	[cv addSubview:sw];

	UILayoutGuide *m = cv.layoutMarginsGuide;
	[NSLayoutConstraint activateConstraints:@[
		[icon.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
		[icon.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
		[icon.widthAnchor constraintEqualToConstant:24.0],
		[label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12.0],
		[label.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
		[sw.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
		[sw.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
		[label.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-12.0],
	]];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];

	if (ip.section == 1) {
		[SCIUtils showRestartConfirmation];
		return;
	}

	if (ip.section != 2) return;

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@?", SCILocalized(@"Reset to defaults")]
																   message:SCILocalized(@"This will restore the default tab order and unhide all tabs.")
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

	__weak typeof(self) weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Reset") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
		__strong typeof(weakSelf) self = weakSelf;
		if (!self) return;
		[SCIUtils setPref:@"" forKey:@"nav_tab_order"];
		for (NSDictionary *entry in sciTabCatalog())
			[SCIUtils setPref:@(NO) forKey:entry[@"hidePref"]];
		[self loadOrder];
		[self.tableView reloadData];
	}]];

	[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Toggles

- (void)tabToggleChanged:(UISwitch *)sender {
	NSString *hidePref = sender.accessibilityIdentifier;
	if (!hidePref.length) return;
	[SCIUtils setPref:@(!sender.isOn) forKey:hidePref];
}

#pragma mark - Reorder

- (BOOL)isReorderableSection:(NSInteger)section {
	return section == 0;
}

- (void)didMoveRowFromIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
	if (src.row >= (NSInteger)self.orderedKeys.count || dst.row >= (NSInteger)self.orderedKeys.count) return;

	NSString *key = self.orderedKeys[src.row];
	[self.orderedKeys removeObjectAtIndex:src.row];
	[self.orderedKeys insertObject:key atIndex:dst.row];

	[self saveOrder];
}

@end
