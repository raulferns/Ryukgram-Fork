#import "RYGMobileConfig.h"
#import "RYGMobileConfigNameMappingStore.h"
#import "RYGMobileConfigJSONIO.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <pthread.h>
#import <execinfo.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>

// One MobileConfig owner: one getter-hook chain, one runtime metadata parser,
// one name catalog, and the framework's native StartupConfigs override API.
static __weak id gManager;
static NSMutableDictionary<NSNumber *, id> *gManagersByUnit;
static NSMutableDictionary<NSNumber *, NSValue *> *gCallSites;
static NSMutableDictionary<NSNumber *, id> *gActiveOverrides;
static NSMutableDictionary<NSNumber *, NSNumber *> *gRealPidByOrdIdx;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool gPersistedNativeSyncScheduled = false;

static void *rygSym(const char *name) { return dlsym(RTLD_DEFAULT, name); }

static BOOL rygImageRangeIsReadable(const void *pointer, size_t length) {
    if (!pointer || !length) return NO;
    uintptr_t start = (uintptr_t)pointer; if (start > UINTPTR_MAX - length) return NO; uintptr_t end = start + length;
    Dl_info info = {0}; if (!dladdr(pointer, &info) || !info.dli_fbase) return NO;
    const struct mach_header *raw = (const struct mach_header *)info.dli_fbase; if (raw->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)raw;
    if (!header->sizeofcmds || header->sizeofcmds > 16 * 1024 * 1024 || header->ncmds > 65535) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1), *commandsEnd = cursor + header->sizeofcmds; uint64_t textVMAddr = UINT64_MAX;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor > commandsEnd || (size_t)(commandsEnd - cursor) < sizeof(struct load_command)) return NO;
        const struct load_command *cmd = (const struct load_command *)cursor; if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > (size_t)(commandsEnd - cursor)) return NO;
        if (cmd->cmd == LC_SEGMENT_64) { const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd; if (seg->cmdsize < sizeof(*seg)) return NO; if (strncmp(seg->segname, SEG_TEXT, sizeof(seg->segname)) == 0) textVMAddr = seg->vmaddr; }
        cursor += cmd->cmdsize;
    }
    if (textVMAddr == UINT64_MAX || (uintptr_t)header < (uintptr_t)textVMAddr) return NO;
    uintptr_t slide = (uintptr_t)header - (uintptr_t)textVMAddr; cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) { const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd; if ((seg->initprot & VM_PROT_READ) && seg->vmaddr <= UINTPTR_MAX - slide) { uintptr_t a = slide + (uintptr_t)seg->vmaddr; if ((uintptr_t)seg->vmsize <= UINTPTR_MAX - a) { uintptr_t b = a + (uintptr_t)seg->vmsize; if (start >= a && end <= b) return YES; } } }
        cursor += cmd->cmdsize;
    }
    return NO;
}

static uintptr_t rygCanonicalPointerValue(const void *pointer) { return ((uintptr_t)pointer) & 0x0000FFFFFFFFFFFFULL; }
static unsigned long long rygCanonicalPid(unsigned long long pid) { if (!pid) return 0; unsigned long long type = (pid >> 48) & 0x0F; return (pid & 0x0000FFFFFFFFFFFFULL) | ((0x40ULL | type) << 48); }
static unsigned long long rygVariantPid(unsigned long long pid, unsigned long long base) { if (!pid) return 0; unsigned long long type = (pid >> 48) & 0x0F; return (pid & 0x0000FFFFFFFFFFFFULL) | ((base | type) << 48); }

static id rygActiveOverride(unsigned long long pid) { pthread_mutex_lock(&gLock); id value = gActiveOverrides[@(pid)]; pthread_mutex_unlock(&gLock); return value; }
static void rygActivateOverride(unsigned long long pid, id value) { if (!pid || !value) return; pthread_mutex_lock(&gLock); if (!gActiveOverrides) gActiveOverrides = [NSMutableDictionary dictionary]; gActiveOverrides[@(rygVariantPid(pid, 0x40))] = value; gActiveOverrides[@(rygVariantPid(pid, 0x80))] = value; pthread_mutex_unlock(&gLock); }
static void rygDeactivateOverride(unsigned long long pid) { if (!pid) return; pthread_mutex_lock(&gLock); [gActiveOverrides removeObjectForKey:@(rygVariantPid(pid, 0x40))]; [gActiveOverrides removeObjectForKey:@(rygVariantPid(pid, 0x80))]; pthread_mutex_unlock(&gLock); }

static void rygCaptureManager(id manager, unsigned long long pid) {
    if (!manager || !pid) return; gManager = manager;
    unsigned long long unit = (pid >> 48) & 0xF0; unsigned int ordinal = (unsigned int)((pid >> 32) & 0xFFFF); unsigned int index = (unsigned int)((pid >> 16) & 0xFFFF);
    pthread_mutex_lock(&gLock); if (!gManagersByUnit) gManagersByUnit = [NSMutableDictionary dictionary]; if (!gRealPidByOrdIdx) gRealPidByOrdIdx = [NSMutableDictionary dictionary]; gManagersByUnit[@(unit)] = manager; gRealPidByOrdIdx[@(((unsigned long long)ordinal << 20) | index)] = @(pid); pthread_mutex_unlock(&gLock);

    bool expected = false;
    if (atomic_compare_exchange_strong_explicit(&gPersistedNativeSyncScheduled, &expected, true, memory_order_relaxed, memory_order_relaxed)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
            if (mobileConfig.overrideCount) [mobileConfig reapplyOverridesToNativeTable];
        });
    }
}

