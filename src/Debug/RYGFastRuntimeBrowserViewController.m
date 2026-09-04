#import "RYGFastRuntimeBrowserViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeLiveObserver.h"
#import "RYGRuntimeValueStore.h"
#import "../UI/RYGLiquidGlass.h"
#import "../UI/RYGPopupChrome.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <math.h>
#include <stdlib.h>

static NSString *const kRYGRuntimeSelectedImageKey = @"ryg_runtime_browser_selected_image_v2";

typedef NS_ENUM(NSInteger, RYGRuntimeBrowserMode) {
    RYGRuntimeBrowserModeObjectiveC = 0,
    RYGRuntimeBrowserModeCSymbols,
};

static NSString *RYGBrowserCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved.stringByStandardizingPath : standard;
}

static NSString *RYGBrowserImageID(NSString *path) {
    NSString *standard = path.stringByStandardizingPath;
    NSString *root = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if ([standard hasPrefix:prefix]) return [standard substringFromIndex:prefix.length];
    if ([standard isEqualToString:NSBundle.mainBundle.executablePath.stringByStandardizingPath]) return @"@executable";
    return standard.lastPathComponent ?: @"";
}

static NSString *RYGBrowserRuntimeName(NSString *imagePath) {
    NSString *wanted = RYGBrowserCanonicalPath(imagePath);
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw] ?: @"";
        if ([RYGBrowserCanonicalPath(path) isEqualToString:wanted]) return path;
    }
    return nil;
}

static NSArray<NSString *> *RYGBrowserTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens.copy;
}

static BOOL RYGBrowserMatches(NSString *text, NSArray<NSString *> *tokens) {
    if (!tokens.count) return YES;
    NSString *lower = text.lowercaseString ?: @"";
    NSString *compact = [[lower componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    for (NSString *group in tokens) {
        BOOL matched = NO;
        for (NSString *token in [group componentsSeparatedByString:@"|"]) {
            if (!token.length) continue;
            NSString *compactToken = [[token componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
            if ([lower rangeOfString:token].location != NSNotFound ||
                (compactToken.length && [compact rangeOfString:compactToken].location != NSNotFound)) {
                matched = YES;
                break;
            }
        }
        if (!matched) return NO;
    }
    return YES;
}

static NSString *RYGBrowserEditableObjectText(id value) {
    if (!value || value == NSNull.null) return @"nil";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value description] ?: @"0";
    if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
        NSString *json = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (json.length) return json;
    }
    return [value description] ?: @"";
}

// First stage is intentionally class names only. Methods are not indexed until needed.
static NSArray<RYGRuntimeClassRow *> *RYGBrowserClassNamesForImage(NSString *imagePath) {
    NSString *runtimeName = RYGBrowserRuntimeName(imagePath);
    if (!runtimeName.length) return @[];
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(runtimeName.fileSystemRepresentation, &count);
    if (!names || !count || count > 500000) {
        if (names) free(names);
        return @[];
    }
    NSMutableArray<RYGRuntimeClassRow *> *rows = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        const char *raw = names[index];
        if (!raw || !*raw) continue;
        RYGRuntimeClassRow *row = [RYGRuntimeClassRow new];
        row.imagePath = imagePath ?: @"";
        row.className = [NSString stringWithUTF8String:raw] ?: @"";
        if (row.className.length) [rows addObject:row];
    }
    free(names);
    [rows sortUsingComparator:^NSComparisonResult(RYGRuntimeClassRow *left, RYGRuntimeClassRow *right) {
        return [left.className localizedCaseInsensitiveCompare:right.className];
    }];
    return rows.copy;
}

#pragma mark - Class detail

@interface RYGRuntimeClassDetailViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *initialQuery;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSArray<RYGRuntimeMemberRow *> *members;
@property (nonatomic, copy) NSArray<RYGRuntimeMemberRow *> *visibleMembers;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) NSUInteger generation;
- (instancetype)initWithImagePath:(NSString *)imagePath className:(NSString *)className initialQuery:(NSString *)query;
@end

@implementation RYGRuntimeClassDetailViewController

