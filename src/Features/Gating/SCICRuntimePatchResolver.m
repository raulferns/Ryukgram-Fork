// SCICRuntimePatchResolver.m
#import "SCICRuntimePatchResolver.h"
#import "SCICSymbolStub.h"
#import "../../Utils.h"
#import "../Dogfooding/SCISymbolBrowserEngine.h"
#import "../../../modules/fishhook/fishhook.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <unistd.h>
#import <stdint.h>
#import <string.h>

NSString *const SCICPatchStrategyObserve = @"observe";
NSString *const SCICPatchStrategyObjCBool = @"objc.bool";
NSString *const SCICPatchStrategyFunctionBool = @"function.bool";
NSString *const SCICPatchStrategyFunctionTyped = @"function.typed";
NSString *const SCICPatchStrategyDataReaderBool = @"data.reader.bool";
NSString *const SCICPatchStrategyDataStringRebind = @"data.rebind.string";
NSString *const SCICPatchStrategyDataBytesPatch = @"data.patch.bytes";

static NSString *const kRuntimePatchPlans = @"sci_runtime_patch_plans";

#define RPLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] Resolver " fmt,##__VA_ARGS__)

@implementation SCICPatchPlan
@end

static NSDictionary *SCICPatchPlanPrefs(void) {
    NSDictionary *d = [SCIUtils getDictPref:kRuntimePatchPlans];
    return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static void SCICSetPatchPlanPref(NSString *symbol, NSDictionary *entry) {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return;
    NSMutableDictionary *d = [SCICPatchPlanPrefs() mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([entry isKindOfClass:NSDictionary.class]) d[symbol] = entry;
    else [d removeObjectForKey:symbol];
    [SCIUtils setPref:d forKey:kRuntimePatchPlans];
}

static NSString *SCICHexFromData(NSData *data) {
    if (!data.length) return @"";
    const unsigned char *bytes = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", bytes[i]];
    return out.copy;
}

static NSData *SCICDataFromHex(NSString *hex) {
    if (![hex isKindOfClass:NSString.class]) return nil;
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < hex.length; i++) {
        unichar c = [hex characterAtIndex:i];
        if ([allowed characterIsMember:c]) [clean appendFormat:@"%C", c];
    }
    if (!clean.length || (clean.length % 2) != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
        unsigned int v = 0;
        NSString *byteString = [clean substringWithRange:NSMakeRange(i, 2)];
        [[NSScanner scannerWithString:byteString] scanHexInt:&v];
        uint8_t b = (uint8_t)v;
        [data appendBytes:&b length:1];
    }
    return data.copy;
}

static BOOL SCICRuntimeResolveSymbol(NSString *name, void **addrOut) {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    void *p = dlsym(RTLD_DEFAULT, name.UTF8String);
    if (!p) {
        NSString *under = [@"_" stringByAppendingString:name];
        p = dlsym(RTLD_DEFAULT, under.UTF8String);
    }
    if (addrOut) *addrOut = p;
    return p != NULL;
}

static NSString *SCICShortImage(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return @"unknown";
    if ([path containsString:@"/FBSharedFramework"]) return @"FBSharedFramework";
    if ([path.lastPathComponent isEqualToString:@"Instagram"]) return @"Instagram";
    return path.lastPathComponent ?: path;
}

static BOOL SCICIsWantedImagePath(NSString *path) {
    return [path.lastPathComponent isEqualToString:@"Instagram"] || [path containsString:@"/FBSharedFramework"];
}

static NSString *SCICSectionLabel(const struct section_64 *sec) {
    if (!sec) return @"unknown";
    char seg[17] = {0}; char sect[17] = {0};
    memcpy(seg, sec->segname, 16); memcpy(sect, sec->sectname, 16);
    return [NSString stringWithFormat:@"%s,%s", seg, sect];
}

typedef struct {
    const struct symtab_command *symtab;
    const struct dysymtab_command *dysymtab;
    const struct segment_command_64 *linkedit;
    NSMutableArray<NSValue *> *sections;
} SCICMachInfo;

static void SCICCollectMachInfo(const struct mach_header_64 *mh, SCICMachInfo *info) {
    if (!mh || !info) return;
    info->sections = [NSMutableArray array];
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) info->linkedit = seg;
            const struct section_64 *sec = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) [info->sections addObject:[NSValue valueWithPointer:&sec[j]]];
        } else if (lc->cmd == LC_SYMTAB) {
            info->symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            info->dysymtab = (const struct dysymtab_command *)lc;
        }
        p += lc->cmdsize;
    }
}