static BOOL rygPathIsRyukGram(NSString *path) { return [path.lastPathComponent.lowercaseString containsString:@"ryukgram"]; }
static BOOL rygPathBelongsToApp(NSString *path) {
    NSString *standard = path.stringByStandardizingPath, *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath, *executable = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    if (!standard.length || !bundle.length) return NO; return [standard isEqualToString:executable] || [standard hasPrefix:[bundle stringByAppendingString:@"/"]];
}
static void rygRecordCaller(unsigned long long pid) {
    if (!pid) return; pthread_mutex_lock(&gLock); BOOL seen = gCallSites[@(pid)] != nil; pthread_mutex_unlock(&gLock); if (seen) return;
    void *frames[16] = {0}; int count = backtrace(frames, 16); void *external = NULL;
    for (int i = 2; i < count; i++) { Dl_info info = {0}; if (!dladdr(frames[i], &info) || !info.dli_fname) continue; NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @""; if (rygPathIsRyukGram(path)) continue; if (!rygPathBelongsToApp(path)) break; external = frames[i]; break; }
    if (!external) return; pthread_mutex_lock(&gLock); if (!gCallSites) gCallSites = [NSMutableDictionary dictionary]; if (!gCallSites[@(pid)]) gCallSites[@(pid)] = [NSValue valueWithPointer:external]; pthread_mutex_unlock(&gLock);
}

#pragma mark - Single typed pass-through getter chain
#define RYG_CAPTURE() do { rygCaptureManager(self, pid); rygRecordCaller(pid); } while (0)
static BOOL (*orig_getBool)(id, SEL, unsigned long long);
static BOOL new_getBool(id self, SEL cmd, unsigned long long pid) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v boolValue] : (orig_getBool ? orig_getBool(self, cmd, pid) : NO); }
static BOOL (*orig_getBoolDef)(id, SEL, unsigned long long, BOOL);
static BOOL new_getBoolDef(id self, SEL cmd, unsigned long long pid, BOOL def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v boolValue] : (orig_getBoolDef ? orig_getBoolDef(self, cmd, pid, def) : def); }
static BOOL (*orig_getBoolOpts)(id, SEL, unsigned long long, id);
static BOOL new_getBoolOpts(id self, SEL cmd, unsigned long long pid, id opts) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v boolValue] : (orig_getBoolOpts ? orig_getBoolOpts(self, cmd, pid, opts) : NO); }
static BOOL (*orig_getBoolOptsDef)(id, SEL, unsigned long long, id, BOOL);
static BOOL new_getBoolOptsDef(id self, SEL cmd, unsigned long long pid, id opts, BOOL def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v boolValue] : (orig_getBoolOptsDef ? orig_getBoolOptsDef(self, cmd, pid, opts, def) : def); }
static long long (*orig_getInt)(id, SEL, unsigned long long);
static long long new_getInt(id self, SEL cmd, unsigned long long pid) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v longLongValue] : (orig_getInt ? orig_getInt(self, cmd, pid) : 0); }
static long long (*orig_getIntDef)(id, SEL, unsigned long long, long long);
static long long new_getIntDef(id self, SEL cmd, unsigned long long pid, long long def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v longLongValue] : (orig_getIntDef ? orig_getIntDef(self, cmd, pid, def) : def); }
static long long (*orig_getIntOpts)(id, SEL, unsigned long long, id);
static long long new_getIntOpts(id self, SEL cmd, unsigned long long pid, id opts) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v longLongValue] : (orig_getIntOpts ? orig_getIntOpts(self, cmd, pid, opts) : 0); }
static long long (*orig_getIntOptsDef)(id, SEL, unsigned long long, id, long long);
static long long new_getIntOptsDef(id self, SEL cmd, unsigned long long pid, id opts, long long def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v longLongValue] : (orig_getIntOptsDef ? orig_getIntOptsDef(self, cmd, pid, opts, def) : def); }
static double (*orig_getDouble)(id, SEL, unsigned long long);
static double new_getDouble(id self, SEL cmd, unsigned long long pid) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v doubleValue] : (orig_getDouble ? orig_getDouble(self, cmd, pid) : 0.0); }
static double (*orig_getDoubleDef)(id, SEL, unsigned long long, double);
static double new_getDoubleDef(id self, SEL cmd, unsigned long long pid, double def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v doubleValue] : (orig_getDoubleDef ? orig_getDoubleDef(self, cmd, pid, def) : def); }
static double (*orig_getDoubleOpts)(id, SEL, unsigned long long, id);
static double new_getDoubleOpts(id self, SEL cmd, unsigned long long pid, id opts) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v doubleValue] : (orig_getDoubleOpts ? orig_getDoubleOpts(self, cmd, pid, opts) : 0.0); }
static double (*orig_getDoubleOptsDef)(id, SEL, unsigned long long, id, double);
static double new_getDoubleOptsDef(id self, SEL cmd, unsigned long long pid, id opts, double def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return v ? [v doubleValue] : (orig_getDoubleOptsDef ? orig_getDoubleOptsDef(self, cmd, pid, opts, def) : def); }
static id (*orig_getString)(id, SEL, unsigned long long);
static id new_getString(id self, SEL cmd, unsigned long long pid) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return [v isKindOfClass:NSString.class] ? v : (orig_getString ? orig_getString(self, cmd, pid) : nil); }
static id (*orig_getStringDef)(id, SEL, unsigned long long, id);
static id new_getStringDef(id self, SEL cmd, unsigned long long pid, id def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return [v isKindOfClass:NSString.class] ? v : (orig_getStringDef ? orig_getStringDef(self, cmd, pid, def) : def); }
static id (*orig_getStringOpts)(id, SEL, unsigned long long, id);
static id new_getStringOpts(id self, SEL cmd, unsigned long long pid, id opts) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return [v isKindOfClass:NSString.class] ? v : (orig_getStringOpts ? orig_getStringOpts(self, cmd, pid, opts) : nil); }
static id (*orig_getStringOptsDef)(id, SEL, unsigned long long, id, id);
static id new_getStringOptsDef(id self, SEL cmd, unsigned long long pid, id opts, id def) { RYG_CAPTURE(); id v = rygActiveOverride(pid); return [v isKindOfClass:NSString.class] ? v : (orig_getStringOptsDef ? orig_getStringOptsDef(self, cmd, pid, opts, def) : def); }
#undef RYG_CAPTURE

