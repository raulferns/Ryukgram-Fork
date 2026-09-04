#import "RYGMobileConfigJSONIO.h"
#import "RYGMobileConfigNameMappingStore.h"
#import <math.h>
#include <stdlib.h>
#include <stdint.h>

static NSString *const kRYGMobileConfigNamesDidChangeNotification = @"RYGMobileConfigNamesDidChange";
static NSString *const kRYGMCQEOverridesKey = @"_qe_overrides_";
static NSString *const kRYGMCCanonicalSeparator = @": : ";
NSString *const RYGMCRuntimeSnapshotSchemaV1 = @"com.ryukgram.mobileconfig.runtime-snapshot.v1";

@interface RYGMobileConfig (RYGPrivateNativePath)
- (NSString *)mcDirectory;
@end

static NSError *RYGMCJSONError(NSString *message) {
    return [NSError errorWithDomain:@"com.ryukgram.mobileconfig.json"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:message ?: @"MobileConfig JSON error"}];
}

static NSString *RYGMCCanonicalOverridesCachePath(void) {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                NSUserDomainMask,
                                                                YES).firstObject
        stringByAppendingPathComponent:@"RyukGram"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [directory stringByAppendingPathComponent:@"mc_overrides_canonical.json"];
}

static BOOL RYGMCParseUnsigned(NSString *text,
                               unsigned long long maximum,
                               unsigned long long *result) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    const char *raw = trimmed.UTF8String;
    if (!raw || !*raw || *raw == '-') return NO;
    char *end = NULL;
    unsigned long long value = strtoull(raw, &end, 10);
    if (end == raw || *end != '\0' || value > maximum) return NO;
    if (result) *result = value;
    return YES;
}

static NSString *RYGMCJSONValueString(id value, RYGMCType type) {
    if (type == RYGMCTypeBool) return [value boolValue] ? @"true" : @"false";
    if (type == RYGMCTypeInt) return [NSString stringWithFormat:@"%lld", [value longLongValue]];
    if (type == RYGMCTypeDouble) return [NSString stringWithFormat:@"%.17g", [value doubleValue]];
    return [value isKindOfClass:NSString.class] ? value : [value description];
}

// Canonical native mc_overrides grammar is typed by the runtime parameter table:
// 1=bool, 2=int64, 3=string, 4=double. Unknown/mapping-only rows are preserved
// byte-semantically as strings but deliberately not interpreted or applied.
static id RYGMCParseCanonicalJSONValue(NSString *text, RYGMCType type) {
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (type == RYGMCTypeBool) {
        NSString *lower = trim.lowercaseString;
        if ([lower isEqualToString:@"true"]) return @YES;
        if ([lower isEqualToString:@"false"]) return @NO;
        return nil;
    }
    if (type == RYGMCTypeInt) {
        const char *raw = trim.UTF8String;
        if (!raw || !*raw) return nil;
        char *end = NULL;
        long long value = strtoll(raw, &end, 10);
        return end != raw && *end == '\0' ? @(value) : nil;
    }
    if (type == RYGMCTypeDouble) {
        const char *raw = trim.UTF8String;
        if (!raw || !*raw) return nil;
        char *end = NULL;
        double value = strtod(raw, &end);
        return end != raw && *end == '\0' && isfinite(value) ? @(value) : nil;
    }
    if (type == RYGMCTypeString) return text ?: @"";
    return nil;
}

static NSNumber *RYGMCRuntimeOverrideKey(unsigned int configNumber, unsigned int paramIndex) {
    uint64_t key = ((uint64_t)configNumber << 32) | (uint64_t)paramIndex;
    return @(key);
}

static NSDictionary<NSNumber *, NSDictionary *> *RYGMCCatalogFromCurrentModels(RYGMobileConfig *mobileConfig) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *catalog = [NSMutableDictionary dictionary];
    for (RYGMCConfig *config in mobileConfig.allConfigs) {
        NSMutableDictionary<NSNumber *, NSString *> *params = [NSMutableDictionary dictionary];
        for (RYGMCParam *param in config.params) {
            if (param.name.length) params[@(param.paramIndex)] = param.name;
        }
        if (config.name.length || params.count) {
            catalog[@(config.number)] = @{@"name":config.name ?: @"", @"params":params.copy};
        }
    }
    return catalog.copy;
}

