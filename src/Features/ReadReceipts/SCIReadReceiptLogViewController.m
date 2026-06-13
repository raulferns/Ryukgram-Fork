#import "SCIReadReceiptLogViewController.h"
#import "SCIReadReceiptModels.h"
#import "SCIReadReceiptStorage.h"
#import "../../UI/SCIPopupChrome.h"
#import "../../SCIImageCache.h"
#import "../StoriesAndMessages/SCIDirectThreadInfo.h"
#import "../../Utils.h"

typedef NS_ENUM(NSInteger, SCIRRDateRange) { SCIRRDateAll = 0, SCIRRDateToday, SCIRRDate7, SCIRRDate30 };
typedef NS_ENUM(NSInteger, SCIRRSort)      { SCIRRSortRecent = 0, SCIRRSortMostReads, SCIRRSortName };

static NSString *rrRelative(NSDate *d) {
    if (!d) return @"";
    if (@available(iOS 13.0, *)) {
        static NSRelativeDateTimeFormatter *f; static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSRelativeDateTimeFormatter new]; });
        return [f localizedStringForDate:d relativeToDate:[NSDate date]];
    }
    return d.description;
}
static NSString *rrAbsolute(NSDate *d) {
    if (!d) return @"";
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterShortStyle; });
    return [f stringFromDate:d];
}
static BOOL rrDateInRange(NSDate *d, SCIRRDateRange r) {
    if (r == SCIRRDateAll || !d) return YES;
    NSTimeInterval age = -[d timeIntervalSinceNow];
    switch (r) {
        case SCIRRDateToday: { NSCalendar *c = NSCalendar.currentCalendar; return [c isDateInToday:d]; }
        case SCIRRDate7:  return age <= 7  * 86400;
        case SCIRRDate30: return age <= 30 * 86400;
        default: return YES;
    }
}

#pragma mark - Avatar helper

static void rrLoadAvatar(UIImageView *iv, NSString *urlStr, NSString *pk) {
    iv.image = [UIImage systemImageNamed:@"person.circle.fill"];
    iv.tintColor = UIColor.systemGray3Color;
    iv.accessibilityValue = urlStr;
    if (!urlStr.length) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    // key by URL (not a stable pk key) so a changed photo actually shows after a refresh
    [SCIImageCache loadImageFromURL:url cacheKey:nil completion:^(UIImage *img) {
        if (img && [iv.accessibilityValue isEqualToString:urlStr]) iv.image = img;
    }];
}

#pragma mark - Seen tracking

static NSString *const kSCIRRSeenPrefKey = @"read_receipts_seen";

static NSString *rrSeenKey(NSString *ownerPk, NSString *identifier) {
    return [NSString stringWithFormat:@"%@:%@", ownerPk ?: @"", identifier ?: @""];
}

static NSTimeInterval rrSeenTimestamp(NSString *ownerPk, NSString *identifier) {
    NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:kSCIRRSeenPrefKey];
    id v = all[rrSeenKey(ownerPk, identifier)];
    return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 0;
}

static void rrMarkGroupSeen(NSString *ownerPk, NSString *identifier) {
    if (!identifier.length) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *m = [[d dictionaryForKey:kSCIRRSeenPrefKey] ?: @{} mutableCopy];
    m[rrSeenKey(ownerPk, identifier)] = @(NSDate.date.timeIntervalSince1970);
    [d setObject:m forKey:kSCIRRSeenPrefKey];
    [d synchronize];
}

static NSUInteger rrUnseenCountForGroup(SCIReadReceiptGroup *g, NSString *ownerPk) {
    NSTimeInterval seen = rrSeenTimestamp(ownerPk, g.identifier);
    if (seen <= 0) return g.count;
    NSUInteger n = 0;
    for (SCIReadReceipt *r in g.receipts)
        if (r.readAt.timeIntervalSince1970 > seen) n++;
    return n;
}

#pragma mark - Cell

