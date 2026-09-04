#import "RYGPortedRuntimeBrowserViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeValueStore.h"
#import "../UI/RYGLiquidGlass.h"
#import "../UI/RYGPopupChrome.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kRYGPortSelectedImageKey = @"ryg_runtime_port_selected_image_v1";
static const void *kRYGPortEntryKey = &kRYGPortEntryKey;

typedef NS_ENUM(NSInteger, RYGPortScope) {
    RYGPortScopeAll = 0,
    RYGPortScopeBoolean,
    RYGPortScopeNumeric,
    RYGPortScopeObject,
    RYGPortScopeOverrides,
};

static NSString *RYGPortShortImage(NSString *path) {
    if (!path.length) return @"Runtime";
    NSString *exec = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    NSString *standard = path.stringByStandardizingPath;
    if ([standard isEqualToString:exec]) return @"Instagram Executable";
    NSString *name = path.lastPathComponent ?: path;
    if ([name.lowercaseString containsString:@"fbsharedframework"]) return @"FBSharedFramework";
    return name.length ? name : @"Runtime";
}

static NSArray<NSString *> *RYGPortTokens(NSString *query) {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *part in [(query ?: @"").lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (part.length) [tokens addObject:part];
    }
    return tokens.copy;
}

static BOOL RYGPortMatches(NSString *haystack, NSArray<NSString *> *tokens) {
    if (!tokens.count) return YES;
    NSString *lower = haystack.lowercaseString ?: @"";
    NSString *compact = [[lower componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    for (NSString *group in tokens) {
        BOOL matched = NO;
        for (NSString *token in [group componentsSeparatedByString:@"|"]) {
            if (!token.length) continue;
            NSString *compactToken = [[token componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
            if ([lower containsString:token] || (compactToken.length && [compact containsString:compactToken])) {
                matched = YES;
                break;
            }
        }
        if (!matched) return NO;
    }
    return YES;
}

static BOOL RYGPortScopeMatches(RYGRuntimeMemberRow *entry, RYGPortScope scope) {
    if (!entry.hookableValue) return NO;
    switch (scope) {
        case RYGPortScopeBoolean: return RYGRuntimeValueTypeIsBoolean(entry.valueTypeCode);
        case RYGPortScopeNumeric: return RYGRuntimeValueTypeIsSignedInteger(entry.valueTypeCode) || RYGRuntimeValueTypeIsUnsignedInteger(entry.valueTypeCode) || RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode);
        case RYGPortScopeObject: return RYGRuntimeValueTypeIsObject(entry.valueTypeCode);
        case RYGPortScopeOverrides: return RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember);
        default: return YES;
    }
}

static NSString *RYGPortCompactObject(id value) {
    if (!value || value == NSNull.null) return @"nil";
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) text = value;
    else if ([NSJSONSerialization isValidJSONObject:value]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    }
    if (!text.length) text = [value description] ?: @"?";
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    if (text.length > 120) text = [[text substringToIndex:120] stringByAppendingString:@"…"];
    return text;
}

#pragma mark - Runtime receiver resolution (WATweaks port)

static BOOL RYGPortExactReceiver(id object, Class cls, SEL selector) {
    return object && cls && [object isKindOfClass:cls] && [object respondsToSelector:selector];
}

static id RYGPortFindInView(UIView *view, Class cls, SEL selector) {
    if (!view) return nil;
    if (RYGPortExactReceiver(view, cls, selector)) return view;
    for (UIView *subview in view.subviews) {
        id found = RYGPortFindInView(subview, cls, selector);
        if (found) return found;
    }
    return nil;
}

static id RYGPortFindInController(UIViewController *controller, Class cls, SEL selector) {
    if (!controller) return nil;
    if (RYGPortExactReceiver(controller, cls, selector)) return controller;
    id inView = RYGPortFindInView(controller.viewIfLoaded, cls, selector);
    if (inView) return inView;
    if (controller.presentedViewController) {
        id found = RYGPortFindInController(controller.presentedViewController, cls, selector);
        if (found) return found;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers.reverseObjectEnumerator) {
            id found = RYGPortFindInController(child, cls, selector);
            if (found) return found;
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)controller).viewControllers ?: @[]) {
            id found = RYGPortFindInController(child, cls, selector);
            if (found) return found;
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = RYGPortFindInController(child, cls, selector);
        if (found) return found;
    }
    return nil;
}

