// SCIMCBrowser.m — RyukGram-Fork
#import "SCIMCBrowser.h"
#import "../../Localization/SCILocalization.h"
#import "../../Features/Dogfooding/SCIDogfoodObjectRuntime.h"
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>
#include <math.h>

// Read the id-name mapping embedded directly in THIS dylib's own __DATA,__idmap
// section (via -sectcreate at link time — see Makefile). This is the primary
// source: unlike a bundle resource, it cannot be dropped by a sideload injector
// independently of the dylib, because it IS part of the dylib's own bytes.
static NSData *SCIEmbeddedMappingData(void) {
    Dl_info info;
    if (!dladdr((const void *)&SCIEmbeddedMappingData, &info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint8_t *data = getsectiondata(mh, "__DATA", "__idmap", &size);
    if (!data || size == 0) return nil;
    return [NSData dataWithBytes:data length:size];
}

#pragma mark - Helpers

// Lowercase + strip '_' and whitespace, so "internal settings" matches
// "is_internal_settings_enabled".
static NSString *SCIMCNorm(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length == 0) return @"";
    NSMutableString *m = [s.lowercaseString mutableCopy];
    [m replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, m.length)];
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableString *o = [NSMutableString stringWithCapacity:m.length];
    for (NSUInteger i = 0; i < m.length; i++) {
        unichar c = [m characterAtIndex:i];
        if (![ws characterIsMember:c]) [o appendFormat:@"%C", c];
    }
    return o;
}

static NSArray<NSString *> *SCIMCTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [query ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *token = SCIMCNorm(part);
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

static UIColor *SCIMCPageBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:36.0 / 255.0
                                   green:37.0 / 255.0
                                    blue:38.0 / 255.0
                                   alpha:1.0];
        }
        return UIColor.systemGroupedBackgroundColor;
    }];
}

static UIColor *SCIMCCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:28.0 / 255.0
                                   green:30.0 / 255.0
                                    blue:33.0 / 255.0
                                   alpha:1.0];
        }
        return UIColor.secondarySystemGroupedBackgroundColor;
    }];
}

static void SCIMCApplyNavigationAppearance(UIViewController *controller) {
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = SCIMCPageBackgroundColor();
    appearance.shadowColor = UIColor.separatorColor;
    controller.navigationItem.standardAppearance = appearance;
    controller.navigationItem.scrollEdgeAppearance = appearance;
    controller.navigationItem.compactAppearance = appearance;
}

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
    SCIMCBrowserResult *result = [SCIMCBrowserResult new];
    result.kind = SCIMCBrowserResultConfig;
    result.configID = configID;
    return result;
}
+ (instancetype)paramResult:(NSNumber *)paramID config:(NSNumber *)configID {
    SCIMCBrowserResult *result = [SCIMCBrowserResult new];
    result.kind = SCIMCBrowserResultParam;
    result.configID = configID;
    result.paramID = paramID;
    return result;
}
@end

static NSAttributedString *SCIMCPrefixedText(NSString *prefix,
                                             NSString *value,
                                             NSString *query,
                                             UIFont *font) {
    NSString *safePrefix = prefix ?: @"";
    NSString *safeValue = value ?: @"";
    NSString *full = [safePrefix stringByAppendingString:safeValue];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:full attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    [text addAttribute:NSForegroundColorAttributeName
                 value:UIColor.secondaryLabelColor
                 range:NSMakeRange(0, safePrefix.length)];

    for (NSString *rawToken in [query ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *token = [rawToken stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (token.length == 0) continue;
        NSRange searchRange = NSMakeRange(safePrefix.length, safeValue.length);
        while (searchRange.length) {
            NSRange found = [full rangeOfString:token
                                       options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                         range:searchRange];
            if (found.location == NSNotFound) break;
            [text addAttributes:@{
                NSBackgroundColorAttributeName: UIColor.tertiarySystemFillColor,
                NSForegroundColorAttributeName: UIColor.labelColor,
            } range:found];
            NSUInteger next = NSMaxRange(found);
            if (next >= full.length) break;
            searchRange = NSMakeRange(next, full.length - next);
        }
    }
    return text;
}

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
    static SCIMCOverrideStore *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [SCIMCOverrideStore new];
        [s reload];
    });
    return s;
}

