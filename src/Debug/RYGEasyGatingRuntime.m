#import "RYGEasyGatingRuntime.h"
#import "../../modules/fishhook/fishhook.h"
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif
#include <stdlib.h>
#include <string.h>

NSString *const RYGEasyGatingDidObserveNotification = @"RYGEasyGatingDidObserveNotification";
NSString *const RYGEasyGatingGateIDUserInfoKey = @"gateID";

static NSString *const kRYGEasyGatingOverridesKey = @"ryg_easy_gating_platform_bool_overrides_v2";

// Current FBShared ABI, verified with LIEF + Capstone + radare2/llvm-objdump:
//
// EasyGatingGetBoolean_Internal_DoNotUseOrMock(context, selectorIndex,
//                                              defaultValue, exposureSource)
// maps selectorIndex to the FINAL gate ID, normalizes exposureSource to a bool,
// and then tail-branches to EasyGatingPlatformGetBoolean(context, finalGateID,
//                                                        defaultValue, exposure).
//
// Sideload rule: no instruction in FBSharedFramework.__TEXT is modified. The
// 1207 build used MSHookFunction on EasyGatingPlatformGetBoolean at +0x50faf4;
// that lives in the same signed 16 KiB page as the later crash at +0x50d0ac.
// iOS killed the process with CODESIGNING/Invalid Page. This implementation
// only rebinds imported symbol slots and READS the wrapper's mapping table.
typedef uint32_t (*RYGEasyGatingBoolFn)(uintptr_t context,
                                        uint32_t selectorOrGateID,
                                        uint32_t defaultValue,
                                        uintptr_t exposureSource);

static RYGEasyGatingBoolFn gRYGOriginalEasyGatingWrapper;
static os_unfair_lock gRYGEasyGatingLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, RYGEasyGatingObservation *> *gRYGEasyGatingObservations;
static NSDictionary<NSString *, NSNumber *> *gRYGEasyGatingOverrideCache;
static atomic_bool gRYGEasyGatingRebindingRegistered = false;

@implementation RYGEasyGatingObservation
- (NSNumber *)overrideValue { return [[RYGEasyGatingRuntime shared] overrideForGateID:self.gateID]; }
@end

static NSDictionary<NSString *, NSNumber *> *RYGEasyGatingReadOverrides(void) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:kRYGEasyGatingOverridesKey];
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary<NSString *, NSNumber *> *clean = [NSMutableDictionary dictionary];
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSNumber.class]) return;
        const char *digits = [(NSString *)key UTF8String];
        if (!digits || !*digits || *digits == '-') return;
        char *end = NULL;
        unsigned long long numeric = strtoull(digits, &end, 10);
        if (end == digits || *end != '\0' || numeric > UINT32_MAX) return;
        clean[key] = @([value boolValue]);
    }];
    return clean.copy;
}

static void RYGEasyGatingRefreshOverrideCache(void) {
    NSDictionary *next = RYGEasyGatingReadOverrides();
    os_unfair_lock_lock(&gRYGEasyGatingLock);
    gRYGEasyGatingOverrideCache = next;
    os_unfair_lock_unlock(&gRYGEasyGatingLock);
}

static NSNumber *RYGEasyGatingCachedOverride(uint32_t gateID) {
    NSString *key = [NSString stringWithFormat:@"%u", gateID];
    os_unfair_lock_lock(&gRYGEasyGatingLock);
    NSNumber *value = gRYGEasyGatingOverrideCache[key];
    os_unfair_lock_unlock(&gRYGEasyGatingLock);
    return value;
}

static void RYGEasyGatingRecord(uint32_t gateID,
                                BOOL defaultValue,
                                BOOL exposureEnabled,
                                BOOL nativeValue) {
    BOOL notify = NO;
    os_unfair_lock_lock(&gRYGEasyGatingLock);
    if (!gRYGEasyGatingObservations) gRYGEasyGatingObservations = [NSMutableDictionary dictionary];
    NSNumber *key = @(gateID);
    RYGEasyGatingObservation *row = gRYGEasyGatingObservations[key];
    if (!row) {
        row = [RYGEasyGatingObservation new];
        row.gateID = gateID;
        row.defaultValue = defaultValue;
        row.exposureEnabled = exposureEnabled;
        row.nativeValue = nativeValue;
        row.callCount = 1;
        row.lastSeen = NSDate.date;
        gRYGEasyGatingObservations[key] = row;
        notify = YES;
    } else {
        row.callCount += 1;
        if (row.defaultValue != defaultValue ||
            row.exposureEnabled != exposureEnabled ||
            row.nativeValue != nativeValue) {
            row.defaultValue = defaultValue;
            row.exposureEnabled = exposureEnabled;
            row.nativeValue = nativeValue;
            notify = YES;
        }
        if ((row.callCount & 63u) == 0u || notify) row.lastSeen = NSDate.date;
    }
    os_unfair_lock_unlock(&gRYGEasyGatingLock);

    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:RYGEasyGatingDidObserveNotification
                                                              object:nil
                                                            userInfo:@{RYGEasyGatingGateIDUserInfoKey:@(gateID)}];
        });
    }
}

