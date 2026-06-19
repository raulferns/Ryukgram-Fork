// SCIRuntimeXrefScanner.m
#import "SCIRuntimeXrefScanner.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdint.h>
#import <string.h>

#define XLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] Xref " fmt, ##__VA_ARGS__)

@implementation SCIXrefHit
@end

#pragma mark - ARM64 decoders

static inline int sci_decode_adrp(uint32_t instr, uint64_t pc, int *rd, uint64_t *page) {
    if ((instr & 0x9F000000u) != 0x90000000u) return 0;
    *rd = (int)(instr & 0x1F);
    uint32_t immlo = (instr >> 29) & 0x3;
    uint32_t immhi = (instr >> 5) & 0x7FFFF;
    int64_t imm = (int64_t)((immhi << 2) | immlo);
    if (imm & (1LL << 20)) imm -= (1LL << 21);
    *page = (pc & ~0xFFFULL) + (uint64_t)(imm << 12);
    return 1;
}

static inline int sci_decode_adr(uint32_t instr, uint64_t pc, int *rd, uint64_t *addr) {
    if ((instr & 0x9F000000u) != 0x10000000u) return 0;
    *rd = (int)(instr & 0x1F);
    uint32_t immlo = (instr >> 29) & 0x3;
    uint32_t immhi = (instr >> 5) & 0x7FFFF;
    int64_t imm = (int64_t)((immhi << 2) | immlo);
    if (imm & (1LL << 20)) imm -= (1LL << 21);
    *addr = pc + (uint64_t)imm;
    return 1;
}

static inline int sci_decode_add_imm(uint32_t instr, int *rd, int *rn, uint64_t *imm) {
    if ((instr & 0xFF800000u) != 0x91000000u) return 0;
    *rd = (int)(instr & 0x1F);
    *rn = (int)((instr >> 5) & 0x1F);
    uint64_t imm12 = (instr >> 10) & 0xFFF;
    if ((instr >> 22) & 1) imm12 <<= 12;
    *imm = imm12;
    return 1;
}

static inline int sci_decode_ldr_imm64(uint32_t instr, int *rt, int *rn, uint64_t *imm) {
    if ((instr & 0xFFC00000u) != 0xF9400000u) return 0;
    *rt = (int)(instr & 0x1F);
    *rn = (int)((instr >> 5) & 0x1F);
    *imm = ((uint64_t)((instr >> 10) & 0xFFF)) << 3;
    return 1;
}

static inline int sci_decode_bl(uint32_t instr, uint64_t pc, uint64_t *target) {
    if ((instr & 0xFC000000u) != 0x94000000u) return 0;
    int64_t imm26 = instr & 0x3FFFFFF;
    if (imm26 & (1LL << 25)) imm26 -= (1LL << 26);
    *target = pc + (uint64_t)(imm26 << 2);
    return 1;
}

static inline int sci_decode_blr(uint32_t instr, int *rn) {
    if ((instr & 0xFFFFFC1Fu) != 0xD63F0000u) return 0;
    *rn = (int)((instr >> 5) & 0x1F);
    return 1;
}

static inline int sci_decode_br(uint32_t instr, int *rn) {
    if ((instr & 0xFFFFFC1Fu) != 0xD61F0000u) return 0;
    *rn = (int)((instr >> 5) & 0x1F);
    return 1;
}

#pragma mark - Images

static BOOL sci_is_scope_image(const char *path) {
    if (!path) return NO;
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    return strcmp(base, "Instagram") == 0 || strstr(path, "/FBSharedFramework") != NULL;
}

static NSString *sci_short_image_name(const char *path) {
    if (!path) return @"?";
    const char *slash = strrchr(path, '/');
    return [NSString stringWithUTF8String:slash ? slash + 1 : path];
}