- (NSArray<NSURL *> *)candidateRoots {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    for (NSString *group in @[@"group.com.burbn.instagram", @"group.com.burbn.family"]) {
        NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:group];
        if (container) {
            [roots addObject:[[container URLByAppendingPathComponent:@"Documents"]
                              URLByAppendingPathComponent:@"mobileconfig"]];
        }
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                NSUserDomainMask,
                                                                YES).firstObject;
    if (documents.length) {
        [roots addObject:[[NSURL fileURLWithPath:documents]
                          URLByAppendingPathComponent:@"mobileconfig"]];
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
        for (NSURL *url in [fm contentsOfDirectoryAtURL:root
                             includingPropertiesForKeys:nil
                                                options:0
                                                  error:nil]) {
            if (![url.lastPathComponent hasSuffix:@".data"]) continue;
            if ([fm fileExistsAtPath:[url URLByAppendingPathComponent:@"mc_overrides.json"].path] ||
                [fm fileExistsAtPath:[url URLByAppendingPathComponent:@"id_name_mapping.json"].path]) {
                return url;
            }
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
        if (!path) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length) return data;
    }
    return nil;
}

- (void)reload {
    _ov = [NSMutableDictionary dictionary];
    _names = [NSMutableDictionary dictionary];
    _params = [NSMutableDictionary dictionary];
    _norm = [NSMutableDictionary dictionary];

    NSURL *dir = self.userDataDir;
    NSURL *root = self.mobileconfigRoot;

    NSData *overrideData = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"mc_overrides.json"]];
    if (overrideData) {
        id json = [NSJSONSerialization JSONObjectWithData:overrideData options:0 error:nil];
        if ([json isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                if ([key isEqualToString:@"_qe_overrides_"]) return;
                if ([value isKindOfClass:NSArray.class]) _ov[key] = [(NSArray *)value mutableCopy];
            }];
        }
    }

    NSData *mappingData = SCIEmbeddedMappingData();
    if (!mappingData) mappingData = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"id_name_mapping.json"]];
    if (!mappingData) mappingData = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"id_name_mapping.json"]];
    if (!mappingData) mappingData = [self bundledMappingData];

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
                NSInteger configID = [parts[0] integerValue];
                _names[@(configID)] = parts[1];
                NSMutableDictionary<NSNumber *, NSString *> *parameters = [NSMutableDictionary dictionary];
                for (NSUInteger i = 2; i + 1 < parts.count; i += 2) {
                    parameters[@([parts[i] integerValue])] = parts[i + 1];
                }
                _params[@(configID)] = parameters;
            }
        }
    }
    _ids = [_names.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<NSNumber *> *)configIDs { return _ids ?: @[]; }
- (NSString *)nameForConfig:(NSInteger)cid {
    return _names[@(cid)] ?: [NSString stringWithFormat:@"config %ld", (long)cid];
}
- (NSDictionary *)paramsForConfig:(NSInteger)cid { return _params[@(cid)] ?: @{}; }
- (NSString *)nameForConfig:(NSInteger)cid param:(NSInteger)idx {
    return _params[@(cid)][@(idx)] ?: [NSString stringWithFormat:@"param %ld", (long)idx];
}

- (NSString *)normForConfig:(NSNumber *)cid {
    NSString *cached = _norm[cid];
    if (cached) return cached;
    NSMutableString *haystack = [NSMutableString stringWithFormat:@"%@ %@",
                                  [self nameForConfig:cid.integerValue],
                                  cid];
    for (NSString *paramName in [_params[cid] allValues]) {
        [haystack appendFormat:@" %@", paramName];
    }
    cached = SCIMCNorm(haystack);
    _norm[cid] = cached;
    return cached;
}