static BOOL RYGMCVerifyPersistedCatalog(NSDictionary<NSNumber *, NSDictionary *> *expected, NSError **error) {
    NSDictionary<NSNumber *, NSDictionary *> *actual = RYGMCLoadCachedNameMappingCatalog(error);
    if (!actual) return NO;
    for (NSNumber *configNumber in expected) {
        NSDictionary *wanted = expected[configNumber];
        NSDictionary *got = actual[configNumber];
        if (!got) {
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Config %@ was not persisted.", configNumber]);
            return NO;
        }
        NSString *wantedName = [wanted[@"name"] isKindOfClass:NSString.class] ? wanted[@"name"] : @"";
        NSString *gotName = [got[@"name"] isKindOfClass:NSString.class] ? got[@"name"] : @"";
        if (wantedName.length && ![wantedName isEqualToString:gotName]) {
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Config %@ name did not round-trip.", configNumber]);
            return NO;
        }
        NSDictionary *wantedParams = [wanted[@"params"] isKindOfClass:NSDictionary.class] ? wanted[@"params"] : @{};
        NSDictionary *gotParams = [got[@"params"] isKindOfClass:NSDictionary.class] ? got[@"params"] : @{};
        for (NSNumber *paramIndex in wantedParams) {
            if (![wantedParams[paramIndex] isEqual:gotParams[paramIndex]]) {
                if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Param %@:%@ did not round-trip.", configNumber, paramIndex]);
                return NO;
            }
        }
    }
    return YES;
}

static void RYGMCPostNamesChanged(RYGMobileConfig *mobileConfig) {
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:kRYGMobileConfigNamesDidChangeNotification
                                                          object:mobileConfig];
    };
    if (NSThread.isMainThread) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

static NSDictionary *RYGMCOverridesRootFromData(NSData *data) {
    if (!data.length) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [root isKindOfClass:NSDictionary.class] ? root : nil;
}

static BOOL RYGMCValueMatchesType(id value, RYGMCType type) {
    if (type == RYGMCTypeString) return [value isKindOfClass:NSString.class];
    return (type == RYGMCTypeBool || type == RYGMCTypeInt || type == RYGMCTypeDouble) &&
           [value isKindOfClass:NSNumber.class];
}

static BOOL RYGMCParseCanonicalLine(NSString *line,
                                    unsigned int *paramIndex,
                                    NSString **valueText) {
    if (![line isKindOfClass:NSString.class]) return NO;
    NSRange separator = [line rangeOfString:kRYGMCCanonicalSeparator];
    if (separator.location == NSNotFound) return NO;
    NSString *indexText = [line substringToIndex:separator.location];
    unsigned long long parsedIndex = 0;
    if (!RYGMCParseUnsigned(indexText, UINT32_MAX, &parsedIndex)) return NO;
    if (paramIndex) *paramIndex = (unsigned int)parsedIndex;
    if (valueText) *valueText = [line substringFromIndex:NSMaxRange(separator)];
    return YES;
}

@implementation RYGMobileConfig (RYGJSONIO)

- (NSString *)ryg_nativeDataDirectory {
    NSString *path = nil;
    @try { path = [self mcDirectory]; } @catch (__unused NSException *exception) {}
    if (![path isKindOfClass:NSString.class] || !path.length) return nil;

    path = path.stringByStandardizingPath;
    // getOverridesTablePath is the authority for the active MobileConfig unit.
    // Its parent is the native Documents/mobileconfig/<user>.data directory;
    // never synthesize an App Group UUID or a sessionless subdirectory here.
    if (![path.pathExtension.lowercaseString isEqualToString:@"data"]) return nil;

    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        return isDirectory ? path : nil;
    }
    // Read-only native-file policy: an absent app-owned MobileConfig directory
    // is not synthesized by RyukGram.
    return nil;
}