static BOOL sci_text_bounds_for_index(uint32_t i, const uint32_t **outCode, uint64_t *outBase, size_t *outCount, NSString **outName) {
    const char *path = _dyld_get_image_name(i);
    const struct mach_header *raw = _dyld_get_image_header(i);
    if (!path || !raw || raw->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const struct section_64 *sect = getsectbynamefromheader_64(mh, "__TEXT", "__text");
    if (!sect || sect->size < 8) return NO;
    uint64_t textStart = (uint64_t)sect->addr + (uint64_t)slide;
    if (outCode) *outCode = (const uint32_t *)(uintptr_t)textStart;
    if (outBase) *outBase = textStart;
    if (outCount) *outCount = (size_t)(sect->size / 4);
    if (outName) *outName = sci_short_image_name(path);
    return YES;
}

static BOOL sci_section_bounds_for_index(uint32_t i, const char *segname, const char *sectname, const uint32_t **outCode, uint64_t *outBase, size_t *outCount) {
    const struct mach_header *raw = _dyld_get_image_header(i);
    if (!raw || raw->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const struct section_64 *sect = getsectbynamefromheader_64(mh, segname, sectname);
    if (!sect || sect->size < 4) return NO;
    uint64_t start = (uint64_t)sect->addr + (uint64_t)slide;
    if (outCode) *outCode = (const uint32_t *)(uintptr_t)start;
    if (outBase) *outBase = start;
    if (outCount) *outCount = (size_t)(sect->size / 4);
    return YES;
}

static BOOL sci_address_is_in_text(uintptr_t address) {
    if (!address) return NO;
    Dl_info info; memset(&info, 0, sizeof(info));
    if (!dladdr((const void *)address, &info) || !info.dli_fbase) return NO;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if ((const void *)_dyld_get_image_header(i) != info.dli_fbase) continue;
        const uint32_t *code = NULL; uint64_t base = 0; size_t count = 0;
        if (!sci_text_bounds_for_index(i, &code, &base, &count, NULL)) return NO;
        uint64_t end = base + count * 4;
        return ((uint64_t)address >= base && (uint64_t)address < end);
    }
    return NO;
}

static BOOL sci_safe_read_ptr(uint64_t address, uint64_t *outValue) {
    if (!address || !outValue) return NO;
    vm_size_t outSize = 0;
    uint64_t value = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address, (vm_size_t)sizeof(value), (vm_address_t)&value, &outSize);
    if (kr != KERN_SUCCESS || outSize != sizeof(value)) return NO;
    *outValue = value;
    return YES;
}

#pragma mark - Display

static NSString *sci_describe_address(uintptr_t address) {
    if (!address) return @"(null)";
    Dl_info info; memset(&info, 0, sizeof(info));
    if (dladdr((const void *)address, &info) == 0) return [NSString stringWithFormat:@"0x%lx", (unsigned long)address];
    const char *path = info.dli_fname ?: "";
    NSString *img = sci_short_image_name(path);
    if (info.dli_sname) {
        const char *s = info.dli_sname;
        NSString *sym = [NSString stringWithUTF8String:(s[0] == '_') ? s + 1 : s];
        uintptr_t off = address - (uintptr_t)info.dli_saddr;
        return off ? [NSString stringWithFormat:@"%@`%@+0x%lx", img, sym, (unsigned long)off]
                   : [NSString stringWithFormat:@"%@`%@", img, sym];
    }
    uintptr_t off = address - (uintptr_t)info.dli_fbase;
    return [NSString stringWithFormat:@"%@+0x%lx", img, (unsigned long)off];
}

static SCIXrefHit *sci_make_hit(uint64_t loadPC, uint64_t callPC, uint64_t callee, NSString *image, NSString *kind) {
    SCIXrefHit *h = [SCIXrefHit new];
    h.loadPC = (uintptr_t)loadPC;
    h.callPC = (uintptr_t)callPC;
    h.calleeAddress = (uintptr_t)callee;
    h.image = image;
    h.referenceKind = kind;
    if (callee) {
        Dl_info ci; memset(&ci, 0, sizeof(ci));
        if (dladdr((const void *)(uintptr_t)callee, &ci) && ci.dli_sname) {
            const char *cs = ci.dli_sname;
            h.calleeSymbol = [NSString stringWithUTF8String:(cs[0] == '_') ? cs + 1 : cs];
        }
    }
    Dl_info kr; memset(&kr, 0, sizeof(kr));
    if (dladdr((const void *)(uintptr_t)callPC, &kr) && kr.dli_sname) {
        const char *ks = kr.dli_sname;
        h.callerSymbol = [NSString stringWithUTF8String:(ks[0] == '_') ? ks + 1 : ks];
    }
    h.detail = [NSString stringWithFormat:@"%@ · caller %@ · call %@ · load %@",
                kind ?: @"xref",
                h.callerSymbol ?: sci_describe_address((uintptr_t)callPC),
                sci_describe_address((uintptr_t)callPC),
                sci_describe_address((uintptr_t)loadPC)];
    return h;
}