static id RYGPortSingletonReceiver(Class cls, SEL selector) {
    if (!cls) return nil;
    for (NSString *name in @[@"shared", @"sharedInstance", @"current", @"defaultInstance", @"defaultManager", @"manager", @"provider", @"properties", @"instance", @"getInstance"]) {
        SEL factory = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, factory);
        if (!method || method_getNumberOfArguments(method) != 2) continue;
        char raw[32] = {0};
        method_getReturnType(method, raw, sizeof(raw));
        const char *cursor = raw;
        while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
        if (*cursor != '@') continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)((id)cls, factory);
            if (RYGPortExactReceiver(value, cls, selector)) return value;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static id RYGPortGraphSearch(id root, Class wantedClass, SEL selector, NSHashTable *visited, NSUInteger depth, NSUInteger *budget) {
    if (!root || !wantedClass || !budget || !*budget || depth > 3) return nil;
    if ([visited containsObject:root]) return nil;
    [visited addObject:root];
    (*budget)--;
    if (RYGPortExactReceiver(root, wantedClass, selector)) return root;
    for (Class current = [root class]; current && current != NSObject.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; ivars && index < count; index++) {
            const char *encoding = ivar_getTypeEncoding(ivars[index]);
            if (!encoding) continue;
            while (*encoding && strchr("rnNoORV", *encoding)) encoding++;
            if (*encoding != '@') continue;
            id child = nil;
            @try { child = object_getIvar(root, ivars[index]); }
            @catch (__unused NSException *exception) { child = nil; }
            if (!child || child == root) continue;
            id found = RYGPortGraphSearch(child, wantedClass, selector, visited, depth + 1, budget);
            if (found) { free(ivars); return found; }
            if (!*budget) { free(ivars); return nil; }
        }
        free(ivars);
    }
    return nil;
}

static id RYGPortResolveReceiver(RYGRuntimeMemberRow *entry, NSMutableDictionary<NSString *, id> *cache) {
    if (!entry || entry.classMember) return nil;
    Class cls = NSClassFromString(entry.className) ?: objc_getClass(entry.className.UTF8String);
    SEL selector = NSSelectorFromString(entry.name);
    if (!cls || !selector) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%@", entry.className ?: @"", entry.name ?: @""];
    id cached = cache[key];
    if (cached && RYGPortExactReceiver(cached, cls, selector)) return cached;

    id singleton = RYGPortSingletonReceiver(cls, selector);
    if (singleton) { cache[key] = singleton; return singleton; }

    UIApplication *application = UIApplication.sharedApplication;
    id delegate = application.delegate;
    if (RYGPortExactReceiver(delegate, cls, selector)) { cache[key] = delegate; return delegate; }
    for (UIWindow *window in application.windows) {
        if (RYGPortExactReceiver(window, cls, selector)) { cache[key] = window; return window; }
        id found = RYGPortFindInController(window.rootViewController, cls, selector);
        if (found) { cache[key] = found; return found; }
    }

    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger budget = 220;
    if (delegate) {
        id found = RYGPortGraphSearch(delegate, cls, selector, visited, 0, &budget);
        if (found) { cache[key] = found; return found; }
    }
    return nil;
}

#pragma mark - Fullscreen object editor

@interface RYGPortObjectEditorViewController : UIViewController
@property(nonatomic, copy) NSString *className;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic, copy) NSString *typeCode;
@property(nonatomic, assign) BOOL classMethod;
@property(nonatomic, strong) id nativeValue;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, copy) dispatch_block_t completion;
@end

@implementation RYGPortObjectEditorViewController