- (instancetype)initWithImagePath:(NSString *)imagePath className:(NSString *)className initialQuery:(NSString *)query {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _imagePath = [imagePath copy] ?: @"";
        _className = [className copy] ?: @"Class";
        _initialQuery = [query copy] ?: @"";
        _members = @[];
        _visibleMembers = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.className;
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Selector, type or ABI";
    self.searchController.searchBar.text = self.initialQuery;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply"
                                                                               style:UIBarButtonItemStyleDone
                                                                              target:self
                                                                              action:@selector(applyPersistedRuntimeValues)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(nativeChanged:) name:RYGRuntimeNativeValueDidChangeNotification object:nil];
    RYGLiquidGlassApplyToViewController(self);
    [self loadMembers];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)nativeChanged:(NSNotification *)note {
    NSString *key = note.userInfo[RYGRuntimeNativeValueKeyUserInfoKey];
    if (!key.length || [key containsString:self.className]) [self.tableView reloadData];
}

- (void)loadMembers {
    NSString *path = self.imagePath.copy;
    NSString *className = self.className.copy;
    NSUInteger generation = ++self.generation;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<RYGRuntimeMemberRow *> *members = [RYGRuntimeBrowserEngine membersForClassName:className imagePath:path] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.members = members;
            [self.spinner stopAnimating];
            [self applyFilter];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self applyFilter];
}

- (void)applyFilter {
    NSArray<NSString *> *tokens = RYGBrowserTokens(self.searchController.searchBar.text ?: @"");
    if (!tokens.count) self.visibleMembers = self.members;
    else self.visibleMembers = [self.members filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RYGRuntimeMemberRow *member, NSDictionary *bindings) {
        (void)bindings;
        return RYGBrowserMatches([NSString stringWithFormat:@"%@ %@ %@", member.className ?: @"", member.name ?: @"", member.typeEncoding ?: @""], tokens);
    }]];
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.visibleMembers.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [NSString stringWithFormat:@"%lu ABI-validated runtime getters", (unsigned long)self.visibleMembers.count];
}

- (void)applyPersistedRuntimeValues {
    [RYGRuntimeBrowserEngine reinstallPersistedOverrides];
    NSUInteger installed = RYGRuntimeValueReinstallPersistedHooks();
    NSUInteger persisted = RYGRuntimeValueAllOverrideSpecs().count;
    [RYGUtils showToastForDuration:1.3 title:@"Runtime overrides applied"
                          subtitle:[NSString stringWithFormat:@"%lu/%lu typed hooks installed",
                                    (unsigned long)installed, (unsigned long)persisted]];
    [self.tableView reloadData];
}

- (NSString *)typedOverrideSummary:(RYGRuntimeMemberRow *)member {
    BOOL meta = member.kind == RYGRuntimeMemberClassMethod;
    if (!RYGRuntimeValueHasOverride(member.className, member.name, meta))
        return RYGRuntimeValueTypeName(member.valueTypeCode) ?: @"value";
    id value = RYGRuntimeValueOverride(member.className, member.name, meta);
    if (!value) return @"Forced nil";
    NSString *description = [value description] ?: @"";
    if (description.length > 36) description = [[description substringToIndex:36] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"Forced %@", description];
}

