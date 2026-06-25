#import "SCIDogfoodBrowserViewController.h"
#import "../Features/MobileConfig/SCIMobileConfigRuntime.h"
#import "../Features/Dogfooding/SCIDogfoodObjectRuntime.h"
#import "../Features/Dogfooding/SCILauncherOverride.h"
#import "../Features/Dogfooding/SCIInternalActions.h"
#import "../Utils.h"

static NSString *SCIDFBrowserString(id value) {
    if (!value || value == (id)kCFNull) return @"";
    @try { return [[value description] copy] ?: @""; } @catch (__unused id ex) { return @"<exception>"; }
}

static NSString *SCIDFBrowserJSON(id object) {
    if (!object) return @"";
    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text.length) return text;
    }
    return SCIDFBrowserString(object);
}

static NSString *SCIDFBrowserJoined(id value) {
    if ([value isKindOfClass:NSArray.class]) return [(NSArray *)value componentsJoinedByString:@", "];
    return SCIDFBrowserString(value);
}

static NSString *SCIDFBrowserHaystack(id value) {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableString *s = [NSMutableString string];
        NSDictionary *d = (NSDictionary *)value;
        for (id key in d) {
            [s appendFormat:@" %@ %@", SCIDFBrowserString(key), SCIDFBrowserHaystack(d[key])];
        }
        return s;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableString *s = [NSMutableString string];
        for (id item in (NSArray *)value) [s appendFormat:@" %@", SCIDFBrowserHaystack(item)];
        return s;
    }
    return SCIDFBrowserString(value);
}

static BOOL SCIDFBrowserMatches(id value, NSString *query) {
    if (!query.length) return YES;
    return [[SCIDFBrowserHaystack(value) lowercaseString] containsString:query.lowercaseString];
}

static NSString *SCIDFBrowserBoolBadge(BOOL value) { return value ? @"ON" : @"OFF"; }

static BOOL SCIDFNativeReady(NSDictionary *state) {
    return [state[@"launcherRespondsOpenWithConfig"] boolValue] &&
           [state[@"viewControllerRespondsInitWithConfig"] boolValue] &&
           ![SCIDFBrowserString(state[@"config"]) isEqualToString:@"nil"] &&
           ![SCIDFBrowserString(state[@"session"]) isEqualToString:@"nil"] &&
           ![SCIDFBrowserString(state[@"topViewController"]) isEqualToString:@"nil"];
}

@interface SCIDogfoodJSONDetailViewController : UIViewController
@property (nonatomic, copy) NSString *detailTitle;
@property (nonatomic, copy) NSString *detailText;
@property (nonatomic, strong) UITextView *textView;
- (instancetype)initWithTitle:(NSString *)title object:(id)object;
@end

@implementation SCIDogfoodJSONDetailViewController

- (instancetype)initWithTitle:(NSString *)title object:(id)object {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _detailTitle = [title copy] ?: @"Details";
        _detailText = [SCIDFBrowserJSON(object) copy] ?: @"";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.detailTitle;
    SCIUIKit26ConfigureViewController(self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(copyDetails)];

    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.backgroundColor = UIColor.clearColor;
    self.textView.textColor = UIColor.labelColor;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(18.0, 16.0, 18.0, 16.0);
    self.textView.text = self.detailText ?: @"";
    [self.view addSubview:self.textView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:g.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)copyDetails {
    UIPasteboard.generalPasteboard.string = self.detailText ?: @"";
    [SCIUtils showToastForDuration:1.2 title:@"Copied" subtitle:@"Details copied to clipboard"];
}

@end

typedef NS_ENUM(NSInteger, SCIDogfoodBrowserMode) {
    SCIDogfoodBrowserModeLaunchpad = 0,
    SCIDogfoodBrowserModeRuntime = 1,
    SCIDogfoodBrowserModeCaptures = 2,
    SCIDogfoodBrowserModeLogs = 3,
};

@interface SCIDogfoodBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) SCIUIKit26SearchBarContainerView *glassSearchBar;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) SCIUIKit26GlassPanelView *modePanel;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, assign) SCIDogfoodBrowserMode mode;