@implementation RYGMCParam
- (NSString *)typeName { if (!self.runtimeBacked) return @"mapping"; switch (self.type) { case RYGMCTypeBool:return @"bool"; case RYGMCTypeInt:return @"int"; case RYGMCTypeString:return @"string"; case RYGMCTypeDouble:return @"double"; default:return @"unknown"; } }
@end
@implementation RYGMCConfig
- (NSString *)displayName { return self.name.length ? self.name : [NSString stringWithFormat:@"Config %u", self.number]; }
- (BOOL)hasRuntimeBacking { for (RYGMCParam *param in self.params) if (param.runtimeBacked) return YES; return NO; }
@end

@interface RYGMobileConfig ()
- (NSString *)mcDirectory;
- (NSMutableDictionary *)loadOverrides;
- (NSMutableDictionary *)loadNotes;
- (void)saveOverrides;
- (void)saveNotes;
- (unsigned long long)validParamIDForOrdinal:(unsigned int)ordinal index:(unsigned int)paramIndex serial:(unsigned int)serial type:(RYGMCType)type;
@end

@implementation RYGMobileConfig {
    NSArray<RYGMCConfig *> *_configs;
    NSMutableDictionary<NSNumber *, id> *_overrides;
    NSMutableDictionary<NSNumber *, NSString *> *_notes;
    BOOL _ready;
    NSUInteger _namedConfigCount;
    int (*_typeFromParam)(unsigned long long);
}

+ (instancetype)shared { static RYGMobileConfig *shared; static dispatch_once_t once; dispatch_once(&once, ^{ shared = [RYGMobileConfig new]; }); return shared; }
- (instancetype)init {
    if ((self = [super init])) {
        _overrides = [self loadOverrides];
        for (NSNumber *pid in _overrides) rygActivateOverride(pid.unsignedLongLongValue, _overrides[pid]);
        _notes = [self loadNotes];
        _typeFromParam = (int (*)(unsigned long long))rygSym("_ZN12mobileconfig17typeFromParameterEy");
    }
    return self;
}
- (BOOL)ready { return _ready; }
- (NSUInteger)namedConfigCount { return _namedConfigCount; }

#pragma mark - Name catalog
- (NSDictionary *)loadNameCatalog { NSDictionary *cached = RYGMCLoadCachedNameMappingCatalog(NULL); if (cached.count) return cached; NSMutableDictionary *catalog = [NSMutableDictionary dictionary]; [self mergeDiskNamesInto:catalog]; return catalog.copy; }
- (NSString *)mcDirectory {
    id manager = gManager;
    SEL selector = NSSelectorFromString(@"getOverridesTablePath");
    Method method = manager ? class_getInstanceMethod([manager class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    if (*ret != '@') return nil;

    id value = ((id (*)(id, SEL))objc_msgSend)(manager, selector);
    NSString *path = [value isKindOfClass:NSURL.class] ? [(NSURL *)value path] : ([value isKindOfClass:NSString.class] ? value : nil);
    if ([path hasPrefix:@"file://"]) path = [NSURL URLWithString:path].path;
    path = path.stringByStandardizingPath;
    if (!path.length) return nil;

    // The framework's getOverridesTablePath is the native authority. In the
    // current FB/IG MobileConfig implementation it resolves the mc_overrides
    // table inside Documents/mobileconfig/<user>.data. Accept either the table
    // path or the data directory itself, but never synthesize sessionless paths.
    if ([path.pathExtension.lowercaseString isEqualToString:@"data"]) return path;
    NSString *directory = path.stringByDeletingLastPathComponent;
    return [directory.pathExtension.lowercaseString isEqualToString:@"data"] ? directory : nil;
}
- (void)mergeDiskNamesInto:(NSMutableDictionary *)catalog {
    NSString *directory = [self mcDirectory]; if (!directory.length) return; NSFileManager *fm = NSFileManager.defaultManager; NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) if ([name isEqualToString:@"id_name_mapping.json"] || [name hasPrefix:@"mc_sync_response_dump"]) [files addObject:[directory stringByAppendingPathComponent:name]];
    for (NSString *path in files) {
        NSData *data = [NSData dataWithContentsOfFile:path]; if (!data.length) continue; id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; NSArray *entries = nil;
        if ([json isKindOfClass:NSArray.class]) entries = (NSArray *)json; else if ([json isKindOfClass:NSDictionary.class]) { id names = ((NSDictionary *)json)[@"id_to_names"]; if ([names isKindOfClass:NSArray.class]) entries = (NSArray *)names; }
        for (id raw in entries) { if (![raw isKindOfClass:NSString.class]) continue; NSArray<NSString *> *parts = [raw componentsSeparatedByString:@":"]; if (parts.count < 2) continue; unsigned long long cfg = strtoull(parts[0].UTF8String, NULL, 10); if (cfg > UINT32_MAX) continue; NSNumber *key = @((unsigned int)cfg); NSDictionary *old = [catalog[key] isKindOfClass:NSDictionary.class] ? catalog[key] : nil; NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:[old[@"params"] isKindOfClass:NSDictionary.class] ? old[@"params"] : @{}]; for (NSUInteger i = 2; i + 1 < parts.count; i += 2) { unsigned long long idx = strtoull(parts[i].UTF8String, NULL, 10); if (idx <= UINT32_MAX && parts[i+1].length) params[@((unsigned int)idx)] = parts[i+1]; } catalog[key] = @{@"name":parts[1].length ? parts[1] : (old[@"name"] ?: @""), @"params":params.copy}; }
    }
}