- (void)showTypedReadForMember:(RYGRuntimeMemberRow *)member {
    BOOL meta = member.kind == RYGRuntimeMemberClassMethod;
    id raw = nil;
    NSString *value = RYGRuntimeValueRead(member.className, member.name, meta, nil, &raw);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:member.name
                                                                   message:value
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = value ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (id)typedValueFromText:(NSString *)text type:(NSString *)type valid:(BOOL *)valid {
    if (valid) *valid = NO;
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (RYGRuntimeValueTypeIsSignedInteger(type)) {
        const char *raw = trim.UTF8String; char *end = NULL; long long value = raw ? strtoll(raw, &end, 10) : 0;
        if (raw && end != raw && *end == '\0') { if (valid) *valid = YES; return @(value); }
        return nil;
    }
    if (RYGRuntimeValueTypeIsUnsignedInteger(type)) {
        if ([trim hasPrefix:@"-"]) return nil;
        const char *raw = trim.UTF8String; char *end = NULL; unsigned long long value = raw ? strtoull(raw, &end, 10) : 0;
        if (raw && end != raw && *end == '\0') { if (valid) *valid = YES; return @(value); }
        return nil;
    }
    if (RYGRuntimeValueTypeIsFloatingPoint(type)) {
        const char *raw = trim.UTF8String; char *end = NULL; double value = raw ? strtod(raw, &end) : 0;
        if (raw && end != raw && *end == '\0' && isfinite(value)) { if (valid) *valid = YES; return @(value); }
        return nil;
    }
    if (RYGRuntimeValueTypeIsObject(type)) {
        if ([trim.lowercaseString isEqualToString:@"null"] || [trim.lowercaseString isEqualToString:@"nil"]) {
            if (valid) *valid = YES;
            return nil;
        }
        NSData *data = [trim dataUsingEncoding:NSUTF8StringEncoding];
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (json) { if (valid) *valid = YES; return json; }
        if (valid) *valid = YES;
        return text ?: @"";
    }
    return nil;
}

- (void)presentTypedEditorForMember:(RYGRuntimeMemberRow *)member {
    BOOL meta = member.kind == RYGRuntimeMemberClassMethod;
    BOOL had = RYGRuntimeValueHasOverride(member.className, member.name, meta);
    id current = had ? RYGRuntimeValueOverride(member.className, member.name, meta) : nil;
    NSString *initial = current ? RYGBrowserEditableObjectText(current) : (had ? @"nil" : @"");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:member.name
                                                                   message:[NSString stringWithFormat:@"%@ · %@ method",
                                                                            RYGRuntimeValueTypeName(member.valueTypeCode) ?: member.valueTypeCode,
                                                                            meta ? @"class" : @"instance"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initial;
        if (!RYGRuntimeValueTypeIsObject(member.valueTypeCode)) field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.placeholder = RYGRuntimeValueTypeIsObject(member.valueTypeCode) ? @"String, JSON, or nil" : @"Typed value";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (had) [alert addAction:[UIAlertAction actionWithTitle:@"Use Native" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        RYGRuntimeValueClearOverride(member.className, member.name, meta);
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Persist + Apply" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        BOOL valid = NO;
        id value = [self typedValueFromText:alert.textFields.firstObject.text type:member.valueTypeCode valid:&valid];
        if (!valid) { [RYGUtils showErrorHUDWithDescription:@"Value does not match the getter ABI"]; return; }
        RYGRuntimeValueSetOverride(member.className, member.name, meta, member.valueTypeCode, value);
        BOOL installed = RYGRuntimeValueInstallHook(member.className, member.name, meta, member.valueTypeCode);
        [RYGUtils showToastForDuration:1.2 title:installed ? @"Typed override applied" : @"Override persisted"
                              subtitle:installed ? nil : @"Exact hook is pending; use Apply after the image loads"];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIButton *)buttonForTypedMember:(RYGRuntimeMemberRow *)member {
    BOOL meta = member.kind == RYGRuntimeMemberClassMethod;
    BOOL had = RYGRuntimeValueHasOverride(member.className, member.name, meta);
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    if (meta) [actions addObject:[UIAction actionWithTitle:@"Read current value" image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf showTypedReadForMember:member]; }]];
    [actions addObject:[UIAction actionWithTitle:@"Edit typed override" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf presentTypedEditorForMember:member]; }]];
    if (had) [actions addObject:[UIAction actionWithTitle:@"Use Native" image:nil identifier:nil handler:^(__unused UIAction *action) { RYGRuntimeValueClearOverride(member.className, member.name, meta); [weakSelf.tableView reloadData]; }]];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.menu = [UIMenu menuWithTitle:member.name ?: @"Runtime value" children:actions];
    button.showsMenuAsPrimaryAction = YES;
    RYGLiquidGlassConfigureButton(button, NO);
    UIButtonConfiguration *configuration = button.configuration;
    NSString *title = [self typedOverrideSummary:member];
    if (configuration) { configuration.title = title; configuration.baseForegroundColor = UIColor.labelColor; button.configuration = configuration; }
    else [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UIButton *)buttonForMethod:(RYGRuntimeBoolMethod *)method {
    NSNumber *forced = method.overrideValue;
    NSNumber *native = method.liveValue;
    NSString *title = forced ? (forced.boolValue ? @"Forced On" : @"Forced Off") : (native ? (native.boolValue ? @"Native On" : @"Native Off") : @"Native");
    __weak typeof(self) weakSelf = self;
    UIAction *observe = [UIAction actionWithTitle:@"Observe native" image:[UIImage systemImageNamed:@"waveform.path.ecg"] identifier:nil handler:^(__unused UIAction *action) {
        RYGRuntimeBeginLiveObservation(@[method]);
        [weakSelf.tableView reloadData];
    }];
    UIAction *useNative = [UIAction actionWithTitle:@"Use Native" image:nil identifier:nil handler:^(__unused UIAction *action) {
        [RYGRuntimeBrowserEngine setOverride:nil forMethod:method];
        [weakSelf.tableView reloadData];
    }];
    UIAction *forceOn = [UIAction actionWithTitle:@"Force On" image:nil identifier:nil handler:^(__unused UIAction *action) {
        [RYGRuntimeBrowserEngine setOverride:@YES forMethod:method];
        [weakSelf.tableView reloadData];
    }];
    UIAction *forceOff = [UIAction actionWithTitle:@"Force Off" image:nil identifier:nil handler:^(__unused UIAction *action) {
        [RYGRuntimeBrowserEngine setOverride:@NO forMethod:method];
        [weakSelf.tableView reloadData];
    }];
    useNative.state = forced ? UIMenuElementStateOff : UIMenuElementStateOn;
    forceOn.state = forced && forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;
    forceOff.state = forced && !forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.menu = [UIMenu menuWithTitle:method.selectorName ?: @"BOOL" image:nil identifier:nil options:0 children:@[
        observe,
        [UIMenu menuWithTitle:@"Output" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:@[useNative, forceOn, forceOff]],
    ]];
    button.showsMenuAsPrimaryAction = YES;
    RYGLiquidGlassConfigureButton(button, NO);
    UIButtonConfiguration *configuration = button.configuration;
    if (configuration) {
        configuration.title = title;
        configuration.baseForegroundColor = UIColor.labelColor;
        button.configuration = configuration;
    } else {
        [button setTitle:title forState:UIControlStateNormal];
    }
    return button;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RYGRuntimeMethod"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RYGRuntimeMethod"];
    RYGRuntimeMemberRow *member = self.visibleMembers[(NSUInteger)indexPath.row];
    RYGRuntimeBoolMethod *method = [RYGRuntimeBrowserEngine boolMethodForMember:member];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", member.classMember ? @"+" : @"−", member.name ?: @""];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 2;
    NSString *valueType = member.hookableValue ? (RYGRuntimeValueTypeName(member.valueTypeCode) ?: member.valueTypeCode) : @"BOOL";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", valueType ?: @"value", member.typeEncoding ?: @""];
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = method ? [self buttonForMethod:method] : (member.hookableValue ? [self buttonForTypedMember:member] : nil);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    RYGRuntimeMemberRow *member = self.visibleMembers[(NSUInteger)indexPath.row];
    if ([RYGRuntimeBrowserEngine boolMethodForMember:member] || !member.hookableValue) return;
    [self presentTypedEditorForMember:member];
}