@property (nonatomic, copy) NSDictionary *state;
@property (nonatomic, copy) NSDictionary *nativeState;
@property (nonatomic, copy) NSDictionary *autofillState;
@property (nonatomic, copy) NSArray<NSDictionary *> *statusRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *nativeActionRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *autofillRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *stubs;
@property (nonatomic, copy) NSArray<NSDictionary *> *objects;
@property (nonatomic, copy) NSArray<NSDictionary *> *settingsTargets;
@property (nonatomic, copy) NSArray<NSDictionary *> *notesChanges;
@property (nonatomic, copy) NSArray<NSDictionary *> *params;
@property (nonatomic, copy) NSArray<NSDictionary *> *actions;

@property (nonatomic, copy) NSArray<NSDictionary *> *filteredStatusRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredNativeActionRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredAutofillRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredStubs;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredObjects;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredSettingsTargets;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredNotesChanges;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredParams;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredActions;
@end

@implementation SCIDogfoodBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dogfood Browser";
    self.mode = SCIDogfoodBrowserModeLaunchpad;
    SCIUIKit26ConfigureViewController(self);

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAll)];
    UIBarButtonItem *export = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(exportSnapshot)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(confirmClearRuntime)];
    // NAO sobrescrever leftBarButtonItem: preserva o botao Voltar nativo do push.
    self.navigationItem.rightBarButtonItems = @[refresh, export, clear];

    self.glassSearchBar = [[SCIUIKit26SearchBarContainerView alloc] initWithRadius:22.0];
    self.glassSearchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar = self.glassSearchBar.searchBar;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search class, selector, ivar, session, launcher, param";
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.glassSearchBar];

    self.modePanel = [[SCIUIKit26GlassPanelView alloc] initWithRadius:18.0];
    self.modePanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.modePanel];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Run", @"Runtime", @"Captures", @"Logs"]];
    self.modeControl.selectedSegmentIndex = self.mode;
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    SCIUIKit26ConfigureSegmentedControl(self.modeControl);
    [self.modePanel.contentView addSubview:self.modeControl];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 16.0, 0);
    self.tableView.verticalScrollIndicatorInsets = self.tableView.contentInset;
    SCIUIKit26ConfigureTableView(self.tableView);
    [self.tableView registerClass:SCIUIKit26ParamCell.class forCellReuseIdentifier:@"cell"];
    [self.tableView registerClass:SCIUIKit26SectionHeaderView.class forHeaderFooterViewReuseIdentifier:@"header"];
    [self.view addSubview:self.tableView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.glassSearchBar.topAnchor constraintEqualToAnchor:g.topAnchor constant:8.0],
        [self.glassSearchBar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:14.0],
        [self.glassSearchBar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-14.0],
        [self.glassSearchBar.heightAnchor constraintEqualToConstant:52.0],
        [self.modePanel.topAnchor constraintEqualToAnchor:self.glassSearchBar.bottomAnchor constant:10.0],
        [self.modePanel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16.0],
        [self.modePanel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16.0],
        [self.modeControl.topAnchor constraintEqualToAnchor:self.modePanel.contentView.topAnchor constant:8.0],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:self.modePanel.contentView.leadingAnchor constant:10.0],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:self.modePanel.contentView.trailingAnchor constant:-10.0],
        [self.modeControl.bottomAnchor constraintEqualToAnchor:self.modePanel.contentView.bottomAnchor constant:-8.0],
        [self.tableView.topAnchor constraintEqualToAnchor:self.modePanel.bottomAnchor constant:6.0],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [SCIDogfoodObjectRuntime installIfNeeded];
    [self refreshAll];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    SCIUIKit26ConfigureViewController(self);
    [SCIDogfoodObjectRuntime installIfNeeded];
    [self refreshRuntimeStateOnly];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [SCIMobileConfigRuntime setRuntimeCaptureActive:NO];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    self.mode = (SCIDogfoodBrowserMode)sender.selectedSegmentIndex;
    [self.tableView reloadData];
}