- (NSArray<SCIMCBrowserResult *> *)browserResultsMatching:(NSString *)query {
    NSArray<NSString *> *tokens = SCIMCTokens(query);
    BOOL searching = tokens.count != 0;
    NSMutableArray<SCIMCBrowserResult *> *results = [NSMutableArray array];

    for (NSNumber *configID in self.configIDs) {
        NSInteger cid = configID.integerValue;
        NSString *configName = [self nameForConfig:cid];
        NSString *configCandidate = [NSString stringWithFormat:@"%@ %@", configName, configID];

        if (!searching) {
            [results addObject:[SCIMCBrowserResult configResult:configID]];
            continue;
        }

        if (SCIMCMatchesTokens(configCandidate, tokens)) {
            [results addObject:[SCIMCBrowserResult configResult:configID]];
        }

        NSArray<NSNumber *> *indexes = [[self paramsForConfig:cid].allKeys
                                         sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *paramID in indexes) {
            NSString *paramName = [self nameForConfig:cid param:paramID.integerValue];
            NSString *candidate = [NSString stringWithFormat:@"%@ %@ %@ %@",
                                    paramName,
                                    paramID,
                                    configName,
                                    configID];
            if (SCIMCMatchesTokens(candidate, tokens)) {
                [results addObject:[SCIMCBrowserResult paramResult:paramID config:configID]];
            }
        }
    }
    return results;
}

- (NSArray<NSNumber *> *)configIDsMatching:(NSString *)query {
    NSMutableOrderedSet<NSNumber *> *matches = [NSMutableOrderedSet orderedSet];
    for (SCIMCBrowserResult *result in [self browserResultsMatching:query]) {
        [matches addObject:result.configID];
    }
    return matches.array;
}

- (NSString *)keyForConfig:(NSInteger)cid {
    NSString *name = _names[@(cid)];
    return name.length ? [NSString stringWithFormat:@"%ld:%@", (long)cid, name]
                       : [NSString stringWithFormat:@"%ld:", (long)cid];
}