@end

#pragma mark - Browser root

@interface RYGFastRuntimeBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *browserTitle;
@property (nonatomic, copy) NSString *initialQuery;
@property (nonatomic, assign) BOOL allowsBulkVisibilityOverride;
@property (nonatomic, strong) UIButton *imageButton;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, copy) NSArray<NSString *> *images;
@property (nonatomic, copy) NSString *selectedImagePath;
@property (nonatomic, copy) NSArray<RYGRuntimeClassRow *> *classRows;
@property (nonatomic, copy) NSArray<RYGRuntimeClassRow *> *visibleClasses;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<RYGRuntimeMemberRow *> *> *selectorMatches;
@property (nonatomic, copy) NSArray<RYGMachOSymbol *> *symbols;
@property (nonatomic, copy) NSArray<RYGMachOSymbol *> *visibleSymbols;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) NSUInteger searchGeneration;
@end

@implementation RYGFastRuntimeBrowserViewController

- (instancetype)init { return [self initWithTitle:@"Runtime Browser" initialQuery:@"" allowsBulkVisibilityOverride:NO]; }
- (instancetype)initWithTitle:(NSString *)title initialQuery:(NSString *)initialQuery {
    return [self initWithTitle:title initialQuery:initialQuery allowsBulkVisibilityOverride:NO];
}