- (NSArray<NSDictionary *> *)buildStatusRows {
    NSDictionary *state = self.state ?: @{};
    NSDictionary *native = self.nativeState ?: @{};
    NSDictionary *autofill = self.autofillState ?: @{};
    BOOL nativeReady = SCIDFNativeReady(native);
    NSString *session = SCIDFBrowserString(state[@"activeUserSession"]);
    NSString *config = SCIDFBrowserString(native[@"config"]);
    NSString *top = SCIDFBrowserString(state[@"topViewController"]);
    NSString *launcherSet = SCIDFBrowserString(state[@"bestLauncherSet"]);
    NSString *autofillObj = SCIDFBrowserString(autofill[@"autofillInternalSettings"]);
    NSString *runtimeSubtitle = [NSString stringWithFormat:@"Objects %@ · Settings targets %@ · Notes changes %lu · MC reads %lu",
                                 state[@"liveObjects"] ?: @0,
                                 state[@"settingsTargets"] ?: @0,
                                 (unsigned long)self.notesChanges.count,
                                 (unsigned long)self.params.count];
    return @[
        @{ @"title": @"Native Dogfood readiness", @"subtitle": [NSString stringWithFormat:@"%@ · Config %@ · Session %@", nativeReady ? @"Ready" : @"Waiting for native config", config.length ? config : @"nil", session.length ? session : @"nil"], @"badge": nativeReady ? @"READY" : @"WAIT", @"object": native },
        @{ @"title": @"Current presentation context", @"subtitle": [NSString stringWithFormat:@"Top %@ · LauncherSet %@", top.length ? top : @"nil", launcherSet.length ? launcherSet : @"nil"], @"badge": @"CTX", @"object": state },
        @{ @"title": @"Autofill Internal state", @"subtitle": [NSString stringWithFormat:@"Object %@ · Bloks %@ · Prefetch %@ · Footer %@", autofillObj.length ? autofillObj : @"nil", autofill[@"bloksForceExperienceState"] ?: @"?", SCIDFBrowserBoolBadge([autofill[@"bloksPrefetchEnabled"] boolValue]), SCIDFBrowserBoolBadge([autofill[@"debugFooterEnabled"] boolValue])], @"badge": @"AUTO", @"object": autofill },
        @{ @"title": @"Runtime index", @"subtitle": runtimeSubtitle, @"badge": @"IDX", @"object": @{ @"state": state, @"native": native, @"autofill": autofill } },
    ];
}

- (NSArray<NSDictionary *> *)buildNativeActionRows {
    BOOL nativeReady = SCIDFNativeReady(self.nativeState ?: @{});
    BOOL capture = [SCIMobileConfigRuntime runtimeHooksEnabled];
    BOOL deep = [SCIMobileConfigRuntime deepCallerSymbolsEnabled];
    return @[
        @{ @"title": @"Open Native Dogfood Settings", @"subtitle": nativeReady ? @"Uses openWithConfig:onViewController:userSession: with the captured native config." : @"Waiting for IGDogfoodingSettingsConfig captured from the real native flow.", @"badge": nativeReady ? @"OPEN" : @"WAIT", @"action": @"openNative", @"emphasized": @(nativeReady) },
        @{ @"title": @"Open Notes Dogfooding", @"subtitle": @"Uses notesDogfoodingSettingsOpenOnViewController:userSession: with the live user session.", @"badge": @"NOTES", @"action": @"openNotes", @"emphasized": @(YES) },
        @{ @"title": @"Copy full runtime snapshot", @"subtitle": @"Exports state, stubs, live objects, captures, MobileConfig reads and launcher overrides as JSON.", @"badge": @"JSON", @"action": @"export", @"emphasized": @(NO) },
        @{ @"title": @"MobileConfig runtime capture", @"subtitle": capture ? @"ON for this session. Dogfood/Internal read tracer is active." : @"OFF. Tap to enable only while investigating a specific getter.", @"badge": SCIDFBrowserBoolBadge(capture), @"action": @"toggleCapture", @"emphasized": @(capture) },
        @{ @"title": @"Deep caller symbols", @"subtitle": deep ? @"ON. Delayed stack/caller symbol enrichment is active." : @"OFF. Safer default; enable only when the callsite is needed.", @"badge": SCIDFBrowserBoolBadge(deep), @"action": @"toggleDeep", @"emphasized": @(deep) },
    ];
}

