#import "SCILockGroupDetailViewController.h"

#import "SCILockedChatsViewController.h"
#import "SCILockTimeoutPickerViewController.h"

#import "../SCILockManager.h"
#import "../SCILockGroups.h"

#import "../../UI/SCIPopupChrome.h"
#import "../../UI/SCIIcon.h"
#import "../../Utils.h"
#import "../../Localization/SCILocalization.h"

#import <objc/runtime.h>

@interface SCILockGroupDetailViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSString *groupID;
@property (nonatomic, strong) SCILockGroupInfo *info;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation SCILockGroupDetailViewController

- (instancetype)initWithGroupID:(NSString *)groupID {
	if ((self = [super init])) {
		_groupID = [groupID copy];
		_info = SCILockGroupInfoFor(groupID);
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);

	self.title = self.info.displayName;
	self.view.backgroundColor = SCIUIKit26BaseSurfaceColor();
	self.navigationController.navigationBar.prefersLargeTitles = NO;

	self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
	self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.contentInset = UIEdgeInsetsZero;
	self.tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
	self.tableView.estimatedRowHeight = 58.0;
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.dataSource = self;
	self.tableView.delegate = self;

	[self.view addSubview:self.tableView];

	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(prefsChanged:)
												 name:SCILockPrefsDidChangeNotification
											   object:nil];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (void)prefsChanged:(__unused NSNotification *)note {
	if (NSThread.isMainThread) {
		[self.tableView reloadData];
		return;
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		[self.tableView reloadData];
	});
}

#pragma mark - State

- (BOOL)isChats {
	return [self.groupID isEqualToString:SCILockGroupChats];
}

- (UIColor *)primaryColor {
	return [SCIUtils SCIColor_Primary] ?: UIColor.systemBlueColor;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
	return [self isChats] ? 3 : 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (section == 0) return 1;
	if (section == 1) return 4;
	return [self isChats] ? 2 : 0;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (section == 1) return SCILocalized(@"Behavior");
	if (section == 2) return SCILocalized(@"Locked chats");
	return nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == 0) return self.info.displayDescription;

	if (section == 1) {
		return SCILocalized(@"Lock every time overrides idle timeout. Don't share unlock keeps this target separate.");
	}

	return nil;
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.section == 0) return [self enabledCell];

	if (indexPath.section == 1) {
		if (indexPath.row == 0) return [self relockOnDismissCell];
		if (indexPath.row == 1) return [self relockOnBackgroundCell];
		if (indexPath.row == 2) return [self idleTimeoutCell];
		return [self independentSessionCell];
	}

	if (indexPath.row == 0) return [self hidePreviewCell];
	return [self manageChatsCell];
}

#pragma mark - Cell Helpers