- (NSString *)textForObject:(id)value {
    if (!value || value == NSNull.null) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSDate.class]) return [NSString stringWithFormat:@"%.6f", [(NSDate *)value timeIntervalSince1970]];
    id json = [value isKindOfClass:NSSet.class] ? [(NSSet *)value allObjects] : value;
    if ([NSJSONSerialization isValidJSONObject:json]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text.length) return text;
    }
    return [value description] ?: @"";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.selectorName.length ? self.selectorName : @"Runtime Object";
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(save)];

    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    text.autocorrectionType = UITextAutocorrectionTypeNo;
    text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text.backgroundColor = UIColor.secondarySystemBackgroundColor;
    text.layer.cornerRadius = 14.0;
    text.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    id initial = RYGRuntimeValueHasOverride(self.className, self.selectorName, self.classMethod)
        ? RYGRuntimeValueOverride(self.className, self.selectorName, self.classMethod) : self.nativeValue;
    text.text = [self textForObject:initial];
    self.textView = text;
    [self.view addSubview:text];

    UILabel *help = [UILabel new];
    help.translatesAutoresizingMaskIntoConstraints = NO;
    help.numberOfLines = 0;
    help.font = [UIFont systemFontOfSize:11.5];
    help.textColor = UIColor.secondaryLabelColor;
    help.text = [NSString stringWithFormat:@"%@ · %@\nNSString preserves text/JSON as NSString. NSArray/NSDictionary use JSON. NSSet uses a JSON array. URL/Data/Date preserve their Foundation type.", self.className ?: @"Runtime", NSStringFromClass([self.nativeValue class]) ?: @"object"];
    [self.view addSubview:help];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [help.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [help.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [help.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [text.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
        [text.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
    ]];
    RYGLiquidGlassApplyToViewController(self);
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (id)parsedValue:(NSString **)error {
    NSString *text = self.textView.text ?: @"";
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    id current = self.nativeValue;
    if ([current isKindOfClass:NSString.class] || !current) return text;
    if ([current isKindOfClass:NSURL.class]) {
        NSURL *url = [NSURL URLWithString:trim];
        if (!url && error) *error = @"Invalid URL";
        return url;
    }
    if ([current isKindOfClass:NSData.class]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:trim options:0];
        if (!data && error) *error = @"Invalid Base64";
        return data;
    }
    if ([current isKindOfClass:NSDate.class]) {
        char *end = NULL; double value = strtod(trim.UTF8String ?: "", &end);
        if (!end || *end != '\0') { if (error) *error = @"Invalid timestamp"; return nil; }
        return [NSDate dateWithTimeIntervalSince1970:value];
    }
    NSData *data = [trim dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError] : nil;
    if (!json || jsonError) { if (error) *error = jsonError.localizedDescription ?: @"Invalid JSON"; return nil; }
    if ([current isKindOfClass:NSSet.class]) {
        if (![json isKindOfClass:NSArray.class]) { if (error) *error = @"NSSet requires a JSON array"; return nil; }
        return [NSSet setWithArray:json];
    }
    if ([current isKindOfClass:NSArray.class] && ![json isKindOfClass:NSArray.class]) { if (error) *error = @"Expected JSON array"; return nil; }
    if ([current isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSDictionary.class]) { if (error) *error = @"Expected JSON object"; return nil; }
    return json;
}

- (void)save {
    NSString *error = nil;
    id value = [self parsedValue:&error];
    if (!value) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Invalid value" message:error ?: @"Could not parse value" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    RYGRuntimeValueSetOverride(self.className, self.selectorName, self.classMethod, self.typeCode, value);
    (void)RYGRuntimeValueInstallHook(self.className, self.selectorName, self.classMethod, self.typeCode);
    dispatch_block_t completion = self.completion;
    [self dismissViewControllerAnimated:YES completion:completion];
}
@end

#pragma mark - Typed image surface

@interface RYGPortedRuntimeImageViewController : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate, UITextFieldDelegate>
@property(nonatomic, copy) NSString *imagePath;
@property(nonatomic, copy) NSString *initialQuery;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, copy) NSArray<RYGRuntimeMemberRow *> *allEntries;
@property(nonatomic, copy) NSArray<NSString *> *sectionKeys;
@property(nonatomic, copy) NSDictionary<NSString *, NSArray<RYGRuntimeMemberRow *> *> *sections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *receiverCache;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) NSUInteger generation;
@end