static NSArray<NSDictionary<NSString *, id> *> *SCICFindImportPointersForSymbol(NSString *symbol) {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return @[];
    NSString *wanted = [@"_" stringByAppendingString:symbol];
    NSMutableArray *hits = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t idx = 0; idx < count; idx++) {
        const char *cpath = _dyld_get_image_name(idx);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (!SCICIsWantedImagePath(path)) continue;
        const struct mach_header *raw = _dyld_get_image_header(idx);
        if (!raw || raw->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
        intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
        SCICMachInfo info = {0};
        SCICCollectMachInfo(mh, &info);
        if (!info.symtab || !info.dysymtab || !info.linkedit || !info.dysymtab->indirectsymoff) continue;
        uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)info.linkedit->vmaddr - (uintptr_t)info.linkedit->fileoff;
        const struct nlist_64 *nl = (const struct nlist_64 *)(linkeditBase + info.symtab->symoff);
        const char *strtab = (const char *)(linkeditBase + info.symtab->stroff);
        const uint32_t *indirect = (const uint32_t *)(linkeditBase + info.dysymtab->indirectsymoff);
        for (NSValue *v in info.sections) {
            const struct section_64 *sec = v.pointerValue;
            uint32_t type = sec->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            uint64_t ptrCount = sec->size / sizeof(void *);
            if (!ptrCount) continue;
            for (uint64_t j = 0; j < ptrCount; j++) {
                uint32_t symIndex = indirect[sec->reserved1 + (uint32_t)j];
                if (symIndex == INDIRECT_SYMBOL_ABS || symIndex == INDIRECT_SYMBOL_LOCAL || (symIndex & INDIRECT_SYMBOL_LOCAL)) continue;
                if (symIndex >= info.symtab->nsyms) continue;
                uint32_t strx = nl[symIndex].n_un.n_strx;
                if (!strx) continue;
                const char *rawName = strtab + strx;
                if (!rawName) continue;
                if (strcmp(rawName, wanted.UTF8String) != 0 && strcmp(rawName, symbol.UTF8String) != 0) continue;
                uintptr_t slotAddr = (uintptr_t)slide + (uintptr_t)sec->addr + (uintptr_t)(j * sizeof(void *));
                [hits addObject:@{
                    @"image": SCICShortImage(path),
                    @"section": SCICSectionLabel(sec),
                    @"slot": [NSString stringWithFormat:@"0x%llx", (unsigned long long)slotAddr],
                }];
            }
        }
    }
    return hits.copy;
}

static NSUInteger SCICKnownSymbolSize(uintptr_t target, NSString *imageName, NSString *sectionLabel) {
    if (!target || ![imageName isKindOfClass:NSString.class]) return 0;
    NSUInteger best = 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t idx = 0; idx < count; idx++) {
        const char *cpath = _dyld_get_image_name(idx);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (![SCICShortImage(path) isEqualToString:imageName]) continue;
        const struct mach_header *raw = _dyld_get_image_header(idx);
        if (!raw || raw->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
        intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
        SCICMachInfo info = {0}; SCICCollectMachInfo(mh, &info);
        if (!info.symtab || !info.linkedit) continue;
        uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)info.linkedit->vmaddr - (uintptr_t)info.linkedit->fileoff;
        const struct nlist_64 *nl = (const struct nlist_64 *)(linkeditBase + info.symtab->symoff);
        for (uint32_t i = 0; i < info.symtab->nsyms; i++) {
            if ((nl[i].n_type & N_TYPE) != N_SECT || (nl[i].n_type & N_STAB) || !nl[i].n_value) continue;
            uintptr_t addr = (uintptr_t)nl[i].n_value + (uintptr_t)slide;
            if (addr <= target) continue;
            if (sectionLabel.length) {
                uint8_t sectIndex = nl[i].n_sect;
                const struct section_64 *sec = (sectIndex > 0 && sectIndex <= info.sections.count) ? [info.sections[sectIndex - 1] pointerValue] : NULL;
                if (![[SCICSectionLabel(sec) lowercaseString] isEqualToString:sectionLabel.lowercaseString]) continue;
            }
            NSUInteger delta = (NSUInteger)(addr - target);
            if (delta > 0 && (!best || delta < best)) best = delta;
        }
    }
    if (best > 0 && best <= 256) return best;
    return 0;
}

static int64_t SCICSignExtend(int64_t value, unsigned bits) {
    int64_t shift = 64 - bits;
    return (value << shift) >> shift;
}

static BOOL SCICDecodeADRP(uint32_t insn, uintptr_t pc, unsigned *rdOut, uintptr_t *pageOut) {
    if ((insn & 0x9f000000) != 0x90000000) return NO;
    uint64_t immlo = (insn >> 29) & 0x3;
    uint64_t immhi = (insn >> 5) & 0x7ffff;
    int64_t imm = SCICSignExtend((int64_t)((immhi << 2) | immlo), 21) << 12;
    uintptr_t base = pc & ~(uintptr_t)0xfff;
    if (rdOut) *rdOut = insn & 31;
    if (pageOut) *pageOut = (uintptr_t)((int64_t)base + imm);
    return YES;
}