- (nullable NSString *)stringValueForConfig:(NSInteger)cid param:(NSInteger)idx {
    NSArray *list = _ov[[self keyForConfig:cid]];
    for (NSString *line in list) {
        NSArray<NSString *> *segments = [line componentsSeparatedByString:@":"];
        if (segments.count >= 3 &&
            [[segments[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] integerValue] == idx) {
            return [segments.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
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
    NSMutableArray *list = _ov[key] ?: [NSMutableArray array];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *line in list) {
        NSInteger lineIndex = [[[line componentsSeparatedByString:@":"][0]
                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                               integerValue];
        if (lineIndex != idx) [keep addObject:line];
    }
    if (state != SCIMCOverrideSYS) {
        NSString *paramName = [self nameForConfig:cid param:idx];
        [keep addObject:[NSString stringWithFormat:@"%ld: %@: %@",
                         (long)idx,
                         paramName,
                         state == SCIMCOverrideON ? @"true" : @"false"]];
    }
    [keep sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger ia = [[a componentsSeparatedByString:@":"][0] integerValue];
        NSInteger ib = [[b componentsSeparatedByString:@":"][0] integerValue];
        return ia < ib ? NSOrderedDescending : (ia > ib ? NSOrderedAscending : NSOrderedSame);
    }];
    if (keep.count) _ov[key] = keep;
    else [_ov removeObjectForKey:key];
}

- (BOOL)save:(NSError **)error {
    NSMutableString *json = [NSMutableString stringWithString:@"{"];
    NSArray *keys = [_ov.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@([a integerValue]) compare:@([b integerValue])];
    }];
    BOOL first = YES;
    for (NSString *key in keys) {
        if (!first) [json appendString:@","];
        first = NO;
        NSData *keyData = [NSJSONSerialization dataWithJSONObject:@[key] options:0 error:nil];
        NSString *keyJSON = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
        keyJSON = [keyJSON substringWithRange:NSMakeRange(1, keyJSON.length - 2)];
        NSData *valueData = [NSJSONSerialization dataWithJSONObject:_ov[key] options:0 error:nil];
        NSString *valueJSON = [[NSString alloc] initWithData:valueData encoding:NSUTF8StringEncoding];
        [json appendFormat:@"%@:%@", keyJSON, valueJSON];
    }
    if (!first) [json appendString:@","];
    [json appendString:@"\"_qe_overrides_\":[]}"];

    NSURL *destination = [self.userDataDir URLByAppendingPathComponent:@"mc_overrides.json"];
    return [[json dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:destination
               options:NSDataWritingAtomic
                 error:error];
}

- (BOOL)deployBundledMappingOverwrite:(NSError **)error {
    NSData *data = [self bundledMappingData];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"SCIMC"
                                         code:404
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"bundled id_name_mapping (.json/.bin) not in RyukGram.bundle"}];
        }
        return NO;
    }
    BOOL ok = [data writeToURL:[self.userDataDir URLByAppendingPathComponent:@"id_name_mapping.json"]
                       options:NSDataWritingAtomic
                         error:error];
    [self reload];
    return ok;
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
        NSArray *parts = [key componentsSeparatedByString:@":"];
        [self setState:(SCIMCOverrideState)state.integerValue
             forConfig:[parts[0] integerValue]
                 param:[parts[1] integerValue]];
    }];
}
@end

#pragma mark - Shared browser UI

@interface SCIMCOverrideBadgeView : UIView
@end

@implementation SCIMCOverrideBadgeView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.systemOrangeColor;
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    NSString *title = @"Override";
    UIFont *font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: UIColor.whiteColor,
    };
    CGSize size = [title sizeWithAttributes:attributes];
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGContextRotateCTM(context, (CGFloat)-M_PI_2);
    [title drawAtPoint:CGPointMake(-size.width / 2.0, -size.height / 2.0)
        withAttributes:attributes];
    CGContextRestoreGState(context);
}
@end

@interface SCIMCParameterSwitch : UISwitch
@property (nonatomic) NSInteger configID;
@property (nonatomic) NSInteger paramID;
@end
@implementation SCIMCParameterSwitch
@end

@interface SCIMCParameterCell : UITableViewCell
@property (nonatomic, strong) UILabel *parameterLabel;
@property (nonatomic, strong) SCIMCParameterSwitch *overrideSwitch;
@property (nonatomic, strong) SCIMCOverrideBadgeView *overrideBadge;
@property (nonatomic, strong) NSLayoutConstraint *labelLeadingConstraint;
- (void)configureWithName:(NSString *)name
                    state:(SCIMCOverrideState)state
                 configID:(NSInteger)configID
                  paramID:(NSInteger)paramID;
@end