- (instancetype)initWithTitle:(NSString *)title initialQuery:(NSString *)initialQuery allowsBulkVisibilityOverride:(BOOL)allowsBulkVisibilityOverride {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        NSString *copied = [title copy];
        _browserTitle = copied.length ? copied : @"Runtime Browser";
        _initialQuery = [initialQuery copy] ?: @"";
        _allowsBulkVisibilityOverride = allowsBulkVisibilityOverride;
        _classRows = @[];
        _visibleClasses = @[];
        _selectorMatches = @{};
        _symbols = @[];
        _visibleSymbols = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.browserTitle;
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];

    self.imageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.imageButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageButton.showsMenuAsPrimaryAction = YES;
    [self.view addSubview:self.imageButton];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Objective-C", @"C Symbols"]];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeControl.selectedSegmentIndex = RYGRuntimeBrowserModeObjectiveC;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeControl];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *margins = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.imageButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [self.imageButton.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.imageButton.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.modeControl.topAnchor constraintEqualToAnchor:self.imageButton.bottomAnchor constant:8.0],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:4.0],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Class, selector or typed getter";
    self.searchController.searchBar.text = self.initialQuery;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.emptyLabel = [UILabel new];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(refreshTapped)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(applyAllPersistedRuntimeValues)];
    if (self.allowsBulkVisibilityOverride) {
        UIBarButtonItem *reveal = [[UIBarButtonItem alloc] initWithTitle:@"Reveal All" style:UIBarButtonItemStylePlain target:self action:@selector(revealAllVisibilityRows)];
        self.navigationItem.rightBarButtonItems = @[refresh, apply, reveal];
    } else {
        self.navigationItem.rightBarButtonItems = @[refresh, apply];
    }

    [self refreshImages];
    [self rebuildImageMenu];
    RYGLiquidGlassApplyToViewController(self);
    [self loadSelectedImage];
}

- (void)refreshImages {
    self.images = [RYGRuntimeBrowserEngine runtimeImagePaths] ?: @[];
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kRYGRuntimeSelectedImageKey];
    NSString *main = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if (self.selectedImagePath.length && [self.images containsObject:self.selectedImagePath]) return;
    self.selectedImagePath = nil;
    for (NSString *path in self.images) if (stored.length && [RYGBrowserImageID(path) isEqualToString:stored]) { self.selectedImagePath = path; break; }
    if (!self.selectedImagePath.length) for (NSString *path in self.images) if ([path.stringByStandardizingPath isEqualToString:main]) { self.selectedImagePath = path; break; }
    if (!self.selectedImagePath.length) self.selectedImagePath = self.images.firstObject;
}

- (void)rebuildImageMenu {
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSString *path in self.images) {
        UIAction *action = [UIAction actionWithTitle:[RYGRuntimeBrowserEngine shortNameForImagePath:path] image:nil identifier:nil handler:^(__unused UIAction *item) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.selectedImagePath = path;
            [NSUserDefaults.standardUserDefaults setObject:RYGBrowserImageID(path) forKey:kRYGRuntimeSelectedImageKey];
            [self rebuildImageMenu];
            [self loadSelectedImage];
        }];
        action.state = [path isEqualToString:self.selectedImagePath] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    self.imageButton.menu = [UIMenu menuWithTitle:@"Loaded executable and frameworks" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:actions];
    RYGLiquidGlassConfigureButton(self.imageButton, NO);
    NSString *name = self.selectedImagePath.length ? [RYGRuntimeBrowserEngine shortNameForImagePath:self.selectedImagePath] : @"None";
    UIButtonConfiguration *configuration = self.imageButton.configuration;
    if (configuration) {
        configuration.title = [NSString stringWithFormat:@"Image: %@", name];
        configuration.baseForegroundColor = UIColor.labelColor;
        self.imageButton.configuration = configuration;
    } else {
        [self.imageButton setTitle:[NSString stringWithFormat:@"Image: %@", name] forState:UIControlStateNormal];
    }
}

- (void)modeChanged:(UISegmentedControl *)sender {
    (void)sender;
    self.searchGeneration++;
    self.searchController.searchBar.placeholder = self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC ? @"Class, selector or typed getter" : @"C symbol";
    [self loadSelectedImage];
}