@interface SCIRRGroupCell : UITableViewCell
@property (nonatomic, strong) UIImageView *avatar;
@property (nonatomic, strong) UILabel *titleLbl;
@property (nonatomic, strong) UILabel *subLbl;
@property (nonatomic, strong) UIImageView *mutedIcon;
@property (nonatomic, strong) UIView *countBadge;
@property (nonatomic, strong) UILabel *countLabel;
@end
@implementation SCIRRGroupCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) {
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        _avatar = [UIImageView new];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.layer.cornerRadius = 23; _avatar.layer.masksToBounds = YES;
        _avatar.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _titleLbl = [UILabel new]; _titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _subLbl = [UILabel new]; _subLbl.font = [UIFont systemFontOfSize:13]; _subLbl.textColor = UIColor.secondaryLabelColor;
        _mutedIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill"]];
        _mutedIcon.tintColor = UIColor.systemGray3Color; _mutedIcon.contentMode = UIViewContentModeScaleAspectFit;
        _countBadge = [UIView new];
        _countBadge.layer.cornerRadius = 10; _countBadge.layer.masksToBounds = YES;
        _countBadge.backgroundColor = UIColor.systemRedColor;
        _countBadge.hidden = YES;
        _countLabel = [UILabel new];
        _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _countLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _countLabel.textColor = UIColor.whiteColor;
        _countLabel.textAlignment = NSTextAlignmentCenter;
        [_countBadge addSubview:_countLabel];
        for (UIView *v in @[_avatar, _titleLbl, _subLbl, _mutedIcon, _countBadge]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
        [NSLayoutConstraint activateConstraints:@[
            [_avatar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_avatar.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_avatar.widthAnchor constraintEqualToConstant:46], [_avatar.heightAnchor constraintEqualToConstant:46],
            [_titleLbl.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:12],
            [_titleLbl.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:_mutedIcon.leadingAnchor constant:-8],
            [_subLbl.leadingAnchor constraintEqualToAnchor:_titleLbl.leadingAnchor],
            [_subLbl.topAnchor constraintEqualToAnchor:_titleLbl.bottomAnchor constant:3],
            [_subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:_mutedIcon.leadingAnchor constant:-8],
            [_subLbl.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [_mutedIcon.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_mutedIcon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_mutedIcon.widthAnchor constraintEqualToConstant:18], [_mutedIcon.heightAnchor constraintEqualToConstant:18],
            [_countBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_countBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_countBadge.heightAnchor constraintEqualToConstant:20],
            [_countBadge.widthAnchor constraintGreaterThanOrEqualToConstant:24],
            [_countLabel.topAnchor constraintEqualToAnchor:_countBadge.topAnchor],
            [_countLabel.bottomAnchor constraintEqualToAnchor:_countBadge.bottomAnchor],
            [_countLabel.leadingAnchor constraintEqualToAnchor:_countBadge.leadingAnchor constant:6],
            [_countLabel.trailingAnchor constraintEqualToAnchor:_countBadge.trailingAnchor constant:-6],
        ]];
    }
    return self;
}
@end

#pragma mark - Detail (one chat's receipts)

@interface SCIRRDetailViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *threadId, *navTitle, *readerPicURL, *readerPk, *ownerPK;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<SCIReadReceipt *> *receipts;
@end
@implementation SCIRRDetailViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SCIPopupChrome backgroundColor];
    self.title = self.navTitle.length ? self.navTitle : SCILocalized(@"Reads");
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SCIReadReceiptsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reload {
    self.receipts = [SCIReadReceiptStorage receiptsForThreadId:self.threadId ownerPK:self.ownerPK];
    [self.tableView reloadData];
}
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, t.bounds.size.width, 92)];
    UIImageView *av = [UIImageView new];
    av.translatesAutoresizingMaskIntoConstraints = NO;
    av.contentMode = UIViewContentModeScaleAspectFill;
    av.layer.cornerRadius = 32; av.layer.masksToBounds = YES;
    if (self.isGroup && !self.readerPicURL.length) { av.image = [UIImage systemImageNamed:@"person.2.circle.fill"]; av.tintColor = UIColor.systemGray2Color; }
    else rrLoadAvatar(av, self.readerPicURL, self.isGroup ? self.threadId : self.readerPk);
    [h addSubview:av];
    [NSLayoutConstraint activateConstraints:@[
        [av.centerXAnchor constraintEqualToAnchor:h.centerXAnchor],
        [av.topAnchor constraintEqualToAnchor:h.topAnchor constant:14],
        [av.widthAnchor constraintEqualToConstant:64],
        [av.heightAnchor constraintEqualToConstant:64],
    ]];
    return h;
}
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s { return 92; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.receipts.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    SCIRRGroupCell *c = [t dequeueReusableCellWithIdentifier:@"d"];
    if (!c) c = [[SCIRRGroupCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
    SCIReadReceipt *r = self.receipts[ip.row];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.mutedIcon.hidden = YES;
    c.contentView.alpha = 1.0;
    c.titleLbl.numberOfLines = 0;
    c.titleLbl.font = [UIFont systemFontOfSize:15];
    NSString *who = r.readerUsername.length ? [@"@" stringByAppendingString:r.readerUsername] : r.readerPk;
    NSString *msg = r.messagePreview.length ? r.messagePreview : SCILocalized(@"Your message");
    c.titleLbl.text = self.isGroup ? [NSString stringWithFormat:@"%@ — %@", who, msg] : msg;
    c.subLbl.text = [NSString stringWithFormat:SCILocalized(@"Read %@ · %@"), rrRelative(r.readAt), rrAbsolute(r.readAt)];
    rrLoadAvatar(c.avatar, r.readerProfilePicURL, r.readerPk);
    return c;
}
@end

#pragma mark - Ignored management

@interface SCIRRIgnoredViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *ownerPK;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *ids;            // raw exclude identifiers
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *pkNames;      // pk -> username
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *threadTitles; // threadId -> group name
@end
@implementation SCIRRIgnoredViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SCILocalized(@"Ignored");
    self.view.backgroundColor = [SCIPopupChrome backgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:SCILocalized(@"Clear all") style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SCIReadReceiptsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reload {
    self.ids = [SCIReadReceiptStorage excludedIdentifiersForOwnerPK:self.ownerPK];
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSMutableDictionary *tt = [NSMutableDictionary dictionary];
    for (SCIReadReceipt *r in [SCIReadReceiptStorage allReceiptsForOwnerPK:self.ownerPK]) {
        if (r.readerPk && r.readerUsername) m[r.readerPk] = r.readerUsername;
        if (r.isGroup && r.threadId && r.threadTitle.length) tt[r.threadId] = r.threadTitle;
    }
    self.pkNames = m;
    self.threadTitles = tt;
    self.navigationItem.rightBarButtonItem.enabled = self.ids.count > 0;
    [self.tableView reloadData];
}
- (void)clearAll {
    for (NSString *id_ in self.ids.copy) {
        if ([id_ hasPrefix:@"u:"]) [SCIReadReceiptStorage setReader:[id_ substringFromIndex:2] excluded:NO ownerPK:self.ownerPK];
        else [SCIReadReceiptStorage setThread:id_ excluded:NO ownerPK:self.ownerPK];
    }
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.ids.count; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return self.ids.count ? SCILocalized(@"Swipe to remove. Removing resumes logging for that person or chat.") : SCILocalized(@"Nothing is ignored. Long-press someone in the log to stop logging them.");
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"i"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"i"];
    c.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    NSString *id_ = self.ids[ip.row];
    if ([id_ hasPrefix:@"u:"]) {
        NSString *pk = [id_ substringFromIndex:2];
        c.textLabel.text = self.pkNames[pk] ? [@"@" stringByAppendingString:self.pkNames[pk]] : pk;
        c.detailTextLabel.text = SCILocalized(@"Person");
    } else {
        c.textLabel.text = self.threadTitles[id_] ?: SCILocalized(@"Group chat");
        c.detailTextLabel.text = SCILocalized(@"Chat");
    }
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"eye.slash"];
    c.imageView.tintColor = UIColor.systemGray2Color;
    return c;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *id_ = self.ids[ip.row];
    NSString *owner = self.ownerPK;
    UIContextualAction *rm = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:SCILocalized(@"Remove") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if ([id_ hasPrefix:@"u:"]) [SCIReadReceiptStorage setReader:[id_ substringFromIndex:2] excluded:NO ownerPK:owner];
        else [SCIReadReceiptStorage setThread:id_ excluded:NO ownerPK:owner];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[rm]];
}
@end