static BOOL SCICDecodeADD64Imm(uint32_t insn, unsigned *rdOut, unsigned *rnOut, uint64_t *immOut) {
    if ((insn & 0xffc00000) != 0x91000000) return NO;
    unsigned shift = (insn >> 22) & 0x3;
    uint64_t imm = (insn >> 10) & 0xfff;
    if (shift == 1) imm <<= 12;
    else if (shift != 0) return NO;
    if (rdOut) *rdOut = insn & 31;
    if (rnOut) *rnOut = (insn >> 5) & 31;
    if (immOut) *immOut = imm;
    return YES;
}

static BOOL SCICDecodeLDRUnsigned(uint32_t insn, unsigned *rtOut, unsigned *rnOut, uint64_t *immOut) {
    uint64_t scale = 0;
    if ((insn & 0xffc00000) == 0xf9400000) scale = 8;
    else if ((insn & 0xffc00000) == 0xb9400000) scale = 4;
    else if ((insn & 0xffc00000) == 0x39400000) scale = 1;
    else return NO;
    if (rtOut) *rtOut = insn & 31;
    if (rnOut) *rnOut = (insn >> 5) & 31;
    if (immOut) *immOut = ((insn >> 10) & 0xfff) * scale;
    return YES;
}

static BOOL SCICDecodeBL(uint32_t insn, uintptr_t pc, uintptr_t *targetOut) {
    if ((insn & 0xfc000000) != 0x94000000) return NO;
    int64_t imm = SCICSignExtend((int64_t)(insn & 0x03ffffff), 26) << 2;
    if (targetOut) *targetOut = (uintptr_t)((int64_t)pc + imm);
    return YES;
}

static NSString *SCICSymbolNameForAddress(uintptr_t address) {
    if (!address) return @"unknown";
    Dl_info info = {0};
    if (dladdr((void *)address, &info)) {
        NSString *s = nil;
        if (info.dli_sname) s = [NSString stringWithUTF8String:info.dli_sname];
        if (s.length) return [s hasPrefix:@"_"] ? [s substringFromIndex:1] : s;
        if (info.dli_fname) return [NSString stringWithFormat:@"%@+0x%llx", SCICShortImage([NSString stringWithUTF8String:info.dli_fname]), (unsigned long long)((uintptr_t)address - (uintptr_t)info.dli_fbase)];
    }
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
}

static NSArray<NSDictionary<NSString *, id> *> *SCICFindXrefsToAddress(uintptr_t target, NSUInteger limit) {
    if (!target) return @[];
    NSMutableArray *hits = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t idx = 0; idx < count && hits.count < limit; idx++) {
        const char *cpath = _dyld_get_image_name(idx);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (!SCICIsWantedImagePath(path)) continue;
        const struct mach_header *raw = _dyld_get_image_header(idx);
        if (!raw || raw->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
        intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
        SCICMachInfo info = {0}; SCICCollectMachInfo(mh, &info);
        for (NSValue *v in info.sections) {
            const struct section_64 *sec = v.pointerValue;
            if (strncmp(sec->segname, "__TEXT", 16) != 0 || strncmp(sec->sectname, "__text", 16) != 0) continue;
            uintptr_t start = (uintptr_t)slide + (uintptr_t)sec->addr;
            NSUInteger words = (NSUInteger)(sec->size / 4);
            uintptr_t regValue[32] = {0};
            BOOL regKnown[32] = {0};
            NSInteger lastHitDistance = 999;
            uintptr_t lastHitPC = 0;
            NSString *lastForm = nil;
            for (NSUInteger w = 0; w < words && hits.count < limit; w++) {
                uintptr_t pc = start + w * 4;
                uint32_t insn = 0;
                memcpy(&insn, (const void *)pc, sizeof(insn));
                unsigned rd = 0, rn = 0, rt = 0; uint64_t imm = 0; uintptr_t page = 0; uintptr_t blTarget = 0;
                if (SCICDecodeADRP(insn, pc, &rd, &page)) {
                    if (rd < 32) { regValue[rd] = page; regKnown[rd] = YES; }
                } else if (SCICDecodeADD64Imm(insn, &rd, &rn, &imm)) {
                    if (rn < 32 && rd < 32 && regKnown[rn]) {
                        uintptr_t value = regValue[rn] + (uintptr_t)imm;
                        regValue[rd] = value; regKnown[rd] = YES;
                        if (value == target) { lastHitPC = pc; lastHitDistance = 0; lastForm = @"adrp/add"; }
                    }
                } else if (SCICDecodeLDRUnsigned(insn, &rt, &rn, &imm)) {
                    if (rn < 32 && rt < 32 && regKnown[rn]) {
                        uintptr_t value = regValue[rn] + (uintptr_t)imm;
                        if (value == target) { lastHitPC = pc; lastHitDistance = 0; lastForm = @"ldr from symbol address"; }
                    }
                } else if (SCICDecodeBL(insn, pc, &blTarget)) {
                    if (lastHitDistance >= 0 && lastHitDistance <= 8 && lastHitPC) {
                        [hits addObject:@{
                            @"image": SCICShortImage(path),
                            @"at": [NSString stringWithFormat:@"0x%llx", (unsigned long long)lastHitPC],
                            @"form": lastForm ?: @"address materialized",
                            @"consumer": SCICSymbolNameForAddress(blTarget),
                            @"call": [NSString stringWithFormat:@"0x%llx", (unsigned long long)blTarget],
                        }];
                        lastHitPC = 0; lastHitDistance = 999; lastForm = nil;
                    }
                }
                if (lastHitDistance < 999) lastHitDistance++;
            }
        }
    }
    return hits.copy;
}