@implementation RYGPortedRuntimeImageViewController

- (instancetype)initWithImagePath:(NSString *)path query:(NSString *)query {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _imagePath = [path copy] ?: @"";
        _initialQuery = [query copy] ?: @"";
        _allEntries = @[];
        _sectionKeys = @[];
        _sections = @{};
        _receiverCache = [NSMutableDictionary dictionary];
        self.title = RYGPortShortImage(path);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74.0;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.searchBar.delegate = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Class, selector, ABI or type";
    search.searchBar.scopeButtonTitles = @[@"All", @"BOOL", @"Numbers", @"Objects", @"Overrides"];
    search.searchBar.text = self.initialQuery;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.search = search;

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(scanNow)];
    UIBarButtonItem *apply = [[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(applyAll)];
    self.navigationItem.rightBarButtonItems = @[apply, refresh];

    UIRefreshControl *pull = [UIRefreshControl new];
    [pull addTarget:self action:@selector(scanNow) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = pull;
    RYGLiquidGlassApplyToViewController(self);
    [self scanNow];
}

- (void)scanNow {
    if (self.scanning) return;
    self.scanning = YES;
    NSUInteger generation = ++self.generation;
    NSString *image = self.imagePath.copy;
    self.title = @"Scanning runtime…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<RYGRuntimeMemberRow *> *entries = [NSMutableArray array];
        NSArray<RYGRuntimeClassRow *> *classes = [RYGRuntimeBrowserEngine classesForImagePath:image] ?: @[];
        for (RYGRuntimeClassRow *classRow in classes) {
            @autoreleasepool {
                NSArray<RYGRuntimeMemberRow *> *members = [RYGRuntimeBrowserEngine membersForClassName:classRow.className imagePath:image] ?: @[];
                for (RYGRuntimeMemberRow *member in members) {
                    if (!member.method || !member.hookableValue) continue;
                    if (!RYGRuntimeValueTypeIsSupported(member.valueTypeCode)) continue;
                    if (!RYGRuntimeValueSelectorIsSafeGetter(member.name)) continue;
                    [entries addObject:member];
                }
            }
        }
        [entries sortUsingComparator:^NSComparisonResult(RYGRuntimeMemberRow *left, RYGRuntimeMemberRow *right) {
            NSComparisonResult byClass = [left.className localizedCaseInsensitiveCompare:right.className];
            return byClass == NSOrderedSame ? [left.name localizedCaseInsensitiveCompare:right.name] : byClass;
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.scanning = NO;
            [self.refreshControl endRefreshing];
            self.allEntries = entries.copy;
            [self.receiverCache removeAllObjects];
            [self applyFilter];
        });
    });
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController { [self applyFilter]; }
- (void)searchBar:(__unused UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(__unused NSInteger)selectedScope { [self applyFilter]; }

- (void)applyFilter {
    NSArray<NSString *> *tokens = RYGPortTokens(self.search.searchBar.text ?: @"");
    RYGPortScope scope = (RYGPortScope)self.search.searchBar.selectedScopeButtonIndex;
    NSMutableDictionary<NSString *, NSMutableArray<RYGRuntimeMemberRow *> *> *groups = [NSMutableDictionary dictionary];
    NSUInteger visible = 0, active = 0;
    for (RYGRuntimeMemberRow *entry in self.allEntries) {
        if (!RYGPortScopeMatches(entry, scope)) continue;
        NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@", entry.className ?: @"", entry.name ?: @"", entry.typeEncoding ?: @"", entry.valueTypeCode ?: @"", RYGRuntimeValueTypeName(entry.valueTypeCode) ?: @""];
        if (!RYGPortMatches(haystack, tokens)) continue;
        NSString *section = entry.className.length ? entry.className : @"Runtime";
        if (!groups[section]) groups[section] = [NSMutableArray array];
        [groups[section] addObject:entry];
        visible++;
        if (RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember)) active++;
    }
    self.sectionKeys = [groups.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    self.sections = groups.copy;
    NSString *base = [NSString stringWithFormat:@"%@ (%lu)", RYGPortShortImage(self.imagePath), (unsigned long)visible];
    self.title = active ? [base stringByAppendingFormat:@" · %lu active", (unsigned long)active] : base;
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return (NSInteger)self.sectionKeys.count; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return 0;
    return (NSInteger)self.sections[self.sectionKeys[(NSUInteger)section]].count;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) return nil;
    NSString *key = self.sectionKeys[(NSUInteger)section];
    return [NSString stringWithFormat:@"%@ (%lu)", key, (unsigned long)self.sections[key].count];
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sectionKeys.count - 1) return nil;
    return @"Ported from WATweaks dogfood2: runtime-backed no-argument getters only. BOOL uses direct switches; numeric/string/object values use typed editors. Overrides persist before hook installation and remain pending when an image/receiver is not ready.";
}

