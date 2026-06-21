// SCICRuntimePatchResolver.m
#import "SCICRuntimePatchResolver.h"
#import "SCICSymbolStub.h"
#import "../../Features/Dogfooding/SCISymbolBrowserEngine.h"
#import "../../Utils.h"
#import "../../../modules/fishhook/fishhook.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <os/log.h>
#import <unistd.h>
#import <stdatomic.h>
#import <string.h>

#define RLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] PatchResolver " fmt, ##__VA_ARGS__)

static NSString *const kSCICRuntimePatchPlansKey = @"sci_runtime_patch_plans";
static NSString *const kSCICRuntimeDataPatchSnapshotsKey = @"sci_runtime_data_patch_snapshots";

static NSString *SCICStrategyString(SCICRuntimePatchStrategy s) {
    switch (s) {
        case SCICRuntimePatchStrategyObjCBool: return @"objc.bool";
        case SCICRuntimePatchStrategyFunctionBool: return @"function.bool";
        case SCICRuntimePatchStrategyFunctionTyped: return @"function.typed";
        case SCICRuntimePatchStrategyFunctionObserve: return @"function.observe";
        case SCICRuntimePatchStrategyDataReaderBool: return @"data.reader.bool";
        case SCICRuntimePatchStrategyDataRebindString: return @"data.rebind.string";
        case SCICRuntimePatchStrategyDataPatchBytes: return @"data.patch.bytes";
        default: return @"none";
    }
}

static SCICRuntimePatchStrategy SCICStrategyFromString(NSString *s) {
    if ([s isEqualToString:@"objc.bool"]) return SCICRuntimePatchStrategyObjCBool;
    if ([s isEqualToString:@"function.bool"]) return SCICRuntimePatchStrategyFunctionBool;
    if ([s isEqualToString:@"function.typed"]) return SCICRuntimePatchStrategyFunctionTyped;
    if ([s isEqualToString:@"function.observe"]) return SCICRuntimePatchStrategyFunctionObserve;
    if ([s isEqualToString:@"data.reader.bool"]) return SCICRuntimePatchStrategyDataReaderBool;
    if ([s isEqualToString:@"data.rebind.string"]) return SCICRuntimePatchStrategyDataRebindString;
    if ([s isEqualToString:@"data.patch.bytes"]) return SCICRuntimePatchStrategyDataPatchBytes;
    return SCICRuntimePatchStrategyNone;
}

static NSString *SCICObjCKey(NSString *className, NSString *selectorName, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@%@#%@", classMethod ? @"+" : @"", className ?: @"", selectorName ?: @""];
}

static NSDictionary *SCICDictPref(NSString *key) {
    NSDictionary *d = [SCIUtils getDictPref:key];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static void *SCICResolveSymbolAddress(NSString *symbol) {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return NULL;
    void *p = dlsym(RTLD_DEFAULT, symbol.UTF8String);
    if (!p) {
        NSString *under = [@"_" stringByAppendingString:symbol];
        p = dlsym(RTLD_DEFAULT, under.UTF8String);
    }
    return p;
}

static BOOL SCICSectionIsExecutable(NSString *section) {
    NSString *s = section ?: @"";
    return [s containsString:@"__TEXT,__text"] || [s hasSuffix:@",__text"];
}

static BOOL SCICSectionIsPatchableData(NSString *section) {
    if (SCICSectionIsExecutable(section)) return NO;
    NSString *s = section ?: @"";
    return [s containsString:@"__DATA"] || [s containsString:@"__DATA_CONST"] || [s containsString:@"__TEXT,__const"] || [s containsString:@"__TEXT,__cstring"] || [s containsString:@"__TEXT,__objc_methname"];
}

static BOOL SCICLooksStringDataSymbol(NSString *name, NSString *section) {
    NSString *n = name ?: @"";
    NSString *s = section ?: @"";
    if ([s containsString:@"__cstring"] || [s containsString:@"__objc_methname"] || [s containsString:@"__cfstring"]) return YES;
    return [n containsString:@"String"] || [n containsString:@"Name"] || [n containsString:@"Key"] || [n hasPrefix:@"k"] || [n hasSuffix:@"Key"];
}

static BOOL SCICConsumerIsBoolReader(NSArray<SCIXrefHit *> *hits, NSString **consumerOut, NSString **callerOut) {
    for (SCIXrefHit *h in hits ?: @[]) {
        NSString *c = h.calleeSymbol ?: @"";
        if ([c isEqualToString:@"IGMobileConfigBooleanValueForInternalUse"] || [c containsString:@"MobileConfigBoolean"] || [c containsString:@"EasyGatingGetBoolean"]) {
            if (consumerOut) *consumerOut = c;
            if (callerOut) *callerOut = h.callerSymbol;
            return YES;
        }
    }
    return NO;
}

@implementation SCICRuntimePatchPlan

- (id)copyWithZone:(NSZone *)zone {
    SCICRuntimePatchPlan *p = [[[self class] allocWithZone:zone] init];
    p.symbol = self.symbol; p.image = self.image; p.section = self.section; p.kind = self.kind; p.abi = self.abi;
    p.runtimeAddress = self.runtimeAddress; p.symtabAddress = self.symtabAddress; p.dataSize = self.dataSize;
    p.function = self.function; p.data = self.data; p.swiftLike = self.swiftLike; p.hasBindPointer = self.hasBindPointer;
    p.objcClassName = self.objcClassName; p.objcSelectorName = self.objcSelectorName; p.objcClassMethod = self.objcClassMethod;
    p.consumerSymbol = self.consumerSymbol; p.callerSymbol = self.callerSymbol; p.strategy = self.strategy;
    p.strategyName = self.strategyName; p.shortStrategyName = self.shortStrategyName; p.reason = self.reason; p.returnKind = self.returnKind;
    p.inlineToggleSafe = self.inlineToggleSafe; p.safeAtLaunch = self.safeAtLaunch; p.requiresPromptValue = self.requiresPromptValue; p.requiresConfirmedConsumer = self.requiresConfirmedConsumer;
    return p;
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.symbol) d[@"symbol"] = self.symbol;
    if (self.image) d[@"image"] = self.image;
    if (self.section) d[@"section"] = self.section;
    if (self.kind) d[@"kind"] = self.kind;
    if (self.abi) d[@"abi"] = self.abi;
    if (self.objcClassName) d[@"objcClassName"] = self.objcClassName;
    if (self.objcSelectorName) d[@"objcSelectorName"] = self.objcSelectorName;
    if (self.consumerSymbol) d[@"consumerSymbol"] = self.consumerSymbol;
    if (self.callerSymbol) d[@"callerSymbol"] = self.callerSymbol;
    if (self.returnKind) d[@"returnKind"] = self.returnKind;
    d[@"strategy"] = SCICStrategyString(self.strategy);
    d[@"runtimeAddress"] = @(self.runtimeAddress);
    d[@"symtabAddress"] = @(self.symtabAddress);
    d[@"dataSize"] = @(self.dataSize);
    d[@"function"] = @(self.function);
    d[@"data"] = @(self.data);
    d[@"swiftLike"] = @(self.swiftLike);
    d[@"hasBindPointer"] = @(self.hasBindPointer);
    d[@"objcClassMethod"] = @(self.objcClassMethod);
    d[@"inlineToggleSafe"] = @(self.inlineToggleSafe);
    d[@"safeAtLaunch"] = @(self.safeAtLaunch);
    d[@"requiresPromptValue"] = @(self.requiresPromptValue);
    d[@"requiresConfirmedConsumer"] = @(self.requiresConfirmedConsumer);
    return d.copy;
}