#pragma mark - Main list

@interface SCIReadReceiptLogViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) NSArray<SCIReadReceiptGroup *> *allGroups;
@property (nonatomic, strong) NSArray<SCIReadReceiptGroup *> *visible;
@property (nonatomic, copy) NSString *ownerPK;
@property (nonatomic, assign) SCIRRDateRange dateRange;
@property (nonatomic, assign) SCIRRSort sort;
@property (nonatomic, strong) UIBarButtonItem *filterItem;
@end

@implementation SCIReadReceiptLogViewController

+ (void)load {
    [SCINotificationCenter.shared setDefaultTapProvider:^void (^(void))(void) {
        if (![SCIUtils getBoolPref:@"read_receipts_save_log"]) return (void (^)(void))nil;
        return ^{ [SCIReadReceiptLogViewController presentFromViewController:nil]; };
    } ownerVCClass:[SCIReadReceiptLogViewController class]
      forAction:SCI_NOTIF_READ_RECEIPT];
}

+ (void)presentFromViewController:(UIViewController *)presenter {
    [SCIPopupChrome presentVC:[SCIReadReceiptLogViewController new] from:presenter];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.ownerPK = [SCIUtils currentUserPK];
    self.title = SCILocalized(@"Read receipts");
    self.view.backgroundColor = [SCIPopupChrome backgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.rowHeight = 70;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    [self.tableView registerClass:[SCIRRGroupCell class] forCellReuseIdentifier:@"g"];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 32, 0)];
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyLabel.numberOfLines = 0; self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.text = SCILocalized(@"No read receipts yet.\nWhen someone reads a message you sent, it shows up here.");
    [self.view addSubview:self.emptyLabel];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = SCILocalized(@"Search by username");
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // X close lives on the left (auto-injected by SCIPopupChrome). Our controls go on the right.
    self.filterItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] menu:[self filterMenu]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self moreMenu]];
    self.navigationItem.rightBarButtonItems = @[more, self.filterItem];

    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SCIReadReceiptsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (UIMenu *)filterMenu {
    __weak typeof(self) ws = self;
    UIAction *(^d)(NSString *, SCIRRDateRange) = ^(NSString *t, SCIRRDateRange r) {
        UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *x){ ws.dateRange = r; [ws applyFilter]; [ws refreshMenus]; }];
        a.state = ws.dateRange == r ? UIMenuElementStateOn : UIMenuElementStateOff; return a;
    };
    UIMenu *date = [UIMenu menuWithTitle:SCILocalized(@"Date") image:[UIImage systemImageNamed:@"calendar"] identifier:nil options:UIMenuOptionsDisplayInline children:@[
        d(SCILocalized(@"All time"), SCIRRDateAll), d(SCILocalized(@"Today"), SCIRRDateToday), d(SCILocalized(@"Last 7 days"), SCIRRDate7), d(SCILocalized(@"Last 30 days"), SCIRRDate30) ]];
    UIAction *(^so)(NSString *, SCIRRSort) = ^(NSString *t, SCIRRSort s) {
        UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *x){ ws.sort = s; [ws applyFilter]; [ws refreshMenus]; }];
        a.state = ws.sort == s ? UIMenuElementStateOn : UIMenuElementStateOff; return a;
    };
    UIMenu *sort = [UIMenu menuWithTitle:SCILocalized(@"Sort") image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:UIMenuOptionsDisplayInline children:@[
        so(SCILocalized(@"Most recent"), SCIRRSortRecent), so(SCILocalized(@"Most reads"), SCIRRSortMostReads), so(SCILocalized(@"Username"), SCIRRSortName) ]];
    return [UIMenu menuWithTitle:@"" children:@[date, sort]];
}
- (UIMenu *)moreMenu {
    __weak typeof(self) ws = self;
    UIAction *refresh = [UIAction actionWithTitle:SCILocalized(@"Refresh names & photos") image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *x){ [ws refreshMetadata]; }];
    UIAction *ignored = [UIAction actionWithTitle:SCILocalized(@"Ignored people & chats") image:[UIImage systemImageNamed:@"eye.slash"] identifier:nil handler:^(UIAction *x){
        SCIRRIgnoredViewController *v = [SCIRRIgnoredViewController new]; v.ownerPK = ws.ownerPK;
        [ws.navigationController pushViewController:v animated:YES];
    }];
    UIAction *clear = [UIAction actionWithTitle:SCILocalized(@"Clear all records") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *x){ [ws confirmReset]; }];
    clear.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:@"" children:@[refresh, ignored, clear]];
}