- (NSArray<NSDictionary *> *)buildAutofillRows {
    NSDictionary *state = self.autofillState ?: @{};
    NSInteger forceState = [state[@"bloksForceExperienceState"] integerValue];
    NSString *forceLabel = forceState == 1 ? @"ON" : (forceState == 0 ? @"OFF" : @"NATIVE");
    return @[
        @{ @"title": @"Bloks Experience: ON", @"subtitle": @"Calls setForceBloksExperienceOn on IGAutofillInternalSettings.", @"badge": [forceLabel isEqualToString:@"ON"] ? @"ON" : @"SET", @"action": @"bloksOn", @"emphasized": @([forceLabel isEqualToString:@"ON"]) },
        @{ @"title": @"Bloks Experience: OFF", @"subtitle": @"Calls setForceBloksExperienceOff on IGAutofillInternalSettings.", @"badge": [forceLabel isEqualToString:@"OFF"] ? @"OFF" : @"SET", @"action": @"bloksOff", @"emphasized": @([forceLabel isEqualToString:@"OFF"]) },
        @{ @"title": @"Bloks Experience: native/default", @"subtitle": @"Calls clearForceBloksExperience to stop forcing ON/OFF.", @"badge": forceLabel, @"action": @"bloksClear", @"emphasized": @([forceLabel isEqualToString:@"NATIVE"]) },
        @{ @"title": @"Enable Bloks Prefetch", @"subtitle": @"Calls setBloksPrefetchEnabledWithEnabled:YES.", @"badge": SCIDFBrowserBoolBadge([state[@"bloksPrefetchEnabled"] boolValue]), @"action": @"prefetchOn", @"emphasized": @([state[@"bloksPrefetchEnabled"] boolValue]) },
        @{ @"title": @"Enable Debug Footer", @"subtitle": @"Calls setDebugFooterEnabledWithEnabled:YES.", @"badge": SCIDFBrowserBoolBadge([state[@"debugFooterEnabled"] boolValue]), @"action": @"debugFooterOn", @"emphasized": @([state[@"debugFooterEnabled"] boolValue]) },
    ];
}

- (void)refreshRuntimeStateOnly {
    self.state = [SCIDogfoodObjectRuntime runtimeState] ?: @{};
    self.nativeState = [SCIDogfoodObjectRuntime dogfoodNativeState] ?: @{};
    self.autofillState = [SCIInternalActions state] ?: @{};
    self.stubs = [SCIDogfoodObjectRuntime runtimeStubsMatching:self.query limit:220] ?: @[];
    self.objects = [SCIDogfoodObjectRuntime liveObjectGraph] ?: @[];
    self.settingsTargets = [SCIDogfoodObjectRuntime settingsInjectionTargets] ?: @[];
    self.notesChanges = [SCIDogfoodObjectRuntime dogfoodingSettingChanges] ?: @[];
    self.actions = [SCIDogfoodObjectRuntime recentActions] ?: @[];
    if (![SCIMobileConfigRuntime runtimeHooksEnabled]) self.params = @[];
    self.statusRows = [self buildStatusRows];
    self.nativeActionRows = [self buildNativeActionRows];
    self.autofillRows = [self buildAutofillRows];
    [self applyFilterAndReload:YES];
}

- (void)refreshAll {
    if ([SCIMobileConfigRuntime runtimeHooksEnabled]) [SCIMobileConfigRuntime reloadParamsMapIndex];
    self.params = [SCIMobileConfigRuntime runtimeHooksEnabled] ? ([SCIMobileConfigRuntime dogfoodCandidateParams] ?: @[]) : @[];
    [self refreshRuntimeStateOnly];
}

- (void)confirmClearRuntime {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Clear runtime capture?" message:@"This clears captured Dogfood objects, Notes persistence snapshots and MobileConfig observations. Manual launcher overrides are not removed." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *_) {
        [SCIDogfoodObjectRuntime clear];
        [SCIMobileConfigRuntime clearObservations];
        [self refreshAll];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)filterArray:(NSArray<NSDictionary *> *)array query:(NSString *)q {
    if (!q.length) return array ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in array ?: @[]) if (SCIDFBrowserMatches(d, q)) [out addObject:d];
    return out.copy;
}