#pragma mark - Runtime metadata
- (unsigned long long)validParamIDForOrdinal:(unsigned int)ordinal index:(unsigned int)paramIndex serial:(unsigned int)serial type:(RYGMCType)type {
    if (!_typeFromParam || !RYGMCTypeIsRuntimeValue(type)) return 0;
    for (unsigned long long base = 0x40; base <= 0x80; base += 0x40) { unsigned long long pid = ((base | type) << 48) | ((unsigned long long)ordinal << 32) | ((unsigned long long)paramIndex << 16) | serial; if (_typeFromParam(pid) == (int)type) return pid; }
    return 0;
}
- (size_t)exportedParamCount {
    void *symbol = rygSym("_ZN12mobileconfig23kMobileConfigParamsSizeE"); if (!rygImageRangeIsReadable(symbol, 4 * sizeof(uint32_t))) return 0; uint32_t raw[4] = {0}; memcpy(raw, symbol, sizeof(raw));
    for (NSUInteger i = 0; i < 4; i++) if (raw[i] && raw[i] <= 200000) for (NSUInteger j = i + 1; j < 4; j++) if (raw[j] == raw[i]) return raw[i];
    for (NSUInteger i = 0; i < 4; i++) if (raw[i] && raw[i] <= 200000) return raw[i]; return 0;
}
- (BOOL)descriptorAt:(const char *)row stride:(size_t)stride validatesType:(BOOL)validateType {
    if (!row || stride < 40 || !rygImageRangeIsReadable(row, stride)) return NO; unsigned int paramIndex = 0, ordinalMix = 0, typeSerial = 0; memcpy(&paramIndex, row + 16, 4); memcpy(&ordinalMix, row + 20, 4); memcpy(&typeSerial, row + 24, 4); RYGMCType type = (RYGMCType)(typeSerial >> 16); if (!RYGMCTypeIsRuntimeValue(type)) return NO; if (!validateType) return YES; return [self validParamIDForOrdinal:(ordinalMix & 0xFFFF) index:paramIndex serial:(typeSerial & 0xFFFF) type:type] != 0;
}
- (const char *)paramsArrayStride:(size_t *)stride count:(size_t *)count {
    void *listSymbol = rygSym("_ZN12mobileconfig23kMobileConfigParamsListE"); size_t rowCount = [self exportedParamCount]; if (!rowCount || !rygImageRangeIsReadable(listSymbol, 8 * sizeof(void *))) return NULL;
    void *slots[8] = {0}; memcpy(slots, listSymbol, sizeof(slots)); const size_t samples[] = {0, 1, 2, 7, 31, 127}; const char *bestTable = NULL; size_t bestStride = 0; NSUInteger bestScore = 0;
    for (NSUInteger slot = 0; slot < 8; slot++) { uintptr_t canonical = rygCanonicalPointerValue(slots[slot]); const char *table = canonical ? (const char *)canonical : NULL; if (!rygImageRangeIsReadable(table, 256)) continue;
        for (size_t candidateStride = 32; candidateStride <= 128; candidateStride += 8) { if (candidateStride > SIZE_MAX / rowCount || !rygImageRangeIsReadable(table, candidateStride * rowCount)) continue; NSUInteger score = 0, attempted = 0; for (NSUInteger s = 0; s < sizeof(samples)/sizeof(samples[0]); s++) { size_t rowIndex = samples[s]; if (rowIndex >= rowCount) continue; attempted++; if ([self descriptorAt:table + rowIndex * candidateStride stride:candidateStride validatesType:YES]) score++; } if (attempted && score > bestScore) { bestScore = score; bestStride = candidateStride; bestTable = table; } }
    }
    if (!bestTable || bestScore < 3) return NULL; if (stride) *stride = bestStride; if (count) *count = rowCount; return bestTable;
}