static NSArray<NSString *> *SCICSummarizeImports(NSArray<NSDictionary<NSString *, id> *> *imports) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in imports) {
        NSString *s = [NSString stringWithFormat:@"%@ %@ slot %@", d[@"image"] ?: @"Image", d[@"section"] ?: @"section", d[@"slot"] ?: @"?"];
        [out addObject:s];
        if (out.count >= 8) break;
    }
    return out.copy;
}

static NSArray<NSString *> *SCICSummarizeXrefs(NSArray<NSDictionary<NSString *, id> *> *xrefs) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in xrefs) {
        NSString *s = [NSString stringWithFormat:@"%@ %@ → %@ (%@)", d[@"image"] ?: @"Image", d[@"at"] ?: @"?", d[@"consumer"] ?: @"consumer?", d[@"form"] ?: @"xref"];
        [out addObject:s];
        if (out.count >= 12) break;
    }
    return out.copy;
}


static BOOL SCICKnownSafeParamDescriptorName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    static NSSet<NSString *> *safe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        safe = [NSSet setWithArray:@[
            @"ig_is_employee",
            @"ig_is_employee_or_test_user",
            @"ig_user_session_canary_test",
            @"ig_user_session_ep_test_1",
            @"ig_user_session_ep_test_2",
            @"ig_user_session_ep_test_3",
            @"ig_user_session_ep_test_4",
            @"xav_switcher_ig_ios_test_user_check_fdid",
            @"mc_team_mixed_fb_user_igfbidv2_test_config",
            @"mc_team_mixed_fb_user_igfbidv2_test_config_1",
        ]];
    });
    return [safe containsObject:name];
}

static BOOL SCICLooksParamDescriptor(NSString *name) {
    if ([SCICSymbolStub isParamDescriptorSymbol:name]) return YES;
    return [name hasPrefix:@"ig_"] || [name hasPrefix:@"xav_"] || [name hasPrefix:@"mc_team_"];
}

static BOOL SCICLooksNSStringConstant(NSString *name, NSString *section) {
    NSString *lower = name.lowercaseString ?: @"";
    NSString *sec = section.lowercaseString ?: @"";
    return [lower hasPrefix:@"k"] || [lower containsString:@"key"] || [lower containsString:@"name"] || [lower containsString:@"string"] || [sec containsString:@"cfstring"] || [sec containsString:@"objc_methname"];
}

static kern_return_t SCICPatchMemory(uintptr_t address, NSData *patch, NSData **originalOut, NSString **errorOut) {
    if (!address || !patch.length) { if (errorOut) *errorOut = @"invalid address/patch"; return KERN_INVALID_ARGUMENT; }
    NSData *orig = [NSData dataWithBytes:(const void *)address length:patch.length];
    if (originalOut) *originalOut = orig;
    vm_address_t region = (vm_address_t)address;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &regionSize, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &objectName);
    if (kr != KERN_SUCCESS) { if (errorOut) *errorOut = [NSString stringWithFormat:@"vm_region failed: %d", kr]; return kr; }
    uintptr_t pageSize = (uintptr_t)getpagesize();
    vm_address_t pageStart = (vm_address_t)((uintptr_t)address & ~(pageSize - 1));
    vm_size_t pageEnd = (vm_size_t)(((uintptr_t)address + patch.length + pageSize - 1) & ~(pageSize - 1));
    vm_size_t protectLen = pageEnd - pageStart;
    kr = vm_protect(mach_task_self(), pageStart, protectLen, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), pageStart, protectLen, false, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) { if (errorOut) *errorOut = [NSString stringWithFormat:@"vm_protect write failed: %d", kr]; return kr; }
    }
    memcpy((void *)address, patch.bytes, patch.length);
    vm_protect(mach_task_self(), pageStart, protectLen, false, info.protection ? info.protection : VM_PROT_READ);
    return KERN_SUCCESS;
}

#define MAX_DATA_REBINDS 48
typedef struct {
    char name[192];
    void *replacement;
    void *original;
} SCICDataRebindSlot;
static SCICDataRebindSlot g_dataRebinds[MAX_DATA_REBINDS];
static int g_dataRebindCount = 0;