- (NSString *)ryg_nativeNameMappingPath {
    NSString *directory = [self ryg_nativeDataDirectory];
    return directory.length ? [directory stringByAppendingPathComponent:@"id_name_mapping.json"] : nil;
}

- (NSString *)ryg_nativeOverridesJSONPath {
    NSString *directory = [self ryg_nativeDataDirectory];
    return directory.length ? [directory stringByAppendingPathComponent:@"mc_overrides.json"] : nil;
}

- (BOOL)ryg_importNameMappingData:(NSData *)data error:(NSError **)error {
    return [self ryg_importNameMappingData:data mode:RYGMCNameMappingImportModeReplace error:error];
}

- (BOOL)ryg_importNameMappingData:(NSData *)data
                             mode:(RYGMCNameMappingImportMode)mode
                            error:(NSError **)error {
    NSDictionary<NSNumber *, NSDictionary *> *incoming = RYGMCNameMappingCatalogFromData(data, error);
    if (!incoming) return NO;

    NSMutableDictionary<NSNumber *, NSDictionary *> *result = [NSMutableDictionary dictionary];
    if (mode == RYGMCNameMappingImportModeMerge) {
        NSDictionary *existing = RYGMCLoadCachedNameMappingCatalog(NULL);
        if (!existing.count) existing = RYGMCCatalogFromCurrentModels(self);
        if (existing.count) [result addEntriesFromDictionary:existing];
    }
    RYGMCMergeNameMappingCatalog(result, incoming);
    if (!RYGMCSaveNameMappingCatalog(result, error)) return NO;
    if (!RYGMCVerifyPersistedCatalog(result, error)) return NO;

    [self reloadFromRuntime];
    RYGMCPostNamesChanged(self);
    return YES;
}

- (NSData *)ryg_exportNameMappingData:(NSError **)error {
    NSData *cached = RYGMCLoadCachedNameMappingData();
    if (cached.length) return cached;
    NSString *nativePath = [self ryg_nativeNameMappingPath];
    NSData *native = nativePath.length ? [NSData dataWithContentsOfFile:nativePath options:0 error:nil] : nil;
    if (native.length) return native;
    NSDictionary *catalog = RYGMCCatalogFromCurrentModels(self);
    if (!catalog.count) {
        if (error) *error = RYGMCJSONError(@"No MobileConfig name mapping is available to export.");
        return nil;
    }
    return RYGMCNameMappingDataFromCatalog(catalog, error);
}