static int64_t RYGSignExtend21(uint32_t value) {
    uint64_t raw = (uint64_t)value & 0x1fffffULL;
    uint64_t sign = 1ULL << 20;
    return (int64_t)((raw ^ sign) - sign);
}

static BOOL RYGAddSignedOffset(uintptr_t base, int64_t offset, uintptr_t *result) {
    if (!result) return NO;
    if (offset >= 0) {
        uint64_t positive = (uint64_t)offset;
        if (positive > UINTPTR_MAX - base) return NO;
        *result = base + (uintptr_t)positive;
        return YES;
    }
    uint64_t magnitude = (uint64_t)(-(offset + 1)) + 1u;
    if (magnitude > base) return NO;
    *result = base - (uintptr_t)magnitude;
    return YES;
}

static uintptr_t RYGStripFunctionPointer(RYGEasyGatingBoolFn function) {
    if (!function) return 0;
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)function, ptrauth_key_function_pointer);
#else
    return (uintptr_t)function;
#endif
}

static BOOL RYGEasyGatingImageRangeHasProtection(const void *imageBase,
                                                   uintptr_t start,
                                                   size_t length,
                                                   vm_prot_t requiredProtection) {
    if (!imageBase || !start || !length || start > UINTPTR_MAX - length) return NO;
    const struct mach_header *rawHeader = (const struct mach_header *)imageBase;
    if (rawHeader->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)rawHeader;
    if (!header->sizeofcmds || header->sizeofcmds > 16 * 1024 * 1024 || header->ncmds > 65535) return NO;

    const uint8_t *commands = (const uint8_t *)(header + 1);
    const uint8_t *commandsEnd = commands + header->sizeofcmds;
    const uint8_t *cursor = commands;
    uint64_t textVMAddress = UINT64_MAX;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor > commandsEnd || (size_t)(commandsEnd - cursor) < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(commandsEnd - cursor)) return NO;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) textVMAddress = segment->vmaddr;
        }
        cursor += command->cmdsize;
    }
    if (textVMAddress == UINT64_MAX || (uintptr_t)header < (uintptr_t)textVMAddress) return NO;

    uintptr_t slide = (uintptr_t)header - (uintptr_t)textVMAddress;
    uintptr_t end = start + length;
    cursor = commands;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if ((segment->initprot & requiredProtection) == requiredProtection &&
                segment->vmaddr <= UINTPTR_MAX - slide) {
                uintptr_t segmentStart = slide + (uintptr_t)segment->vmaddr;
                if ((uintptr_t)segment->vmsize <= UINTPTR_MAX - segmentStart) {
                    uintptr_t segmentEnd = segmentStart + (uintptr_t)segment->vmsize;
                    if (start >= segmentStart && end <= segmentEnd) return YES;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NO;
}

// Decode the exact read-only mapper embedded in the current wrapper instead of
// jumping into the middle of signed code. This remains safe with BTI/PAC because
// no indirect branch targets an interior instruction.
static BOOL RYGResolveFinalGateID(RYGEasyGatingBoolFn wrapper,
                                  uint32_t selectorIndex,
                                  uint32_t *finalGateID) {
    uintptr_t wrapperAddress = RYGStripFunctionPointer(wrapper);
    if (!wrapperAddress || !finalGateID || selectorIndex > 0xffffu) return NO;

    Dl_info info = {0};
    if (!dladdr((const void *)wrapperAddress, &info) || !info.dli_fname) return NO;
    NSString *image = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    if (![image.lastPathComponent containsString:@"FBSharedFramework"]) return NO;

    // FBSharedFramework(20260821-132949): mapper starts at wrapper + 0x34.
    // Validate ARM64 ADRP/ADD/ADR instructions before trusting any address so a
    // future build simply becomes unobservable instead of reading arbitrary data.
    uintptr_t helper = wrapperAddress + 0x34;
    if (helper < wrapperAddress ||
        !RYGEasyGatingImageRangeHasProtection(info.dli_fbase, helper, 0x24, VM_PROT_READ | VM_PROT_EXECUTE)) return NO;
    uint32_t instructions[9] = {0};
    memcpy(instructions, (const void *)helper, sizeof(instructions));
    if (instructions[0] != 0x2a0003ebu || // mov w11, w0
        instructions[1] != 0xa9bf7bfdu || // stp x29, x30, [sp, #-0x10]!
        instructions[2] != 0x910003fdu || // mov x29, sp
        instructions[6] != 0x786b7928u || // ldrh w8, [x9, x11, lsl #1]
        instructions[7] != 0x8b08094au || // add x10, x10, x8, lsl #2
        instructions[8] != 0xd61f0140u) return NO; // br x10
    uint32_t adrp = instructions[3];
    uint32_t add  = instructions[4];
    uint32_t adr  = instructions[5];
    if ((adrp & 0x9f000000u) != 0x90000000u || (adrp & 0x1fu) != 9u) return NO;
    if ((add & 0x7f000000u) != 0x11000000u || (add & 0x1fu) != 9u || ((add >> 5) & 0x1fu) != 9u) return NO;
    if ((adr & 0x9f000000u) != 0x10000000u || (adr & 0x1fu) != 10u) return NO;

    uint32_t adrpImm21 = (((adrp >> 5) & 0x7ffffu) << 2) | ((adrp >> 29) & 0x3u);
    uintptr_t adrpPC = helper + 0x0c;
    int64_t pageDelta = RYGSignExtend21(adrpImm21) * 4096;
    uintptr_t table = 0;
    if (!RYGAddSignedOffset(adrpPC & ~(uintptr_t)0xfff, pageDelta, &table)) return NO;
    uint32_t addImm = (add >> 10) & 0xfffu;
    if ((add >> 22) & 1u) addImm <<= 12;
    if (table > UINTPTR_MAX - addImm) return NO;
    table += addImm;

    uint32_t adrImm21 = (((adr >> 5) & 0x7ffffu) << 2) | ((adr >> 29) & 0x3u);
    uintptr_t adrPC = helper + 0x14;
    uintptr_t jumpBase = 0;
    if (!RYGAddSignedOffset(adrPC, RYGSignExtend21(adrImm21), &jumpBase)) return NO;

    uintptr_t tableOffset = (uintptr_t)selectorIndex * sizeof(uint16_t);
    if (table > UINTPTR_MAX - tableOffset) return NO;
    uintptr_t tableEntry = table + tableOffset;
    if (!RYGEasyGatingImageRangeHasProtection(info.dli_fbase, tableEntry, sizeof(uint16_t), VM_PROT_READ)) return NO;
    uint16_t jumpUnits = 0;
    memcpy(&jumpUnits, (const void *)tableEntry, sizeof(jumpUnits));
    if ((uintptr_t)jumpUnits > (UINTPTR_MAX - jumpBase) / 4u) return NO;
    uintptr_t target = jumpBase + (uintptr_t)jumpUnits * 4u;
    if (target < wrapperAddress + 0x34 || target >= wrapperAddress + 0x2000) return NO;
    if (!RYGEasyGatingImageRangeHasProtection(info.dli_fbase, target, 8, VM_PROT_READ | VM_PROT_EXECUTE)) return NO;

    uint32_t targetInstructions[2] = {0};
    memcpy(targetInstructions, (const void *)target, sizeof(targetInstructions));

    // The current table has identity entries that branch directly to the exact
    // wrapper epilogue. W0 still contains selectorIndex there, so rejecting these
    // entries would make legitimate gates invisible to the runtime browser.
    if (targetInstructions[0] == 0xa8c17bfdu && // ldp x29, x30, [sp], #0x10
        targetInstructions[1] == 0xd65f03c0u) { // ret
        *finalGateID = selectorIndex;
        return YES;
    }

    uint32_t movz = targetInstructions[0];
    if ((movz & 0x7f80001fu) != 0x52800000u) return NO; // MOVZ W0, #imm
    uint32_t hw = (movz >> 21) & 0x3u;
    if (hw > 1u) return NO;
    uint32_t value = ((movz >> 5) & 0xffffu) << (hw * 16u);

    uint32_t next = targetInstructions[1];
    if ((next & 0x7f80001fu) == 0x72800000u) { // optional MOVK W0
        uint32_t nextHW = (next >> 21) & 0x3u;
        if (nextHW > 1u) return NO;
        uint32_t shift = nextHW * 16u;
        uint32_t mask = 0xffffu << shift;
        value = (value & ~mask) | (((next >> 5) & 0xffffu) << shift);
    }
    if (!value) return NO;
    *finalGateID = value;
    return YES;
}

static uint32_t RYGEasyGatingWrapperReplacement(uintptr_t context,
                                                 uint32_t selectorIndex,
                                                 uint32_t defaultValue,
                                                 uintptr_t exposureSource) {
    RYGEasyGatingBoolFn original = gRYGOriginalEasyGatingWrapper;
    uint32_t native = original ? original(context, selectorIndex, defaultValue, exposureSource)
                               : (defaultValue ? 1u : 0u);
    uint32_t finalID = 0;
    if (!RYGResolveFinalGateID(original, selectorIndex, &finalID)) return native;
    BOOL exposure = exposureSource != 0;
    RYGEasyGatingRecord(finalID, defaultValue != 0, exposure, native != 0);
    NSNumber *forced = RYGEasyGatingCachedOverride(finalID);
    return forced ? (forced.boolValue ? 1u : 0u) : native;
}

static BOOL RYGRegisterEasyGatingRebindings(void) {
    if (atomic_load(&gRYGEasyGatingRebindingRegistered)) return YES;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gRYGEasyGatingRebindingRegistered, &expected, true)) return YES;

    const struct mach_header *mainHeader = NULL; intptr_t mainSlide = 0;
    NSString *wanted = NSBundle.mainBundle.executablePath.stringByStandardizingPath;
    for (uint32_t i=0; i<_dyld_image_count(); i++) {
        const char *raw=_dyld_get_image_name(i); if (!raw) continue;
        NSString *path=[[NSString stringWithUTF8String:raw] stringByStandardizingPath];
        if ([path isEqualToString:wanted]) { mainHeader=_dyld_get_image_header(i); mainSlide=_dyld_get_image_vmaddr_slide(i); break; }
    }
    if (!mainHeader) { atomic_store(&gRYGEasyGatingRebindingRegistered, false); return NO; }

    struct rebinding binding = {
        .name = "EasyGatingGetBoolean_Internal_DoNotUseOrMock",
        .replacement = (void *)&RYGEasyGatingWrapperReplacement,
        .replaced = (void **)&gRYGOriginalEasyGatingWrapper,
    };
    // Instagram(9) imports/calls this wrapper directly. Rebind only the main
    // executable's import slot; do not register a process-wide hook and do not
    // modify FBSharedFramework.__TEXT.
    if (rebind_symbols_image((void *)mainHeader, mainSlide, &binding, 1) != 0 || !gRYGOriginalEasyGatingWrapper) {
        atomic_store(&gRYGEasyGatingRebindingRegistered, false);
        return NO;
    }
    return YES;
}

