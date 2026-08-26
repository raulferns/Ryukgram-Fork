#import "RYGMobileConfig.h"
#import "RYGMobileConfigJSONIO.h"
#import "RYGMobileConfigNameMappingStore.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

@interface RYGMobileConfig (RYGBridgePrivate)
- (NSDictionary *)loadNameCatalog;
@end

static NSString *const kRYGBridgeVerifiedDataLeafKey = @"ryg_mc_verified_native_data_leaf_v1";
static NSString *const kRYGBridgeInstagramGroupIdentifier = @"group.com.burbn.instagram";

static BOOL RYGBridgeDirectoryExists(NSString *path) {
    if (!path.length) return NO;
    BOOL directory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory;
}

static NSString *RYGBridgeStandardPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return nil;
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath;
    return resolved.length ? resolved.stringByStandardizingPath : standard;
}

static NSString *RYGBridgeDataLeafFromCandidate(NSString *candidate) {
    NSString *path = RYGBridgeStandardPath(candidate);
    if (!path.length) return nil;
    if ([path.lastPathComponent.lowercaseString hasSuffix:@".data"]) return path.lastPathComponent;
    NSString *parent = path.stringByDeletingLastPathComponent;
    return [parent.lastPathComponent.lowercaseString hasSuffix:@".data"] ? parent.lastPathComponent : nil;
}

static NSString *RYGBridgeRememberResolvedDataDirectory(NSString *path) {
    NSString *standard = RYGBridgeStandardPath(path);
    NSString *leaf = RYGBridgeDataLeafFromCandidate(standard);
    if (!standard.length || !leaf.length || ![standard.lastPathComponent isEqualToString:leaf]) return standard;
    [NSUserDefaults.standardUserDefaults setObject:leaf forKey:kRYGBridgeVerifiedDataLeafKey];
    return standard;
}

static NSString *RYGBridgePreviouslyVerifiedDataLeaf(void) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:kRYGBridgeVerifiedDataLeafKey];
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *leaf = [(NSString *)raw lastPathComponent];
    return [leaf.lowercaseString hasSuffix:@".data"] ? leaf : nil;
}

static NSDictionary<NSString *, NSURL *> *RYGBridgeGroupContainerURLs(void) {
    Class proxyClass = objc_lookUpClass("LSBundleProxy");
    SEL currentSelector = NSSelectorFromString(@"bundleProxyForCurrentProcess");
    Method currentMethod = proxyClass ? class_getClassMethod(proxyClass, currentSelector) : NULL;
    if (!currentMethod || method_getNumberOfArguments(currentMethod) != 2) return @{};

    char returnType[32] = {0};
    method_getReturnType(currentMethod, returnType, sizeof(returnType));
    if (returnType[0] != '@') return @{};
    id proxy = ((id (*)(id, SEL))objc_msgSend)((id)proxyClass, currentSelector);
    if (!proxy) return @{};

    SEL groupsSelector = NSSelectorFromString(@"groupContainerURLs");
    Method groupsMethod = class_getInstanceMethod([proxy class], groupsSelector);
    if (!groupsMethod || method_getNumberOfArguments(groupsMethod) != 2) return @{};
    memset(returnType, 0, sizeof(returnType));
    method_getReturnType(groupsMethod, returnType, sizeof(returnType));
    if (returnType[0] != '@') return @{};

    id raw = ((id (*)(id, SEL))objc_msgSend)(proxy, groupsSelector);
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary<NSString *, NSURL *> *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSURL.class]) return;
        NSURL *url = value;
        if (url.path.length) clean[key] = url;
    }];
    return clean.copy;
}

static NSArray<NSURL *> *RYGBridgeUniqueGroupRoots(NSDictionary<NSString *, NSURL *> *groups) {
    NSMutableOrderedSet<NSURL *> *roots = [NSMutableOrderedSet orderedSet];
    for (NSURL *url in groups.allValues) if ([url isKindOfClass:NSURL.class] && url.path.length) [roots addObject:url];
    return roots.array;
}