+ (instancetype)planWithDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *symbol = [dict[@"symbol"] isKindOfClass:NSString.class] ? dict[@"symbol"] : nil;
    if (!symbol.length) return nil;
    SCICRuntimePatchPlan *p = [SCICRuntimePatchPlan new];
    p.symbol = symbol;
    p.image = [dict[@"image"] isKindOfClass:NSString.class] ? dict[@"image"] : nil;
    p.section = [dict[@"section"] isKindOfClass:NSString.class] ? dict[@"section"] : nil;
    p.kind = [dict[@"kind"] isKindOfClass:NSString.class] ? dict[@"kind"] : nil;
    p.abi = [dict[@"abi"] isKindOfClass:NSString.class] ? dict[@"abi"] : nil;
    p.objcClassName = [dict[@"objcClassName"] isKindOfClass:NSString.class] ? dict[@"objcClassName"] : nil;
    p.objcSelectorName = [dict[@"objcSelectorName"] isKindOfClass:NSString.class] ? dict[@"objcSelectorName"] : nil;
    p.consumerSymbol = [dict[@"consumerSymbol"] isKindOfClass:NSString.class] ? dict[@"consumerSymbol"] : nil;
    p.callerSymbol = [dict[@"callerSymbol"] isKindOfClass:NSString.class] ? dict[@"callerSymbol"] : nil;
    p.returnKind = [dict[@"returnKind"] isKindOfClass:NSString.class] ? dict[@"returnKind"] : nil;
    p.strategy = SCICStrategyFromString([dict[@"strategy"] isKindOfClass:NSString.class] ? dict[@"strategy"] : nil);
    p.runtimeAddress = [dict[@"runtimeAddress"] respondsToSelector:@selector(longLongValue)] ? (uintptr_t)[dict[@"runtimeAddress"] longLongValue] : 0;
    p.symtabAddress = [dict[@"symtabAddress"] respondsToSelector:@selector(longLongValue)] ? (uintptr_t)[dict[@"symtabAddress"] longLongValue] : 0;
    p.dataSize = [dict[@"dataSize"] respondsToSelector:@selector(longLongValue)] ? (NSUInteger)[dict[@"dataSize"] longLongValue] : 0;
    p.function = [dict[@"function"] boolValue]; p.data = [dict[@"data"] boolValue]; p.swiftLike = [dict[@"swiftLike"] boolValue];
    p.hasBindPointer = [dict[@"hasBindPointer"] boolValue]; p.objcClassMethod = [dict[@"objcClassMethod"] boolValue];
    p.inlineToggleSafe = [dict[@"inlineToggleSafe"] boolValue]; p.safeAtLaunch = [dict[@"safeAtLaunch"] boolValue];
    p.requiresPromptValue = [dict[@"requiresPromptValue"] boolValue]; p.requiresConfirmedConsumer = [dict[@"requiresConfirmedConsumer"] boolValue];
    p.strategyName = [self displayNameForStrategy:p.strategy returnKind:p.returnKind];
    p.shortStrategyName = [self shortNameForStrategy:p.strategy returnKind:p.returnKind];
    p.reason = [dict[@"reason"] isKindOfClass:NSString.class] ? dict[@"reason"] : @"persisted plan";
    return p;
}