- (void)applyFilterAndReload:(BOOL)reload {
    NSString *q = self.query ?: @"";
    self.filteredStatusRows = [self filterArray:self.statusRows query:q];
    self.filteredNativeActionRows = [self filterArray:self.nativeActionRows query:q];
    self.filteredAutofillRows = [self filterArray:self.autofillRows query:q];
    self.filteredStubs = q.length ? ([SCIDogfoodObjectRuntime runtimeStubsMatching:q limit:220] ?: @[]) : (self.stubs ?: @[]);
    self.filteredObjects = [self filterArray:self.objects query:q];
    self.filteredSettingsTargets = [self filterArray:self.settingsTargets query:q];
    self.filteredNotesChanges = [self filterArray:self.notesChanges query:q];
    self.filteredParams = [self filterArray:self.params query:q];
    self.filteredActions = [self filterArray:self.actions query:q];
    if (reload) [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.query = searchText ?: @"";
    [self applyFilterAndReload:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (BOOL)sectionVisible:(NSInteger)section {
    switch (self.mode) {
        case SCIDogfoodBrowserModeLaunchpad: return section == 0 || section == 1 || section == 2;
        case SCIDogfoodBrowserModeRuntime: return section == 3 || section == 4 || section == 5;
        case SCIDogfoodBrowserModeCaptures: return section == 6 || section == 7;
        case SCIDogfoodBrowserModeLogs: return section == 8;
    }
    return NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 9; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (![self sectionVisible:section]) return 0;
    if (section == 0) return self.filteredStatusRows.count;
    if (section == 1) return self.filteredNativeActionRows.count;
    if (section == 2) return self.filteredAutofillRows.count;
    if (section == 3) return self.filteredStubs.count;
    if (section == 4) return self.filteredObjects.count;
    if (section == 5) return self.filteredSettingsTargets.count;
    if (section == 6) return self.filteredNotesChanges.count;
    if (section == 7) return self.filteredParams.count;
    return MIN((NSInteger)self.filteredActions.count, 60);
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (![self sectionVisible:section]) return nil;
    SCIUIKit26SectionHeaderView *h = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"header"];
    if (section == 0) [h configureWithTitle:@"Runtime status" subtitle:@"Readiness cards. No giant state dump in the header; tap a row for the full JSON."];
    else if (section == 1) [h configureWithTitle:@"Authorized native openers" subtitle:@"Only selectors confirmed by the static dump are used. Missing config/session is shown instead of crashing."];
    else if (section == 2) [h configureWithTitle:@"Autofill Internal Settings" subtitle:@"Native IGAutofillInternalSettings setters. Actions ask for confirmation and log errors."];
    else if (section == 3) [h configureWithTitle:[NSString stringWithFormat:@"Runtime stubs · %lu", (unsigned long)self.filteredStubs.count] subtitle:@"Class, method, property and ivar stubs from loaded ObjC metadata. No method invocation."];
    else if (section == 4) [h configureWithTitle:[NSString stringWithFormat:@"Live objects · %lu", (unsigned long)self.filteredObjects.count] subtitle:@"Objects captured by named hooks only. No heap scan."];
    else if (section == 5) [h configureWithTitle:[NSString stringWithFormat:@"Settings targets · %lu", (unsigned long)self.filteredSettingsTargets.count] subtitle:@"Captured settings-related controllers/models. Overlay injection stays disabled."];
    else if (section == 6) [h configureWithTitle:[NSString stringWithFormat:@"Notes persistence captures · %lu", (unsigned long)self.filteredNotesChanges.count] subtitle:@"Native DogfoodingSettings item/options snapshots and replayability evidence."];
    else if (section == 7) [h configureWithTitle:[NSString stringWithFormat:@"MobileConfig dogfood reads · %lu", (unsigned long)self.filteredParams.count] subtitle:@"Secondary tracer. Enable capture only while investigating a specific callsite."];
    else [h configureWithTitle:[NSString stringWithFormat:@"Recent actions · %lu", (unsigned long)self.filteredActions.count] subtitle:@"Open attempts, exceptions and diagnostics."];
    return h;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self sectionVisible:section] ? 76.0 : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return [self sectionVisible:section] ? 8.0 : CGFLOAT_MIN;
}

- (UITableViewCell *)configuredCellForIndexPath:(NSIndexPath *)ip model:(NSDictionary *)model badge:(NSString *)fallbackBadge emphasized:(BOOL)fallbackEmphasis {
    SCIUIKit26ParamCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:ip];
	SCIUIKit26ConfigureTableCell(cell);
    NSString *title = model[@"title"] ?: model[@"display"] ?: model[@"class"] ?: model[@"paramID"] ?: model[@"action"] ?: @"";
    NSString *subtitle = model[@"subtitle"];
    if (!subtitle.length) {
        if (model[@"selector"] || model[@"sourceClass"]) subtitle = [NSString stringWithFormat:@"%@ · %@ · %@", model[@"selector"] ?: @"", model[@"sourceClass"] ?: @"", model[@"map"] ?: @""];
        else if (model[@"roles"] || model[@"sources"]) subtitle = [NSString stringWithFormat:@"roles %@ · sources %@", SCIDFBrowserJoined(model[@"roles"]), SCIDFBrowserJoined(model[@"sources"])] ;
        else if (model[@"detail"]) subtitle = SCIDFBrowserString(model[@"detail"]);
        else subtitle = SCIDFBrowserString(model);
    }
    NSString *badge = model[@"badge"] ?: fallbackBadge;
    BOOL emph = model[@"emphasized"] ? [model[@"emphasized"] boolValue] : fallbackEmphasis;
    [cell configureWithTitle:title subtitle:subtitle badge:badge emphasized:emph];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSDictionary *)modelForIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row < (NSInteger)self.filteredStatusRows.count) return self.filteredStatusRows[ip.row];
    if (ip.section == 1 && ip.row < (NSInteger)self.filteredNativeActionRows.count) return self.filteredNativeActionRows[ip.row];
    if (ip.section == 2 && ip.row < (NSInteger)self.filteredAutofillRows.count) return self.filteredAutofillRows[ip.row];
    if (ip.section == 3 && ip.row < (NSInteger)self.filteredStubs.count) return self.filteredStubs[ip.row];
    if (ip.section == 4 && ip.row < (NSInteger)self.filteredObjects.count) return self.filteredObjects[ip.row];
    if (ip.section == 5 && ip.row < (NSInteger)self.filteredSettingsTargets.count) return self.filteredSettingsTargets[ip.row];
    if (ip.section == 6 && ip.row < (NSInteger)self.filteredNotesChanges.count) return self.filteredNotesChanges[ip.row];
    if (ip.section == 7 && ip.row < (NSInteger)self.filteredParams.count) return self.filteredParams[ip.row];
    if (ip.section == 8 && ip.row < (NSInteger)self.filteredActions.count) return self.filteredActions[ip.row];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *model = [self modelForIndexPath:ip] ?: @{};
    if (ip.section == 3) {
        NSMutableDictionary *m = [model mutableCopy];
        if (!m[@"subtitle"]) m[@"subtitle"] = [NSString stringWithFormat:@"methods %@/%@ · props %@ · ivars %@", model[@"methodCountPreview"] ?: @0, model[@"classMethodCountPreview"] ?: @0, model[@"propertyCountPreview"] ?: @0, model[@"ivarCountPreview"] ?: @0];
        return [self configuredCellForIndexPath:ip model:m badge:@"STUB" emphasized:YES];
    }
    if (ip.section == 4 || ip.section == 5) {
        NSMutableDictionary *m = [model mutableCopy];
        m[@"title"] = [NSString stringWithFormat:@"%@ %@", model[@"class"] ?: @"", model[@"address"] ?: @""];
        m[@"subtitle"] = [NSString stringWithFormat:@"roles %@ · sources %@ · ivars %@", SCIDFBrowserJoined(model[@"roles"]), SCIDFBrowserJoined(model[@"sources"]), @([model[@"ivars"] count])];
        return [self configuredCellForIndexPath:ip model:m badge:(ip.section == 5 ? @"SET" : @"LIVE") emphasized:(ip.section == 4)];
    }
    if (ip.section == 6) {
        NSMutableDictionary *m = [model mutableCopy];
        BOOL replay = [model[@"canReplayLauncherOverride"] boolValue];
        m[@"title"] = [NSString stringWithFormat:@"%@ %@", replay ? @"Replayable" : @"Snapshot", model[@"source"] ?: @""];
        m[@"subtitle"] = [NSString stringWithFormat:@"launcher %@ · parameter %@ · value %@ · item %@", model[@"launcher"] ?: @"?", model[@"parameter"] ?: @"?", model[@"value"] ?: @"?", model[@"itemClass"] ?: @""];
        return [self configuredCellForIndexPath:ip model:m badge:@"SAVE" emphasized:replay];
    }
    if (ip.section == 7) {
        NSMutableDictionary *m = [model mutableCopy];
        NSArray *tags = [model[@"tags"] isKindOfClass:NSArray.class] ? model[@"tags"] : @[];
        m[@"title"] = [NSString stringWithFormat:@"%@%@ %@", tags.count ? [[tags componentsJoinedByString:@", "] stringByAppendingString:@" · "] : @"", model[@"paramID"] ?: @"", model[@"type"] ?: @""];
        m[@"subtitle"] = [NSString stringWithFormat:@"count %@ · value %@ · %@", model[@"count"] ?: @0, model[@"returned"] ?: @"", model[@"map"] ?: @""];
        return [self configuredCellForIndexPath:ip model:m badge:@"MC" emphasized:NO];
    }
    if (ip.section == 8) {
        NSMutableDictionary *m = [model mutableCopy];
        m[@"title"] = [NSString stringWithFormat:@"%@ · %@", model[@"action"] ?: @"", model[@"status"] ?: @""];
        m[@"subtitle"] = model[@"detail"] ?: @"";
        return [self configuredCellForIndexPath:ip model:m badge:@"LOG" emphasized:NO];
    }
    return [self configuredCellForIndexPath:ip model:model badge:nil emphasized:NO];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *model = [self modelForIndexPath:ip];
    if (!model) return;
    if (ip.section == 1 || ip.section == 2) {
        NSString *action = model[@"action"];
        if ([self performAction:action model:model]) return;
    }
    [self presentDetailsForModel:model section:ip.section];
}