static SCICDataRebindSlot *SCICDataSlotForName(const char *name) {
    if (!name) return NULL;
    for (int i = 0; i < g_dataRebindCount; i++) if (strcmp(g_dataRebinds[i].name, name) == 0) return &g_dataRebinds[i];
    return NULL;
}

static BOOL SCICInstallDataStringRebind(NSString *symbol, NSString *replacementString) {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return NO;
    if (![replacementString isKindOfClass:NSString.class]) replacementString = @"";
    SCICDataRebindSlot *slot = SCICDataSlotForName(symbol.UTF8String);
    if (slot) {
        if (slot->replacement) CFRelease((CFTypeRef)slot->replacement);
        slot->replacement = (void *)CFBridgingRetain([replacementString copy]);
        return YES;
    }
    if (g_dataRebindCount >= MAX_DATA_REBINDS) return NO;
    slot = &g_dataRebinds[g_dataRebindCount++];
    memset(slot, 0, sizeof(*slot));
    strncpy(slot->name, symbol.UTF8String, sizeof(slot->name)-1);
    slot->replacement = (void *)CFBridgingRetain([replacementString copy]);
    struct rebinding rb = { slot->name, slot->replacement, &slot->original };
    int rc = rebind_symbols(&rb, 1);
    RPLOG("data rebind %{public}s rc=%d", symbol.UTF8String, rc);
    return rc == 0;
}

@implementation SCICRuntimePatchResolver

+ (SCICPatchPlan *)resolveSymbol:(NSString *)symbol
                           image:(NSString *)image
                         section:(NSString *)section
                         address:(uintptr_t)address
                       isFunction:(BOOL)isFunction
                           isData:(BOOL)isData
                        swiftLike:(BOOL)swiftLike
                    objcClassName:(NSString *)objcClassName
                 objcSelectorName:(NSString *)objcSelectorName
                objcIsClassMethod:(BOOL)objcIsClassMethod {
    SCICPatchPlan *plan = [SCICPatchPlan new];
    plan.symbol = symbol ?: @"";
    plan.image = image ?: @"";
    plan.section = section ?: @"";
    plan.kind = objcSelectorName.length ? @"ObjC method" : (isFunction ? (swiftLike ? @"Swift/C++ function" : @"C function") : @"DATA/const");

    void *runtime = NULL;
    if (SCICRuntimeResolveSymbol(symbol, &runtime)) address = (uintptr_t)runtime;

    NSArray *imports = SCICFindImportPointersForSymbol(symbol);
    NSArray *xrefs = isData ? SCICFindXrefsToAddress(address, 24) : @[];
    plan.importedByImages = [imports valueForKey:@"image"] ?: @[];
    plan.bindPointerSummary = SCICSummarizeImports(imports);
    plan.xrefSummary = SCICSummarizeXrefs(xrefs);
    plan.hasBindPointer = imports.count > 0;
    plan.hasXrefs = xrefs.count > 0;
    plan.knownSize = isData ? SCICKnownSymbolSize(address, image, section) : 0;
    plan.dataPatchable = isData && plan.knownSize > 0 && plan.knownSize <= 64 && ![section.lowercaseString containsString:@"cstring"] && ![section.lowercaseString containsString:@"objc_methname"];
    plan.functionHookable = isFunction && [SCICSymbolStub isHookableSymbol:symbol];
    NSDictionary *persisted = [self persistedPatchForSymbol:symbol];
    plan.appliedStrategy = [persisted[@"strategy"] isKindOfClass:NSString.class] ? persisted[@"strategy"] : nil;
    plan.appliedValue = persisted[@"value"];

    NSMutableArray *summary = [NSMutableArray array];
    [summary addObject:plan.kind];
    if (plan.hasBindPointer) [summary addObject:[NSString stringWithFormat:@"%lu import slot(s)", (unsigned long)imports.count]];
    if (plan.hasXrefs) [summary addObject:[NSString stringWithFormat:@"%lu xref(s)", (unsigned long)xrefs.count]];
    if (plan.knownSize) [summary addObject:[NSString stringWithFormat:@"size %lu", (unsigned long)plan.knownSize]];
    if (plan.appliedStrategy.length) [summary addObject:[NSString stringWithFormat:@"applied %@", plan.appliedStrategy]];
    plan.summary = summary.count ? [summary componentsJoinedByString:@" · "] : @"runtime resolved";

    NSString *firstConsumer = nil;
    for (NSDictionary *xref in xrefs) { if ([xref[@"consumer"] isKindOfClass:NSString.class]) { firstConsumer = xref[@"consumer"]; break; } }
    if (firstConsumer.length) plan.consumerSummary = [NSString stringWithFormat:@"Likely consumer: %@", firstConsumer];
    else if (objcSelectorName.length) plan.consumerSummary = @"ObjC dispatch consumer: selector is hook target.";
    else if (isFunction) plan.consumerSummary = @"Function is the consumer entry; use typed ABI only.";
    else plan.consumerSummary = @"Consumer not confirmed yet; observe or use bind/xref detail.";

    if (objcSelectorName.length) {
        plan.strategySummary = @"Resolved strategy: ObjC BOOL getter override via runtime browser cache.";
        plan.safetySummary = @"Safe: MSHookMessageEx/ObjC dispatch, no C stub, no DATA byte patch.";
    } else if (isFunction && [SCICSymbolStub isForceableSymbol:symbol]) {
        plan.strategySummary = @"Resolved strategy: BOOL function fishhook with cached force value.";
        plan.safetySummary = @"Safe only for validated ABI symbols; no NSUserDefaults in C hot path.";
    } else if (isFunction && [SCICSymbolStub isTypedForceableSymbol:symbol]) {
        plan.strategySummary = [NSString stringWithFormat:@"Resolved strategy: typed %@ function fishhook.", [SCICSymbolStub returnKindForSymbol:symbol] ?: @"value"];
        plan.safetySummary = @"Safe only with ABI-specific return register/ownership handling.";
    } else if (isFunction && [SCICSymbolStub isHookableSymbol:symbol]) {
        plan.strategySummary = @"Resolved strategy: observe action/function calls; no blind return stub.";
        plan.safetySummary = @"Action/registration functions are pass-through observed only.";
    } else if (isData && SCICLooksParamDescriptor(symbol)) {
        if (plan.hasXrefs || SCICKnownSafeParamDescriptorName(symbol)) plan.strategySummary = @"Resolved strategy: MobileConfig descriptor filter via typed reader.";
        else plan.strategySummary = @"Candidate strategy: capture/xref first, then MobileConfig reader filter.";
        plan.safetySummary = @"DATA is not patched as code. Force applies only when the reader receives this descriptor pointer.";
    } else if (isData && SCICLooksNSStringConstant(symbol, section)) {
        plan.strategySummary = plan.hasBindPointer ? @"Resolved strategy: imported NSString pointer rebind." : @"No import pointer found; string constant is consumer-only/patch unsafe.";
        plan.safetySummary = @"String rebind uses a persistent NSString replacement. It does not coerce NSString/schema DATA into BOOL.";
    } else if (isData && plan.dataPatchable) {
        plan.strategySummary = @"Resolved strategy: bounded DATA byte patch is available.";
        plan.safetySummary = @"Patch uses vm_protect + original-byte snapshot; only for known-size non-code DATA.";
    } else if (isData && plan.hasBindPointer) {
        plan.strategySummary = @"Import pointer exists, but replacement layout is unknown.";
        plan.safetySummary = @"Blocked until a compatible replacement object/descriptor is known.";
    } else {
        NSString *r = [SCICSymbolStub blacklistReasonForSymbol:symbol] ?: [SCICSymbolStub notHookableReasonForSymbol:symbol];
        plan.strategySummary = r.length ? r : @"No safe automatic patch strategy resolved.";
        plan.safetySummary = @"Observe/log or add a dedicated ABI/layout profile first.";
    }
    return plan;
}