+ (NSString *)displayNameForStrategy:(SCICRuntimePatchStrategy)s returnKind:(NSString *)kind {
    switch (s) {
        case SCICRuntimePatchStrategyObjCBool: return @"ObjC IMP swizzle (MSHookMessageEx)";
        case SCICRuntimePatchStrategyFunctionBool: return @"fishhook BOOL hardstub";
        case SCICRuntimePatchStrategyFunctionTyped: return [NSString stringWithFormat:@"fishhook typed force (%@)", kind.length ? kind : @"typed"];
        case SCICRuntimePatchStrategyFunctionObserve: return @"validated observe hook";
        case SCICRuntimePatchStrategyDataReaderBool: return @"MobileConfig descriptor reader-filter";
        case SCICRuntimePatchStrategyDataRebindString: return @"DATA imported pointer rebind (NSString compatible)";
        case SCICRuntimePatchStrategyDataPatchBytes: return @"DATA memory patch (vm_protect snapshot/revert)";
        default: return @"none (sideload-safe patch unavailable)";
    }
}

+ (NSString *)shortNameForStrategy:(SCICRuntimePatchStrategy)s returnKind:(NSString *)kind {
    switch (s) {
        case SCICRuntimePatchStrategyObjCBool: return @"ObjC live swizzle";
        case SCICRuntimePatchStrategyFunctionBool: return @"BOOL fishhook";
        case SCICRuntimePatchStrategyFunctionTyped: return [NSString stringWithFormat:@"%@ fishhook", kind.length ? kind : @"typed"];
        case SCICRuntimePatchStrategyFunctionObserve: return @"observe hook";
        case SCICRuntimePatchStrategyDataReaderBool: return @"DATA → MC reader";
        case SCICRuntimePatchStrategyDataRebindString: return @"DATA pointer rebind";
        case SCICRuntimePatchStrategyDataPatchBytes: return @"DATA bytes patch";
        default: return @"resolve only";
    }
}

@end

#pragma mark - DATA pointer rebind

typedef struct {
    char symbol[192];
    void *original;
    void *replacement;
    CFTypeRef retainedObject;
    atomic_int installed;
} SCICDataRebindSlot;

#define MAX_DATA_REBINDS 32
static SCICDataRebindSlot g_dataRebinds[MAX_DATA_REBINDS];
static int g_dataRebindCount = 0;

static SCICDataRebindSlot *SCICDataRebindSlotFor(NSString *symbol, BOOL create) {
    if (!symbol.length) return NULL;
    const char *name = symbol.UTF8String;
    for (int i = 0; i < g_dataRebindCount; i++) if (strcmp(g_dataRebinds[i].symbol, name) == 0) return &g_dataRebinds[i];
    if (!create || g_dataRebindCount >= MAX_DATA_REBINDS) return NULL;
    SCICDataRebindSlot *slot = &g_dataRebinds[g_dataRebindCount++];
    memset(slot, 0, sizeof(*slot));
    strncpy(slot->symbol, name, sizeof(slot->symbol) - 1);
    return slot;
}

static BOOL SCICInstallDataRebind(NSString *symbol, id replacementObject) {
    if (!symbol.length || !replacementObject) return NO;
    SCICDataRebindSlot *slot = SCICDataRebindSlotFor(symbol, YES);
    if (!slot) return NO;
    if (slot->retainedObject) { CFRelease(slot->retainedObject); slot->retainedObject = NULL; }
    slot->retainedObject = CFBridgingRetain(replacementObject);
    slot->replacement = (void *)slot->retainedObject;
    struct rebinding rb;
    memset(&rb, 0, sizeof(rb));
    rb.name = slot->symbol;
    rb.replacement = slot->replacement;
    rb.replaced = &slot->original;
    int rc = rebind_symbols(&rb, 1);
    atomic_store(&slot->installed, rc == 0 ? 1 : 0);
    RLOG("DATA rebind %{public}s rc=%d original=%p replacement=%p", slot->symbol, rc, slot->original, slot->replacement);
    return rc == 0;
}

static BOOL SCICRevertDataRebind(NSString *symbol) {
    SCICDataRebindSlot *slot = SCICDataRebindSlotFor(symbol, NO);
    if (!slot || !slot->original) return NO;
    struct rebinding rb;
    memset(&rb, 0, sizeof(rb));
    rb.name = slot->symbol;
    rb.replacement = slot->original;
    rb.replaced = NULL;
    int rc = rebind_symbols(&rb, 1);
    if (slot->retainedObject) { CFRelease(slot->retainedObject); slot->retainedObject = NULL; }
    slot->replacement = NULL;
    atomic_store(&slot->installed, 0);
    RLOG("DATA rebind revert %{public}s rc=%d", slot->symbol, rc);
    return rc == 0;
}

#pragma mark - DATA byte patch