- (void)prepare {
    if (_ready) return; _typeFromParam = (int (*)(unsigned long long))rygSym("_ZN12mobileconfig17typeFromParameterEy"); NSDictionary<NSNumber *, NSDictionary *> *catalog = [self loadNameCatalog] ?: @{}; NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, RYGMCParam *> *> *paramsByConfig = [NSMutableDictionary dictionary];
    size_t stride = 0, count = 0; const char *table = [self paramsArrayStride:&stride count:&count];
    if (table && stride && count && _typeFromParam) for (size_t i = 0; i < count; i++) {
        const char *row = table + i * stride; if (![self descriptorAt:row stride:stride validatesType:NO]) continue; unsigned int paramIndex = 0, ordinalMix = 0, typeSerial = 0, configNumber = 0; memcpy(&paramIndex,row+16,4); memcpy(&ordinalMix,row+20,4); memcpy(&typeSerial,row+24,4); memcpy(&configNumber,row+stride-4,4); RYGMCType type = (RYGMCType)(typeSerial >> 16); unsigned int ordinal = ordinalMix & 0xFFFF, serial = typeSerial & 0xFFFF; unsigned long long pid = [self validParamIDForOrdinal:ordinal index:paramIndex serial:serial type:type]; if (!pid) continue;
        RYGMCParam *param = [RYGMCParam new]; param.paramID = pid; param.ordinal = ordinal; param.configNumber = configNumber; param.paramIndex = paramIndex; param.type = type; param.runtimeBacked = YES; NSDictionary *info = catalog[@(configNumber)]; NSDictionary *mapped = [info[@"params"] isKindOfClass:NSDictionary.class] ? info[@"params"] : nil; param.name = mapped[@(paramIndex)]; NSMutableDictionary *bucket = paramsByConfig[@(configNumber)]; if (!bucket) { bucket = [NSMutableDictionary dictionary]; paramsByConfig[@(configNumber)] = bucket; } bucket[@(paramIndex)] = param;
    }
    [catalog enumerateKeysAndObjectsUsingBlock:^(NSNumber *cfg, NSDictionary *info, BOOL *stop) { (void)stop; NSMutableDictionary *bucket = paramsByConfig[cfg]; if (!bucket) { bucket = [NSMutableDictionary dictionary]; paramsByConfig[cfg] = bucket; } NSDictionary *mapped = [info[@"params"] isKindOfClass:NSDictionary.class] ? info[@"params"] : @{}; [mapped enumerateKeysAndObjectsUsingBlock:^(NSNumber *idx, NSString *name, BOOL *innerStop) { (void)innerStop; RYGMCParam *p = bucket[idx]; if (p) { if (name.length) p.name = name; } else { p = [RYGMCParam new]; p.configNumber = cfg.unsignedIntValue; p.paramIndex = idx.unsignedIntValue; p.type = RYGMCTypeUnknown; p.runtimeBacked = NO; p.name = name; bucket[idx] = p; } }]; }];
    NSMutableArray *configs = [NSMutableArray array]; [paramsByConfig enumerateKeysAndObjectsUsingBlock:^(NSNumber *cfg, NSDictionary *bucket, BOOL *stop) { (void)stop; RYGMCConfig *c = [RYGMCConfig new]; c.number = cfg.unsignedIntValue; NSDictionary *info = catalog[cfg]; c.name = [info[@"name"] isKindOfClass:NSString.class] ? info[@"name"] : nil; c.params = [bucket.allValues sortedArrayUsingComparator:^NSComparisonResult(RYGMCParam *a, RYGMCParam *b) { return a.paramIndex == b.paramIndex ? NSOrderedSame : (a.paramIndex < b.paramIndex ? NSOrderedAscending : NSOrderedDescending); }]; [configs addObject:c]; }];
    [configs sortUsingComparator:^NSComparisonResult(RYGMCConfig *a, RYGMCConfig *b) { BOOL an = a.name.length, bn = b.name.length; if (an != bn) return an ? NSOrderedAscending : NSOrderedDescending; if (an) { NSComparisonResult n = [a.name localizedCaseInsensitiveCompare:b.name]; if (n != NSOrderedSame) return n; } return a.number == b.number ? NSOrderedSame : (a.number < b.number ? NSOrderedAscending : NSOrderedDescending); }]; _configs = configs.copy; _namedConfigCount = catalog.count; _ready = YES;
}
- (void)reloadFromRuntime { _ready = NO; _configs = nil; _namedConfigCount = 0; [self prepare]; }
- (NSArray<RYGMCConfig *> *)allConfigs { [self prepare]; return _configs ?: @[]; }

static NSString *rygNormalize(NSString *s) { if (!s.length) return @""; NSString *lower = s.lowercaseString; NSMutableString *out = [NSMutableString stringWithCapacity:lower.length]; for (NSUInteger i = 0; i < lower.length; i++) { unichar c = [lower characterAtIndex:i]; if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [out appendFormat:@"%C", c]; } return out.copy; }
- (NSArray<RYGMCConfig *> *)configsMatching:(NSString *)query onlyOverridden:(BOOL)onlyOverridden {
    [self prepare]; NSString *n = rygNormalize(query); NSString *trim = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""; unsigned long long numeric = trim.length ? strtoull(trim.UTF8String, NULL, 10) : 0; NSMutableArray *out = [NSMutableArray array];
    for (RYGMCConfig *c in _configs) { if (onlyOverridden) { BOOL any = NO; for (RYGMCParam *p in c.params) if ([self overrideStateFor:p] == RYGMCOverrideSet) { any = YES; break; } if (!any) continue; } BOOL hit = !n.length || [rygNormalize(c.name) containsString:n] || (numeric && c.number == numeric); if (!hit) for (RYGMCParam *p in c.params) if ([rygNormalize(p.name) containsString:n] || (numeric && p.paramIndex == numeric) || (numeric && p.paramID == numeric)) { hit = YES; break; } if (hit) [out addObject:c]; }
    return out.copy;
}
- (NSArray<NSString *> *)paramsMatching:(NSString *)query inConfig:(RYGMCConfig *)config { NSString *n = rygNormalize(query); if (!n.length) return @[]; NSMutableArray *out = [NSMutableArray array]; for (RYGMCParam *p in config.params) if (p.name.length && [rygNormalize(p.name) containsString:n]) [out addObject:p.name]; return out.copy; }