static NSURL *RYGBridgePreferredWritableGroupRoot(NSDictionary<NSString *, NSURL *> *groups) {
    NSURL *exact = groups[kRYGBridgeInstagramGroupIdentifier];
    if (exact.path.length) return exact;

    NSMutableOrderedSet<NSURL *> *instagramRoots = [NSMutableOrderedSet orderedSet];
    [groups enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSURL *url, BOOL *stop) {
        (void)stop;
        NSString *lower = key.lowercaseString ?: @"";
        if (([lower containsString:@"instagram"] || [lower containsString:@"burbn"]) && url.path.length) {
            [instagramRoots addObject:url];
        }
    }];
    if (instagramRoots.count == 1) return instagramRoots.firstObject;

    NSArray<NSURL *> *all = RYGBridgeUniqueGroupRoots(groups);
    return all.count == 1 ? all.firstObject : nil;
}

static NSArray<NSString *> *RYGBridgeMobileConfigRootsForGroupURL(NSURL *groupURL) {
    if (!groupURL.path.length) return @[];
    NSString *root = RYGBridgeStandardPath(groupURL.path);
    if (!root.length) return @[];
    return @[
        [[root stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"mobileconfig"],
        [root stringByAppendingPathComponent:@"mobileconfig"],
    ];
}

static NSArray<NSString *> *RYGBridgeExistingDataDirectories(NSArray<NSURL *> *groupRoots) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableOrderedSet<NSString *> *matches = [NSMutableOrderedSet orderedSet];
    for (NSURL *groupURL in groupRoots) {
        for (NSString *mobileConfigRoot in RYGBridgeMobileConfigRootsForGroupURL(groupURL)) {
            BOOL isDirectory = NO;
            if (![fm fileExistsAtPath:mobileConfigRoot isDirectory:&isDirectory] || !isDirectory) continue;
            for (NSString *name in [fm contentsOfDirectoryAtPath:mobileConfigRoot error:nil] ?: @[]) {
                if (![name.lowercaseString hasSuffix:@".data"]) continue;
                NSString *path = RYGBridgeStandardPath([mobileConfigRoot stringByAppendingPathComponent:name]);
                if (RYGBridgeDirectoryExists(path)) [matches addObject:path];
            }
        }
    }
    return matches.array;
}