- (BOOL)ryg_importAndApplyOverridesData:(NSData *)data
                           appliedCount:(NSUInteger *)appliedCount
                                  error:(NSError **)error {
    if (appliedCount) *appliedCount = 0;
    if (!data.length) {
        if (error) *error = RYGMCJSONError(@"The mc_overrides.json file is empty.");
        return NO;
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = RYGMCJSONError(@"mc_overrides.json must be an object keyed by <config>:. ");
        return NO;
    }
    NSDictionary *json = parsed;

    [self prepare];
    NSMutableDictionary<NSNumber *, RYGMCConfig *> *configs = [NSMutableDictionary dictionary];
    for (RYGMCConfig *config in self.allConfigs) configs[@(config.number)] = config;

    // The imported mc_overrides.json is the complete active document for every
    // parameter whose ABI is known in this binary. Unknown/mapping-only rows are
    // preserved in the canonical JSON, but never converted into fabricated PIDs.
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    NSMutableSet<NSNumber *> *desiredRuntimeKeys = [NSMutableSet set];
    for (id rawKey in json) {
        if (![rawKey isKindOfClass:NSString.class]) {
            if (error) *error = RYGMCJSONError(@"Every mc_overrides key must be a string.");
            return NO;
        }
        NSString *key = rawKey;
        id rawLines = json[key];

        if ([key isEqualToString:kRYGMCQEOverridesKey]) {
            if (![rawLines isKindOfClass:NSArray.class]) {
                if (error) *error = RYGMCJSONError(@"_qe_overrides_ must be an array.");
                return NO;
            }
            for (id item in (NSArray *)rawLines) {
                if (![item isKindOfClass:NSString.class]) {
                    if (error) *error = RYGMCJSONError(@"Every _qe_overrides_ entry must be a string.");
                    return NO;
                }
            }
            continue;
        }

        if (![key hasSuffix:@":"] || key.length < 2 || ![rawLines isKindOfClass:NSArray.class]) {
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Invalid canonical config entry: %@", key]);
            return NO;
        }
        unsigned long long configNumber = 0;
        if (!RYGMCParseUnsigned([key substringToIndex:key.length - 1], UINT32_MAX, &configNumber)) {
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Invalid config id: %@", key]);
            return NO;
        }

        RYGMCConfig *config = configs[@(configNumber)];
        NSMutableDictionary<NSNumber *, RYGMCParam *> *params = [NSMutableDictionary dictionary];
        for (RYGMCParam *param in config.params) params[@(param.paramIndex)] = param;
        NSMutableSet<NSNumber *> *seenIndices = [NSMutableSet set];

        for (id rawLine in (NSArray *)rawLines) {
            if (![rawLine isKindOfClass:NSString.class]) {
                if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Config %@ contains a non-string override row.", key]);
                return NO;
            }
            unsigned int paramIndex = 0;
            NSString *valueText = nil;
            if (!RYGMCParseCanonicalLine(rawLine, &paramIndex, &valueText)) {
                if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Invalid override row in %@: %@", key, rawLine]);
                return NO;
            }
            NSNumber *indexKey = @(paramIndex);
            if ([seenIndices containsObject:indexKey]) {
                if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Duplicate override %@:%u", key, paramIndex]);
                return NO;
            }
            [seenIndices addObject:indexKey];

            RYGMCParam *param = params[indexKey];
            if (!param || !param.isRuntimeBacked || !RYGMCTypeIsRuntimeValue(param.type)) {
                continue;
            }
            id value = RYGMCParseCanonicalJSONValue(valueText, param.type);
            if (!value) {
                if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Type mismatch for %@:%u (%@).",
                                                    key, paramIndex, param.typeName ?: @"unknown"]);
                return NO;
            }
            [desiredRuntimeKeys addObject:RYGMCRuntimeOverrideKey(param.configNumber, param.paramIndex)];
            [actions addObject:@{@"param":param, @"value":value}];
        }
    }

    NSMutableArray<RYGMCParam *> *clearParams = [NSMutableArray array];
    for (RYGMCConfig *config in self.allConfigs) {
        for (RYGMCParam *param in config.params) {
            if (!param.isRuntimeBacked || !RYGMCTypeIsRuntimeValue(param.type)) continue;
            if ([self overrideStateFor:param] != RYGMCOverrideSet) continue;
            NSNumber *runtimeKey = RYGMCRuntimeOverrideKey(param.configNumber, param.paramIndex);
            if (![desiredRuntimeKeys containsObject:runtimeKey]) [clearParams addObject:param];
        }
    }

    NSData *canonical = [NSJSONSerialization dataWithJSONObject:json options:0 error:error];
    if (!canonical) return NO;

    NSString *cachePath = RYGMCCanonicalOverridesCachePath();
    NSFileManager *fileManager = NSFileManager.defaultManager;

    BOOL cacheExisted = [fileManager fileExistsAtPath:cachePath];
    NSError *snapshotError = nil;
    NSData *previousCache = cacheExisted
        ? [NSData dataWithContentsOfFile:cachePath options:0 error:&snapshotError]
        : nil;
    if (cacheExisted && !previousCache) {
        if (error) *error = snapshotError ?: RYGMCJSONError(@"Could not snapshot the existing canonical overrides cache.");
        return NO;
    }
    // Snapshot every touched runtime parameter once — both rows being replaced
    // and old active rows that the imported final document intentionally omits.
    NSMutableArray<NSDictionary *> *previousOverrides = [NSMutableArray arrayWithCapacity:actions.count + clearParams.count];
    NSMutableSet<NSNumber *> *snapshottedKeys = [NSMutableSet set];
    void (^snapshotParam)(RYGMCParam *) = ^(RYGMCParam *param) {
        NSNumber *runtimeKey = RYGMCRuntimeOverrideKey(param.configNumber, param.paramIndex);
        if ([snapshottedKeys containsObject:runtimeKey]) return;
        [snapshottedKeys addObject:runtimeKey];
        BOOL hadOverride = [self overrideStateFor:param] == RYGMCOverrideSet;
        id previousValue = hadOverride ? [self overrideValueFor:param] : nil;
        [previousOverrides addObject:@{
            @"param":param,
            @"had":@(hadOverride),
            @"value":previousValue ?: NSNull.null,
        }];
    };
    for (RYGMCParam *param in clearParams) snapshotParam(param);
    for (NSDictionary *action in actions) snapshotParam(action[@"param"]);

    void (^rollbackLiveState)(void) = ^{
        for (NSInteger index = (NSInteger)previousOverrides.count - 1; index >= 0; index--) {
            NSDictionary *snapshot = previousOverrides[(NSUInteger)index];
            RYGMCParam *param = snapshot[@"param"];
            if ([snapshot[@"had"] boolValue]) {
                id previousValue = snapshot[@"value"];
                if (previousValue != NSNull.null) [self setOverride:previousValue for:param];
            } else {
                [self clearOverrideFor:param];
            }
        }
        [self reapplyOverridesToNativeTable];
    };

    void (^restoreDiskState)(void) = ^{
        if (cacheExisted) {
            [previousCache writeToFile:cachePath options:NSDataWritingAtomic error:nil];
        } else {
            [fileManager removeItemAtPath:cachePath error:nil];
        }
    };

    for (RYGMCParam *param in clearParams) [self clearOverrideFor:param];

    NSUInteger applied = 0;
    for (NSDictionary *action in actions) {
        RYGMCParam *param = action[@"param"];
        id value = action[@"value"];
        if (![self setOverride:value for:param]) {
            rollbackLiveState();
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Could not apply %u:%u; the previous override state was restored.",
                                                param.configNumber,
                                                param.paramIndex]);
            return NO;
        }
        applied++;
    }
    [self reapplyOverridesToNativeTable];

    NSError *writeError = nil;
    if (![canonical writeToFile:cachePath options:NSDataWritingAtomic error:&writeError]) {
        restoreDiskState();
        rollbackLiveState();
        if (error) *error = writeError ?: RYGMCJSONError(@"Could not persist the canonical overrides cache.");
        return NO;
    }
    if (appliedCount) *appliedCount = applied;
    return YES;
}