#pragma mark - Live values
- (unsigned long long)bestParamIDFor:(RYGMCParam *)param { if (!param.runtimeBacked || !param.paramID) return 0; pthread_mutex_lock(&gLock); NSNumber *real = gRealPidByOrdIdx[@(((unsigned long long)param.ordinal << 20) | param.paramIndex)]; pthread_mutex_unlock(&gLock); return real ? real.unsignedLongLongValue : param.paramID; }
- (id)managerForPid:(unsigned long long)pid { if (!pid) return nil; unsigned long long unit = (pid >> 48) & 0xF0; pthread_mutex_lock(&gLock); id m = gManagersByUnit[@(unit)]; pthread_mutex_unlock(&gLock); return m ?: gManager; }
- (id)liveValueFor:(RYGMCParam *)param {
    if (!param.runtimeBacked || !param.paramID || param.type == RYGMCTypeUnknown) return nil; unsigned long long pid = [self bestParamIDFor:param]; id m = [self managerForPid:pid]; if (!m) return nil;
    switch (param.type) { case RYGMCTypeBool: if ([m respondsToSelector:@selector(getBool:)]) return @(((BOOL (*)(id, SEL, unsigned long long))objc_msgSend)(m, @selector(getBool:), pid)); break; case RYGMCTypeInt: if ([m respondsToSelector:@selector(getInt64:)]) return @(((long long (*)(id, SEL, unsigned long long))objc_msgSend)(m, @selector(getInt64:), pid)); break; case RYGMCTypeDouble: if ([m respondsToSelector:@selector(getDouble:)]) return @(((double (*)(id, SEL, unsigned long long))objc_msgSend)(m, @selector(getDouble:), pid)); break; case RYGMCTypeString: if ([m respondsToSelector:@selector(getString:)]) { id v = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(m, @selector(getString:), pid); return [v isKindOfClass:NSString.class] ? v : nil; } break; default: break; }
    return nil;
}