static BOOL RYGBridgePathIsInsideGroupRoots(NSString *path, NSArray<NSURL *> *groupRoots) {
    NSString *standard = RYGBridgeStandardPath(path);
    if (!standard.length) return NO;
    for (NSURL *rootURL in groupRoots) {
        NSString *root = RYGBridgeStandardPath(rootURL.path);
        if (!root.length) continue;
        if ([standard isEqualToString:root] || [standard hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static NSString *RYGBridgeUniqueMappingMatch(NSArray<NSString *> *dataDirectories) {
    NSData *mapping = RYGMCLoadCachedNameMappingData();
    if (!mapping.length) return nil;
    NSString *matched = nil;
    for (NSString *directory in dataDirectories) {
        NSData *native = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"id_name_mapping.json"] options:0 error:nil];
        if (!native.length || ![native isEqualToData:mapping]) continue;
        if (matched) return nil;
        matched = directory;
    }
    return matched;
}

static NSString *RYGBridgeResolveDataDirectoryFromCandidate(NSString *candidate) {
    NSString *standardCandidate = RYGBridgeStandardPath(candidate);
    NSString *leaf = RYGBridgeDataLeafFromCandidate(standardCandidate);
    NSDictionary<NSString *, NSURL *> *groups = RYGBridgeGroupContainerURLs();
    NSArray<NSURL *> *groupRoots = RYGBridgeUniqueGroupRoots(groups);

    // Once the native manager has positively identified <user>.data, preserve
    // that exact leaf across launches. App Group UUIDs can change after signing;
    // the account leaf is stable and is never synthesized by RyukGram.
    if (!leaf.length) leaf = RYGBridgePreviouslyVerifiedDataLeaf();

    // A native candidate is accepted immediately only when it already points at
    // an existing .data directory inside an App Group actually enumerated for
    // the current process.
    if (standardCandidate.length && [standardCandidate.lastPathComponent.lowercaseString hasSuffix:@".data"] &&
        RYGBridgeDirectoryExists(standardCandidate) && RYGBridgePathIsInsideGroupRoots(standardCandidate, groupRoots)) {
        return RYGBridgeRememberResolvedDataDirectory(standardCandidate);
    }

    NSArray<NSString *> *existing = RYGBridgeExistingDataDirectories(groupRoots);
    if (leaf.length) {
        NSMutableArray<NSString *> *sameLeaf = [NSMutableArray array];
        for (NSString *directory in existing) if ([directory.lastPathComponent isEqualToString:leaf]) [sameLeaf addObject:directory];
        if (sameLeaf.count == 1) return RYGBridgeRememberResolvedDataDirectory(sameLeaf.firstObject);
        NSString *mappingMatch = RYGBridgeUniqueMappingMatch(sameLeaf);
        if (mappingMatch.length) return RYGBridgeRememberResolvedDataDirectory(mappingMatch);
    }

    if (existing.count == 1) return RYGBridgeRememberResolvedDataDirectory(existing.firstObject);
    NSString *mappingMatch = RYGBridgeUniqueMappingMatch(existing);
    if (mappingMatch.length) return RYGBridgeRememberResolvedDataDirectory(mappingMatch);

    // A missing directory may be recreated only with an exact leaf that came
    // from the native manager on this or a previous verified launch and one
    // unambiguous App Group root actually returned for this process.
    NSURL *writableRoot = leaf.length ? RYGBridgePreferredWritableGroupRoot(groups) : nil;
    if (writableRoot.path.length) {
        NSString *mobileConfigRoot = RYGBridgeMobileConfigRootsForGroupURL(writableRoot).firstObject;
        NSError *error = nil;
        if ([NSFileManager.defaultManager createDirectoryAtPath:mobileConfigRoot
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error]) {
            NSString *target = [mobileConfigRoot stringByAppendingPathComponent:leaf];
            if ([NSFileManager.defaultManager createDirectoryAtPath:target
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:&error]) {
                return RYGBridgeRememberResolvedDataDirectory(target);
            }
        }
    }

    // Rootful/jailbreak installs may expose no App Group dictionary at all. In
    // that environment preserve the manager's existing exact .data directory;
    // there is deliberately no guessed account fallback.
    if (!groupRoots.count && standardCandidate.length &&
        [standardCandidate.lastPathComponent.lowercaseString hasSuffix:@".data"] &&
        RYGBridgeDirectoryExists(standardCandidate)) {
        return RYGBridgeRememberResolvedDataDirectory(standardCandidate);
    }
    return nil;
}

static void RYGBridgeMirrorMappingCache(NSString *dataDirectory) {
    if (!dataDirectory.length) return;
    NSData *mapping = RYGMCLoadCachedNameMappingData();
    if (!mapping.length) return;

    NSString *destination = [dataDirectory stringByAppendingPathComponent:@"id_name_mapping.json"];
    NSData *existing = [NSData dataWithContentsOfFile:destination options:0 error:nil];
    if (![existing isEqualToData:mapping]) {
        [mapping writeToFile:destination options:NSDataWritingAtomic error:nil];
    }
}

@implementation RYGMobileConfig (RYGMobileConfigBridge)

- (NSString *)ryg_bridgeNativeDataDirectory {
    // After exchange this invokes JSONIO's manager-backed resolver first. If the
    // manager is not captured yet, resolve from the process' actually enumerated
    // group container(s) and the existing or previously verified
    // Documents/mobileconfig/<user>.data directory.
    NSString *candidate = [self ryg_bridgeNativeDataDirectory];
    NSString *resolved = RYGBridgeResolveDataDirectoryFromCandidate(candidate);
    if (resolved.length) RYGBridgeMirrorMappingCache(resolved);
    return resolved;
}

- (NSDictionary *)ryg_bridgeLoadNameCatalog {
    NSDictionary *cached = RYGMCLoadCachedNameMappingCatalog(NULL);
    if (cached) return cached;
    return [self ryg_bridgeLoadNameCatalog];
}

@end

static void RYGBridgeExchange(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

__attribute__((constructor(100))) static void RYGMobileConfigEnableCaptureByDefault(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults objectForKey:@"ryg_metaconfig_enabled"] == nil) [defaults setBool:YES forKey:@"ryg_metaconfig_enabled"];
    }
}

__attribute__((constructor(65460))) static void RYGInstallMobileConfigBridge(void) {
    @autoreleasepool {
        Class cls = RYGMobileConfig.class;
        RYGBridgeExchange(cls, @selector(ryg_nativeDataDirectory), @selector(ryg_bridgeNativeDataDirectory));
        RYGBridgeExchange(cls, @selector(loadNameCatalog), @selector(ryg_bridgeLoadNameCatalog));
    }
}