static BOOL SCICPatchMemory(uintptr_t address, NSData *bytes, NSData **snapshotOut, NSError **error) {
    if (!address || !bytes.length || bytes.length > 64) {
        if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:10 userInfo:@{NSLocalizedDescriptionKey: @"invalid DATA patch address/size"}];
        return NO;
    }
    if (snapshotOut) *snapshotOut = [NSData dataWithBytes:(const void *)address length:bytes.length];
    vm_size_t pageSize = (vm_size_t)getpagesize();
    vm_address_t pageStart = (vm_address_t)(address & ~((uintptr_t)pageSize - 1));
    vm_address_t pageEnd = (vm_address_t)((address + bytes.length + pageSize - 1) & ~((uintptr_t)pageSize - 1));
    vm_size_t span = (vm_size_t)(pageEnd - pageStart);
    kern_return_t kr = vm_protect(mach_task_self(), pageStart, span, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) kr = vm_protect(mach_task_self(), pageStart, span, false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:11 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"vm_protect failed: %d", kr]}];
        return NO;
    }
    memcpy((void *)address, bytes.bytes, bytes.length);
    // DATA patch only: no instruction-cache flush here. Some Theos/iOS SDK
    // toolchains lower that builtin to an unresolved arm64 runtime symbol, and
    // cache invalidation is only required for executable-code patching, which this
    // resolver intentionally does not perform.
    vm_protect(mach_task_self(), pageStart, span, false, VM_PROT_READ);
    return YES;
}

@implementation SCICRuntimePatchResolver

+ (NSString *)persistedPlansKey { return kSCICRuntimePatchPlansKey; }
+ (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)persistedPatchPlans { return (NSDictionary *)SCICDictPref(kSCICRuntimePatchPlansKey); }
+ (NSDictionary<NSString *, id> *)persistedPatchForSymbol:(NSString *)symbol { id v = [self persistedPatchPlans][symbol ?: @""]; return [v isKindOfClass:NSDictionary.class] ? v : nil; }