@implementation SCIMCParameterCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = SCIMCCardBackgroundColor();
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _overrideBadge = [SCIMCOverrideBadgeView new];
        _overrideBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_overrideBadge];

        _parameterLabel = [UILabel new];
        _parameterLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _parameterLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        _parameterLabel.textColor = UIColor.labelColor;
        _parameterLabel.numberOfLines = 2;
        _parameterLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_parameterLabel];

        _overrideSwitch = [SCIMCParameterSwitch new];
        _overrideSwitch.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_overrideSwitch];

        _labelLeadingConstraint = [_parameterLabel.leadingAnchor
                                   constraintEqualToAnchor:self.contentView.leadingAnchor
                                   constant:16.0];
        [NSLayoutConstraint activateConstraints:@[
            [_overrideBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_overrideBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_overrideBadge.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [_overrideBadge.widthAnchor constraintEqualToConstant:24.0],
            _labelLeadingConstraint,
            [_parameterLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:16.0],
            [_parameterLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-16.0],
            [_parameterLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_parameterLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_overrideSwitch.leadingAnchor constant:-14.0],
            [_overrideSwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
            [_overrideSwitch.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.overrideSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
}

- (void)configureWithName:(NSString *)name
                    state:(SCIMCOverrideState)state
                 configID:(NSInteger)configID
                  paramID:(NSInteger)paramID {
    self.parameterLabel.text = name;
    self.overrideSwitch.configID = configID;
    self.overrideSwitch.paramID = paramID;
    [self.overrideSwitch setOn:(state == SCIMCOverrideON) animated:NO];
    self.overrideSwitch.alpha = state == SCIMCOverrideSYS ? 0.72 : 1.0;
    self.overrideBadge.hidden = state == SCIMCOverrideSYS;
    self.labelLeadingConstraint.constant = state == SCIMCOverrideSYS ? 16.0 : 36.0;
    self.accessibilityValue = state == SCIMCOverrideSYS
        ? @"System value"
        : (state == SCIMCOverrideON ? @"Override on" : @"Override off");
}
@end

#pragma mark - Root browser

@class SCIMCConfigDetailController;

@interface SCIMCBrowserListController () <UITableViewDataSource,
                                           UITableViewDelegate,
                                           UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<SCIMCBrowserResult *> *rows;
@end

@implementation SCIMCBrowserListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MobileConfig";
    self.view.backgroundColor = SCIMCPageBackgroundColor();
    SCIMCApplyNavigationAppearance(self);
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.definesPresentationContext = YES;

    [SCIMCOverrideStore.shared reload];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Pesquisar";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchController.searchBar.returnKeyType = UIReturnKeyDone;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (@available(iOS 16.0, *)) {
        self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.backgroundColor = SCIMCPageBackgroundColor();
    self.table.separatorInset = UIEdgeInsetsMake(0, 20.0, 0, 20.0);
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 66.0;
    [self.view addSubview:self.table];

    [self configureActionsMenu];
    [self refreshRows];
}

- (void)configureActionsMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *preset = [UIAction actionWithTitle:@"Aplicar preset interno"
                                          image:[UIImage systemImageNamed:@"wand.and.stars"]
                                     identifier:nil
                                        handler:^(__unused UIAction *action) {
        [weakSelf applyPreset];
    }];
    UIAction *deploy = [UIAction actionWithTitle:@"Atualizar mapeamento"
                                          image:[UIImage systemImageNamed:@"arrow.down.doc"]
                                     identifier:nil
                                        handler:^(__unused UIAction *action) {
        [weakSelf deployMapping];
    }];
    UIAction *info = [UIAction actionWithTitle:@"Informações"
                                        image:[UIImage systemImageNamed:@"info.circle"]
                                   identifier:nil
                                      handler:^(__unused UIAction *action) {
        [weakSelf showInfo];
    }];
    UIMenu *menu = [UIMenu menuWithTitle:@"" children:@[preset, deploy, info]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc]
                             initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                             style:UIBarButtonItemStylePlain
                             target:nil
                             action:nil];
    more.menu = menu;
    self.navigationItem.rightBarButtonItem = more;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.table reloadData];
}

- (void)refreshRows {
    self.rows = [SCIMCOverrideStore.shared
                 browserResultsMatching:self.searchController.searchBar.text];
    [self.table reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self refreshRows];
}