// Re-pull group name/image + reader usernames/photos from the live threads onto stored records.
- (void)refreshMetadata {
    NSString *owner = self.ownerPK;
    for (SCIReadReceiptGroup *g in self.allGroups) {
        NSString *tid = g.threadId; BOOL grp = g.isGroup;
        if (!tid.length) continue;
        [SCIDirectThreadInfo fetchThreadId:tid ownerPK:owner completion:^(id thread) {
            if (!thread) return;
            if (grp) {
                NSDictionary *gi = [SCIDirectThreadInfo groupInfoForThread:thread viewerPK:owner];
                [SCIReadReceiptStorage applyThreadTitle:gi[@"name"] avatarURL:gi[@"image"] forThreadId:tid ownerPK:owner];
            }
            NSDictionary *parts = [SCIDirectThreadInfo participantsForThread:thread];
            [parts enumerateKeysAndObjectsUsingBlock:^(NSString *pk, NSDictionary *info, BOOL *stop) {
                [SCIReadReceiptStorage applyReaderUsername:info[@"username"] profilePicURL:info[@"profile_pic_url"] forReaderPK:pk ownerPK:owner];
            }];
        }];
    }
    SCINotifyInfo(SCI_NOTIF_GENERIC, SCILocalized(@"Refreshing…"), SCILocalized(@"Updating names and photos"));
}
- (void)refreshMenus {
    self.filterItem.menu = [self filterMenu];
}