- (NSData *)ryg_exportOverridesData:(NSError **)error {
    NSDictionary *base = nil;
    NSString *nativePath = [self ryg_nativeOverridesJSONPath];
    if (nativePath.length) {
        base = RYGMCOverridesRootFromData([NSData dataWithContentsOfFile:nativePath options:0 error:nil]);
    }
    if (!base) {
        base = RYGMCOverridesRootFromData([NSData dataWithContentsOfFile:RYGMCCanonicalOverridesCachePath()
                                                                 options:0
                                                                   error:nil]);
    }

    NSMutableDictionary<NSString *, id> *root = [NSMutableDictionary dictionary];
    if (base) [root addEntriesFromDictionary:base];
    if (![root[kRYGMCQEOverridesKey] isKindOfClass:NSArray.class]) root[kRYGMCQEOverridesKey] = @[];

    for (RYGMCConfig *config in self.allConfigs) {
        NSString *configKey = [NSString stringWithFormat:@"%u:", config.number];
        NSArray *existing = [root[configKey] isKindOfClass:NSArray.class] ? root[configKey] : @[];
        NSMutableDictionary<NSNumber *, NSString *> *knownLines = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *passthrough = [NSMutableArray array];

        for (id rawLine in existing) {
            if (![rawLine isKindOfClass:NSString.class]) continue;
            unsigned int index = 0;
            if (RYGMCParseCanonicalLine(rawLine, &index, NULL)) knownLines[@(index)] = rawLine;
            else [passthrough addObject:rawLine];
        }

        for (RYGMCParam *param in config.params) {
            if (!param.isRuntimeBacked || !RYGMCTypeIsRuntimeValue(param.type)) continue;
            NSNumber *indexKey = @(param.paramIndex);
            if ([self overrideStateFor:param] == RYGMCOverrideSet) {
                id value = [self overrideValueFor:param];
                if (value) {
                    knownLines[indexKey] = [NSString stringWithFormat:@"%u: : %@",
                                            param.paramIndex,
                                            RYGMCJSONValueString(value, param.type)];
                }
            } else {
                [knownLines removeObjectForKey:indexKey];
            }
        }

        NSArray<NSNumber *> *indices = [knownLines.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:passthrough.count + indices.count];
        [lines addObjectsFromArray:passthrough];
        for (NSNumber *index in indices) [lines addObject:knownLines[index]];
        if (lines.count) root[configKey] = lines;
        else [root removeObjectForKey:configKey];
    }

    return [NSJSONSerialization dataWithJSONObject:root options:0 error:error];
}

