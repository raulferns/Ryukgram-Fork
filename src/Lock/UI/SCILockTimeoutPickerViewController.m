#import "SCILockTimeoutPickerViewController.h"

#import "../SCILockGroups.h"

#import "../../UI/SCIPopupChrome.h"
#import "../../Utils.h"
#import "../../Localization/SCILocalization.h"

@interface SCILockTimeoutPickerViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSString *groupID;
@property (nonatomic, copy) NSArray<NSNumber *> *options;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation SCILockTimeoutPickerViewController

- (instancetype)initWithGroupID:(NSString *)groupID {
	if ((self = [super init])) {
		_groupID = [groupID copy];
		_options = @[
			@0,
			@30,
			@60,
			@300,
			@900,
			@1800,
			@3600
		];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);

	self.title = SCILocalized(@"Auto-relock after idle");
	self.view.backgroundColor = SCIUIKit26BaseSurfaceColor();
	self.navigationController.navigationBar.prefersLargeTitles = NO;

	self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.contentInset = UIEdgeInsetsZero;
	self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
	self.tableView.estimatedRowHeight = 52.0;
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;

	[self.view addSubview:self.tableView];
}

#pragma mark - Helpers

- (UIColor *)primaryColor {
	return [SCIUtils SCIColor_Primary] ?: UIColor.systemBlueColor;
}

- (double)currentTimeout {
	return [SCIUtils getDoublePref:SCILockPrefIdleTimeout(self.groupID)];
}

- (NSString *)labelForSeconds:(double)seconds {
	if (seconds <= 0.0) {
		return SCILocalized(@"Never");
	}

	if (seconds < 60.0) {
		return [NSString stringWithFormat:SCILocalized(@"%lds"), (long)seconds];
	}

	if (seconds < 3600.0) {
		return [NSString stringWithFormat:SCILocalized(@"%ld min"), (long)(seconds / 60.0)];
	}

	return [NSString stringWithFormat:SCILocalized(@"%ld h"), (long)(seconds / 3600.0)];
}

- (NSString *)subtitleForSeconds:(double)seconds {
	if (seconds <= 0.0) {
		return SCILocalized(@"Stay unlocked until app close or background");
	}

	if (seconds == 30.0) {
		return SCILocalized(@"Best for sensitive sections");
	}

	if (seconds == 60.0) {
		return SCILocalized(@"Short idle window");
	}

	if (seconds == 300.0) {
		return SCILocalized(@"Balanced default");
	}

	if (seconds == 900.0 || seconds == 1800.0) {
		return SCILocalized(@"Less frequent prompts");
	}

	return SCILocalized(@"Longest idle window");
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
	return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
	return self.options.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
	return SCILocalized(@"Choose how long this section stays unlocked while idle. Never keeps it unlocked until Instagram closes or goes to background.");
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.row >= (NSInteger)self.options.count) {
		return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	}

	double seconds = self.options[indexPath.row].doubleValue;
	double current = [self currentTimeout];
	BOOL selected = (NSInteger)current == (NSInteger)seconds;

	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

	UIListContentConfiguration *config = cell.defaultContentConfiguration;
	config.text = [self labelForSeconds:seconds];
	config.textProperties.color = UIColor.labelColor;

	NSString *subtitle = [self subtitleForSeconds:seconds];
	if (subtitle.length) {
		config.secondaryText = subtitle;
		config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
		config.textToSecondaryTextVerticalPadding = 4.5;
	}

	cell.contentConfiguration = config;
	cell.tintColor = [self primaryColor];
	cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	if (indexPath.row >= (NSInteger)self.options.count) return;

	double seconds = self.options[indexPath.row].doubleValue;

	[[NSUserDefaults standardUserDefaults] setObject:@(seconds) forKey:SCILockPrefIdleTimeout(self.groupID)];

	[[NSNotificationCenter defaultCenter] postNotificationName:SCILockPrefsDidChangeNotification
														object:self.groupID];

	[self.tableView reloadData];
	[self.navigationController popViewControllerAnimated:YES];
}

@end