- (RYGRuntimeMemberRow *)entryAtIndexPath:(NSIndexPath *)path {
    if (!path || path.section >= (NSInteger)self.sectionKeys.count) return nil;
    NSArray *rows = self.sections[self.sectionKeys[(NSUInteger)path.section]];
    return path.row < (NSInteger)rows.count ? rows[(NSUInteger)path.row] : nil;
}

- (NSString *)currentForEntry:(RYGRuntimeMemberRow *)entry raw:(id *)raw {
    id receiver = entry.classMember ? nil : RYGPortResolveReceiver(entry, self.receiverCache);
    return RYGRuntimeValueRead(entry.className, entry.name, entry.classMember, receiver, raw);
}

- (BOOL)installValue:(id)value forEntry:(RYGRuntimeMemberRow *)entry {
    if (!entry || (!value && !RYGRuntimeValueTypeIsObject(entry.valueTypeCode))) return NO;
    RYGRuntimeValueSetOverride(entry.className, entry.name, entry.classMember, entry.valueTypeCode, value ?: NSNull.null);
    return RYGRuntimeValueInstallHook(entry.className, entry.name, entry.classMember, entry.valueTypeCode);
}

- (void)switchChanged:(UISwitch *)sender {
    RYGRuntimeMemberRow *entry = objc_getAssociatedObject(sender, kRYGPortEntryKey);
    if (!entry) return;
    (void)[self installValue:@(sender.isOn) forEntry:entry];
    UITableViewCell *cell = nil;
    for (UIView *cursor = sender; cursor; cursor = cursor.superview) if ([cursor isKindOfClass:UITableViewCell.class]) { cell = (UITableViewCell *)cursor; break; }
    NSIndexPath *path = cell ? [self.tableView indexPathForCell:cell] : nil;
    if (path) [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

- (id)parsedField:(UITextField *)field entry:(RYGRuntimeMemberRow *)entry valid:(BOOL *)valid {
    if (valid) *valid = NO;
    NSString *trim = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (RYGRuntimeValueTypeIsSignedInteger(entry.valueTypeCode)) {
        const char *start = trim.UTF8String ?: ""; char *end = NULL; long long value = strtoll(start, &end, 0);
        if (end && end != start && *end == '\0') { if (valid) *valid = YES; return @(value); }
    } else if (RYGRuntimeValueTypeIsUnsignedInteger(entry.valueTypeCode)) {
        if ([trim hasPrefix:@"-"]) return nil;
        const char *start = trim.UTF8String ?: ""; char *end = NULL; unsigned long long value = strtoull(start, &end, 0);
        if (end && end != start && *end == '\0') { if (valid) *valid = YES; return @(value); }
    } else if (RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode)) {
        NSString *normalized = [trim stringByReplacingOccurrencesOfString:@"," withString:@"."];
        const char *start = normalized.UTF8String ?: ""; char *end = NULL; double value = strtod(start, &end);
        if (end && end != start && *end == '\0' && isfinite(value)) { if (valid) *valid = YES; return @(value); }
    } else if (RYGRuntimeValueTypeIsObject(entry.valueTypeCode)) {
        if (valid) *valid = YES; return field.text ?: @"";
    }
    return nil;
}

- (void)fieldCommitted:(UITextField *)field {
    RYGRuntimeMemberRow *entry = objc_getAssociatedObject(field, kRYGPortEntryKey);
    BOOL valid = NO;
    id value = [self parsedField:field entry:entry valid:&valid];
    if (!valid || !value) { field.textColor = UIColor.systemRedColor; return; }
    (void)[self installValue:value forEntry:entry];
    field.textColor = RYGRuntimeValueHookIsInstalled(entry.className, entry.name, entry.classMember) ? UIColor.systemBlueColor : UIColor.systemOrangeColor;
}

- (UITextField *)fieldForEntry:(RYGRuntimeMemberRow *)entry value:(id)value {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 132, 36)];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    field.textAlignment = NSTextAlignmentRight;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    field.text = value ? [value description] : @"";
    field.keyboardType = RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode) ? UIKeyboardTypeDecimalPad : (RYGRuntimeValueTypeIsObject(entry.valueTypeCode) ? UIKeyboardTypeDefault : UIKeyboardTypeNumbersAndPunctuation);
    objc_setAssociatedObject(field, kRYGPortEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [field addTarget:self action:@selector(fieldCommitted:) forControlEvents:UIControlEventEditingDidEnd];
    return field;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *reuse = @"RYGPortedRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    RYGRuntimeMemberRow *entry = [self entryAtIndexPath:path];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 3;
    if (!entry) return cell;

    id raw = nil;
    NSString *current = [self currentForEntry:entry raw:&raw] ?: @"?";
    BOOL overridden = RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember);
    BOOL installed = overridden && RYGRuntimeValueHookIsInstalled(entry.className, entry.name, entry.classMember);
    id forced = overridden ? RYGRuntimeValueOverride(entry.className, entry.name, entry.classMember) : nil;
    id effective = overridden ? forced : raw;
    NSString *typeName = RYGRuntimeValueTypeName(entry.valueTypeCode) ?: entry.valueTypeCode ?: @"?";
    NSString *state = overridden ? (installed ? @"OVERRIDE · INSTALLED" : @"OVERRIDE · PENDING") : @"NATIVE";
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", entry.classMember ? @"+" : @"−", entry.name ?: @"?"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@\n%@ · %@", typeName, entry.typeEncoding ?: @"", current, state, RYGPortCompactObject(effective)];
    cell.detailTextLabel.textColor = overridden ? (installed ? UIColor.systemBlueColor : UIColor.systemOrangeColor) : UIColor.secondaryLabelColor;

    if (RYGRuntimeValueTypeIsBoolean(entry.valueTypeCode)) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = effective && [effective respondsToSelector:@selector(boolValue)] ? [effective boolValue] : NO;
        toggle.onTintColor = overridden ? (installed ? UIColor.systemBlueColor : UIColor.systemOrangeColor) : UIColor.systemGreenColor;
        objc_setAssociatedObject(toggle, kRYGPortEntryKey, entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (RYGRuntimeValueTypeIsSignedInteger(entry.valueTypeCode) || RYGRuntimeValueTypeIsUnsignedInteger(entry.valueTypeCode) || RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode) || (RYGRuntimeValueTypeIsObject(entry.valueTypeCode) && (!effective || [effective isKindOfClass:NSString.class]))) {
        UITextField *field = [self fieldForEntry:entry value:effective];
        field.textColor = overridden ? (installed ? UIColor.systemBlueColor : UIColor.systemOrangeColor) : UIColor.labelColor;
        cell.accessoryView = field;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)presentScalarEditor:(RYGRuntimeMemberRow *)entry current:(id)raw {
    BOOL overridden = RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember);
    id forced = overridden ? RYGRuntimeValueOverride(entry.className, entry.name, entry.classMember) : nil;
    NSString *typeName = RYGRuntimeValueTypeName(entry.valueTypeCode) ?: entry.valueTypeCode;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry.name message:[NSString stringWithFormat:@"%@ · %@\n%@", entry.className ?: @"Runtime", typeName ?: @"?", overridden ? @"Override persisted" : @"Native value"] preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    __weak typeof(self) weakSelf = self;
    if (RYGRuntimeValueTypeIsBoolean(entry.valueTypeCode)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force YES" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [weakSelf installValue:@YES forEntry:entry]; [weakSelf applyFilter]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Force NO" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [weakSelf installValue:@NO forEntry:entry]; [weakSelf applyFilter]; }]];
    }
    if (overridden) [sheet addAction:[UIAlertAction actionWithTitle:@"Use Native" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){ RYGRuntimeValueClearOverride(entry.className, entry.name, entry.classMember); [weakSelf applyFilter]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy value" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ UIPasteboard.generalPasteboard.string = RYGPortCompactObject(overridden ? forced : raw); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    RYGRuntimeMemberRow *entry = [self entryAtIndexPath:path];
    if (!entry) return;
    id raw = nil;
    (void)[self currentForEntry:entry raw:&raw];
    if (RYGRuntimeValueTypeIsObject(entry.valueTypeCode) && (!raw || ![raw isKindOfClass:NSString.class])) {
        RYGPortObjectEditorViewController *editor = [RYGPortObjectEditorViewController new];
        editor.className = entry.className;
        editor.selectorName = entry.name;
        editor.classMethod = entry.classMember;
        editor.typeCode = entry.valueTypeCode;
        editor.nativeValue = raw;
        __weak typeof(self) weakSelf = self;
        editor.completion = ^{ [weakSelf applyFilter]; };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    [self presentScalarEditor:entry current:raw];
}

- (void)applyAll {
    NSUInteger active = 0, installed = 0;
    for (RYGRuntimeMemberRow *entry in self.allEntries) {
        if (!RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember)) continue;
        active++;
        if (RYGRuntimeValueInstallHook(entry.className, entry.name, entry.classMember, entry.valueTypeCode)) installed++;
    }
    NSUInteger pending = active >= installed ? active - installed : 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply Runtime" message:[NSString stringWithFormat:@"Overrides in this image: %lu\nInstalled/reapplied: %lu\nPending: %lu", (unsigned long)active, (unsigned long)installed, (unsigned long)pending] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self applyFilter];
}
@end

#pragma mark - Image surface list

@interface RYGPortedRuntimeBrowserViewController () <UISearchResultsUpdating>
@property(nonatomic, copy) NSString *browserTitle;
@property(nonatomic, copy) NSString *initialQuery;
@property(nonatomic, assign) BOOL allowsBulkVisibilityOverride;
@property(nonatomic, copy) NSArray<NSString *> *primaryImages;
@property(nonatomic, copy) NSArray<NSString *> *otherImages;
@property(nonatomic, copy) NSArray<NSString *> *visiblePrimary;
@property(nonatomic, copy) NSArray<NSString *> *visibleOthers;
@property(nonatomic, strong) UISearchController *search;
@end

@implementation RYGPortedRuntimeBrowserViewController

- (instancetype)init { return [self initWithTitle:@"Runtime Browser" initialQuery:@"" allowsBulkVisibilityOverride:NO]; }
- (instancetype)initWithTitle:(NSString *)title initialQuery:(NSString *)query { return [self initWithTitle:title initialQuery:query allowsBulkVisibilityOverride:NO]; }
- (instancetype)initWithTitle:(NSString *)title initialQuery:(NSString *)query allowsBulkVisibilityOverride:(BOOL)bulk {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        NSString *copy = [title copy];
        _browserTitle = copy.length ? copy : @"Runtime Browser";
        _initialQuery = [query copy] ?: @"";
        _allowsBulkVisibilityOverride = bulk;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.browserTitle;
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Filter loaded images";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.search = search;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Apply All" style:UIBarButtonItemStyleDone target:self action:@selector(applyAllPersisted)];
    [self rebuildImages];
    RYGLiquidGlassApplyToViewController(self);
}