- (BOOL)ryg_isRuntimeSnapshotData:(NSData *)data {
    if (!data.length) return NO;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [root isKindOfClass:NSDictionary.class] &&
           [root[@"schema"] isEqualToString:RYGMCRuntimeSnapshotSchemaV1] &&
           [root[@"entries"] isKindOfClass:NSArray.class];
}

- (NSData *)ryg_exportRuntimeSnapshotData:(NSError **)error {
    [self prepare];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger effectiveCount = 0;
    NSUInteger overrideCount = 0;
    for (RYGMCConfig *config in self.allConfigs) {
        for (RYGMCParam *param in config.params) {
            if (!param.isRuntimeBacked || !param.paramID || !RYGMCTypeIsRuntimeValue(param.type)) continue;
            NSMutableDictionary *row = [@{
                @"pid": [NSString stringWithFormat:@"%llu", param.paramID],
                @"config": @(param.configNumber),
                @"param": @(param.paramIndex),
                @"ordinal": @(param.ordinal),
                @"type": param.typeName ?: @"unknown",
                @"override_present": @([self overrideStateFor:param] == RYGMCOverrideSet),
            } mutableCopy];
            if (config.name.length) row[@"config_name"] = config.name;
            if (param.name.length) row[@"name"] = param.name;

            id effective = [self liveValueFor:param];
            if (RYGMCValueMatchesType(effective, param.type)) {
                row[@"effective_present"] = @YES;
                row[@"effective_value"] = effective;
                effectiveCount++;
            } else {
                row[@"effective_present"] = @NO;
            }

            if ([row[@"override_present"] boolValue]) {
                id value = [self overrideValueFor:param];
                if (RYGMCValueMatchesType(value, param.type)) {
                    row[@"override_value"] = value;
                    overrideCount++;
                } else {
                    row[@"override_present"] = @NO;
                }
            }
            [entries addObject:row.copy];
        }
    }
    if (!entries.count) {
        if (error) *error = RYGMCJSONError(@"Instagram's exported MobileConfig runtime table is unavailable.");
        return nil;
    }
    NSDictionary *document = @{
        @"schema": RYGMCRuntimeSnapshotSchemaV1,
        @"created_at": @([[NSDate date] timeIntervalSince1970]),
        @"bundle_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"runtime_parameter_count": @(entries.count),
        @"effective_value_count": @(effectiveCount),
        @"override_count": @(overrideCount),
        @"import_policy": @"restore_explicit_overrides_only",
        @"entries": entries,
    };
    return [NSJSONSerialization dataWithJSONObject:document options:0 error:error];
}