#pragma mark - Native StartupConfigs overrides
static BOOL rygMethodIsVoidQObject(Method m) { if (!m || method_getNumberOfArguments(m) != 4) return NO; char t[64] = {0}; method_getReturnType(m,t,sizeof(t)); if (*t != 'v') return NO; method_getArgumentType(m,2,t,sizeof(t)); const char *a = t; while (a && strchr("rnNoORV",*a)) a++; if (!a || (*a != 'Q' && *a != 'q')) return NO; memset(t,0,sizeof(t)); method_getArgumentType(m,3,t,sizeof(t)); a = t; while (a && strchr("rnNoORV",*a)) a++; return a && *a == '@'; }
static BOOL rygMethodIsVoidQ(Method m) { if (!m || method_getNumberOfArguments(m) != 3) return NO; char t[64] = {0}; method_getReturnType(m,t,sizeof(t)); if (*t != 'v') return NO; method_getArgumentType(m,2,t,sizeof(t)); const char *a = t; while (a && strchr("rnNoORV",*a)) a++; return a && (*a == 'Q' || *a == 'q'); }
- (id)startupConfigs { Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs"); SEL sel = NSSelectorFromString(@"getInstance"); Method m = cls ? class_getClassMethod(cls,sel) : NULL; if (!m || method_getNumberOfArguments(m) != 2) return nil; char t[16] = {0}; method_getReturnType(m,t,sizeof(t)); if (*t != '@') return nil; return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel); }
- (BOOL)writeNativeForPid:(unsigned long long)pid value:(id)value { if (!pid || !value) return NO; id startup = [self startupConfigs]; SEL sel = NSSelectorFromString(@"setOverrideForParam:andValue:"); Method m = startup ? class_getInstanceMethod([startup class],sel) : NULL; if (!rygMethodIsVoidQObject(m)) return NO; ((void (*)(id, SEL, unsigned long long, id))objc_msgSend)(startup,sel,pid,value); return YES; }
- (BOOL)writeNativeBothUnitsForPid:(unsigned long long)pid value:(id)value { BOOL a = [self writeNativeForPid:rygVariantPid(pid,0x40) value:value]; BOOL b = [self writeNativeForPid:rygVariantPid(pid,0x80) value:value]; return a || b; }
- (BOOL)removeNativeForPid:(unsigned long long)pid { id startup = [self startupConfigs]; SEL sel = NSSelectorFromString(@"removeOverrideForParam:"); Method m = startup ? class_getInstanceMethod([startup class],sel) : NULL; if (!rygMethodIsVoidQ(m)) return NO; ((void (*)(id, SEL, unsigned long long))objc_msgSend)(startup,sel,pid); return YES; }
- (void)removeNativeBothUnitsForPid:(unsigned long long)pid { [self removeNativeForPid:rygVariantPid(pid,0x40)]; [self removeNativeForPid:rygVariantPid(pid,0x80)]; }

- (RYGMCOverrideState)overrideStateFor:(RYGMCParam *)param { return (param.runtimeBacked && param.paramID && _overrides[@(rygCanonicalPid(param.paramID))]) ? RYGMCOverrideSet : RYGMCOverrideNone; }
- (id)overrideValueFor:(RYGMCParam *)param { return (param.runtimeBacked && param.paramID) ? _overrides[@(rygCanonicalPid(param.paramID))] : nil; }
- (BOOL)setOverride:(id)value for:(RYGMCParam *)param {
    if (!param.runtimeBacked || !param.paramID || !RYGMCTypeIsRuntimeValue(param.type)) return NO; BOOL valid = param.type == RYGMCTypeString ? [value isKindOfClass:NSString.class] : [value isKindOfClass:NSNumber.class]; if (!valid) return NO;
    unsigned long long pid = rygCanonicalPid(param.paramID);
    // Getter interception is the authoritative runtime path. Persist and arm it
    // even when StartupConfigs is not instantiated yet; native table sync is a
    // best-effort mirror, not a prerequisite for an override to exist.
    rygActivateOverride(pid,value); _overrides[@(pid)] = value; [self saveOverrides];
    (void)[self writeNativeBothUnitsForPid:pid value:value];
    return YES;
}
- (void)clearOverrideFor:(RYGMCParam *)param { if (!param.runtimeBacked || !param.paramID) return; unsigned long long pid = rygCanonicalPid(param.paramID); rygDeactivateOverride(pid); [_overrides removeObjectForKey:@(pid)]; [self saveOverrides]; [self removeNativeBothUnitsForPid:pid]; }
- (void)resetOverridesForConfig:(RYGMCConfig *)config { for (RYGMCParam *p in config.params) if ([self overrideStateFor:p] == RYGMCOverrideSet) [self clearOverrideFor:p]; }
- (NSUInteger)overrideCount { return _overrides.count; }
- (void)resetAllOverrides { for (NSNumber *k in _overrides.allKeys.copy) { rygDeactivateOverride(k.unsignedLongLongValue); [self removeNativeBothUnitsForPid:k.unsignedLongLongValue]; } [_overrides removeAllObjects]; [self saveOverrides]; }
- (void)reapplyOverridesToNativeTable { for (NSNumber *k in _overrides.copy) { id v = _overrides[k]; rygActivateOverride(k.unsignedLongLongValue,v); (void)[self writeNativeBothUnitsForPid:k.unsignedLongLongValue value:v]; } }

#pragma mark - Seen, notes, persistence
- (NSString *)callSiteFor:(RYGMCParam *)param { if (!param.runtimeBacked || !param.paramID) return nil; unsigned long long best = [self bestParamIDFor:param]; pthread_mutex_lock(&gLock); NSValue *v = gCallSites[@(best)] ?: gCallSites[@(rygVariantPid(param.paramID,0x40))] ?: gCallSites[@(rygVariantPid(param.paramID,0x80))]; pthread_mutex_unlock(&gLock); if (!v) return nil; Dl_info info = {0}; if (dladdr(v.pointerValue,&info) && info.dli_sname) return [NSString stringWithUTF8String:info.dli_sname]; return @"Instagram runtime"; }
- (NSNumber *)noteKeyForParam:(RYGMCParam *)param { return param.runtimeBacked && param.paramID ? @(param.paramID) : @(((unsigned long long)param.configNumber << 32) | param.paramIndex); }
- (NSString *)noteFor:(RYGMCParam *)param { return _notes[[self noteKeyForParam:param]]; }
- (void)setNote:(NSString *)note for:(RYGMCParam *)param { NSNumber *k = [self noteKeyForParam:param]; if (note.length) _notes[k] = note; else [_notes removeObjectForKey:k]; [self saveNotes]; }
- (NSString *)storePathFor:(NSString *)name { NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"RyukGram"]; [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]; return [d stringByAppendingPathComponent:name]; }
- (NSMutableDictionary *)loadOverrides { NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:[self storePathFor:@"mc_overrides.plist"]]; NSMutableDictionary *out = [NSMutableDictionary dictionary]; for (id raw in disk) { if (![raw isKindOfClass:NSString.class]) continue; unsigned long long pid = strtoull([raw UTF8String],NULL,10); RYGMCType type = (RYGMCType)((pid >> 48) & 0x0F); id v = disk[raw]; BOOL valid = type == RYGMCTypeString ? [v isKindOfClass:NSString.class] : [v isKindOfClass:NSNumber.class]; if (pid && RYGMCTypeIsRuntimeValue(type) && valid) out[@(rygCanonicalPid(pid))] = v; } return out; }
- (void)syncOverridesJSON { NSError *error = nil; NSData *data = [self ryg_exportOverridesData:&error]; NSString *path = [self ryg_nativeOverridesJSONPath]; if (data.length && path.length) [data writeToFile:path options:NSDataWritingAtomic error:nil]; }
- (void)saveOverrides {
    NSMutableDictionary *disk = [NSMutableDictionary dictionary];
    for (NSNumber *k in _overrides) disk[k.stringValue] = _overrides[k];
    [disk writeToFile:[self storePathFor:@"mc_overrides.plist"] atomically:YES];
    // A switch must only update the native PID + tiny plist synchronously.
    // Canonical JSON is a backup/export concern and is coalesced off-main.
    static atomic_uint_fast64_t generation = 0;
    uint64_t mine = atomic_fetch_add_explicit(&generation, 1, memory_order_relaxed) + 1;
    RYGMobileConfig *target = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (atomic_load_explicit(&generation, memory_order_relaxed) != mine) return;
        [target syncOverridesJSON];
    });
}
- (NSMutableDictionary *)loadNotes { NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:[self storePathFor:@"mc_notes.plist"]]; NSMutableDictionary *out = [NSMutableDictionary dictionary]; for (id k in disk) { id v = disk[k]; if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) { unsigned long long n = strtoull([k UTF8String],NULL,10); if (n) out[@(n)] = v; } } return out; }
- (void)saveNotes { NSMutableDictionary *disk = [NSMutableDictionary dictionary]; for (NSNumber *k in _notes) disk[k.stringValue] = _notes[k]; [disk writeToFile:[self storePathFor:@"mc_notes.plist"] atomically:YES]; }
- (BOOL)consumeCrashLoopFlag { return NO; }
- (void)markLaunchStable { }
@end

