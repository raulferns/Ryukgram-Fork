// SCIMCBrowser.m — RyukGram-Fork
#import "SCIMCBrowser.h"
#import "../../Localization/SCILocalization.h"
#import "../../Features/Dogfooding/SCIDogfoodObjectRuntime.h"
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>

#pragma mark - Embedded mapping

static NSData *SCIEmbeddedMappingData(void) {
    Dl_info info;
    if (!dladdr((const void *)&SCIEmbeddedMappingData, &info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint8_t *bytes = getsectiondata(header, "__DATA", "__idmap", &size);
    return bytes && size ? [NSData dataWithBytes:bytes length:size] : nil;
}

#pragma mark - Shared UI helpers

static NSString *SCIMCNorm(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return @"";
    NSMutableString *normalized = value.lowercaseString.mutableCopy;
    [normalized replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@" " withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"\n" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    return normalized;
}

static NSArray<NSString *> *SCIMCTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = NSMutableArray.array;
    NSCharacterSet *separators = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *component in [query ?: @"" componentsSeparatedByCharactersInSet:separators]) {
        NSString *token = SCIMCNorm(component);
        if (token.length) [tokens addObject:token];
    }
    return tokens;
}

static BOOL SCIMCMatchesTokens(NSString *candidate, NSArray<NSString *> *tokens) {
    if (tokens.count == 0) return YES;
    NSString *haystack = SCIMCNorm(candidate);
    for (NSString *token in tokens) {
        if (![haystack containsString:token]) return NO;
    }
    return YES;
}

static NSAttributedString *SCIMCHighlightedText(NSString *value,
                                                NSString *query,
                                                UIFont *font,
                                                UIColor *color) {
    NSString *safeValue = value ?: @"";
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:safeValue attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    }];
    for (NSString *raw in [query ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *token = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!token.length) continue;
        NSRange remaining = NSMakeRange(0, safeValue.length);
        while (remaining.length) {
            NSRange found = [safeValue rangeOfString:token
                                            options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                              range:remaining];
            if (found.location == NSNotFound) break;
            [text addAttributes:@{
                NSBackgroundColorAttributeName: UIColor.tertiarySystemFillColor,
                NSForegroundColorAttributeName: UIColor.labelColor,
            } range:found];
            NSUInteger next = NSMaxRange(found);
            if (next >= safeValue.length) break;
            remaining = NSMakeRange(next, safeValue.length - next);
        }
    }
    return text;
}

static UIColor *SCIMCPageBackgroundColor(void) {
    return UIColor.systemBackgroundColor;
}

static UIColor *SCIMCCellBackgroundColor(void) {
    return UIColor.secondarySystemBackgroundColor;
}

static void SCIMCApplyNavigationAppearance(UIViewController *controller) {
    UINavigationBarAppearance *appearance = UINavigationBarAppearance.new;
    [appearance configureWithDefaultBackground];
    appearance.titleTextAttributes = @{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline],
        NSForegroundColorAttributeName: UIColor.labelColor,
    };
    controller.navigationItem.standardAppearance = appearance;
    controller.navigationItem.scrollEdgeAppearance = appearance;
    controller.navigationItem.compactAppearance = appearance;
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

static void SCIMCConfigureSearchController(UISearchController *search,
                                           UIViewController *controller,
                                           NSString *placeholder) {
    search.obscuresBackgroundDuringPresentation = NO;
    search.hidesNavigationBarDuringPresentation = NO;
    search.searchBar.placeholder = placeholder;
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    search.searchBar.returnKeyType = UIReturnKeyDone;
    search.searchBar.searchTextField.adjustsFontForContentSizeCategory = YES;
    search.searchBar.searchTextField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    controller.navigationItem.searchController = search;
    controller.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (@available(iOS 16.0, *)) {
        controller.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }
}

#pragma mark - Search result model

typedef NS_ENUM(NSInteger, SCIMCBrowserResultKind) {
    SCIMCBrowserResultConfig = 0,
    SCIMCBrowserResultParam = 1,
};

@interface SCIMCBrowserResult : NSObject
@property (nonatomic) SCIMCBrowserResultKind kind;
@property (nonatomic, strong) NSNumber *configID;
@property (nonatomic, strong, nullable) NSNumber *paramID;
+ (instancetype)configResult:(NSNumber *)configID;
+ (instancetype)paramResult:(NSNumber *)paramID config:(NSNumber *)configID;
@end