+ (void)savePatchPlan:(SCICRuntimePatchPlan *)plan extra:(NSDictionary<NSString *, id> *)extra {
    if (!plan.symbol.length || plan.strategy == SCICRuntimePatchStrategyNone) return;
    NSMutableDictionary *all = [[self persistedPatchPlans] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *d = [[plan dictionaryRepresentation] mutableCopy];
    if (plan.reason) d[@"reason"] = plan.reason;
    if (extra) [d addEntriesFromDictionary:extra];
    all[plan.symbol] = d.copy;
    [SCIUtils setPref:all.copy forKey:kSCICRuntimePatchPlansKey];
}

+ (void)forgetPatchPlanForSymbol:(NSString *)symbol {
    if (!symbol.length) return;
    NSMutableDictionary *all = [[self persistedPatchPlans] mutableCopy] ?: [NSMutableDictionary dictionary];
    [all removeObjectForKey:symbol];
    [SCIUtils setPref:all.copy forKey:kSCICRuntimePatchPlansKey];
    NSMutableDictionary *snaps = [SCICDictPref(kSCICRuntimeDataPatchSnapshotsKey) mutableCopy] ?: [NSMutableDictionary dictionary];
    [snaps removeObjectForKey:symbol];
    [SCIUtils setPref:snaps.copy forKey:kSCICRuntimeDataPatchSnapshotsKey];
}

+ (SCICRuntimePatchPlan *)resolvePlanForEntryInfo:(NSDictionary<NSString *, id> *)entryInfo xrefHits:(NSArray<SCIXrefHit *> *)xrefHits {
    SCICRuntimePatchPlan *p = [SCICRuntimePatchPlan new];
    p.symbol = [entryInfo[@"symbol"] isKindOfClass:NSString.class] ? entryInfo[@"symbol"] : @"";
    p.image = [entryInfo[@"image"] isKindOfClass:NSString.class] ? entryInfo[@"image"] : nil;
    p.section = [entryInfo[@"section"] isKindOfClass:NSString.class] ? entryInfo[@"section"] : nil;
    p.kind = [entryInfo[@"kind"] isKindOfClass:NSString.class] ? entryInfo[@"kind"] : nil;
    p.abi = [entryInfo[@"abi"] isKindOfClass:NSString.class] ? entryInfo[@"abi"] : nil;
    p.function = [entryInfo[@"function"] boolValue];
    p.data = [entryInfo[@"data"] boolValue];
    p.swiftLike = [entryInfo[@"swiftLike"] boolValue];
    p.hasBindPointer = [entryInfo[@"hasBindPointer"] boolValue];
    p.runtimeAddress = [entryInfo[@"runtimeAddress"] respondsToSelector:@selector(longLongValue)] ? (uintptr_t)[entryInfo[@"runtimeAddress"] longLongValue] : 0;
    p.symtabAddress = [entryInfo[@"symtabAddress"] respondsToSelector:@selector(longLongValue)] ? (uintptr_t)[entryInfo[@"symtabAddress"] longLongValue] : 0;
    p.dataSize = [entryInfo[@"dataSize"] respondsToSelector:@selector(longLongValue)] ? (NSUInteger)[entryInfo[@"dataSize"] longLongValue] : 0;
    p.objcClassName = [entryInfo[@"objcClassName"] isKindOfClass:NSString.class] ? entryInfo[@"objcClassName"] : nil;
    p.objcSelectorName = [entryInfo[@"objcSelectorName"] isKindOfClass:NSString.class] ? entryInfo[@"objcSelectorName"] : nil;
    p.objcClassMethod = [entryInfo[@"objcClassMethod"] boolValue];
    NSString *consumer = nil, *caller = nil;
    BOOL boolReader = SCICConsumerIsBoolReader(xrefHits, &consumer, &caller);
    p.consumerSymbol = consumer;
    p.callerSymbol = caller;
    p.returnKind = [SCICSymbolStub returnKindForSymbol:p.symbol];

    if (p.objcSelectorName.length && p.objcClassName.length) {
        p.strategy = SCICRuntimePatchStrategyObjCBool;
        p.reason = @"ObjC no-arg BOOL getter; backend is live MSHookMessageEx override cache.";
        p.inlineToggleSafe = YES; p.safeAtLaunch = YES;
    } else if (p.function && p.hasBindPointer && [SCICSymbolStub isForceableSymbol:p.symbol]) {
        p.strategy = SCICRuntimePatchStrategyFunctionBool;
        p.reason = @"validated BOOL-return C symbol with confirmed imported bind pointer; fishhook can replace the slot.";
        p.inlineToggleSafe = YES; p.safeAtLaunch = YES;
    } else if (p.function && p.hasBindPointer && [SCICSymbolStub isTypedForceableSymbol:p.symbol]) {
        p.strategy = SCICRuntimePatchStrategyFunctionTyped;
        p.reason = @"validated typed C reader with confirmed imported bind pointer; value prompt required.";
        p.inlineToggleSafe = NO; p.safeAtLaunch = YES; p.requiresPromptValue = YES;
    } else if (p.data && ([SCICSymbolStub isParamDescriptorSymbol:p.symbol] || (boolReader && [SCICSymbolStub canForceAsParamDescriptor:p.symbol]))) {
        p.strategy = SCICRuntimePatchStrategyDataReaderBool;
        p.reason = boolReader ? @"runtime xref confirmed MobileConfig BOOL reader consumer; force is descriptor-pointer filtered." : @"curated MobileConfig DATA descriptor; force is descriptor-pointer filtered.";
        p.inlineToggleSafe = YES; p.safeAtLaunch = YES; p.requiresConfirmedConsumer = ![SCICSymbolStub isParamDescriptorSymbol:p.symbol];
    } else if (p.data && p.hasBindPointer && SCICLooksStringDataSymbol(p.symbol, p.section)) {
        p.strategy = SCICRuntimePatchStrategyDataRebindString;
        p.reason = @"DATA symbol has imported pointer slot and looks NSString/key-compatible; replacement string prompt required.";
        p.inlineToggleSafe = NO; p.safeAtLaunch = YES; p.requiresPromptValue = YES;
    } else if (p.data && p.runtimeAddress && p.dataSize > 0 && p.dataSize <= 64 && SCICSectionIsPatchableData(p.section)) {
        p.strategy = SCICRuntimePatchStrategyDataPatchBytes;
        p.reason = @"bounded non-code DATA symbol with known size; vm_protect patch uses snapshot/revert.";
        p.inlineToggleSafe = NO; p.safeAtLaunch = YES; p.requiresPromptValue = YES;
    } else if (p.function && p.hasBindPointer && [SCICSymbolStub isHookableSymbol:p.symbol]) {
        p.strategy = SCICRuntimePatchStrategyFunctionObserve;
        p.reason = @"ABI validated but not value-forceable; observe hook only.";
        p.inlineToggleSafe = YES; p.safeAtLaunch = YES;
    } else {
        p.strategy = SCICRuntimePatchStrategyNone;
        if (p.function && [SCICSymbolStub isHookableSymbol:p.symbol] && !p.hasBindPointer) p.reason = @"ABI known, but no imported bind pointer was resolved; fishhook would be a no-op.";
        else if (p.swiftLike) p.reason = @"Swift/C++ direct dispatch: requires xref/ObjC consumer hook; no sideload-safe generic patch.";
        else if (p.data) p.reason = @"DATA has no confirmed reader, imported pointer, or safe bounded layout yet.";
        else p.reason = [SCICSymbolStub notForceableReasonForSymbol:p.symbol] ?: @"unknown ABI; classify before hook.";
    }
    p.strategyName = [SCICRuntimePatchPlan displayNameForStrategy:p.strategy returnKind:p.returnKind];
    p.shortStrategyName = [SCICRuntimePatchPlan shortNameForStrategy:p.strategy returnKind:p.returnKind];
    return p;
}

+ (BOOL)isAppliedPlan:(SCICRuntimePatchPlan *)plan {
    if (!plan.symbol.length) return NO;
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool: return [SCISymbolBrowserEngine overrideForKey:SCICObjCKey(plan.objcClassName, plan.objcSelectorName, plan.objcClassMethod)] != nil;
        case SCICRuntimePatchStrategyFunctionBool: return [SCICSymbolStub forceForSymbol:plan.symbol] != nil;
        case SCICRuntimePatchStrategyFunctionTyped: return [SCICSymbolStub typedForceForSymbol:plan.symbol] != nil || [SCICSymbolStub observeForSymbol:plan.symbol];
        case SCICRuntimePatchStrategyFunctionObserve: return [SCICSymbolStub observeForSymbol:plan.symbol];
        case SCICRuntimePatchStrategyDataReaderBool: return [SCICSymbolStub forceForParamDescriptorSymbol:plan.symbol] != nil || [SCICSymbolStub observeForParamDescriptorSymbol:plan.symbol];
        case SCICRuntimePatchStrategyDataRebindString: return [self persistedPatchForSymbol:plan.symbol] != nil;
        case SCICRuntimePatchStrategyDataPatchBytes: return [self persistedPatchForSymbol:plan.symbol] != nil;
        default: return NO;
    }
}