- (BOOL)performAction:(NSString *)action model:(NSDictionary *)model {
    if (!action.length) return NO;
    if ([action isEqualToString:@"openNative"]) {
        if (![SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings]) [self showNativeFailure];
        [self refreshRuntimeStateOnly];
        return YES;
    }
    if ([action isEqualToString:@"openNotes"]) {
        NSError *err = nil;
        if (![SCIInternalActions openNotesDogfoodSettings:&err]) {
            NSString *msg = err.localizedDescription ?: @"Notes dogfooding unavailable.";
            [SCIDogfoodObjectRuntime noteAction:@"Open Notes Dogfooding" status:@"failed" detail:msg];
            [SCIUtils showErrorHUDWithDescription:msg];
        } else {
            [SCIDogfoodObjectRuntime noteAction:@"Open Notes Dogfooding" status:@"sent native opener" detail:nil];
        }
        [self refreshRuntimeStateOnly];
        return YES;
    }
    if ([action isEqualToString:@"export"]) { [self exportSnapshot]; return YES; }
    if ([action isEqualToString:@"toggleCapture"]) { [self toggleCapturePreference]; return YES; }
    if ([action isEqualToString:@"toggleDeep"]) { [self toggleDeepCallerSymbols]; return YES; }
    if ([action isEqualToString:@"bloksOn"]) { [self confirmAutofillAction:@"Force Bloks Experience ON" message:@"Call setForceBloksExperienceOn on the live IGAutofillInternalSettings object?" block:^{ return [SCIInternalActions setBloksForceExperienceState:1 error:NULL]; }]; return YES; }
    if ([action isEqualToString:@"bloksOff"]) { [self confirmAutofillAction:@"Force Bloks Experience OFF" message:@"Call setForceBloksExperienceOff on the live IGAutofillInternalSettings object?" block:^{ return [SCIInternalActions setBloksForceExperienceState:0 error:NULL]; }]; return YES; }
    if ([action isEqualToString:@"bloksClear"]) { [self confirmAutofillAction:@"Clear forced Bloks Experience" message:@"Call clearForceBloksExperience and return to native/default selection?" block:^{ return [SCIInternalActions setBloksForceExperienceState:2 error:NULL]; }]; return YES; }
    if ([action isEqualToString:@"prefetchOn"]) { [self confirmAutofillAction:@"Enable Bloks Prefetch" message:@"Call setBloksPrefetchEnabledWithEnabled:YES?" block:^{ return [SCIInternalActions setBloksPrefetchEnabled:YES error:NULL]; }]; return YES; }
    if ([action isEqualToString:@"debugFooterOn"]) { [self confirmAutofillAction:@"Enable Debug Footer" message:@"Call setDebugFooterEnabledWithEnabled:YES?" block:^{ return [SCIInternalActions setDebugFooterEnabled:YES error:NULL]; }]; return YES; }
    return NO;
}