@implementation SCIMCBrowserResult
+ (instancetype)configResult:(NSNumber *)configID {
    SCIMCBrowserResult *result = self.new;
    result.kind = SCIMCBrowserResultConfig;
    result.configID = configID;
    return result;
}
+ (instancetype)paramResult:(NSNumber *)paramID config:(NSNumber *)configID {
    SCIMCBrowserResult *result = self.new;
    result.kind = SCIMCBrowserResultParam;
    result.configID = configID;
    result.paramID = paramID;
    return result;
}
@end

#pragma mark - Store

@interface SCIMCOverrideStore () {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_ov;
    NSMutableDictionary<NSNumber *, NSString *> *_names;
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, NSString *> *> *_params;
    NSMutableDictionary<NSNumber *, NSString *> *_norm;
    NSArray<NSNumber *> *_ids;
}
- (NSArray<SCIMCBrowserResult *> *)browserResultsMatching:(nullable NSString *)query;
@end

@implementation SCIMCOverrideStore

+ (instancetype)shared {
    static SCIMCOverrideStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = SCIMCOverrideStore.new;
        [store reload];
    });
    return store;
}

- (NSArray<NSURL *> *)candidateRoots {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *roots = NSMutableArray.array;
    for (NSString *group in @[@"group.com.burbn.instagram", @"group.com.burbn.family"]) {
        NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:group];
        if (container) {
            [roots addObject:[[container URLByAppendingPathComponent:@"Documents"] URLByAppendingPathComponent:@"mobileconfig"]];
        }
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length) {
        [roots addObject:[[NSURL fileURLWithPath:documents] URLByAppendingPathComponent:@"mobileconfig"]];
    }
    return roots;
}