- (void)showInfo {
    SCIMCOverrideStore *store = SCIMCOverrideStore.shared;
    NSString *uid = [store valueForKey:@"currentIGUserID"] ?: @"(unresolved — open an account screen once)";
    NSURL *dir = store.userDataDir;
    BOOL hasOverrides = [NSFileManager.defaultManager
                         fileExistsAtPath:[dir URLByAppendingPathComponent:@"mc_overrides.json"].path];
    BOOL hasMapping = [NSFileManager.defaultManager
                       fileExistsAtPath:[dir URLByAppendingPathComponent:@"id_name_mapping.json"].path];
    NSBundle *bundle = SCILocalizationBundle();
    NSString *jsonPath = [bundle pathForResource:@"id_name_mapping" ofType:@"json"];
    NSString *binaryPath = [bundle pathForResource:@"id_name_mapping" ofType:@"bin"];
    NSString *tagPath = [bundle pathForResource:@"sci_bundle_buildtag" ofType:@"txt"];
    NSString *tag = tagPath
        ? [[NSString stringWithContentsOfFile:tagPath encoding:NSUTF8StringEncoding error:nil]
           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"(no build tag — STALE bundle)";
    NSData *embedded = SCIEmbeddedMappingData();
    NSString *embeddedInfo = embedded
        ? [NSString stringWithFormat:@"y (%lu bytes)", (unsigned long)embedded.length]
        : @"N — dylib has no __idmap section, rebuild needed";
    NSString *message = [NSString stringWithFormat:
                         @"user id: %@\n\ndata dir:\n%@\n\nconfigs: %lu | ov:%@ map:%@\n\nembedded-in-dylib: %@\n\nbundle:\n%@\nmap.json:%@ map.bin:%@\nbuild tag: %@",
                         uid,
                         dir.path,
                         (unsigned long)store.configIDs.count,
                         hasOverrides ? @"y" : @"N",
                         hasMapping ? @"y" : @"N",
                         embeddedInfo,
                         bundle.bundlePath ?: @"(nil)",
                         jsonPath ? @"y" : @"N",
                         binaryPath ? @"y" : @"N",
                         tag];
    [self showAlertTitle:nil message:message];
}

- (void)applyPreset {
    [SCIMCOverrideStore.shared applyInternalPreset];
    NSError *error = nil;
    BOOL ok = [SCIMCOverrideStore.shared save:&error];
    [self showAlertTitle:nil
                 message:ok ? @"Internal preset applied. Restart Instagram."
                            : error.localizedDescription];
    [self refreshRows];
}

- (void)deployMapping {
    NSError *error = nil;
    BOOL ok = [SCIMCOverrideStore.shared deployBundledMappingOverwrite:&error];
    [self refreshRows];
    [self showAlertTitle:nil
                 message:ok ? @"Mapping deployed. Names refreshed."
                            : error.localizedDescription];
}

- (void)showAlertTitle:(nullable NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"SCIMCBrowserResult";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    SCIMCBrowserResult *result = self.rows[indexPath.row];
    NSInteger cid = result.configID.integerValue;
    NSString *configName = [SCIMCOverrideStore.shared nameForConfig:cid];
    NSString *query = self.searchController.searchBar.text;

    cell.backgroundColor = SCIMCPageBackgroundColor();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (result.kind == SCIMCBrowserResultParam) {
        NSString *paramName = [SCIMCOverrideStore.shared
                               nameForConfig:cid
                               param:result.paramID.integerValue];
        cell.textLabel.attributedText = SCIMCPrefixedText(@"Param: ",
                                                          paramName,
                                                          query,
                                                          [UIFont systemFontOfSize:17.0
                                                                            weight:UIFontWeightRegular]);
        cell.detailTextLabel.attributedText = SCIMCPrefixedText(@"Config: ",
                                                                configName,
                                                                query,
                                                                [UIFont systemFontOfSize:14.0
                                                                                  weight:UIFontWeightRegular]);
    } else {
        cell.textLabel.attributedText = SCIMCPrefixedText(@"Config: ",
                                                          configName,
                                                          query,
                                                          [UIFont systemFontOfSize:17.0
                                                                            weight:UIFontWeightRegular]);
        if (SCIMCTokens(query).count == 0) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Stable Id: %ld  ·  %lu parameters",
                                         (long)cid,
                                         (unsigned long)[SCIMCOverrideStore.shared paramsForConfig:cid].count];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        } else {
            cell.detailTextLabel.text = nil;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.searchController.searchBar resignFirstResponder];

    SCIMCBrowserResult *result = self.rows[indexPath.row];
    SCIMCConfigDetailController *detail = [SCIMCConfigDetailController new];
    [detail setValue:result.configID forKey:@"cid"];
    if (result.kind == SCIMCBrowserResultParam) {
        [detail setValue:result.paramID forKey:@"focusParam"];
    }
    [self.navigationController pushViewController:detail animated:YES];
}
@end

