#import "SCIBaseSettingsListViewController.h"
#import "../UI/SCIPopupChrome.h"
#import "../Utils.h"

static NSString *const kSCIBaseCell = @"SCIBaseCell";
static NSString *const kSCIBaseCustomCell = @"SCIBaseCustomCell";

@implementation SCIBaseSettingsRow

+ (instancetype)rowWithTitle:(NSString *)title subtitle:(NSString *)subtitle action:(void(^)(UIViewController *vc))action {
	SCIBaseSettingsRow *r = [SCIBaseSettingsRow new];
	r.title = title ?: @"";
	r.subtitle = subtitle;
	r.action = action;
	r.style = SCIBaseSettingsRowStyleNormal;
	r.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
	return r;
}

+ (instancetype)destructiveRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle action:(void(^)(UIViewController *vc))action {
	SCIBaseSettingsRow *r = [self rowWithTitle:title subtitle:subtitle action:action];
	r.style = SCIBaseSettingsRowStyleDestructive;
	r.titleColor = UIColor.systemRedColor;
	r.accessoryType = UITableViewCellAccessoryNone;
	return r;
}

+ (instancetype)switchRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle value:(BOOL(^)(void))value action:(void(^)(BOOL enabled, UIViewController *vc))action {
	SCIBaseSettingsRow *r = [SCIBaseSettingsRow new];
	r.title = title ?: @"";
	r.subtitle = subtitle;
	r.style = SCIBaseSettingsRowStyleSwitch;
	r.switchValue = value;
	r.switchAction = action;
	return r;
}

+ (instancetype)customRowWithHeight:(CGFloat)height provider:(UITableViewCell *(^)(UITableView *tableView, NSIndexPath *indexPath))provider {
	SCIBaseSettingsRow *r = [SCIBaseSettingsRow new];
	r.style = SCIBaseSettingsRowStyleCustom;
	r.customHeight = height;
	r.customCellProvider = provider;
	return r;
}

@end

@implementation SCIBaseSettingsSection

+ (instancetype)sectionWithHeader:(NSString *)header footer:(NSString *)footer rows:(NSArray<SCIBaseSettingsRow *> *)rows {
	SCIBaseSettingsSection *s = [SCIBaseSettingsSection new];
	s.header = header;
	s.footer = footer;
	s.rows = rows ?: @[];
	return s;
}

@end

@interface SCIBaseSettingsListViewController ()
@property (nonatomic, strong, readwrite) UITableView *tableView;
@end

@implementation SCIBaseSettingsListViewController

- (instancetype)initWithTitle:(NSString *)title {
	if ((self = [super init])) {
		self.title = title;
		_sections = @[];
		_reduceTopInset = YES;
	}
	return self;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	SCIUIKit26ConfigureViewController(self);
	SCIUIKit26InstallNavigationTitleBubble(self);

	_tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
	_tableView.dataSource = self;
	_tableView.delegate = self;
	SCIUIKit26ConfigureTableView(_tableView);
	_tableView.rowHeight = UITableViewAutomaticDimension;
	_tableView.estimatedRowHeight = 52.0;
	_tableView.contentInset = UIEdgeInsetsZero;
	_tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
	if (@available(iOS 11.0, *)) _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
	_tableView.translatesAutoresizingMaskIntoConstraints = NO;
	[_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kSCIBaseCell];
	[_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kSCIBaseCustomCell];
	[self.view addSubview:_tableView];

	[NSLayoutConstraint activateConstraints:@[
		[_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
	]];

	[self reloadSettings];
}

- (void)reloadSettings {
	[self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	SCIConfigureNavigationChromeForGlass(self);
	SCIUIKit26RefreshNavigationTitleBubble(self);
}

#pragma mark - Helpers

- (SCIBaseSettingsRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section >= (NSInteger)self.sections.count) return nil;

	NSArray *rows = self.sections[indexPath.section].rows;
	if (indexPath.row >= (NSInteger)rows.count) return nil;

	return rows[indexPath.row];
}

- (void)switchChanged:(UISwitch *)sender {
	NSIndexPath *indexPath = objc_getAssociatedObject(sender, @selector(switchChanged:));
	SCIBaseSettingsRow *row = indexPath ? [self rowAtIndexPath:indexPath] : nil;
	if (row.switchAction) row.switchAction(sender.isOn, self);
}

- (UITableViewCell *)configuredCellForRow:(SCIBaseSettingsRow *)row tableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSCIBaseCell forIndexPath:indexPath];
	SCIUIKit26ConfigureTableCell(cell);
	cell.accessoryView = nil;
	cell.accessoryType = row.accessoryType;
	cell.selectionStyle = row.action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
	cell.contentView.alpha = 1.0;

	UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
	cfg.text = row.dynamicTitle ? row.dynamicTitle() : row.title;
	cfg.secondaryText = row.dynamicSubtitle ? row.dynamicSubtitle() : row.subtitle;
	cfg.textProperties.color = row.titleColor ?: (row.style == SCIBaseSettingsRowStyleDestructive ? UIColor.systemRedColor : UIColor.labelColor);
	cfg.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
	cfg.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	cfg.textToSecondaryTextVerticalPadding = 3.5;
	cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);

	if (row.icon) {
		cfg.image = row.icon;
		cfg.imageToTextPadding = 14.0;
	}

	if (row.accessoryProvider) {
		cell.accessoryView = row.accessoryProvider();
		cell.accessoryType = UITableViewCellAccessoryNone;
	}

	if (row.style == SCIBaseSettingsRowStyleSwitch) {
		UISwitch *sw = [UISwitch new];
		sw.on = row.switchValue ? row.switchValue() : NO;
		sw.onTintColor = [SCIUtils SCIColor_Primary];
		objc_setAssociatedObject(sw, @selector(switchChanged:), indexPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	}

	cell.contentConfiguration = cfg;
	return cell;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
	return self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return section < (NSInteger)self.sections.count ? self.sections[section].rows.count : 0;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	return section < (NSInteger)self.sections.count ? self.sections[section].header : nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	return section < (NSInteger)self.sections.count ? self.sections[section].footer : nil;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	SCIBaseSettingsRow *row = [self rowAtIndexPath:indexPath];
	return row.style == SCIBaseSettingsRowStyleCustom && row.customHeight > 0 ? row.customHeight : UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	SCIBaseSettingsRow *row = [self rowAtIndexPath:indexPath];
	if (!row) return [tableView dequeueReusableCellWithIdentifier:kSCIBaseCell forIndexPath:indexPath];

	if (row.style == SCIBaseSettingsRowStyleCustom && row.customCellProvider) {
		return row.customCellProvider(tableView, indexPath);
	}

	return [self configuredCellForRow:row tableView:tableView indexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	SCIBaseSettingsRow *row = [self rowAtIndexPath:indexPath];

	if (row.action) row.action(self);
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