- (NSURL *)mobileconfigRoot {
    NSURL *root = self.candidateRoots.firstObject;
    if (root) {
        [NSFileManager.defaultManager createDirectoryAtURL:root
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    }
    return root;
}

- (NSURL *)userDataDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *uid = [self currentIGUserID];
    NSArray<NSURL *> *roots = self.candidateRoots;

    if (uid.length) {
        for (NSURL *root in roots) {
            NSURL *dir = [root URLByAppendingPathComponent:[uid stringByAppendingString:@".data"]];
            if ([fm fileExistsAtPath:dir.path]) return dir;
        }
    }
    for (NSURL *root in roots) {
        for (NSURL *url in [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![url.lastPathComponent hasSuffix:@".data"]) continue;
            if ([fm fileExistsAtPath:[url URLByAppendingPathComponent:@"mc_overrides.json"].path] ||
                [fm fileExistsAtPath:[url URLByAppendingPathComponent:@"id_name_mapping.json"].path]) return url;
        }
    }
    for (NSURL *root in roots) {
        NSURL *best = nil;
        NSDate *bestDate = nil;
        for (NSURL *url in [fm contentsOfDirectoryAtURL:root
                             includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                options:0
                                                  error:nil]) {
            if (![url.lastPathComponent hasSuffix:@".data"]) continue;
            NSDate *date = nil;
            [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
            if (!best || (date && [date compare:bestDate] == NSOrderedDescending)) {
                best = url;
                bestDate = date ?: NSDate.date;
            }
        }
        if (best) return best;
    }
    NSURL *primary = roots.firstObject;
    NSString *folder = uid.length ? [uid stringByAppendingString:@".data"] : @"shared.data";
    NSURL *dir = [primary URLByAppendingPathComponent:folder];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)currentIGUserID {
    @try {
        Class runtime = NSClassFromString(@"SCIDogfoodObjectRuntime");
        id session = nil;
        if ([runtime respondsToSelector:@selector(liveInstanceOfClassNameContaining:)]) {
            session = ((id(*)(id, SEL, id))objc_msgSend)(runtime,
                                                         @selector(liveInstanceOfClassNameContaining:),
                                                         @"IGUserSession");
        }
        NSArray<NSString *> *keys = @[@"instagramUserID", @"userID", @"loggedInUserId", @"pk"];
        for (NSString *key in keys) {
            @try {
                id value = [session valueForKey:key];
                if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
                if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
            } @catch (__unused id exception) {}
        }
        @try {
            id user = [session valueForKey:@"user"] ?: [session valueForKey:@"currentUser"];
            for (NSString *key in keys) {
                @try {
                    id value = [user valueForKey:key];
                    if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
                    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
                } @catch (__unused id exception) {}
            }
        } @catch (__unused id exception) {}
    } @catch (__unused NSException *exception) {}
    return nil;
}

- (NSData *)bundledMappingData {
    NSBundle *bundle = SCILocalizationBundle();
    for (NSString *extension in @[@"json", @"bin"]) {
        NSString *path = [bundle pathForResource:@"id_name_mapping" ofType:extension];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (data.length) return data;
    }
    return nil;
}

- (void)reload {
    _ov = NSMutableDictionary.dictionary;
    _names = NSMutableDictionary.dictionary;
    _params = NSMutableDictionary.dictionary;
    _norm = NSMutableDictionary.dictionary;

    NSURL *dir = self.userDataDir;
    NSURL *root = self.mobileconfigRoot;
    NSData *overrideData = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"mc_overrides.json"]];
    if (overrideData) {
        id json = [NSJSONSerialization JSONObjectWithData:overrideData options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                if (![key isEqualToString:@"_qe_overrides_"] && [value isKindOfClass:NSArray.class]) {
                    self->_ov[key] = [(NSArray *)value mutableCopy];
                }
            }];
        }
    }

    NSData *mappingData = SCIEmbeddedMappingData();
    if (!mappingData) mappingData = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"id_name_mapping.json"]];
    if (!mappingData) mappingData = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"id_name_mapping.json"]];
    if (!mappingData) mappingData = self.bundledMappingData;
    if (mappingData) {
        NSURL *seed = [dir URLByAppendingPathComponent:@"id_name_mapping.json"];
        if (![NSFileManager.defaultManager fileExistsAtPath:seed.path]) {
            [mappingData writeToURL:seed options:NSDataWritingAtomic error:nil];
        }
        id json = [NSJSONSerialization JSONObjectWithData:mappingData options:0 error:nil];
        if ([json isKindOfClass:NSArray.class]) {
            for (NSString *entry in (NSArray *)json) {
                if (![entry isKindOfClass:NSString.class]) continue;
                NSArray<NSString *> *parts = [entry componentsSeparatedByString:@":"];
                if (parts.count < 2) continue;
                NSNumber *configID = @([parts[0] integerValue]);
                _names[configID] = parts[1];
                NSMutableDictionary<NSNumber *, NSString *> *parameters = NSMutableDictionary.dictionary;
                for (NSUInteger index = 2; index + 1 < parts.count; index += 2) {
                    parameters[@([parts[index] integerValue])] = parts[index + 1];
                }
                _params[configID] = parameters;
            }
        }
    }
    _ids = [_names.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<NSNumber *> *)configIDs { return _ids ?: @[]; }
- (NSString *)nameForConfig:(NSInteger)cid { return _names[@(cid)] ?: [NSString stringWithFormat:@"config %ld", (long)cid]; }
- (NSDictionary<NSNumber *,NSString *> *)paramsForConfig:(NSInteger)cid { return _params[@(cid)] ?: @{}; }
- (NSString *)nameForConfig:(NSInteger)cid param:(NSInteger)idx {
    return _params[@(cid)][@(idx)] ?: [NSString stringWithFormat:@"param %ld", (long)idx];
}

- (NSString *)normForConfig:(NSNumber *)configID {
    NSString *cached = _norm[configID];
    if (cached) return cached;
    NSMutableString *haystack = [NSMutableString stringWithFormat:@"%@ %@", [self nameForConfig:configID.integerValue], configID];
    for (NSString *name in [_params[configID] allValues]) [haystack appendFormat:@" %@", name];
    cached = SCIMCNorm(haystack);
    _norm[configID] = cached;
    return cached;
}

- (NSArray<SCIMCBrowserResult *> *)browserResultsMatching:(NSString *)query {
    NSArray<NSString *> *tokens = SCIMCTokens(query);
    BOOL searching = tokens.count > 0;
    NSMutableArray<SCIMCBrowserResult *> *results = NSMutableArray.array;
    for (NSNumber *configID in self.configIDs) {
        NSInteger cid = configID.integerValue;
        NSString *configName = [self nameForConfig:cid];
        if (!searching) {
            [results addObject:[SCIMCBrowserResult configResult:configID]];
            continue;
        }
        if (SCIMCMatchesTokens([NSString stringWithFormat:@"%@ %@", configName, configID], tokens)) {
            [results addObject:[SCIMCBrowserResult configResult:configID]];
        }
        NSArray<NSNumber *> *indexes = [[self paramsForConfig:cid].allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *paramID in indexes) {
            NSString *paramName = [self nameForConfig:cid param:paramID.integerValue];
            NSString *candidate = [NSString stringWithFormat:@"%@ %@ %@ %@", paramName, paramID, configName, configID];
            if (SCIMCMatchesTokens(candidate, tokens)) {
                [results addObject:[SCIMCBrowserResult paramResult:paramID config:configID]];
            }
        }
    }
    return results;
}