#pragma mark - Per-config detail

@interface SCIMCConfigDetailController : UIViewController <UITableViewDataSource,
                                                             UITableViewDelegate,
                                                             UISearchResultsUpdating>
@property (nonatomic, strong) NSNumber *cid;
@property (nonatomic, strong, nullable) NSNumber *focusParam;
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
    SCIMCApplyNavigationAppearance(self);
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.definesPresentationContext = YES;

    self.allIndexes = [[SCIMCOverrideStore.shared paramsForConfig:cid].allKeys
                       sortedArrayUsingSelector:@selector(compare:)];
    self.filteredIndexes = self.allIndexes;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Pesquisar parâmetros";
    self.searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    if (@available(iOS 16.0, *)) {
        self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
    }

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                             style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = SCIMCPageBackgroundColor();
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 72.0;
    self.table.sectionHeaderTopPadding = 12.0;
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
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)row inSection:1];
    [self.table scrollToRowAtIndexPath:indexPath
                      atScrollPosition:UITableViewScrollPositionMiddle
                              animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.table selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.table deselectRowAtIndexPath:indexPath animated:YES];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSArray<NSString *> *tokens = SCIMCTokens(searchController.searchBar.text);
    if (tokens.count == 0) {
        self.filteredIndexes = self.allIndexes;
    } else {
        NSInteger cid = self.cid.integerValue;
        NSString *configName = [SCIMCOverrideStore.shared nameForConfig:cid];
        NSMutableArray<NSNumber *> *filtered = [NSMutableArray array];
        for (NSNumber *paramID in self.allIndexes) {
            NSString *paramName = [SCIMCOverrideStore.shared
                                   nameForConfig:cid
                                   param:paramID.integerValue];
            NSString *candidate = [NSString stringWithFormat:@"%@ %@ %@ %@",
                                    paramName,
                                    paramID,
                                    configName,
                                    self.cid];
            if (SCIMCMatchesTokens(candidate, tokens)) [filtered addObject:paramID];
        }
        self.filteredIndexes = filtered;
    }
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:1]
              withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : self.filteredIndexes.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Information" : @"Parameters";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    return @"Sem a faixa laranja Override, o parâmetro usa o valor do sistema. Alterar o switch força ON/OFF. Deslize para restaurar o valor do sistema.";
}

- (UITableViewCell *)informationCellForRow:(NSInteger)row {
    static NSString *identifier = @"SCIMCInformation";
    UITableViewCell *cell = [self.table dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:identifier];
    }
    NSInteger cid = self.cid.integerValue;
    cell.backgroundColor = SCIMCCardBackgroundColor();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    if (row == 0) {
        cell.textLabel.text = @"Config:";
        cell.detailTextLabel.text = [SCIMCOverrideStore.shared nameForConfig:cid];
    } else if (row == 1) {
        cell.textLabel.text = @"Unit Type:";
        cell.detailTextLabel.text = @"AdminId (AAID)";
    } else {
        cell.textLabel.text = @"Stable Id:";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)cid];
    }
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self informationCellForRow:indexPath.row];

    SCIMCParameterCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SCIMCParameter"
                                                               forIndexPath:indexPath];
    NSInteger cid = self.cid.integerValue;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    SCIMCOverrideState state = [SCIMCOverrideStore.shared stateForConfig:cid param:paramID];
    [cell configureWithName:[SCIMCOverrideStore.shared nameForConfig:cid param:paramID]
                      state:state
                   configID:cid
                    paramID:paramID];
    [cell.overrideSwitch addTarget:self
                            action:@selector(overrideSwitchChanged:)
                  forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)overrideSwitchChanged:(SCIMCParameterSwitch *)sender {
    SCIMCOverrideState state = sender.isOn ? SCIMCOverrideON : SCIMCOverrideOFF;
    [self setState:state configID:sender.configID paramID:sender.paramID];
}