static NSSet<NSNumber *> *sci_import_stub_aliases_for_target(uint32_t imageIndex, uint64_t target) {
    NSMutableSet<NSNumber *> *aliases = [NSMutableSet set];
    const char *sections[] = { "__stubs", "__auth_stubs", "__text" };
    for (unsigned si = 0; si < 3; si++) {
        const uint32_t *code = NULL; uint64_t base = 0; size_t count = 0;
        if (!sci_section_bounds_for_index(imageIndex, "__TEXT", sections[si], &code, &base, &count)) continue;
        for (size_t i = 0; i + 2 < count; i++) {
            uint64_t pc = base + i * 4;
            int rd = -1; uint64_t page = 0;
            if (!sci_decode_adrp(code[i], pc, &rd, &page)) continue;
            int lrt = -1, lrn = -1; uint64_t limm = 0;
            if (!sci_decode_ldr_imm64(code[i + 1], &lrt, &lrn, &limm) || lrn != rd) continue;
            uint64_t slot = page + limm, pointed = 0;
            if (!sci_safe_read_ptr(slot, &pointed) || pointed != target) continue;
            for (size_t j = i + 2; j < count && j < i + 7; j++) {
                int brn = -1;
                if ((sci_decode_br(code[j], &brn) || sci_decode_blr(code[j], &brn)) && brn == lrt) {
                    [aliases addObject:@(pc)];
                    break;
                }
            }
        }
    }
    return aliases.copy;
}

#pragma mark - Scan core

static NSArray<SCIXrefHit *> *sci_scan_text(const uint32_t *code, uint64_t base, size_t count,
                                            uint64_t target, BOOL targetIsCode, NSSet<NSNumber *> *codeAliases, uint64_t budget,
                                            int maxHits, NSString *image, BOOL *ioBudgetExhausted,
                                            NSMutableSet<NSString *> *dedupe) {
    NSMutableArray<SCIXrefHit *> *hits = [NSMutableArray array];
    if (!code || count < 2) return hits;
    uint64_t scanned = 0;
    uint64_t realBudget = budget ?: [SCIRuntimeXrefScanner defaultBudget];

    for (size_t i = 0; i + 1 < count; i++) {
        if (++scanned > realBudget) { if (ioBudgetExhausted) *ioBudgetExhausted = YES; break; }
        uint64_t pc = base + i * 4;

        // Function xref: direct call to the target address. This is the common
        // pattern for TEXT symbols; DATA scanners will never see it.
        uint64_t blTarget = 0;
        if (targetIsCode && sci_decode_bl(code[i], pc, &blTarget) && (blTarget == target || [codeAliases containsObject:@(blTarget)])) {
            BOOL viaStub = (blTarget != target);
            NSString *key = [NSString stringWithFormat:@"%llx:%llx:direct", (unsigned long long)pc, (unsigned long long)blTarget];
            if (![dedupe containsObject:key]) {
                [dedupe addObject:key];
                SCIXrefHit *h = sci_make_hit(pc, pc, target, image, viaStub ? @"direct-call-via-import-stub" : @"direct-call");
                if (viaStub) h.detail = [NSString stringWithFormat:@"direct-call-via-import-stub · stub %@ · caller %@", sci_describe_address((uintptr_t)blTarget), h.callerSymbol ?: @"?"];
                [hits addObject:h];
            }
            if (maxHits > 0 && (int)hits.count >= maxHits) break;
            continue;
        }

        int loadedReg = -1;
        uint64_t resolvedAddress = 0;
        NSString *kind = nil;

        int rd = -1; uint64_t page = 0;
        if (sci_decode_adrp(code[i], pc, &rd, &page)) {
            int ard = -1, arn = -1; uint64_t aimm = 0;
            if (i + 1 < count && sci_decode_add_imm(code[i + 1], &ard, &arn, &aimm) && arn == rd) {
                uint64_t addr = page + aimm;
                if (addr == target) { resolvedAddress = target; loadedReg = ard; kind = @"address-load"; }
            } else {
                int lrt = -1, lrn = -1; uint64_t limm = 0;
                if (i + 1 < count && sci_decode_ldr_imm64(code[i + 1], &lrt, &lrn, &limm) && lrn == rd) {
                    uint64_t slot = page + limm;
                    uint64_t pointed = 0;
                    if (slot == target) { resolvedAddress = target; loadedReg = lrt; kind = @"slot-address-load"; }
                    else if (sci_safe_read_ptr(slot, &pointed) && pointed == target) { resolvedAddress = target; loadedReg = lrt; kind = @"got-load"; }
                }
            }
        }

        if (!resolvedAddress) {
            int adrReg = -1; uint64_t adrAddr = 0;
            if (sci_decode_adr(code[i], pc, &adrReg, &adrAddr) && adrAddr == target) {
                resolvedAddress = target; loadedReg = adrReg; kind = @"adr-load";
            }
        }
        if (resolvedAddress != target) continue;

        // For DATA refs, the consumer is usually the next BL reader. For function
        // pointers, the consumer may be BLR loadedReg. Scan a short local window.
        for (size_t j = i + 1; j < count && j < i + 32; j++) {
            uint64_t callPC = base + j * 4, callee = 0;
            if (sci_decode_bl(code[j], callPC, &callee)) {
                NSString *key = [NSString stringWithFormat:@"%llx:%llx:%@", (unsigned long long)callPC, (unsigned long long)callee, kind ?: @""];
                if (![dedupe containsObject:key]) {
                    [dedupe addObject:key];
                    [hits addObject:sci_make_hit(pc, callPC, callee, image, kind ?: @"address-load")];
                }
                break;
            }
            int rn = -1;
            if (sci_decode_blr(code[j], &rn)) {
                if (loadedReg >= 0 && rn != loadedReg) continue;
                NSString *key = [NSString stringWithFormat:@"%llx:%d:%@", (unsigned long long)callPC, rn, kind ?: @""];
                if (![dedupe containsObject:key]) {
                    [dedupe addObject:key];
                    SCIXrefHit *h = sci_make_hit(pc, callPC, targetIsCode ? target : 0, image, @"indirect-call");
                    if (!h.calleeSymbol) h.calleeSymbol = [NSString stringWithFormat:@"blr x%d", rn];
                    [hits addObject:h];
                }
                break;
            }
        }
        if (maxHits > 0 && (int)hits.count >= maxHits) break;
    }
    return hits;
}