+ (NSUInteger)hitCountForPlan:(SCICRuntimePatchPlan *)plan {
    if (plan.strategy == SCICRuntimePatchStrategyDataReaderBool) return [SCICSymbolStub paramDescriptorCallCountForSymbol:plan.symbol];
    return [SCICSymbolStub callCountForSymbol:plan.symbol];
}

+ (BOOL)isHookInstalledForPlan:(SCICRuntimePatchPlan *)plan {
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool: return [SCISymbolBrowserEngine hookInstalledForKey:SCICObjCKey(plan.objcClassName, plan.objcSelectorName, plan.objcClassMethod)];
        case SCICRuntimePatchStrategyDataReaderBool: return [SCICSymbolStub hookInstalledForSymbol:@"IGMobileConfigBooleanValueForInternalUse"];
        case SCICRuntimePatchStrategyDataRebindString: { SCICDataRebindSlot *s = SCICDataRebindSlotFor(plan.symbol, NO); return s && atomic_load(&s->installed); }
        case SCICRuntimePatchStrategyDataPatchBytes: return [self persistedPatchForSymbol:plan.symbol] != nil;
        default: return [SCICSymbolStub hookInstalledForSymbol:plan.symbol];
    }
}

+ (id)currentForcedValueForPlan:(SCICRuntimePatchPlan *)plan {
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool: return [SCISymbolBrowserEngine overrideForKey:SCICObjCKey(plan.objcClassName, plan.objcSelectorName, plan.objcClassMethod)];
        case SCICRuntimePatchStrategyFunctionBool: return [SCICSymbolStub forceForSymbol:plan.symbol];
        case SCICRuntimePatchStrategyFunctionTyped: return [SCICSymbolStub typedForceForSymbol:plan.symbol][@"value"];
        case SCICRuntimePatchStrategyDataReaderBool: return [SCICSymbolStub forceForParamDescriptorSymbol:plan.symbol];
        default: return [self persistedPatchForSymbol:plan.symbol][@"value"] ?: [self persistedPatchForSymbol:plan.symbol][@"patchHex"];
    }
}

+ (id)currentNativeValueForPlan:(SCICRuntimePatchPlan *)plan {
    if (!plan.symbol.length) return nil;
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool:
            return [SCISymbolBrowserEngine liveValueForClass:plan.objcClassName ?: @"" selector:plan.objcSelectorName ?: @"" isClassMethod:plan.objcClassMethod];
        case SCICRuntimePatchStrategyFunctionBool:
            return [SCICSymbolStub observedValueForSymbol:plan.symbol];
        case SCICRuntimePatchStrategyFunctionTyped:
            return [SCICSymbolStub observedTypedValueForSymbol:plan.symbol];
        case SCICRuntimePatchStrategyDataReaderBool:
            return [SCICSymbolStub observedValueForParamDescriptorSymbol:plan.symbol];
        default:
            return nil;
    }
}

+ (BOOL)isEffectivelyEnabledForPlan:(SCICRuntimePatchPlan *)plan {
    id forced = [self currentForcedValueForPlan:plan];
    if ([forced isKindOfClass:NSNumber.class]) return [forced boolValue];
    id native = [self currentNativeValueForPlan:plan];
    if ([native isKindOfClass:NSNumber.class]) return [native boolValue];
    return [self isAppliedPlan:plan];
}

+ (NSString *)stateSummaryForPlan:(SCICRuntimePatchPlan *)plan {
    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    id native = [self currentNativeValueForPlan:plan];
    id forced = [self currentForcedValueForPlan:plan];
    if ([native isKindOfClass:NSNumber.class]) [bits addObject:[NSString stringWithFormat:@"native %@", [native boolValue] ? @"ON" : @"OFF"]];
    else if (native) [bits addObject:[NSString stringWithFormat:@"native %@", native]];
    else [bits addObject:@"native unknown"];
    if ([forced isKindOfClass:NSNumber.class]) [bits addObject:[NSString stringWithFormat:@"override %@", [forced boolValue] ? @"ON" : @"OFF"]];
    else if (forced) [bits addObject:[NSString stringWithFormat:@"override %@", forced]];
    else [bits addObject:@"no override"];
    [bits addObject:[self isHookInstalledForPlan:plan] ? @"hook installed" : @"hook not installed"];
    NSUInteger hits = [self hitCountForPlan:plan];
    if (hits) [bits addObject:[NSString stringWithFormat:@"hits %lu", (unsigned long)hits]];
    return [bits componentsJoinedByString:@" · "];
}