+ (NSDictionary<NSString *,id> *)persistedPatchForSymbol:(NSString *)symbol {
    id v = SCICPatchPlanPrefs()[symbol ?: @""];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

+ (BOOL)applyBoolForce:(NSNumber *)value
             forSymbol:(NSString *)symbol
              strategy:(NSString *)strategy
                  plan:(SCICPatchPlan *)plan
         objcClassName:(NSString *)objcClassName
      objcSelectorName:(NSString *)objcSelectorName
     objcIsClassMethod:(BOOL)objcIsClassMethod {
    if (![symbol isKindOfClass:NSString.class] || !symbol.length) return NO;
    BOOL ok = NO;
    if ([strategy isEqualToString:SCICPatchStrategyObjCBool]) {
        if (!objcClassName.length || !objcSelectorName.length) return NO;
        [SCISymbolBrowserEngine setOverride:value forClass:objcClassName selector:objcSelectorName isClassMethod:objcIsClassMethod];
        ok = YES;
    } else if ([strategy isEqualToString:SCICPatchStrategyFunctionBool]) {
        ok = [SCICSymbolStub setForce:value forSymbol:symbol];
    } else if ([strategy isEqualToString:SCICPatchStrategyDataReaderBool]) {
        if (!(SCICKnownSafeParamDescriptorName(symbol) || (plan && plan.hasXrefs))) return NO;
        ok = [SCICSymbolStub setParamDescriptorForce:value forSymbol:symbol];
    }
    if (ok) {
        if (value) SCICSetPatchPlanPref(symbol, @{ @"strategy": strategy ?: @"", @"value": value, @"image": plan.image ?: @"", @"section": plan.section ?: @"" });
        else SCICSetPatchPlanPref(symbol, nil);
    }
    return ok;
}

+ (BOOL)applyTypedValue:(id)value returnKind:(NSString *)returnKind forSymbol:(NSString *)symbol plan:(SCICPatchPlan *)plan {
    BOOL ok = [SCICSymbolStub setTypedForceValue:value returnKind:returnKind forSymbol:symbol];
    if (ok) {
        if (value) SCICSetPatchPlanPref(symbol, @{ @"strategy": SCICPatchStrategyFunctionTyped, @"kind": returnKind ?: @"", @"value": value, @"image": plan.image ?: @"", @"section": plan.section ?: @"" });
        else SCICSetPatchPlanPref(symbol, nil);
    }
    return ok;
}

+ (BOOL)applyStringRebind:(NSString *)replacement forSymbol:(NSString *)symbol plan:(SCICPatchPlan *)plan {
    if (!plan.hasBindPointer) return NO;
    BOOL ok = SCICInstallDataStringRebind(symbol, replacement ?: @"");
    if (ok) SCICSetPatchPlanPref(symbol, @{ @"strategy": SCICPatchStrategyDataStringRebind, @"value": replacement ?: @"", @"image": plan.image ?: @"", @"section": plan.section ?: @"" });
    return ok;
}

+ (BOOL)applyHexPatch:(NSString *)hexString forSymbol:(NSString *)symbol address:(uintptr_t)address maxSize:(NSUInteger)maxSize plan:(SCICPatchPlan *)plan error:(NSString **)errorOut {
    NSData *patch = SCICDataFromHex(hexString);
    if (!patch.length) { if (errorOut) *errorOut = @"hex inválido"; return NO; }
    if (!maxSize || patch.length > maxSize || patch.length > 64) { if (errorOut) *errorOut = @"patch maior que o tamanho conhecido"; return NO; }
    NSDictionary *existing = [self persistedPatchForSymbol:symbol];
    NSData *original = nil;
    NSString *err = nil;
    kern_return_t kr = SCICPatchMemory(address, patch, &original, &err);
    if (kr != KERN_SUCCESS) { if (errorOut) *errorOut = err ?: @"vm patch falhou"; return NO; }
    NSString *origHex = [existing[@"original"] isKindOfClass:NSString.class] ? existing[@"original"] : SCICHexFromData(original);
    SCICSetPatchPlanPref(symbol, @{ @"strategy": SCICPatchStrategyDataBytesPatch, @"value": SCICHexFromData(patch), @"original": origHex ?: @"", @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address], @"size": @(patch.length), @"image": plan.image ?: @"", @"section": plan.section ?: @"" });
    return YES;
}