- (void)setState:(SCIMCOverrideState)state
        configID:(NSInteger)configID
         paramID:(NSInteger)paramID {
    [SCIMCOverrideStore.shared setState:state forConfig:configID param:paramID];
    NSError *error = nil;
    if (![SCIMCOverrideStore.shared save:&error]) {
        [SCIMCOverrideStore.shared reload];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save failed"
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    [self reloadParameter:paramID];
}

- (void)reloadParameter:(NSInteger)paramID {
    NSUInteger row = [self.filteredIndexes indexOfObject:@(paramID)];
    if (row == NSNotFound) {
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    [self.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:1]]
                      withRowAnimation:UITableViewRowAnimationNone];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *system = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:@"Sistema"
                                                                       handler:^(__unused UIContextualAction *action,
                                                                                 __unused UIView *sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        [weakSelf setState:SCIMCOverrideSYS
                  configID:weakSelf.cid.integerValue
                   paramID:paramID];
        completionHandler(YES);
    }];
    system.backgroundColor = UIColor.systemGrayColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[system]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
 contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                     point:(CGPoint)point {
    if (indexPath.section != 1) return nil;
    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *system = [UIAction actionWithTitle:@"Usar valor do sistema"
                                              image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                                         identifier:nil
                                            handler:^(__unused UIAction *action) {
            [weakSelf setState:SCIMCOverrideSYS
                      configID:weakSelf.cid.integerValue
                       paramID:paramID];
        }];
        UIAction *forceOff = [UIAction actionWithTitle:@"Forçar OFF"
                                                image:[UIImage systemImageNamed:@"xmark.circle"]
                                           identifier:nil
                                              handler:^(__unused UIAction *action) {
            [weakSelf setState:SCIMCOverrideOFF
                      configID:weakSelf.cid.integerValue
                       paramID:paramID];
        }];
        UIAction *forceOn = [UIAction actionWithTitle:@"Forçar ON"
                                               image:[UIImage systemImageNamed:@"checkmark.circle"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            [weakSelf setState:SCIMCOverrideON
                      configID:weakSelf.cid.integerValue
                       paramID:paramID];
        }];
        return [UIMenu menuWithTitle:@"Override" children:@[forceOn, forceOff, system]];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;

    NSInteger paramID = self.filteredIndexes[indexPath.row].integerValue;
    NSInteger cid = self.cid.integerValue;
    SCIMCOverrideState current = [SCIMCOverrideStore.shared stateForConfig:cid param:paramID];
    NSString *name = [SCIMCOverrideStore.shared nameForConfig:cid param:paramID];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                   message:@"Escolha o valor do override"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forçar ON"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideON configID:cid paramID:paramID];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forçar OFF"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideOFF configID:cid paramID:paramID];
    }]];
    NSString *systemTitle = current == SCIMCOverrideSYS ? @"Usando valor do sistema" : @"Restaurar valor do sistema";
    UIAlertAction *system = [UIAlertAction actionWithTitle:systemTitle
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(__unused UIAlertAction *action) {
        [weakSelf setState:SCIMCOverrideSYS configID:cid paramID:paramID];
    }];
    system.enabled = current != SCIMCOverrideSYS;
    [sheet addAction:system];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