- (NSArray<NSNumber *> *)configIDsMatching:(NSString *)query {
    NSMutableOrderedSet<NSNumber *> *matches = NSMutableOrderedSet.orderedSet;
    for (SCIMCBrowserResult *result in [self browserResultsMatching:query]) [matches addObject:result.configID];
    return matches.array;
}

- (NSString *)keyForConfig:(NSInteger)cid {
    NSString *name = _names[@(cid)];
    return name.length ? [NSString stringWithFormat:@"%ld:%@", (long)cid, name]
                       : [NSString stringWithFormat:@"%ld:", (long)cid];
}

- (nullable NSString *)stringValueForConfig:(NSInteger)cid param:(NSInteger)idx {
    for (NSString *line in _ov[[self keyForConfig:cid]]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@":"];
        if (parts.count >= 3 && [[parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] integerValue] == idx) {
            return [parts.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
    }
    return nil;
}

- (SCIMCOverrideState)stateForConfig:(NSInteger)cid param:(NSInteger)idx {
    NSString *value = [self stringValueForConfig:cid param:idx];
    if (!value) return SCIMCOverrideSYS;
    return [value isEqualToString:@"true"] ? SCIMCOverrideON : SCIMCOverrideOFF;
}

- (void)setState:(SCIMCOverrideState)state forConfig:(NSInteger)cid param:(NSInteger)idx {
    NSString *key = [self keyForConfig:cid];
    NSMutableArray<NSString *> *keep = NSMutableArray.array;
    for (NSString *line in _ov[key] ?: @[]) {
        NSInteger lineIndex = [[[line componentsSeparatedByString:@":"][0]
                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] integerValue];
        if (lineIndex != idx) [keep addObject:line];
    }
    if (state != SCIMCOverrideSYS) {
        [keep addObject:[NSString stringWithFormat:@"%ld: %@: %@",
                         (long)idx,
                         [self nameForConfig:cid param:idx],
                         state == SCIMCOverrideON ? @"true" : @"false"]];
    }
    [keep sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        NSInteger lhs = [[first componentsSeparatedByString:@":"][0] integerValue];
        NSInteger rhs = [[second componentsSeparatedByString:@":"][0] integerValue];
        return lhs < rhs ? NSOrderedAscending : (lhs > rhs ? NSOrderedDescending : NSOrderedSame);
    }];
    if (keep.count) _ov[key] = keep;
    else [_ov removeObjectForKey:key];
}

- (BOOL)save:(NSError **)error {
    NSMutableDictionary *payload = NSMutableDictionary.dictionary;
    [_ov enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray *value, BOOL *stop) {
        payload[key] = value;
    }];
    payload[@"_qe_overrides_"] = @[];
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:error];
    if (!data) return NO;
    return [data writeToURL:[self.userDataDir URLByAppendingPathComponent:@"mc_overrides.json"]
                    options:NSDataWritingAtomic
                      error:error];
}

- (BOOL)deployBundledMappingOverwrite:(NSError **)error {
    NSData *data = self.bundledMappingData;
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"SCIMC" code:404 userInfo:@{
            NSLocalizedDescriptionKey: @"bundled id_name_mapping (.json/.bin) not in RyukGram.bundle"
        }];
        return NO;
    }
    BOOL success = [data writeToURL:[self.userDataDir URLByAppendingPathComponent:@"id_name_mapping.json"]
                            options:NSDataWritingAtomic
                              error:error];
    [self reload];
    return success;
}