- (void)refreshTapped {
    [RYGRuntimeBrowserEngine invalidateRuntimeCaches];
    [self refreshImages];
    [self rebuildImageMenu];
    [self loadSelectedImage];
}

- (void)applyAllPersistedRuntimeValues {
    [RYGRuntimeBrowserEngine reinstallPersistedOverrides];
    NSUInteger installed = RYGRuntimeValueReinstallPersistedHooks();
    NSUInteger persisted = RYGRuntimeValueAllOverrideSpecs().count;
    [RYGUtils showToastForDuration:1.3
                             title:@"Runtime hooks applied"
                          subtitle:[NSString stringWithFormat:@"%lu/%lu typed hooks installed",
                                    (unsigned long)installed,
                                    (unsigned long)persisted]];
    [self.tableView reloadData];
}

- (void)loadSelectedImage {
    NSString *path = self.selectedImagePath.copy;
    NSUInteger generation = ++self.loadGeneration;
    self.searchGeneration++;
    self.classRows = @[];
    self.visibleClasses = @[];
    self.selectorMatches = @{};
    self.symbols = @[];
    self.visibleSymbols = @[];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;
    [self.tableView reloadData];

    if (!path.length) {
        [self.spinner stopAnimating];
        self.emptyLabel.text = @"No loaded image.";
        self.tableView.backgroundView = self.emptyLabel;
        return;
    }

    __weak typeof(self) weakSelf = self;
    if (self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<RYGRuntimeClassRow *> *rows = RYGBrowserClassNamesForImage(path);
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.loadGeneration || ![self.selectedImagePath isEqualToString:path]) return;
                self.classRows = rows;
                [self.spinner stopAnimating];
                [self applyObjectiveCFilter];
            });
        });
    } else {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray<RYGMachOSymbol *> *symbols = [RYGRuntimeBrowserEngine machOSymbolsForImagePath:path] ?: @[];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.loadGeneration || ![self.selectedImagePath isEqualToString:path]) return;
                self.symbols = symbols;
                [self.spinner stopAnimating];
                [self applyCSymbolFilter];
            });
        });
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    if (self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC) [self applyObjectiveCFilter];
    else [self applyCSymbolFilter];
}

- (void)applyCSymbolFilter {
    NSArray<NSString *> *tokens = RYGBrowserTokens(self.searchController.searchBar.text ?: @"");
    if (!tokens.count) self.visibleSymbols = self.symbols;
    else self.visibleSymbols = [self.symbols filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RYGMachOSymbol *symbol, NSDictionary *bindings) {
        (void)bindings;
        return RYGBrowserMatches([NSString stringWithFormat:@"%@ %@", symbol.name ?: @"", symbol.kind ?: @""], tokens);
    }]];
    self.emptyLabel.text = @"No C symbol matches.";
    self.tableView.backgroundView = self.visibleSymbols.count ? nil : self.emptyLabel;
    [self.tableView reloadData];
}