@implementation RYGEasyGatingRuntime

+ (instancetype)shared {
    static RYGEasyGatingRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        runtime = [RYGEasyGatingRuntime new];
        RYGEasyGatingRefreshOverrideCache();
    });
    return runtime;
}

- (void)installIfNeeded { (void)RYGRegisterEasyGatingRebindings(); }

- (NSArray<RYGEasyGatingObservation *> *)observations {
    os_unfair_lock_lock(&gRYGEasyGatingLock);
    NSArray *rows = gRYGEasyGatingObservations.allValues.copy ?: @[];
    os_unfair_lock_unlock(&gRYGEasyGatingLock);
    return [rows sortedArrayUsingComparator:^NSComparisonResult(RYGEasyGatingObservation *left, RYGEasyGatingObservation *right) {
        if (left.gateID < right.gateID) return NSOrderedAscending;
        if (left.gateID > right.gateID) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (NSNumber *)overrideForGateID:(uint32_t)gateID { return RYGEasyGatingCachedOverride(gateID); }

- (void)setOverride:(NSNumber *)value forGateID:(uint32_t)gateID {
    NSMutableDictionary<NSString *, NSNumber *> *overrides = [RYGEasyGatingReadOverrides() mutableCopy];
    NSString *key = [NSString stringWithFormat:@"%u", gateID];
    if (value) overrides[key] = @([value boolValue]);
    else [overrides removeObjectForKey:key];
    [NSUserDefaults.standardUserDefaults setObject:overrides.copy forKey:kRYGEasyGatingOverridesKey];
    RYGEasyGatingRefreshOverrideCache();
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:RYGEasyGatingDidObserveNotification
                                                          object:nil
                                                        userInfo:@{RYGEasyGatingGateIDUserInfoKey:@(gateID)}];
    });
}

- (void)clearObservations {
    os_unfair_lock_lock(&gRYGEasyGatingLock);
    [gRYGEasyGatingObservations removeAllObjects];
    os_unfair_lock_unlock(&gRYGEasyGatingLock);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:RYGEasyGatingDidObserveNotification object:nil];
    });
}

@end