+ (BOOL)applyPlan:(SCICRuntimePatchPlan *)plan value:(id)value error:(NSError **)error {
    if (!plan.symbol.length || plan.strategy == SCICRuntimePatchStrategyNone) return NO;
    BOOL ok = NO;
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool: {
            NSNumber *v = [value isKindOfClass:NSNumber.class] ? value : @YES;
            [SCISymbolBrowserEngine setOverride:v forClass:plan.objcClassName ?: @"" selector:plan.objcSelectorName ?: @"" isClassMethod:plan.objcClassMethod];
            ok = YES; extra[@"value"] = v;
            break;
        }
        case SCICRuntimePatchStrategyFunctionBool: {
            NSNumber *v = [value isKindOfClass:NSNumber.class] ? value : @YES;
            ok = [SCICSymbolStub setForce:v forSymbol:plan.symbol]; extra[@"value"] = v;
            break;
        }
        case SCICRuntimePatchStrategyFunctionTyped: {
            if (!value) {
                ok = [SCICSymbolStub setObserve:YES forSymbol:plan.symbol];
                extra[@"observeOnly"] = @YES;
                break;
            }
            ok = [SCICSymbolStub setTypedForceValue:value returnKind:(plan.returnKind ?: [SCICSymbolStub returnKindForSymbol:plan.symbol] ?: @"int64") forSymbol:plan.symbol];
            extra[@"value"] = value;
            break;
        }
        case SCICRuntimePatchStrategyFunctionObserve: {
            ok = [SCICSymbolStub setObserve:YES forSymbol:plan.symbol];
            break;
        }
        case SCICRuntimePatchStrategyDataReaderBool: {
            NSNumber *v = [value isKindOfClass:NSNumber.class] ? value : @YES;
            ok = [SCICSymbolStub setParamDescriptorForce:v forSymbol:plan.symbol]; extra[@"value"] = v;
            break;
        }
        case SCICRuntimePatchStrategyDataRebindString: {
            NSString *str = [value isKindOfClass:NSString.class] ? value : [value description];
            if (!str.length) { if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:21 userInfo:@{NSLocalizedDescriptionKey:@"replacement string required"}]; return NO; }
            ok = SCICInstallDataRebind(plan.symbol, str);
            extra[@"value"] = str;
            break;
        }
        case SCICRuntimePatchStrategyDataPatchBytes: {
            NSData *bytes = [value isKindOfClass:NSData.class] ? value : nil;
            if (!bytes.length) { if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:22 userInfo:@{NSLocalizedDescriptionKey:@"patch bytes required"}]; return NO; }
            uintptr_t addr = (uintptr_t)SCICResolveSymbolAddress(plan.symbol);
            if (!addr) addr = plan.runtimeAddress;
            NSData *snapshot = nil;
            ok = SCICPatchMemory(addr, bytes, &snapshot, error);
            if (ok) {
                NSString *patchB64 = [bytes base64EncodedStringWithOptions:0];
                NSString *snapB64 = [snapshot base64EncodedStringWithOptions:0];
                extra[@"patch"] = patchB64 ?: @"";
                extra[@"snapshot"] = snapB64 ?: @"";
                extra[@"patchHex"] = [self hexStringFromData:bytes];
                NSMutableDictionary *snaps = [SCICDictPref(kSCICRuntimeDataPatchSnapshotsKey) mutableCopy] ?: [NSMutableDictionary dictionary];
                snaps[plan.symbol] = snapB64 ?: @"";
                [SCIUtils setPref:snaps.copy forKey:kSCICRuntimeDataPatchSnapshotsKey];
            }
            break;
        }
        default: break;
    }
    if (ok) [self savePatchPlan:plan extra:extra.copy];
    return ok;
}

+ (BOOL)revertPlan:(SCICRuntimePatchPlan *)plan error:(NSError **)error {
    if (!plan.symbol.length) return NO;
    BOOL ok = YES;
    NSDictionary *persisted = [self persistedPatchForSymbol:plan.symbol];
    switch (plan.strategy) {
        case SCICRuntimePatchStrategyObjCBool:
            [SCISymbolBrowserEngine setOverride:nil forClass:plan.objcClassName ?: @"" selector:plan.objcSelectorName ?: @"" isClassMethod:plan.objcClassMethod]; break;
        case SCICRuntimePatchStrategyFunctionBool:
            ok = [SCICSymbolStub setForce:nil forSymbol:plan.symbol]; break;
        case SCICRuntimePatchStrategyFunctionTyped:
            ok = [SCICSymbolStub setTypedForceValue:nil returnKind:(plan.returnKind ?: @"int64") forSymbol:plan.symbol];
            [SCICSymbolStub setObserve:NO forSymbol:plan.symbol];
            break;
        case SCICRuntimePatchStrategyFunctionObserve:
            ok = [SCICSymbolStub setObserve:NO forSymbol:plan.symbol]; break;
        case SCICRuntimePatchStrategyDataReaderBool:
            [SCICSymbolStub setParamDescriptorForce:nil forSymbol:plan.symbol];
            [SCICSymbolStub setParamDescriptorObserve:NO forSymbol:plan.symbol]; break;
        case SCICRuntimePatchStrategyDataRebindString:
            ok = SCICRevertDataRebind(plan.symbol); break;
        case SCICRuntimePatchStrategyDataPatchBytes: {
            NSString *b64 = [persisted[@"snapshot"] isKindOfClass:NSString.class] ? persisted[@"snapshot"] : SCICDictPref(kSCICRuntimeDataPatchSnapshotsKey)[plan.symbol];
            NSData *snapshot = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
            if (!snapshot.length) { ok = NO; if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:23 userInfo:@{NSLocalizedDescriptionKey:@"missing DATA patch snapshot"}]; break; }
            uintptr_t addr = (uintptr_t)SCICResolveSymbolAddress(plan.symbol);
            if (!addr) addr = plan.runtimeAddress;
            ok = SCICPatchMemory(addr, snapshot, NULL, error);
            break;
        }
        default: ok = NO; break;
    }
    if (ok) [self forgetPatchPlanForSymbol:plan.symbol];
    return ok;
}