- (void)applyObjectiveCFilter {
    NSString *query = self.searchController.searchBar.text ?: @"";
    NSArray<NSString *> *tokens = RYGBrowserTokens(query);
    NSUInteger generation = ++self.searchGeneration;

    if (!tokens.count) {
        self.selectorMatches = @{};
        self.visibleClasses = self.classRows;
        self.emptyLabel.text = @"No Objective-C classes in this loaded image.";
        self.tableView.backgroundView = self.visibleClasses.count ? nil : self.emptyLabel;
        [self.tableView reloadData];
        return;
    }

    NSMutableArray<RYGRuntimeClassRow *> *classNameMatches = [NSMutableArray array];
    for (RYGRuntimeClassRow *row in self.classRows) if (RYGBrowserMatches(row.className ?: @"", tokens)) [classNameMatches addObject:row];
    self.visibleClasses = classNameMatches.copy;
    self.selectorMatches = @{};
    self.emptyLabel.text = @"Searching ABI-validated selectors in this image…";
    self.tableView.backgroundView = self.visibleClasses.count ? nil : self.emptyLabel;
    [self.tableView reloadData];

    NSString *path = self.selectedImagePath.copy;
    NSArray<RYGRuntimeClassRow *> *classes = self.classRows.copy;
    NSArray<RYGRuntimeClassRow *> *nameMatches = classNameMatches.copy;
    __weak typeof(self) weakSelf = self;

    // Cross-class selector scan is on-demand and starts only for a non-empty query.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(220 * NSEC_PER_MSEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RYGFastRuntimeBrowserViewController *owner = weakSelf;
        if (!owner || generation != owner.searchGeneration) return;

        NSMutableDictionary<NSString *, NSArray<RYGRuntimeMemberRow *> *> *matches = [NSMutableDictionary dictionary];
        NSMutableOrderedSet<NSString *> *matchedNames = [NSMutableOrderedSet orderedSet];
        for (RYGRuntimeClassRow *row in nameMatches) if (row.className.length) [matchedNames addObject:row.className];

        NSUInteger inspected = 0;
        for (RYGRuntimeClassRow *row in classes) {
            RYGFastRuntimeBrowserViewController *currentOwner = weakSelf;
            if (!currentOwner || generation != currentOwner.searchGeneration) return;
            NSArray<RYGRuntimeMemberRow *> *members = [RYGRuntimeBrowserEngine membersForClassName:row.className imagePath:path] ?: @[];
            NSMutableArray<RYGRuntimeMemberRow *> *memberMatches = nil;
            for (RYGRuntimeMemberRow *member in members) {
                NSString *text = [NSString stringWithFormat:@"%@ %@ %@", row.className ?: @"", member.name ?: @"", member.typeEncoding ?: @""];
                if (!RYGBrowserMatches(text, tokens)) continue;
                if (!memberMatches) memberMatches = [NSMutableArray array];
                [memberMatches addObject:member];
            }
            if (memberMatches.count) {
                matches[row.className] = memberMatches.copy;
                [matchedNames addObject:row.className];
            }
            inspected++;
            if ((inspected % 128) == 0 && generation != currentOwner.searchGeneration) return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.searchGeneration || ![self.selectedImagePath isEqualToString:path]) return;
            NSMutableDictionary<NSString *, RYGRuntimeClassRow *> *rowsByName = [NSMutableDictionary dictionary];
            for (RYGRuntimeClassRow *row in self.classRows) if (row.className.length) rowsByName[row.className] = row;
            NSMutableArray<RYGRuntimeClassRow *> *visible = [NSMutableArray array];
            for (NSString *name in matchedNames) {
                RYGRuntimeClassRow *row = rowsByName[name];
                if (row) [visible addObject:row];
            }
            [visible sortUsingComparator:^NSComparisonResult(RYGRuntimeClassRow *left, RYGRuntimeClassRow *right) {
                return [left.className localizedCaseInsensitiveCompare:right.className];
            }];
            self.selectorMatches = matches.copy;
            self.visibleClasses = visible.copy;
            self.emptyLabel.text = @"No class or ABI-validated runtime getter matched this image.";
            self.tableView.backgroundView = self.visibleClasses.count ? nil : self.emptyLabel;
            [self.tableView reloadData];
        });
    });
}