+ (BOOL)observeSymbol:(NSString *)symbol plan:(SCICPatchPlan *)plan {
    BOOL paramLike = SCICLooksParamDescriptor(symbol);
    BOOL ok = paramLike ? [SCICSymbolStub setParamDescriptorObserve:YES forSymbol:symbol] : [SCICSymbolStub setObserve:YES forSymbol:symbol];
    if (ok) {
        NSMutableDictionary *entry = [@{ @"strategy": SCICPatchStrategyObserve, @"value": @YES, @"image": plan.image ?: @"", @"section": plan.section ?: @"" } mutableCopy];
        if (paramLike) entry[@"reader"] = @"IGMobileConfigBooleanValueForInternalUse";
        SCICSetPatchPlanPref(symbol, entry);
    }
    return ok;
}

+ (void)clearPatchForSymbol:(NSString *)symbol address:(uintptr_t)address {
    NSDictionary *p = [self persistedPatchForSymbol:symbol];
    NSString *strategy = [p[@"strategy"] isKindOfClass:NSString.class] ? p[@"strategy"] : nil;
    if ([strategy isEqualToString:SCICPatchStrategyFunctionBool]) [SCICSymbolStub setForce:nil forSymbol:symbol];
    else if ([strategy isEqualToString:SCICPatchStrategyFunctionTyped]) [SCICSymbolStub setTypedForceValue:nil returnKind:p[@"kind"] ?: @"" forSymbol:symbol];
    else if ([strategy isEqualToString:SCICPatchStrategyDataReaderBool]) [SCICSymbolStub setParamDescriptorForce:nil forSymbol:symbol];
    else if ([strategy isEqualToString:SCICPatchStrategyObserve]) {
        if (SCICLooksParamDescriptor(symbol)) [SCICSymbolStub setParamDescriptorObserve:NO forSymbol:symbol];
        else [SCICSymbolStub setObserve:NO forSymbol:symbol];
    }
    else if ([strategy isEqualToString:SCICPatchStrategyDataBytesPatch]) {
        NSString *orig = [p[@"original"] isKindOfClass:NSString.class] ? p[@"original"] : nil;
        NSData *data = SCICDataFromHex(orig);
        if (data.length && address) { NSString *err = nil; SCICPatchMemory(address, data, NULL, &err); }
    }
    SCICSetPatchPlanPref(symbol, nil);
}

