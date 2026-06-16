// SCICSymbolBrowserViewController.m
#import "SCICSymbolBrowserViewController.h"
#import "../Features/Gating/SCICSymbolEngine.h"
#import "../Utils.h"

@interface SCICSymbolBrowserViewController () <UISearchResultsUpdating>
@end

@implementation SCICSymbolBrowserViewController {
    UISearchController *_searchController;
    NSTimer *_refreshTimer;
    NSString *_query;
}

- (instancetype)init {
    self = [super initWithTitle:@"FBShared C Symbols"];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _query = @"";

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search FBShared exports, ig_, EasyGating…";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(__unused NSTimer *t) {
        [self rebuild];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _query = searchController.searchBar.text ?: @"";
    [self rebuild];
}

- (NSString *)subtitleForImport:(SCICImport *)item {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:item.imageName ?: @"?"];
    if (item.symbolKind.length) [parts addObject:item.symbolKind];
    [parts addObject:item.resolvable ? @"resolvable" : @"unresolved"];
    if (item.hookable) [parts addObject:@"hookable"];
    else [parts addObject:@"enum-only"];
    if (item.forceAllowed) [parts addObject:(item.mobileConfigKeySymbol ? @"key force allowed" : @"force allowed")];
    else [parts addObject:@"force blocked"];
    if (item.mobileConfigKeySymbol && item.mobileConfigParamCount) [parts addObject:[NSString stringWithFormat:@"%lu param ids", (unsigned long)item.mobileConfigParamCount]];
    if (item.boolLike) [parts addObject:@"bool-like name"];
    if (item.hookInstalled) [parts addObject:@"hooked"];
    if (item.observedCallCount) [parts addObject:[NSString stringWithFormat:@"%lu hits", (unsigned long)item.observedCallCount]];
    NSNumber *observed = item.observedValue;
    if (observed) [parts addObject:[NSString stringWithFormat:@"real=%@", observed.boolValue ? @"YES" : @"NO"]];
    NSNumber *forced = item.override;
    if (forced) [parts addObject:[NSString stringWithFormat:@"forced=%@", forced.boolValue ? @"YES" : @"NO"]];
    return [parts componentsJoinedByString:@" • "];
}

- (void)rebuild {
    NSMutableArray<SCIBaseSettingsSection *> *sections = [NSMutableArray array];

    NSArray<SCICImport *> *hits = [SCICSymbolEngine searchImports:_query limit:200];
    NSString *masterFooter = [NSString stringWithFormat:@"FBShared exports: %lu. Hookable function profiles: %lu. Function symbols use fishhook only when ABI is curated. FBShared __const key symbols use MobileConfig typed overrides from their param-specifier records; no arbitrary C ABI guessing.", (unsigned long)[SCICSymbolEngine totalImportCount], (unsigned long)[SCICSymbolEngine hookableImportCount]];

    NSMutableArray<SCIBaseSettingsRow *> *master = [NSMutableArray array];
    [master addObject:[SCIBaseSettingsRow switchRowWithTitle:@"Enable C-symbol launch hooks"
        subtitle:@"Reinstalls only persisted known-safe C symbol hooks in %ctor. No symbol table scan runs at launch."
        value:^BOOL{ return [SCIUtils getBoolPref:@"sci_c_symbol_force_enabled"]; }
        action:^(BOOL on, UIViewController *vc){ [SCIUtils setPref:@(on) forKey:@"sci_c_symbol_force_enabled"]; }]];

    [master addObject:[SCIBaseSettingsRow switchRowWithTitle:@"Force curated single-purpose gates"
        subtitle:@"Only known single-purpose bool functions. Does not force MobileConfig/EasyGating/MCI multi-key readers."
        value:^BOOL{
            NSArray *names = [SCICSymbolEngine internalGateSymbolNames];
            if (!names.count) return NO;
            for (NSString *name in names) {
                if (![SCICSymbolEngine overrideForSymbolName:name]) return NO;
            }
            return YES;
        }
        action:^(BOOL on, UIViewController *vc){
            NSArray *changed = [SCICSymbolEngine forceInternalReadersEnabled:on];
            [SCIUtils showToastForDuration:1.2 title:(changed.count ? @"Curated gates updated" : @"No curated gates updated")];
        }]];

    [sections addObject:[SCIBaseSettingsSection sectionWithHeader:@"FBShared C symbol browser" footer:masterFooter rows:master]];

    for (SCICImport *item in hits) {
        NSString *name = item.symbolName;
        NSMutableArray<SCIBaseSettingsRow *> *rows = [NSMutableArray array];

        if (item.mobileConfigKeySymbol) {
            NSString *paramSubtitle = [NSString stringWithFormat:@"FBShared const key with %lu param specifier(s). Uses MobileConfig manual bool override, not fishhook.", (unsigned long)item.mobileConfigParamCount];
            [rows addObject:[SCIBaseSettingsRow rowWithTitle:@"MobileConfig key" subtitle:paramSubtitle action:nil]];
        } else if (item.hookable) {
            [rows addObject:[SCIBaseSettingsRow switchRowWithTitle:@"Observe only"
                subtitle:@"Known bool profile: fishhook consumers, call original, record hits/value, return original."
                value:^BOOL{ return [SCICSymbolEngine isObserving:name]; }
                action:^(BOOL on, UIViewController *vc){
                    BOOL ok = [SCICSymbolEngine setObserve:on forSymbolName:name];
                    if (!ok) [SCIUtils showToastForDuration:1.6 title:@"Observe blocked for this symbol"];
                }]];
        } else {
            [rows addObject:[SCIBaseSettingsRow rowWithTitle:@"Observe blocked" subtitle:item.safetyReason action:nil]];
        }

        if (item.forceAllowed) {
            NSString *forceTitle = item.mobileConfigKeySymbol ? @"Force MobileConfig key YES" : @"Force return YES";
            NSString *forceSubtitle = item.mobileConfigKeySymbol ? @"Sets typed bool overrides for this FBShared key's param specifier(s). Installs MobileConfig runtime hooks if needed." : @"Known single-purpose bool function. Returns YES after calling orig. Requires caution/restart for persisted launch hook.";
            [rows addObject:[SCIBaseSettingsRow switchRowWithTitle:forceTitle
                subtitle:forceSubtitle
                value:^BOOL{ NSNumber *o = [SCICSymbolEngine overrideForSymbolName:name]; return o.boolValue; }
                action:^(BOOL on, UIViewController *vc){
                    BOOL ok = [SCICSymbolEngine setForce:(on ? @YES : nil) forSymbolName:name];
                    if (!ok) [SCIUtils showToastForDuration:1.6 title:@"Force blocked for this symbol"];
                }]];
        } else {
            [rows addObject:[SCIBaseSettingsRow rowWithTitle:@"Force blocked" subtitle:item.safetyReason action:nil]];
        }

        SCIBaseSettingsRow *diag = [SCIBaseSettingsRow rowWithTitle:name subtitle:[self subtitleForImport:item] action:nil];
        diag.dynamicSubtitle = ^NSString *{ return [self subtitleForImport:item]; };
        [rows addObject:diag];

        [sections addObject:[SCIBaseSettingsSection sectionWithHeader:name footer:nil rows:rows]];
    }

    self.sections = sections;
    [self reloadSettings];
}

@end