@implementation SCIRuntimeXrefScanner

+ (NSString *)describeAddress:(uintptr_t)address { return sci_describe_address(address); }

+ (uint64_t)defaultBudget { return 9000000ULL; }

+ (NSArray<SCIXrefHit *> *)consumersOfAddress:(uintptr_t)targetAddress
                                imageSubstring:(NSString *)imageSubstring
                                        budget:(uint64_t)budget
                                       maxHits:(int)maxHits
                                     hitBudget:(BOOL *)outHitBudget {
    if (!targetAddress) { if (outHitBudget) *outHitBudget = NO; return @[]; }
    BOOL budgetExhausted = NO;
    BOOL targetIsCode = sci_address_is_in_text(targetAddress);
    NSMutableArray<SCIXrefHit *> *all = [NSMutableArray array];
    NSMutableSet<NSString *> *dedupe = [NSMutableSet set];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        if (imageSubstring.length) {
            if (strstr(path, imageSubstring.UTF8String) == NULL) continue;
        } else if (!sci_is_scope_image(path)) {
            continue;
        }
        const uint32_t *code = NULL; uint64_t base = 0; size_t count = 0; NSString *name = nil;
        if (!sci_text_bounds_for_index(i, &code, &base, &count, &name)) continue;
        XLOG("scan target=0x%lx targetIsCode=%d image=%{public}s count=%zu budget=%llu",
             (unsigned long)targetAddress, targetIsCode, name.UTF8String ?: "?", count, budget);
        int remaining = maxHits > 0 ? (maxHits - (int)all.count) : 0;
        NSSet<NSNumber *> *aliases = targetIsCode ? sci_import_stub_aliases_for_target(i, (uint64_t)targetAddress) : [NSSet set];
        NSArray *hits = sci_scan_text(code, base, count, (uint64_t)targetAddress, targetIsCode, aliases,
                                      budget ?: [self defaultBudget], remaining, name, &budgetExhausted, dedupe);
        [all addObjectsFromArray:hits];
        if (maxHits > 0 && (int)all.count >= maxHits) break;
    }
    if (outHitBudget) *outHitBudget = budgetExhausted;
    return all.copy;
}

+ (void)findConsumersOfAddress:(uintptr_t)targetAddress
                 imageSubstring:(NSString *)imageSubstring
                         budget:(uint64_t)budget
                        maxHits:(int)maxHits
                     completion:(void (^)(NSArray<SCIXrefHit *> *, BOOL))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL hitBudget = NO;
        NSArray<SCIXrefHit *> *hits = [self consumersOfAddress:targetAddress
                                                imageSubstring:imageSubstring
                                                        budget:budget
                                                       maxHits:maxHits
                                                     hitBudget:&hitBudget];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(hits, hitBudget); });
    });
}

@end
