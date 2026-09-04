#import "RYGDeveloperTypedFeatureViewController.h"
#import "../Features/ExpFlags/RYGMobileConfig.h"
#import "../UI/RYGLiquidGlass.h"
#import "../UI/RYGPopupChrome.h"
#import "../Utils.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdlib.h>

static const void *kRYGTypedFeatureParamKey = &kRYGTypedFeatureParamKey;

static NSString *RYGTypedNormalize(NSString *value) {
    if (!value.length) return @"";
    NSString *lower = value.lowercaseString;
    NSMutableString *out = [NSMutableString stringWithCapacity:lower.length];
    BOOL separated = YES;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        BOOL alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (alnum) {
            [out appendFormat:@"%C", c];
            separated = NO;
        } else if (!separated) {
            [out appendString:@" "];
            separated = YES;
        }
    }
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static BOOL RYGTypedContains(NSString *blob, NSString *needle) {
    if (!needle.length) return YES;
    if ([blob containsString:needle]) return YES;
    NSString *compactBlob = [blob stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSString *compactNeedle = [needle stringByReplacingOccurrencesOfString:@" " withString:@""];
    return compactNeedle.length && [compactBlob containsString:compactNeedle];
}

static NSArray<NSString *> *RYGTypedAlternatives(NSString *query) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [query componentsSeparatedByString:@"|"]) {
        NSString *normalized = RYGTypedNormalize(part);
        if (normalized.length) [out addObject:normalized];
    }
    return out.copy;
}

static BOOL RYGTypedDomainMatches(NSString *blob, NSArray<NSString *> *alternatives) {
    if (!alternatives.count) return YES;
    for (NSString *alternative in alternatives) if (RYGTypedContains(blob, alternative)) return YES;
    return NO;
}

static BOOL RYGTypedSearchMatches(NSString *blob, NSString *searchText) {
    NSString *normalized = RYGTypedNormalize(searchText);
    if (!normalized.length) return YES;
    for (NSString *token in [normalized componentsSeparatedByString:@" "]) {
        if (token.length && !RYGTypedContains(blob, token)) return NO;
    }
    return YES;
}

static NSString *RYGTypedValueString(id value) {
    if (!value || value == NSNull.null) return @"—";
    if ([value isKindOfClass:NSString.class]) return (NSString *)value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue] ?: @"—";
    return [value description] ?: @"—";
}

@interface RYGDeveloperTypedFeatureViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *domainTitle;
@property (nonatomic, copy) NSString *domainQuery;
@property (nonatomic, copy) NSArray<NSDictionary *> *allRows;
@property (nonatomic, copy) NSArray<NSDictionary *> *visibleRows;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) BOOL loading;
@end

@implementation RYGDeveloperTypedFeatureViewController

- (instancetype)initWithTitle:(NSString *)title query:(NSString *)query {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        NSString *copiedTitle = [title copy];
        _domainTitle = copiedTitle.length ? copiedTitle : @"Feature Flags";
        _domainQuery = [query copy] ?: @"";
        _allRows = @[];
        _visibleRows = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.domainTitle;
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Filter this feature domain";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.tableView.refreshControl = [UIRefreshControl new];
    [self.tableView.refreshControl addTarget:self action:@selector(forceReload) forControlEvents:UIControlEventValueChanged];
    RYGLiquidGlassApplyToViewController(self);
    [self loadRows:NO];
}

- (void)forceReload { [self loadRows:YES]; }

- (void)loadRows:(BOOL)force {
    if (self.loading && !force) return;
    self.loading = YES;
    NSUInteger generation = ++self.loadGeneration;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.tableView.backgroundView = spinner;
    NSString *domainQuery = self.domainQuery ?: @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        RYGMobileConfig *engine = RYGMobileConfig.shared;
        [engine prepare];
        if (force) [engine reloadFromRuntime];
        NSArray<NSString *> *alternatives = RYGTypedAlternatives(domainQuery);
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        for (RYGMCConfig *config in engine.allConfigs ?: @[]) {
            NSString *configName = config.displayName.length ? config.displayName : (config.name ?: @"");
            for (RYGMCParam *param in config.params ?: @[]) {
                if (!param.isRuntimeBacked || !RYGMCTypeIsRuntimeValue(param.type)) continue;
                NSString *blob = RYGTypedNormalize([NSString stringWithFormat:@"%@ %@ %u %u %llu %@",
                                                     configName ?: @"", param.name ?: @"", config.number,
                                                     param.paramIndex, param.paramID, param.typeName ?: @""]);
                if (!RYGTypedDomainMatches(blob, alternatives)) continue;
                [rows addObject:@{@"config":config, @"param":param, @"blob":blob ?: @""}];
            }
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            RYGMCConfig *lc = left[@"config"]; RYGMCConfig *rc = right[@"config"];
            NSComparisonResult result = [lc.displayName localizedCaseInsensitiveCompare:rc.displayName];
            if (result != NSOrderedSame) return result;
            RYGMCParam *lp = left[@"param"]; RYGMCParam *rp = right[@"param"];
            return [lp.name localizedCaseInsensitiveCompare:rp.name];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.loadGeneration) return;
            self.loading = NO;
            self.allRows = rows.copy;
            [self.tableView.refreshControl endRefreshing];
            [self applySearch];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self applySearch];
}