- (void)showNativeFailure {
    NSDictionary *state = [SCIDogfoodObjectRuntime dogfoodNativeState];
    NSString *msg = [NSString stringWithFormat:@"Native Dogfood Settings is not ready yet.\n\n%@", SCIDFBrowserJSON(state)];
    [SCIUtils showErrorHUDWithDescription:msg dismissAfterDelay:5.0];
}

- (void)toggleCapturePreference {
    BOOL next = ![SCIMobileConfigRuntime runtimeHooksEnabled];
    [SCIMobileConfigRuntime setRuntimeCaptureActive:next];
    if (next) SCIInstallMobileConfigRuntimeHooksIfNeeded();
    [SCIDogfoodObjectRuntime noteAction:@"MobileConfig runtime capture" status:(next ? @"enabled" : @"disabled") detail:nil];
    [self refreshAll];
}

- (void)toggleDeepCallerSymbols {
    BOOL next = ![SCIMobileConfigRuntime deepCallerSymbolsEnabled];
    [SCIUtils setPref:@(next) forKey:@"sci_mc_runtime_deep_symbols_enabled"];
    [SCIDogfoodObjectRuntime noteAction:@"Deep caller symbols" status:(next ? @"enabled" : @"disabled") detail:nil];
    [self refreshAll];
}