- (UITableViewCell *)baseCellWithTitle:(NSString *)title
							  subtitle:(NSString *)subtitle
								  image:(UIImage *)image
							  tintColor:(UIColor *)tintColor {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

	UIListContentConfiguration *config = cell.defaultContentConfiguration;
	config.text = title;
	config.textProperties.color = UIColor.labelColor;

	if (subtitle.length) {
		config.secondaryText = subtitle;
		config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
		config.textToSecondaryTextVerticalPadding = 4.5;
	}

	if (image) {
		config.image = image;
		config.imageProperties.tintColor = tintColor ?: UIColor.labelColor;
		config.imageProperties.maximumSize = CGSizeMake(24.0, 24.0);
		config.imageToTextPadding = 14.0;
	}

	cell.contentConfiguration = config;
	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.accessoryView = nil;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	return cell;
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
								subtitle:(NSString *)subtitle
									icon:(NSString *)icon
								 prefKey:(NSString *)key {
	UIImage *image = icon.length ? [SCIIcon imageNamed:icon pointSize:22.0] : nil;

	UITableViewCell *cell = [self baseCellWithTitle:title
										   subtitle:subtitle
											  image:image
										  tintColor:icon.length ? UIColor.labelColor : nil];

	UISwitch *toggle = UISwitch.new;
	toggle.on = [SCIUtils getBoolPref:key];
	toggle.onTintColor = [self primaryColor];

	objc_setAssociatedObject(toggle, @selector(currentPrefKey), key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[toggle addTarget:self action:@selector(onSwitchToggle:) forControlEvents:UIControlEventValueChanged];

	cell.accessoryView = toggle;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	return cell;
}

- (UITableViewCell *)valueCellWithTitle:(NSString *)title
								  value:(NSString *)value
								   icon:(NSString *)icon
							   disabled:(BOOL)disabled {
	UITableViewCell *cell = [self baseCellWithTitle:title
										   subtitle:nil
											  image:[SCIIcon imageNamed:icon pointSize:22.0]
										  tintColor:disabled ? UIColor.tertiaryLabelColor : UIColor.labelColor];

	UIListContentConfiguration *config = (UIListContentConfiguration *)cell.contentConfiguration;
	config.textProperties.color = disabled ? UIColor.tertiaryLabelColor : UIColor.labelColor;
	cell.contentConfiguration = config;

	UILabel *label = UILabel.new;
	label.text = value;
	label.font = [UIFont systemFontOfSize:16.0];
	label.textColor = disabled ? UIColor.tertiaryLabelColor : UIColor.secondaryLabelColor;
	[label sizeToFit];

	cell.accessoryView = label;
	cell.userInteractionEnabled = !disabled;
	cell.selectionStyle = disabled ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;

	if (!disabled) {
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.accessoryView = nil;
	}

	return cell;
}

#pragma mark - Cells

- (UITableViewCell *)enabledCell {
	return [self switchCellWithTitle:SCILocalized(@"Enable lock")
							subtitle:SCILocalized(@"Require passcode for this section")
								icon:nil
							 prefKey:SCILockPrefEnabled(self.groupID)];
}

- (UITableViewCell *)relockOnDismissCell {
	return [self switchCellWithTitle:SCILocalized(@"Lock every time")
							subtitle:SCILocalized(@"Always ask when opening again")
								icon:@"ig_icon_lock_prism_filled_24"
							 prefKey:SCILockPrefRelockOnDismiss(self.groupID)];
}

- (UITableViewCell *)relockOnBackgroundCell {
	return [self switchCellWithTitle:SCILocalized(@"Re-lock on background")
							subtitle:SCILocalized(@"Ask again after Instagram returns")
								icon:@"ig_icon_moon_outline_24"
							 prefKey:SCILockPrefRelockOnBackground(self.groupID)];
}

- (UITableViewCell *)independentSessionCell {
	return [self switchCellWithTitle:SCILocalized(@"Don't share unlock")
							subtitle:SCILocalized(@"Keep this target locked separately")
								icon:@"bcn_circle-subtract_outline_24"
							 prefKey:SCILockPrefIndependentSession(self.groupID)];
}

- (UITableViewCell *)idleTimeoutCell {
	BOOL everyUse = [SCIUtils getBoolPref:SCILockPrefRelockOnDismiss(self.groupID)];

	return [self valueCellWithTitle:SCILocalized(@"Idle timeout")
							  value:[self timeoutDisplayString]
							   icon:@"ig_icon_clock_dotted_pano_outline_24"
						   disabled:everyUse];
}

- (UITableViewCell *)hidePreviewCell {
	return [self switchCellWithTitle:SCILocalized(@"Hide message preview")
							subtitle:SCILocalized(@"Replace inbox preview with • • •")
								icon:@"ig_icon_news_off_outline_24"
							 prefKey:@"lock_chats_hide_preview"];
}

- (UITableViewCell *)manageChatsCell {
	NSInteger count = [[SCILockManager shared] lockedChatIDs].count;
	NSString *value = [NSString stringWithFormat:@"%ld", (long)count];

	UITableViewCell *cell = [self valueCellWithTitle:SCILocalized(@"Manage locked chats")
											  value:value
											   icon:@"ig_icon_edit_list_outline_24"
										   disabled:NO];

	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

#pragma mark - Values

- (NSString *)timeoutDisplayString {
	if ([SCIUtils getBoolPref:SCILockPrefRelockOnDismiss(self.groupID)]) {
		return SCILocalized(@"Every use");
	}

	double timeout = [SCIUtils getDoublePref:SCILockPrefIdleTimeout(self.groupID)];

	if (timeout <= 0.0) return SCILocalized(@"Never");
	if (timeout < 60.0) return [NSString stringWithFormat:SCILocalized(@"%lds"), (long)timeout];

	long minutes = (long)(timeout / 60.0);
	if (minutes < 60) return [NSString stringWithFormat:SCILocalized(@"%ld min"), minutes];

	return [NSString stringWithFormat:SCILocalized(@"%ld h"), minutes / 60];
}

#pragma mark - Actions

- (void)onSwitchToggle:(UISwitch *)sender {
	NSString *key = objc_getAssociatedObject(sender, @selector(currentPrefKey));
	if (!key.length) return;

	[[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];

	if (sender.isOn && [key isEqualToString:SCILockPrefEnabled(self.groupID)]) {
		[[SCILockManager shared] markGroupLocked:self.groupID];
	}

	[[NSNotificationCenter defaultCenter] postNotificationName:SCILockPrefsDidChangeNotification object:self.groupID];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	if (indexPath.section == 1 && indexPath.row == 2) {
		if ([SCIUtils getBoolPref:SCILockPrefRelockOnDismiss(self.groupID)]) return;

		SCILockTimeoutPickerViewController *vc = [[SCILockTimeoutPickerViewController alloc] initWithGroupID:self.groupID];
		[self.navigationController pushViewController:vc animated:YES];
		return;
	}

	if (indexPath.section == 2 && indexPath.row == 1) {
		[self.navigationController pushViewController:SCILockedChatsViewController.new animated:YES];
	}
}

@end