#pragma mark - Hook installation
static const char *rygMCUnqualifiedType(const char *type) { while (type && strchr("rnNoORV",*type)) type++; return type; }
static BOOL rygMCTypeMatches(const char *raw, char expected) { const char *t = rygMCUnqualifiedType(raw); if (!t || !*t) return NO; switch (expected) { case 'P': return *t == 'Q' || *t == 'q' || (*t == '{' && (strstr(t,"=Q}") || strstr(t,"=q}"))); case 'B': return *t == 'B' || *t == 'c' || *t == 'C'; case 'Q': return *t == 'q' || *t == 'Q'; case 'D': return *t == 'd'; case '@': return *t == '@'; default: return NO; } }
static BOOL rygMCMethodMatches(Method m, char ret, const char *args) { if (!m || !args || method_getNumberOfArguments(m) != strlen(args) + 2) return NO; char e[128] = {0}; method_getReturnType(m,e,sizeof(e)); if (!rygMCTypeMatches(e,ret)) return NO; for (unsigned int i = 0; args[i]; i++) { memset(e,0,sizeof(e)); method_getArgumentType(m,i+2,e,sizeof(e)); if (!rygMCTypeMatches(e,args[i])) return NO; } return YES; }
static BOOL rygHookMC(Class cls, NSString *name, IMP replacement, IMP *original, char ret, const char *args) { if (!cls || !replacement || !original || *original) return original && *original; SEL selector = NSSelectorFromString(name); Method method = class_getInstanceMethod(cls,selector); if (!rygMCMethodMatches(method,ret,args)) return NO; MSHookMessageEx(cls,selector,replacement,original); return *original != NULL; }
static NSUInteger rygMCScore(Class cls) { NSUInteger score = 0; for (NSString *name in @[@"getBool:",@"getInt64:",@"getDouble:",@"getString:"]) if (class_getInstanceMethod(cls,NSSelectorFromString(name))) score++; return score; }
static void rygInstallMobileConfigHooks(void) {
    Class fb = NSClassFromString(@"FBMobileConfigContextManager"), ig = NSClassFromString(@"IGMobileConfigContextManager"); Class cls = rygMCScore(fb) >= rygMCScore(ig) ? fb : ig; if (!cls) return;
    rygHookMC(cls,@"getBool:",(IMP)new_getBool,(IMP *)&orig_getBool,'B',"P"); rygHookMC(cls,@"getBool:withDefault:",(IMP)new_getBoolDef,(IMP *)&orig_getBoolDef,'B',"PB"); rygHookMC(cls,@"getBool:withOptions:",(IMP)new_getBoolOpts,(IMP *)&orig_getBoolOpts,'B',"P@"); rygHookMC(cls,@"getBool:withOptions:withDefault:",(IMP)new_getBoolOptsDef,(IMP *)&orig_getBoolOptsDef,'B',"P@B");
    rygHookMC(cls,@"getInt64:",(IMP)new_getInt,(IMP *)&orig_getInt,'Q',"P"); rygHookMC(cls,@"getInt64:withDefault:",(IMP)new_getIntDef,(IMP *)&orig_getIntDef,'Q',"PQ"); rygHookMC(cls,@"getInt64:withOptions:",(IMP)new_getIntOpts,(IMP *)&orig_getIntOpts,'Q',"P@"); rygHookMC(cls,@"getInt64:withOptions:withDefault:",(IMP)new_getIntOptsDef,(IMP *)&orig_getIntOptsDef,'Q',"P@Q");
    rygHookMC(cls,@"getDouble:",(IMP)new_getDouble,(IMP *)&orig_getDouble,'D',"P"); rygHookMC(cls,@"getDouble:withDefault:",(IMP)new_getDoubleDef,(IMP *)&orig_getDoubleDef,'D',"PD"); rygHookMC(cls,@"getDouble:withOptions:",(IMP)new_getDoubleOpts,(IMP *)&orig_getDoubleOpts,'D',"P@"); rygHookMC(cls,@"getDouble:withOptions:withDefault:",(IMP)new_getDoubleOptsDef,(IMP *)&orig_getDoubleOptsDef,'D',"P@D");
    rygHookMC(cls,@"getString:",(IMP)new_getString,(IMP *)&orig_getString,'@',"P"); rygHookMC(cls,@"getString:withDefault:",(IMP)new_getStringDef,(IMP *)&orig_getStringDef,'@',"P@"); rygHookMC(cls,@"getString:withOptions:",(IMP)new_getStringOpts,(IMP *)&orig_getStringOpts,'@',"P@"); rygHookMC(cls,@"getString:withOptions:withDefault:",(IMP)new_getStringOptsDef,(IMP *)&orig_getStringOptsDef,'@',"P@@");
}
static BOOL gInstallScheduled;
static void rygScheduleInstall(void) { @synchronized(RYGMobileConfig.class) { if (gInstallScheduled) return; gInstallScheduled = YES; } dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.1 * NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ @synchronized(RYGMobileConfig.class) { gInstallScheduled = NO; } rygInstallMobileConfigHooks(); }); }
static void rygImageDidLoad(const struct mach_header *header, intptr_t slide) { (void)header; (void)slide; rygScheduleInstall(); }
%ctor { if (![RYGUtils getBoolPref:@"ryg_metaconfig_enabled"]) return; (void)RYGMobileConfig.shared; rygInstallMobileConfigHooks(); _dyld_register_func_for_add_image(rygImageDidLoad); }