- (void)applySearch {
    if (self.loading) return;
    NSString *query = self.searchController.searchBar.text ?: @"";
    if (!query.length) self.visibleRows = self.allRows ?: @[];
    else {
        NSMutableArray *visible = [NSMutableArray array];
        for (NSDictionary *row in self.allRows ?: @[]) if (RYGTypedSearchMatches(row[@"blob"], query)) [visible addObject:row];
        self.visibleRows = visible.copy;
    }
    if (self.visibleRows.count) self.tableView.backgroundView = nil;
    else {
        UILabel *label = [UILabel new];
        label.text = @"No resolved typed runtime parameter matches this domain.";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.numberOfLines = 0;
        self.tableView.backgroundView = label;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.visibleRows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [NSString stringWithFormat:@"%lu resolved typed parameter%@",
            (unsigned long)self.visibleRows.count, self.visibleRows.count == 1 ? @"" : @"s"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"Only parameters whose type and live runtime backing are resolved are editable here. Swipe an overridden row to restore Instagram's native value.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RYGTypedFeature"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RYGTypedFeature"];
    NSDictionary *row = self.visibleRows[(NSUInteger)indexPath.row];
    RYGMCConfig *config = row[@"config"];
    RYGMCParam *param = row[@"param"];
    RYGMobileConfig *engine = RYGMobileConfig.shared;
    BOOL overridden = [engine overrideStateFor:param] == RYGMCOverrideSet;
    id effective = overridden ? [engine overrideValueFor:param] : [engine liveValueFor:param];

    cell.textLabel.text = param.name.length ? param.name : [NSString stringWithFormat:@"Parameter %u", param.paramIndex];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    cell.detailTextLabel.numberOfLines = 3;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · #%u:%u · %@\n%@ %@",
                                 config.displayName.length ? config.displayName : [NSString stringWithFormat:@"Config %u", config.number],
                                 config.number, param.paramIndex, param.typeName ?: @"typed",
                                 overridden ? @"Override" : @"Native", RYGTypedValueString(effective)];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (param.type == RYGMCTypeBool) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = [effective respondsToSelector:@selector(boolValue)] ? [effective boolValue] : NO;
        toggle.onTintColor = [RYGUtils RYGColor_Primary];
        objc_setAssociatedObject(toggle, kRYGTypedFeatureParamKey, param, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(boolChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)boolChanged:(UISwitch *)toggle {
    RYGMCParam *param = objc_getAssociatedObject(toggle, kRYGTypedFeatureParamKey);
    if (!param) return;
    if (![RYGMobileConfig.shared setOverride:@(toggle.isOn) for:param]) {
        toggle.on = !toggle.isOn;
        [RYGUtils showErrorHUDWithDescription:@"Instagram rejected this typed Boolean override"];
    }
    [self.tableView reloadData];
}

- (id)parsedValue:(NSString *)text forParam:(RYGMCParam *)param valid:(BOOL *)valid {
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (valid) *valid = YES;
    if (param.type == RYGMCTypeString) return text ?: @"";
    const char *raw = trim.UTF8String;
    if (param.type == RYGMCTypeInt) {
        if (!raw || !*raw) { if (valid) *valid = NO; return nil; }
        char *end = NULL; long long value = strtoll(raw, &end, 10);
        if (end == raw || *end != '\0') { if (valid) *valid = NO; return nil; }
        return @(value);
    }
    if (param.type == RYGMCTypeDouble) {
        if (!raw || !*raw) { if (valid) *valid = NO; return nil; }
        char *end = NULL; double value = strtod(raw, &end);
        if (end == raw || *end != '\0' || !isfinite(value)) { if (valid) *valid = NO; return nil; }
        return @(value);
    }
    if (valid) *valid = NO;
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.visibleRows[(NSUInteger)indexPath.row];
    RYGMCParam *param = row[@"param"];
    if (param.type == RYGMCTypeBool) return;
    RYGMobileConfig *engine = RYGMobileConfig.shared;
    id current = [engine overrideStateFor:param] == RYGMCOverrideSet ? [engine overrideValueFor:param] : [engine liveValueFor:param];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:param.name.length ? param.name : @"Typed value"
                                                                     message:[NSString stringWithFormat:@"%@ · stable PID %llu", param.typeName ?: @"typed", param.paramID]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = RYGTypedValueString(current);
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (param.type == RYGMCTypeInt) field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        else if (param.type == RYGMCTypeDouble) field.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        BOOL valid = NO;
        id value = [weakSelf parsedValue:alert.textFields.firstObject.text ?: @"" forParam:param valid:&valid];
        if (!valid || !value) {
            [RYGUtils showErrorHUDWithDescription:@"Value does not match the resolved runtime type"];
            return;
        }
        if (![RYGMobileConfig.shared setOverride:value for:param]) [RYGUtils showErrorHUDWithDescription:@"Instagram rejected this typed override"];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *row = self.visibleRows[(NSUInteger)indexPath.row];
    RYGMCParam *param = row[@"param"];
    if ([RYGMobileConfig.shared overrideStateFor:param] != RYGMCOverrideSet) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *native = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Native"
                                                                       handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
        [RYGMobileConfig.shared clearOverrideFor:param];
        [weakSelf.tableView reloadData];
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[native]];
}

@end