- (void)revealAllVisibilityRows {
    if (!self.allowsBulkVisibilityOverride || self.modeControl.selectedSegmentIndex != RYGRuntimeBrowserModeObjectiveC) return;
    NSUInteger changed = 0;
    for (NSArray<RYGRuntimeMemberRow *> *members in self.selectorMatches.allValues) {
        for (RYGRuntimeMemberRow *member in members) {
            RYGRuntimeBoolMethod *method = [RYGRuntimeBrowserEngine boolMethodForMember:member];
            if (!method) continue;
            NSString *name = [[[method.selectorName lowercaseString] componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
            NSNumber *desired = nil;
            if ([name hasPrefix:@"ishidden"] || [name hasPrefix:@"shouldhide"] || [name hasPrefix:@"hide"]) desired = @NO;
            else if ([name hasPrefix:@"shouldshow"] || [name hasPrefix:@"canshow"] || [name hasPrefix:@"isvisible"] || [name hasPrefix:@"isavailable"] || [name hasPrefix:@"shoulddisplay"]) desired = @YES;
            if (!desired) continue;
            [RYGRuntimeBrowserEngine setOverride:desired forMethod:method];
            changed++;
        }
    }
    [self.tableView reloadData];
    [RYGUtils showToastForDuration:1.3 title:@"Settings visibility applied" subtitle:[NSString stringWithFormat:@"%lu exact persisted gate(s)", (unsigned long)changed]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC ? self.visibleClasses.count : self.visibleSymbols.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeCSymbols) {
        NSUInteger rebindable = 0;
        for (RYGMachOSymbol *symbol in self.visibleSymbols) if (symbol.isRebindableImport) rebindable++;
        return [NSString stringWithFormat:@"%lu symbols · %lu rebindable imports", (unsigned long)self.visibleSymbols.count, (unsigned long)rebindable];
    }
    if (RYGBrowserTokens(self.searchController.searchBar.text ?: @"").count)
        return [NSString stringWithFormat:@"%lu matching classes · selector scan is on-demand", (unsigned long)self.visibleClasses.count];
    return [NSString stringWithFormat:@"%lu classes · methods are not indexed until needed", (unsigned long)self.visibleClasses.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RYGRuntimeRoot"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RYGRuntimeRoot"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC) {
        RYGRuntimeClassRow *row = self.visibleClasses[(NSUInteger)indexPath.row];
        cell.textLabel.text = row.className;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightMedium];
        NSUInteger matchCount = self.selectorMatches[row.className].count;
        cell.detailTextLabel.text = matchCount ? [NSString stringWithFormat:@"%lu matching runtime getter(s)", (unsigned long)matchCount] : @"Tap to inspect this class only";
    } else {
        RYGMachOSymbol *symbol = self.visibleSymbols[(NSUInteger)indexPath.row];
        cell.textLabel.text = symbol.name;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightMedium];
        NSString *state = symbol.overrideValue ? (symbol.overrideValue.boolValue ? @"Forced On" : @"Forced Off") : @"Native";
        cell.detailTextLabel.text = symbol.isRebindableImport ? [NSString stringWithFormat:@"rebindable import · %@", state] : [NSString stringWithFormat:@"%@ · 0x%llx", symbol.kind ?: @"symbol", (unsigned long long)symbol.address];
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)presentCABIForSymbol:(RYGMachOSymbol *)symbol value:(NSNumber *)value source:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"C BOOL ABI" message:@"Mach-O has no C prototype. Select only an integer/pointer-register BOOL ABI confirmed by disassembly." preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *titles = @[@"BOOL f(void)", @"BOOL f(x0)", @"BOOL f(x0,x1)", @"BOOL f(x0,x1,x2)", @"BOOL f(x0,x1,x2,x3)"];
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
        [sheet addAction:[UIAlertAction actionWithTitle:titles[(NSUInteger)index] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            RYGCFunctionABI abi = (RYGCFunctionABI)(RYGCFunctionABIBool0 + index);
            if (![RYGRuntimeBrowserEngine setCOverride:value forSymbol:symbol abi:abi]) [RYGUtils showErrorHUDWithDescription:@"C import rebinding failed"];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = source ?: self.view;
        sheet.popoverPresentationController.sourceRect = source ? source.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.modeControl.selectedSegmentIndex == RYGRuntimeBrowserModeObjectiveC) {
        RYGRuntimeClassRow *row = self.visibleClasses[(NSUInteger)indexPath.row];
        RYGRuntimeClassDetailViewController *detail = [[RYGRuntimeClassDetailViewController alloc] initWithImagePath:self.selectedImagePath className:row.className initialQuery:self.searchController.searchBar.text ?: @""];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    RYGMachOSymbol *symbol = self.visibleSymbols[(NSUInteger)indexPath.row];
    NSString *message = symbol.isRebindableImport ? @"This import can be rebound in this image without modifying __TEXT." : @"This symbol has no lazy/non-lazy import slot in this image and will not be patched.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:symbol.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy symbol" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { UIPasteboard.generalPasteboard.string = symbol.name ?: @""; }]];
    if (symbol.isRebindableImport) {
        if (symbol.overrideValue) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Use Native / remove rebinding" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                if (![RYGRuntimeBrowserEngine setCOverride:nil forSymbol:symbol abi:RYGCFunctionABIUnknown]) [RYGUtils showErrorHUDWithDescription:@"Could not restore original import binding"];
                [self.tableView reloadData];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force On…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self presentCABIForSymbol:symbol value:@YES source:cell]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force Off…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self presentCABIForSymbol:symbol value:@NO source:cell]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = cell;
        sheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