- (BOOL)ryg_importRuntimeSnapshotOverridesData:(NSData *)data
                                   appliedCount:(NSUInteger *)appliedCount
                                          error:(NSError **)error {
    if (appliedCount) *appliedCount = 0;
    id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![parsed isKindOfClass:NSDictionary.class] ||
        ![parsed[@"schema"] isEqualToString:RYGMCRuntimeSnapshotSchemaV1] ||
        ![parsed[@"entries"] isKindOfClass:NSArray.class]) {
        if (error && !*error) *error = RYGMCJSONError(@"This is not a RyukGram typed runtime snapshot.");
        return NO;
    }

    [self prepare];
    NSMutableDictionary<NSString *, RYGMCParam *> *paramsByPID = [NSMutableDictionary dictionary];
    NSMutableArray<RYGMCParam *> *allRuntimeParams = [NSMutableArray array];
    for (RYGMCConfig *config in self.allConfigs) for (RYGMCParam *param in config.params) {
        if (!param.isRuntimeBacked || !param.paramID || !RYGMCTypeIsRuntimeValue(param.type)) continue;
        paramsByPID[[NSString stringWithFormat:@"%llu", param.paramID]] = param;
        [allRuntimeParams addObject:param];
    }

    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id candidate in parsed[@"entries"]) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
            if (error) *error = RYGMCJSONError(@"Runtime snapshot contains a non-object entry.");
            return NO;
        }
        NSDictionary *row = candidate;
        NSString *pid = [row[@"pid"] isKindOfClass:NSString.class] ? row[@"pid"] : nil;
        NSNumber *present = [row[@"override_present"] isKindOfClass:NSNumber.class] ? row[@"override_present"] : nil;
        NSNumber *configNumber = [row[@"config"] isKindOfClass:NSNumber.class] ? row[@"config"] : nil;
        NSNumber *paramIndex = [row[@"param"] isKindOfClass:NSNumber.class] ? row[@"param"] : nil;
        NSNumber *ordinal = [row[@"ordinal"] isKindOfClass:NSNumber.class] ? row[@"ordinal"] : nil;
        unsigned long long parsedPID = 0;
        NSString *canonicalPID = nil;
        if (RYGMCParseUnsigned(pid, UINT64_MAX, &parsedPID) && parsedPID)
            canonicalPID = [NSString stringWithFormat:@"%llu", parsedPID];
        if (!canonicalPID.length || ![pid isEqualToString:canonicalPID] || !present ||
            !configNumber || !paramIndex || !ordinal || [seen containsObject:canonicalPID]) {
            if (error) *error = RYGMCJSONError(@"Runtime snapshot contains an invalid or duplicate PID.");
            return NO;
        }
        [seen addObject:canonicalPID];
        if (!present.boolValue) continue;
        RYGMCParam *param = paramsByPID[canonicalPID];
        if (!param) continue; // A later Instagram build may no longer expose it.
        NSString *type = [row[@"type"] isKindOfClass:NSString.class] ? row[@"type"] : nil;
        id value = row[@"override_value"];
        BOOL identityMatches = configNumber.unsignedLongLongValue == param.configNumber &&
                               paramIndex.unsignedLongLongValue == param.paramIndex &&
                               ordinal.unsignedLongLongValue == param.ordinal;
        if (!identityMatches || ![type isEqualToString:param.typeName] || !RYGMCValueMatchesType(value, param.type)) {
            if (error) *error = RYGMCJSONError([NSString stringWithFormat:@"Identity/type mismatch for runtime PID %@.", canonicalPID]);
            return NO;
        }
        [actions addObject:@{@"param":param, @"value":value}];
    }

    NSMutableArray<NSDictionary *> *previous = [NSMutableArray array];
    for (RYGMCParam *param in allRuntimeParams) {
        if ([self overrideStateFor:param] != RYGMCOverrideSet) continue;
        id value = [self overrideValueFor:param];
        if (RYGMCValueMatchesType(value, param.type)) [previous addObject:@{@"param":param, @"value":value}];
    }

    [self resetAllOverrides];
    NSUInteger applied = 0;
    for (NSDictionary *action in actions) {
        if (![self setOverride:action[@"value"] for:action[@"param"]]) {
            [self resetAllOverrides];
            for (NSDictionary *old in previous) (void)[self setOverride:old[@"value"] for:old[@"param"]];
            [self reapplyOverridesToNativeTable];
            if (error) *error = RYGMCJSONError(@"Could not apply the snapshot; the previous override set was restored.");
            return NO;
        }
        applied++;
    }
    [self reapplyOverridesToNativeTable];
    if (appliedCount) *appliedCount = applied;
    return YES;
}

@end