- (void)applyInternalPreset {
    NSDictionary<NSString *, NSNumber *> *preset = @{
        @"56474:0": @(SCIMCOverrideON), @"56474:1": @(SCIMCOverrideON), @"58792:0": @(SCIMCOverrideON),
        @"90775:1": @(SCIMCOverrideON), @"87318:0": @(SCIMCOverrideON), @"57176:0": @(SCIMCOverrideON),
        @"107035:0": @(SCIMCOverrideON), @"107711:0": @(SCIMCOverrideON), @"121139:0": @(SCIMCOverrideON),
        @"121139:1": @(SCIMCOverrideON), @"121139:2": @(SCIMCOverrideON), @"121139:3": @(SCIMCOverrideON),
        @"90631:0": @(SCIMCOverrideON), @"90631:2": @(SCIMCOverrideON), @"90631:3": @(SCIMCOverrideON),
    };
    [preset enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *state, BOOL *stop) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@":"];
        [self setState:(SCIMCOverrideState)state.integerValue
             forConfig:parts[0].integerValue
                 param:parts[1].integerValue];
    }];
}
@end

#pragma mark - Compact parameter cell

@interface SCIMCParameterSwitch : UISwitch
@property (nonatomic) NSInteger configID;
@property (nonatomic) NSInteger paramID;
@end
@implementation SCIMCParameterSwitch
@end

@interface SCIMCParameterCell : UITableViewCell
@property (nonatomic, strong) SCIMCParameterSwitch *overrideSwitch;
- (void)configureWithName:(NSString *)name state:(SCIMCOverrideState)state configID:(NSInteger)configID paramID:(NSInteger)paramID;
@end

@implementation SCIMCParameterCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = SCIMCCellBackgroundColor();
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(5.0, 16.0, 5.0, 12.0);
        _overrideSwitch = SCIMCParameterSwitch.new;
        _overrideSwitch.transform = CGAffineTransformMakeScale(0.88, 0.88);
        self.accessoryView = _overrideSwitch;
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.overrideSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
}

- (void)configureWithName:(NSString *)name state:(SCIMCOverrideState)state configID:(NSInteger)configID paramID:(NSInteger)paramID {
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = name;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.color = UIColor.labelColor;
    content.textProperties.numberOfLines = 1;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(3.0, 0.0, 3.0, 0.0);
    if (state != SCIMCOverrideSYS) {
        content.secondaryText = state == SCIMCOverrideON ? @"Override ON" : @"Override OFF";
        content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        content.secondaryTextProperties.color = UIColor.systemOrangeColor;
        content.secondaryTextProperties.numberOfLines = 1;
    }
    self.contentConfiguration = content;
    self.overrideSwitch.configID = configID;
    self.overrideSwitch.paramID = paramID;
    [self.overrideSwitch setOn:(state == SCIMCOverrideON) animated:NO];
    self.overrideSwitch.alpha = state == SCIMCOverrideSYS ? 0.72 : 1.0;
    self.accessibilityValue = state == SCIMCOverrideSYS ? @"System value" : (state == SCIMCOverrideON ? @"Override on" : @"Override off");
}
@end

#pragma mark - Controllers

@interface SCIMCConfigDetailController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) NSNumber *cid;
@property (nonatomic, strong, nullable) NSNumber *focusParam;
@end

@interface SCIMCBrowserListController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<SCIMCBrowserResult *> *rows;
@end

@implementation SCIMCBrowserListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MobileConfig";
    self.view.backgroundColor = SCIMCPageBackgroundColor();
    self.definesPresentationContext = YES;
    SCIMCApplyNavigationAppearance(self);
    [SCIMCOverrideStore.shared reload];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    SCIMCConfigureSearchController(self.searchController, self, @"Pesquisar");

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.backgroundColor = SCIMCPageBackgroundColor();
    self.table.rowHeight = 52.0;
    self.table.estimatedRowHeight = 52.0;
    self.table.separatorInsetReference = UITableViewSeparatorInsetFromAutomaticInsets;
    self.table.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    self.table.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 16.0, 0.0, 12.0);
    [self.view addSubview:self.table];

    [self configureActionsMenu];
    [self refreshRows];
}

- (void)configureActionsMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *preset = [UIAction actionWithTitle:@"Aplicar preset interno" image:[UIImage systemImageNamed:@"wand.and.stars"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf applyPreset];
    }];
    UIAction *deploy = [UIAction actionWithTitle:@"Atualizar mapeamento" image:[UIImage systemImageNamed:@"arrow.down.doc"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf deployMapping];
    }];
    UIAction *info = [UIAction actionWithTitle:@"Informações" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(__unused UIAction *action) {
        [weakSelf showInfo];
    }];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:nil action:nil];
    more.menu = [UIMenu menuWithTitle:@"" children:@[preset, deploy, info]];
    self.navigationItem.rightBarButtonItem = more;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.table reloadData];
}