+ (void)reinstallSafePersistedPatchPlansAtLaunch {
    NSDictionary *plans = [self persistedPatchPlans];
    if (!plans.count) return;
    RLOG("reinstall persisted plans count=%lu", (unsigned long)plans.count);
    for (NSString *symbol in plans) {
        SCICRuntimePatchPlan *plan = [SCICRuntimePatchPlan planWithDictionary:plans[symbol]];
        if (!plan.safeAtLaunch || plan.strategy == SCICRuntimePatchStrategyNone) continue;
        @try {
            switch (plan.strategy) {
                case SCICRuntimePatchStrategyObjCBool: {
                    if ([SCISymbolBrowserEngine overrideForKey:SCICObjCKey(plan.objcClassName, plan.objcSelectorName, plan.objcClassMethod)] != nil) [SCISymbolBrowserEngine installOverrideForKey:SCICObjCKey(plan.objcClassName, plan.objcSelectorName, plan.objcClassMethod)];
                    break;
                }
                case SCICRuntimePatchStrategyFunctionBool:
                    if ([SCICSymbolStub isForceableSymbol:plan.symbol] && [SCICSymbolStub forceForSymbol:plan.symbol] != nil) [SCICSymbolStub installStubForSymbol:plan.symbol];
                    break;
                case SCICRuntimePatchStrategyFunctionTyped:
                    if ([SCICSymbolStub isTypedForceableSymbol:plan.symbol] && ([SCICSymbolStub typedForceForSymbol:plan.symbol] != nil || [SCICSymbolStub observeForSymbol:plan.symbol])) [SCICSymbolStub installStubForSymbol:plan.symbol];
                    break;
                case SCICRuntimePatchStrategyFunctionObserve:
                    if ([SCICSymbolStub isHookableSymbol:plan.symbol] && [SCICSymbolStub observeForSymbol:plan.symbol]) [SCICSymbolStub installStubForSymbol:plan.symbol];
                    break;
                case SCICRuntimePatchStrategyDataReaderBool:
                    if ([SCICSymbolStub forceForParamDescriptorSymbol:plan.symbol] != nil) [SCICSymbolStub setParamDescriptorForce:[SCICSymbolStub forceForParamDescriptorSymbol:plan.symbol] forSymbol:plan.symbol];
                    else if ([SCICSymbolStub observeForParamDescriptorSymbol:plan.symbol]) [SCICSymbolStub setParamDescriptorObserve:YES forSymbol:plan.symbol];
                    break;
                case SCICRuntimePatchStrategyDataRebindString: {
                    NSString *replacement = [plans[symbol][@"value"] isKindOfClass:NSString.class] ? plans[symbol][@"value"] : nil;
                    if (replacement.length && plan.hasBindPointer) SCICInstallDataRebind(plan.symbol, replacement);
                    break;
                }
                case SCICRuntimePatchStrategyDataPatchBytes: {
                    NSString *b64 = [plans[symbol][@"patch"] isKindOfClass:NSString.class] ? plans[symbol][@"patch"] : nil;
                    NSData *bytes = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
                    if (bytes.length && bytes.length <= 64 && SCICSectionIsPatchableData(plan.section)) {
                        // Launch reapply must never reuse an old ASLR address.
                        // DATA byte patches are cold-launch safe only when the
                        // current process can resolve the symbol again.
                        uintptr_t addr = (uintptr_t)SCICResolveSymbolAddress(plan.symbol);
                        if (addr) SCICPatchMemory(addr, bytes, NULL, NULL);
                    }
                    break;
                }
                default: break;
            }
        } @catch (__unused id e) {}
    }
}

+ (NSData *)dataFromHexString:(NSString *)hex error:(NSError **)error {
    NSString *clean = hex ?: @"";
    clean = [clean stringByReplacingOccurrencesOfString:@" " withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"0x" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"," withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    if (!clean.length || (clean.length % 2) != 0) {
        if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:30 userInfo:@{NSLocalizedDescriptionKey:@"hex must contain an even number of digits"}];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        NSString *byteStr = [clean substringWithRange:NSMakeRange(i, 2)];
        unsigned int b = 0;
        NSScanner *sc = [NSScanner scannerWithString:byteStr];
        if (![sc scanHexInt:&b]) {
            if (error) *error = [NSError errorWithDomain:@"SCICRuntimePatchResolver" code:31 userInfo:@{NSLocalizedDescriptionKey:@"invalid hex byte"}];
            return nil;
        }
        uint8_t v = (uint8_t)b;
        [data appendBytes:&v length:1];
    }
    return data.copy;
}

+ (NSString *)hexStringFromData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || !data.length) return @"";
    const uint8_t *b = data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02x", b[i]];
    return s.copy;
}

@end