- (void)rebuildImages {
    NSArray<NSString *> *images = [RYGRuntimeBrowserEngine runtimeImagePaths] ?: @[];
    NSMutableArray *primary = [NSMutableArray array];
    NSMutableArray *others = [NSMutableArray array];
    NSString *exec = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    for (NSString *image in images) {
        NSString *standard = image.stringByStandardizingPath;
        NSString *lower = image.lastPathComponent.lowercaseString ?: @"";
        if ([standard isEqualToString:exec] || [lower containsString:@"fbsharedframework"]) [primary addObject:image];
        else [others addObject:image];
    }
    [primary sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b){
        BOOL aExec = [a.stringByStandardizingPath isEqualToString:exec];
        BOOL bExec = [b.stringByStandardizingPath isEqualToString:exec];
        if (aExec != bExec) return aExec ? NSOrderedAscending : NSOrderedDescending;
        return [RYGPortShortImage(a) localizedCaseInsensitiveCompare:RYGPortShortImage(b)];
    }];
    [others sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b){ return [RYGPortShortImage(a) localizedCaseInsensitiveCompare:RYGPortShortImage(b)]; }];
    self.primaryImages = primary.copy;
    self.otherImages = others.copy;
    [self applyImageFilter];
}

- (void)updateSearchResultsForSearchController:(__unused UISearchController *)searchController { [self applyImageFilter]; }
- (void)applyImageFilter {
    NSArray *tokens = RYGPortTokens(self.search.searchBar.text ?: @"");
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSString *path, __unused NSDictionary *bindings){ return RYGPortMatches([NSString stringWithFormat:@"%@ %@", RYGPortShortImage(path), path], tokens); }];
    self.visiblePrimary = tokens.count ? [self.primaryImages filteredArrayUsingPredicate:predicate] : self.primaryImages;
    self.visibleOthers = tokens.count ? [self.otherImages filteredArrayUsingPredicate:predicate] : self.otherImages;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.visibleOthers.count ? 2 : 1; }
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? (NSInteger)self.visiblePrimary.count : (NSInteger)self.visibleOthers.count; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"Primary runtime images" : @"Loaded frameworks"; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != [self numberOfSectionsInTableView:tableView] - 1) return nil;
    return @"Select an image to build the typed runtime surface. Unlike the legacy class drill-down, this port scans ABI-validated getters into one searchable table with BOOL, numeric, object and override scopes.";
}