- (void)refreshRows {
    self.rows = [SCIMCOverrideStore.shared browserResultsMatching:self.searchController.searchBar.text];
    [self.table reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self refreshRows]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"SCIMCBrowserResult";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];

    SCIMCBrowserResult *result = self.rows[indexPath.row];
    NSInteger cid = result.configID.integerValue;
    NSString *configName = [SCIMCOverrideStore.shared nameForConfig:cid];
    NSString *query = self.searchController.searchBar.text;
    BOOL searching = SCIMCTokens(query).count > 0;

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.numberOfLines = 1;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.textToSecondaryTextVerticalPadding = 1.0;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(4.0, 0.0, 4.0, 0.0);

    if (result.kind == SCIMCBrowserResultParam) {
        NSString *paramName = [SCIMCOverrideStore.shared nameForConfig:cid param:result.paramID.integerValue];
        content.attributedText = SCIMCHighlightedText(paramName, query, content.textProperties.font, UIColor.labelColor);
        content.secondaryAttributedText = SCIMCHighlightedText(configName, query, content.secondaryTextProperties.font, UIColor.secondaryLabelColor);
    } else {
        content.attributedText = SCIMCHighlightedText(configName, query, content.textProperties.font, UIColor.labelColor);
        content.secondaryText = searching ? @"Config" : [NSString stringWithFormat:@"Stable ID %ld · %lu parâmetros", (long)cid, (unsigned long)[SCIMCOverrideStore.shared paramsForConfig:cid].count];
    }

    cell.contentConfiguration = content;
    cell.backgroundColor = SCIMCPageBackgroundColor();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 16.0, 0.0, 10.0);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.searchController.searchBar resignFirstResponder];
    SCIMCBrowserResult *result = self.rows[indexPath.row];
    SCIMCConfigDetailController *detail = SCIMCConfigDetailController.new;
    detail.cid = result.configID;
    if (result.kind == SCIMCBrowserResultParam) detail.focusParam = result.paramID;
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)showInfo {
    SCIMCOverrideStore *store = SCIMCOverrideStore.shared;
    NSString *message = [NSString stringWithFormat:@"Data dir:\n%@\n\nConfigs: %lu", store.userDataDir.path, (unsigned long)store.configIDs.count];
    [self showAlertTitle:@"MobileConfig" message:message];
}

- (void)applyPreset {
    [SCIMCOverrideStore.shared applyInternalPreset];
    NSError *error = nil;
    BOOL success = [SCIMCOverrideStore.shared save:&error];
    [self showAlertTitle:nil message:success ? @"Preset aplicado. Reinicie o Instagram." : error.localizedDescription];
    [self refreshRows];
}

- (void)deployMapping {
    NSError *error = nil;
    BOOL success = [SCIMCOverrideStore.shared deployBundledMappingOverwrite:&error];
    [self refreshRows];
    [self showAlertTitle:nil message:success ? @"Mapeamento atualizado." : error.localizedDescription];
}

- (void)showAlertTitle:(nullable NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface SCIMCConfigDetailController ()
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<NSNumber *> *allIndexes;
@property (nonatomic, strong) NSArray<NSNumber *> *filteredIndexes;
@property (nonatomic) BOOL didFocusInitialParam;
@end

@implementation SCIMCConfigDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSInteger cid = self.cid.integerValue;
    self.title = [SCIMCOverrideStore.shared nameForConfig:cid];
    self.view.backgroundColor = SCIMCPageBackgroundColor();
    self.definesPresentationContext = YES;
    SCIMCApplyNavigationAppearance(self);

    self.allIndexes = [[SCIMCOverrideStore.shared paramsForConfig:cid].allKeys sortedArrayUsingSelector:@selector(compare:)];
    self.filteredIndexes = self.allIndexes;
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    SCIMCConfigureSearchController(self.searchController, self, @"Pesquisar parâmetros");

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = SCIMCPageBackgroundColor();
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight = 50.0;
    self.table.estimatedRowHeight = 50.0;
    self.table.sectionHeaderTopPadding = 4.0;
    self.table.separatorInsetReference = UITableViewSeparatorInsetFromAutomaticInsets;
    self.table.separatorInset = UIEdgeInsetsMake(0.0, 16.0, 0.0, 16.0);
    [self.table registerClass:SCIMCParameterCell.class forCellReuseIdentifier:@"SCIMCParameter"];
    [self.view addSubview:self.table];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self focusInitialParameterIfNeeded];
}