- (void)reload {
    self.allGroups = [SCIReadReceiptStorage groupedByThreadForOwnerPK:self.ownerPK];
    [self applyFilter];
}

- (BOOL)groupIgnored:(SCIReadReceiptGroup *)g {
    return g.isGroup ? [SCIReadReceiptStorage isThreadExcluded:g.threadId ownerPK:self.ownerPK]
                     : [SCIReadReceiptStorage isReaderExcluded:g.readerPk ownerPK:self.ownerPK];
}

- (void)applyFilter {
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSMutableArray *out = [NSMutableArray array];
    for (SCIReadReceiptGroup *g in self.allGroups) {
        if (q.length) {
            NSString *title = g.displayTitle.lowercaseString ?: @"";
            BOOL hit = [title containsString:q] || [(g.readerPk ?: @"") containsString:q];
            if (!hit && g.isGroup) for (SCIReadReceipt *r in g.distinctReaders) // search group members too
                if ([(r.readerUsername.lowercaseString ?: @"") containsString:q]) { hit = YES; break; }
            if (!hit) continue;
        }
        if (!rrDateInRange(g.lastReadAt, self.dateRange)) continue;
        [out addObject:g];
    }
    if (self.sort == SCIRRSortMostReads)
        [out sortUsingComparator:^NSComparisonResult(SCIReadReceiptGroup *a, SCIReadReceiptGroup *b){ return [@(b.count) compare:@(a.count)]; }];
    else if (self.sort == SCIRRSortName)
        [out sortUsingComparator:^NSComparisonResult(SCIReadReceiptGroup *a, SCIReadReceiptGroup *b){ return [a.displayTitle caseInsensitiveCompare:b.displayTitle]; }];
    // SCIRRSortRecent: storage already returns newest-first
    self.visible = out;
    self.emptyLabel.hidden = out.count > 0;
    if (out.count == 0 && self.allGroups.count > 0)
        self.emptyLabel.text = SCILocalized(@"Nothing matches your filters.");
    else
        self.emptyLabel.text = SCILocalized(@"No read receipts yet.\nWhen someone reads a message you sent, it shows up here.");
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self applyFilter]; }