- (NSString *)imageAtPath:(NSIndexPath *)path {
    NSArray *rows = path.section == 0 ? self.visiblePrimary : self.visibleOthers;
    return path.row < (NSInteger)rows.count ? rows[(NSUInteger)path.row] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    static NSString *reuse = @"RYGPortRuntimeImage";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    NSString *image = [self imageAtPath:path];
    cell.textLabel.text = RYGPortShortImage(image);
    cell.detailTextLabel.text = image;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSString *image = [self imageAtPath:path];
    if (!image.length) return;
    [NSUserDefaults.standardUserDefaults setObject:image forKey:kRYGPortSelectedImageKey];
    RYGPortedRuntimeImageViewController *detail = [[RYGPortedRuntimeImageViewController alloc] initWithImagePath:image query:self.initialQuery];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)applyAllPersisted {
    NSUInteger persisted = RYGRuntimeValueAllOverrideSpecs().count;
    NSUInteger installed = RYGRuntimeValueReinstallPersistedHooks();
    NSUInteger pending = persisted >= installed ? persisted - installed : 0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apply All Runtime" message:[NSString stringWithFormat:@"Persisted typed overrides: %lu\nInstalled/reapplied: %lu\nPending: %lu", (unsigned long)persisted, (unsigned long)installed, (unsigned long)pending] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