- (void)focusInitialParameterIfNeeded {
    if (self.didFocusInitialParam || !self.focusParam) return;
    NSUInteger row = [self.filteredIndexes indexOfObject:self.focusParam];
    if (row == NSNotFound) return;
    self.didFocusInitialParam = YES;
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:1];
    [self.table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSArray<NSString *> *tokens = SCIMCTokens(searchController.searchBar.text);
    if (!tokens.count) {
        self.filteredIndexes = self.allIndexes;
    } else {
        NSInteger cid = self.cid.integerValue;
        NSMutableArray<NSNumber *> *filtered = NSMutableArray.array;
        for (NSNumber *paramID in self.allIndexes) {
            NSString *name = [SCIMCOverrideStore.shared nameForConfig:cid param:paramID.integerValue];
            if (SCIMCMatchesTokens([NSString stringWithFormat:@"%@ %@", name, paramID], tokens)) [filtered addObject:paramID];
        }
        self.filteredIndexes = filtered;
    }
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : self.filteredIndexes.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"Informações" : @"Parâmetros"; }

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 28.0; }

- (UITableViewCell *)informationCellForRow:(NSInteger)row {
    static NSString *identifier = @"SCIMCInformation";
    UITableViewCell *cell = [self.table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    NSInteger cid = self.cid.integerValue;
    NSArray<NSString *> *labels = @[@"Config", @"Unit Type", @"Stable ID"];
    NSArray<NSString *> *values = @[[SCIMCOverrideStore.shared nameForConfig:cid], @"AdminId (AAID)", [NSString stringWithFormat:@"%ld", (long)cid]];
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = labels[row];
    content.secondaryText = values[row];
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(3.0, 0.0, 3.0, 0.0);
    cell.contentConfiguration = content;
    cell.backgroundColor = SCIMCCellBackgroundColor();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self informationCellForRow:indexPath.row];
    SCIMCParameterCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SCIMCParameter" forIndexPath:indexPath];
    NSInteger cid = self.cid.integerValue;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    SCIMCOverrideState state = [SCIMCOverrideStore.shared stateForConfig:cid param:paramID];
    [cell configureWithName:[SCIMCOverrideStore.shared nameForConfig:cid param:paramID]
                      state:state
                   configID:cid
                    paramID:paramID];
    [cell.overrideSwitch addTarget:self action:@selector(overrideSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)overrideSwitchChanged:(SCIMCParameterSwitch *)sender {
    [self setState:(sender.isOn ? SCIMCOverrideON : SCIMCOverrideOFF) configID:sender.configID paramID:sender.paramID];
}

- (void)setState:(SCIMCOverrideState)state configID:(NSInteger)configID paramID:(NSInteger)paramID {
    [SCIMCOverrideStore.shared setState:state forConfig:configID param:paramID];
    NSError *error = nil;
    if (![SCIMCOverrideStore.shared save:&error]) {
        [SCIMCOverrideStore.shared reload];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Falha ao salvar" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    NSUInteger row = [self.filteredIndexes indexOfObject:@(paramID)];
    if (row != NSNotFound) {
        [self.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:1]] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *system = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Sistema" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
        [weakSelf setState:SCIMCOverrideSYS configID:weakSelf.cid.integerValue paramID:paramID];
        completion(YES);
    }];
    system.backgroundColor = UIColor.systemGrayColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[system]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    NSInteger cid = self.cid.integerValue;
    SCIMCOverrideState current = [SCIMCOverrideStore.shared stateForConfig:cid param:paramID];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[SCIMCOverrideStore.shared nameForConfig:cid param:paramID]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forçar ON" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideON configID:cid paramID:paramID];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forçar OFF" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideOFF configID:cid paramID:paramID];
    }]];
    UIAlertAction *system = [UIAlertAction actionWithTitle:@"Usar valor do sistema" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideSYS configID:cid paramID:paramID];
    }];
    system.enabled = current != SCIMCOverrideSYS;
    [sheet addAction:system];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