- (void)confirmReset {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:SCILocalized(@"Clear read receipts?") message:SCILocalized(@"This removes all recorded reads on this device.") preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Clear") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [SCIReadReceiptStorage resetForOwnerPK:self.ownerPK];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.visible.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    SCIRRGroupCell *c = [t dequeueReusableCellWithIdentifier:@"g" forIndexPath:ip];
    SCIReadReceiptGroup *g = self.visible[ip.row];
    BOOL ignored = [self groupIgnored:g];
    c.titleLbl.text = g.displayTitle;
    NSString *base = [NSString stringWithFormat:(g.count == 1 ? SCILocalized(@"%lu read · %@") : SCILocalized(@"%lu reads · %@")), (unsigned long)g.count, rrRelative(g.lastReadAt)];
    if (g.isGroup) {
        NSUInteger members = g.distinctReaders.count;
        base = [NSString stringWithFormat:(members == 1 ? SCILocalized(@"%lu reads · %lu reader · %@") : SCILocalized(@"%lu reads · %lu readers · %@")), (unsigned long)g.count, (unsigned long)members, rrRelative(g.lastReadAt)];
    }
    c.subLbl.text = ignored ? [SCILocalized(@"Ignored") stringByAppendingFormat:@" · %@", base] : base;
    NSUInteger unseen = ignored ? 0 : rrUnseenCountForGroup(g, self.ownerPK);
    c.countLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)unseen];
    c.countBadge.hidden = unseen == 0;
    c.mutedIcon.hidden = !ignored;
    c.contentView.alpha = ignored ? 0.5 : 1.0;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (g.isGroup && !g.displayAvatarURL.length) { c.avatar.image = [UIImage systemImageNamed:@"person.2.circle.fill"]; c.avatar.tintColor = UIColor.systemGray2Color; c.avatar.accessibilityValue = nil; }
    else rrLoadAvatar(c.avatar, g.displayAvatarURL, g.isGroup ? g.threadId : g.readerPk);
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    SCIReadReceiptGroup *g = self.visible[ip.row];
    rrMarkGroupSeen(self.ownerPK, g.identifier);
    [t reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    SCIRRDetailViewController *d = [SCIRRDetailViewController new];
    d.threadId = g.threadId; d.isGroup = g.isGroup; d.navTitle = g.displayTitle;
    d.readerPk = g.readerPk; d.readerPicURL = g.displayAvatarURL; d.ownerPK = self.ownerPK;
    [self.navigationController pushViewController:d animated:YES];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)t contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    SCIReadReceiptGroup *g = self.visible[ip.row];
    NSString *owner = self.ownerPK;
    NSString *who = g.displayTitle;
    BOOL ignored = [self groupIgnored:g];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *excl = [UIAction actionWithTitle:ignored ? SCILocalized(@"Resume logging") : [NSString stringWithFormat:SCILocalized(@"Stop logging %@"), who]
            image:[UIImage systemImageNamed:ignored ? @"eye" : @"eye.slash"] identifier:nil handler:^(UIAction *action) {
            if (g.isGroup) [SCIReadReceiptStorage setThread:g.threadId excluded:!ignored ownerPK:owner];
            else [SCIReadReceiptStorage setReader:g.readerPk excluded:!ignored ownerPK:owner];
        }];
        UIAction *del = [UIAction actionWithTitle:SCILocalized(@"Delete records") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            if (g.isGroup) [SCIReadReceiptStorage deleteReceiptsForThreadId:g.threadId ownerPK:owner];
            else [SCIReadReceiptStorage deleteReceiptsForReaderPK:g.readerPk ownerPK:owner];
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:who children:@[excl, del]];
    }];
}

@end