- (void)confirmAutofillAction:(NSString *)title message:(NSString *)message block:(BOOL(^)(void))block {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *_) {
        BOOL ok = block ? block() : NO;
        [SCIDogfoodObjectRuntime noteAction:title status:(ok ? @"sent" : @"failed") detail:[SCIInternalActions state]];
        if (ok) [SCIUtils showToastForDuration:1.2 title:@"Sent" subtitle:title];
        else [SCIUtils showErrorHUDWithDescription:@"Action failed. Open Logs for the last runtime error."];
        [self refreshRuntimeStateOnly];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)presentDetailsForModel:(NSDictionary *)model section:(NSInteger)section {
    id detail = model[@"object"] ?: model;
    NSString *title = model[@"title"] ?: model[@"display"] ?: model[@"class"] ?: @"Details";
    if (section == 3) {
        NSString *cls = model[@"class"] ?: @"";
        NSDictionary *rich = [SCIDogfoodObjectRuntime detailsForRuntimeStubClass:cls];
        if (rich.count) detail = rich;
        if (cls.length) title = cls;
    } else if (section == 4 || section == 5) {
        NSString *addr = model[@"address"] ?: @"";
        NSDictionary *rich = [SCIDogfoodObjectRuntime detailsForObjectAddress:addr];
        if (rich.count) detail = rich;
        title = model[@"class"] ?: title;
    }
    SCIDogfoodJSONDetailViewController *vc = [[SCIDogfoodJSONDetailViewController alloc] initWithTitle:title object:detail];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)exportSnapshot {
    NSDictionary *snapshot = @{
        @"dogfoodObjectRuntime": [SCIDogfoodObjectRuntime fullSnapshotIncludingDetails:NO] ?: @{},
        @"nativeState": [SCIDogfoodObjectRuntime dogfoodNativeState] ?: @{},
        @"autofillInternalState": [SCIInternalActions state] ?: @{},
        @"runtimeStubs": self.stubs ?: @[],
        @"notesDogfoodingPersistence": self.notesChanges ?: @[],
        @"mobileConfigReads": self.params ?: @[],
        @"launcherOverrides": [SCILauncherOverride allOverrides] ?: @{},
        @"recentActions": [SCIDogfoodObjectRuntime recentActions] ?: @[]
    };
    UIPasteboard.generalPasteboard.string = SCIDFBrowserJSON(snapshot);
    [SCIDogfoodObjectRuntime noteAction:@"Copy Dogfood Browser snapshot" status:@"copied" detail:nil];
    [SCIUtils showToastForDuration:1.2 title:@"Copied" subtitle:@"Runtime snapshot copied as JSON"];
    [self refreshRuntimeStateOnly];
}

@end