+ (void)reinstallPersistedPatchPlans {
    NSDictionary *plans = SCICPatchPlanPrefs();
    if (!plans.count) return;
    for (NSString *symbol in plans.allKeys) {
        NSDictionary *p = [plans[symbol] isKindOfClass:NSDictionary.class] ? plans[symbol] : nil;
        NSString *strategy = [p[@"strategy"] isKindOfClass:NSString.class] ? p[@"strategy"] : nil;
        id value = p[@"value"];
        if (!strategy.length) continue;
        if ([strategy isEqualToString:SCICPatchStrategyFunctionBool]) {
            if ([value isKindOfClass:NSNumber.class]) [SCICSymbolStub setForce:value forSymbol:symbol];
        } else if ([strategy isEqualToString:SCICPatchStrategyFunctionTyped]) {
            [SCICSymbolStub setTypedForceValue:value returnKind:p[@"kind"] ?: [SCICSymbolStub returnKindForSymbol:symbol] ?: @"" forSymbol:symbol];
        } else if ([strategy isEqualToString:SCICPatchStrategyDataReaderBool]) {
            if ([value isKindOfClass:NSNumber.class]) [SCICSymbolStub setParamDescriptorForce:value forSymbol:symbol];
        } else if ([strategy isEqualToString:SCICPatchStrategyDataStringRebind]) {
            if ([value isKindOfClass:NSString.class]) SCICInstallDataStringRebind(symbol, value);
        } else if ([strategy isEqualToString:SCICPatchStrategyDataBytesPatch]) {
            NSString *hex = [value isKindOfClass:NSString.class] ? value : nil;
            NSString *addrString = [p[@"address"] isKindOfClass:NSString.class] ? p[@"address"] : nil;
            uintptr_t addr = 0;
            if (addrString.length) { unsigned long long tmp = 0; [[NSScanner scannerWithString:addrString] scanHexLongLong:&tmp]; addr = (uintptr_t)tmp; }
            if (!addr) { void *rt = NULL; if (SCICRuntimeResolveSymbol(symbol, &rt)) addr = (uintptr_t)rt; }
            NSData *patch = SCICDataFromHex(hex);
            if (addr && patch.length <= 64) { NSString *err = nil; SCICPatchMemory(addr, patch, NULL, &err); }
        } else if ([strategy isEqualToString:SCICPatchStrategyObserve]) {
            if (SCICLooksParamDescriptor(symbol)) [SCICSymbolStub setParamDescriptorObserve:YES forSymbol:symbol];
            else [SCICSymbolStub setObserve:YES forSymbol:symbol];
        }
    }
}

+ (NSString *)stateSummaryForSymbol:(NSString *)symbol {
    NSMutableArray *bits = [NSMutableArray array];
    NSDictionary *p = [self persistedPatchForSymbol:symbol];
    if (p) [bits addObject:[NSString stringWithFormat:@"persisted %@", p[@"strategy"] ?: @"patch"]];
    if ([SCICSymbolStub hookInstalledForSymbol:symbol]) [bits addObject:[NSString stringWithFormat:@"installed hits=%lu", (unsigned long)[SCICSymbolStub callCountForSymbol:symbol]]];
    NSUInteger paramHits = [SCICSymbolStub paramDescriptorCallCountForSymbol:symbol];
    if (paramHits) [bits addObject:[NSString stringWithFormat:@"param hits=%lu", (unsigned long)paramHits]];
    NSNumber *b = [SCICSymbolStub observedValueForSymbol:symbol];
    if (b) [bits addObject:[NSString stringWithFormat:@"observed=%@", b.boolValue?@"YES":@"NO"]];
    id typed = [SCICSymbolStub observedTypedValueForSymbol:symbol];
    if (typed) [bits addObject:[NSString stringWithFormat:@"observed=%@", typed]];
    return bits.count ? [bits componentsJoinedByString:@" · "] : @"not applied";
}

+ (NSString *)reportForPlan:(SCICPatchPlan *)plan {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@\n\n", plan.symbol ?: @""];
    [s appendFormat:@"Image: %@\nSection: %@\nKind: %@\nSummary: %@\n\n", plan.image ?: @"", plan.section ?: @"", plan.kind ?: @"", plan.summary ?: @""];
    [s appendFormat:@"Consumer\n%@\n\nStrategy\n%@\n\nSafety\n%@\n\n", plan.consumerSummary ?: @"", plan.strategySummary ?: @"", plan.safetySummary ?: @""];
    [s appendString:@"Bind/import pointers\n"];
    if (plan.bindPointerSummary.count) for (NSString *line in plan.bindPointerSummary) [s appendFormat:@"- %@\n", line]; else [s appendString:@"- none\n"];
    [s appendString:@"\nXrefs/callsites\n"];
    if (plan.xrefSummary.count) for (NSString *line in plan.xrefSummary) [s appendFormat:@"- %@\n", line]; else [s appendString:@"- none confirmed\n"];
    [s appendFormat:@"\nState\n%@\n", [self stateSummaryForSymbol:plan.symbol]];
    return s.copy;
}

@end
