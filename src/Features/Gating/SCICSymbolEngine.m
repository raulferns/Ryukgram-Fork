// SCICSymbolEngine.m
// Runtime browser for FBSharedFramework C symbols.
//
// This engine enumerates the whole FBSharedFramework export symbol table at UI
// time, but it only hooks known-safe bool-reader profiles. The previous generic
// wrapper was unsafe: a C symbol name does not encode ABI, and calling arbitrary
// exports as bool(void *, ...) can corrupt return values or crash. Data/key
// symbols such as ig_* MobileConfig names remain searchable, but they are not
// function-hookable here.

#import "SCICSymbolEngine.h"
#import "../../Utils.h"
#import "../../../modules/fishhook/fishhook.h"
#import "../MobileConfig/SCIMobileConfigRuntime.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <os/log.h>
#import <string.h>
#import <stdlib.h>

#define CLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] FBSharedCSym " fmt,##__VA_ARGS__)

static NSString *const kCOverridesKey = @"sci_c_symbol_overrides"; // { "C#name": @(YES/NO) }
static NSString *const kCObserveKey   = @"sci_c_symbol_observe";   // { "C#name": @(YES) }
static NSString *const kCKeyOverridesKey = @"sci_c_symbol_key_overrides"; // { "C#name": { value, paramIDs } }
static NSString *const kCMasterKey    = @"sci_c_symbol_force_enabled";

static NSString *const kProfileNone        = @"none";
static NSString *const kProfileBoolObserve = @"bool-observe";
static NSString *const kProfileBoolForce   = @"bool-force";
static NSString *const kProfileMCKeyForce   = @"mc-key-force";

#define MAX_C_HOOKS 64

typedef struct {
    const char *name;
    void *orig;
    atomic_int force;      // -1 none, 0 NO, 1 YES
    atomic_uint hits;
    atomic_schar observed; // -1 unknown, 0 NO, 1 YES
    bool installed;
} SCIHookSlot;

static SCIHookSlot g_slots[MAX_C_HOOKS];
static int g_slot_count = 0;

static int slotIndexForName(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < g_slot_count; i++) {
        if (g_slots[i].name && strcmp(g_slots[i].name, name) == 0) return i;
    }
    return -1;
}

static bool scicHookCall(int idx, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    if (idx < 0 || idx >= MAX_C_HOOKS) return false;
    SCIHookSlot *slot = &g_slots[idx];
    atomic_fetch_add(&slot->hits, 1);

    bool real = false;
    if (slot->orig) {
        // Only installed for known bool-return profiles. Extra pointer args are
        // intentionally used for known reader-style functions only; arbitrary
        // symbols never reach this wrapper.
        bool (*orig)(void *, void *, void *, void *, void *, void *, void *, void *) = (void *)slot->orig;
        real = orig(a0, a1, a2, a3, a4, a5, a6, a7);
        atomic_store(&slot->observed, real ? 1 : 0);
    }

    int forced = atomic_load(&slot->force);
    return forced < 0 ? real : (forced != 0);
}

static bool scic_repl_0(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(0, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_1(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(1, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_2(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(2, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_3(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(3, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_4(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(4, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_5(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(5, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_6(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(6, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_7(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(7, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_8(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(8, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_9(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(9, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_10(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(10, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_11(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(11, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_12(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(12, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_13(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(13, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_14(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(14, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_15(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(15, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_16(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(16, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_17(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(17, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_18(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(18, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_19(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(19, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_20(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(20, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_21(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(21, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_22(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(22, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_23(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(23, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_24(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(24, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_25(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(25, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_26(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(26, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_27(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(27, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_28(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(28, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_29(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(29, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_30(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(30, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_31(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(31, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_32(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(32, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_33(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(33, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_34(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(34, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_35(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(35, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_36(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(36, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_37(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(37, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_38(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(38, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_39(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(39, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_40(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(40, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_41(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(41, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_42(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(42, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_43(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(43, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_44(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(44, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_45(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(45, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_46(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(46, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_47(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(47, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_48(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(48, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_49(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(49, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_50(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(50, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_51(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(51, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_52(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(52, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_53(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(53, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_54(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(54, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_55(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(55, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_56(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(56, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_57(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(57, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_58(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(58, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_59(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(59, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_60(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(60, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_61(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(61, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_62(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(62, a0, a1, a2, a3, a4, a5, a6, a7); }
static bool scic_repl_63(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) { return scicHookCall(63, a0, a1, a2, a3, a4, a5, a6, a7); }

static void *g_replacements[MAX_C_HOOKS] = {
    (void *)scic_repl_0,
    (void *)scic_repl_1,
    (void *)scic_repl_2,
    (void *)scic_repl_3,
    (void *)scic_repl_4,
    (void *)scic_repl_5,
    (void *)scic_repl_6,
    (void *)scic_repl_7,
    (void *)scic_repl_8,
    (void *)scic_repl_9,
    (void *)scic_repl_10,
    (void *)scic_repl_11,
    (void *)scic_repl_12,
    (void *)scic_repl_13,
    (void *)scic_repl_14,
    (void *)scic_repl_15,
    (void *)scic_repl_16,
    (void *)scic_repl_17,
    (void *)scic_repl_18,
    (void *)scic_repl_19,
    (void *)scic_repl_20,
    (void *)scic_repl_21,
    (void *)scic_repl_22,
    (void *)scic_repl_23,
    (void *)scic_repl_24,
    (void *)scic_repl_25,
    (void *)scic_repl_26,
    (void *)scic_repl_27,
    (void *)scic_repl_28,
    (void *)scic_repl_29,
    (void *)scic_repl_30,
    (void *)scic_repl_31,
    (void *)scic_repl_32,
    (void *)scic_repl_33,
    (void *)scic_repl_34,
    (void *)scic_repl_35,
    (void *)scic_repl_36,
    (void *)scic_repl_37,
    (void *)scic_repl_38,
    (void *)scic_repl_39,
    (void *)scic_repl_40,
    (void *)scic_repl_41,
    (void *)scic_repl_42,
    (void *)scic_repl_43,
    (void *)scic_repl_44,
    (void *)scic_repl_45,
    (void *)scic_repl_46,
    (void *)scic_repl_47,
    (void *)scic_repl_48,
    (void *)scic_repl_49,
    (void *)scic_repl_50,
    (void *)scic_repl_51,
    (void *)scic_repl_52,
    (void *)scic_repl_53,
    (void *)scic_repl_54,
    (void *)scic_repl_55,
    (void *)scic_repl_56,
    (void *)scic_repl_57,
    (void *)scic_repl_58,
    (void *)scic_repl_59,
    (void *)scic_repl_60,
    (void *)scic_repl_61,
    (void *)scic_repl_62,
    (void *)scic_repl_63
};

typedef struct {
    char segname[17];
    char sectname[17];
    uint32_t flags;
} SCISectionInfo;

static int SCICompareU64(const void *a, const void *b) {
    uint64_t va = *(const uint64_t *)a;
    uint64_t vb = *(const uint64_t *)b;
    return (va > vb) - (va < vb);
}

static uint64_t SCINextAddressAfter(uint64_t *addrs, uint32_t count, uint64_t value) {
    if (!addrs || !count) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (addrs[i] > value) return addrs[i];
    }
    return 0;
}

static BOOL SCIImageNameIsFBShared(const char *imageName) {
    if (!imageName) return NO;
    NSString *s = [NSString stringWithUTF8String:imageName];
    NSString *last = s.lastPathComponent;
    return [last isEqualToString:@"FBSharedFramework"] || [s containsString:@"FBSharedFramework.framework/FBSharedFramework"];
}

static NSString *SCICleanExportName(const char *name) {
    if (!name || !name[0]) return nil;
    if (name[0] == '_') name++;
    if (!name[0] || name[0] == '_') return nil;
    NSString *s = [NSString stringWithUTF8String:name];
    if (!s.length) return nil;

    NSArray<NSString *> *badPrefixes = @[
        @"OBJC_", @"_OBJC_", @"objc_", @"__objc", @"__block_descriptor",
        @"__NS", @"_$s", @"$s", @"__ZN", @"_Z", @"__Z", @"l_", @"GCC_", @"_mh_"
    ];
    for (NSString *prefix in badPrefixes) {
        if ([s hasPrefix:prefix]) return nil;
    }
    if ([s containsString:@"<"] || [s containsString:@">"]) return nil;
    return s;
}

static BOOL SCISymbolIsForceBlacklisted(NSString *name) {
    if (!name.length) return YES;
    NSArray<NSString *> *bad = @[
        @"MCI", @"MCDDasm", @"IGDirectOneWayGatingGetBoolValue",
        @"MCISessionedNetworker", @"MCIGraphQL", @"MCIStats"
    ];
    for (NSString *part in bad) {
        if ([name rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL SCISymbolLooksBoolLike(NSString *name) {
    if (!name.length) return NO;
    NSArray<NSString *> *parts = @[
        @"Bool", @"Boolean", @"Gating", @"Gate", @"MobileConfig", @"ConfigBoolean",
        @"IsEmployee", @"IsInternal", @"Dogfood", @"Eligible", @"Eligibility", @"Should", @"CanUse", @"Has"
    ];
    for (NSString *p in parts) {
        if ([name rangeOfString:p options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSSet<NSString *> *SCIForceAllowedBoolFunctions(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18"
        ]];
    });
    return set;
}

static NSSet<NSString *> *SCIObserveOnlyBoolFunctions(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"IGMobileConfigBooleanValueForInternalUse",
            @"EasyGatingGetBoolean_Internal_DoNotUseOrMock",
            @"EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock",
            @"MCQEasyGatingGetBooleanInternalDoNotUseOrMock",
            @"MSGCSessionedMobileConfigGetBoolean",
            @"MCIExperimentCacheGetMobileConfigBoolean",
            @"MCIExtensionExperimentCacheGetMobileConfigBoolean",
            @"MCDDasmNativeGetMobileConfigBooleanV2DvmAdapter",
            @"IGDirectOneWayGatingGetBoolValue"
        ]];
    });
    return set;
}

static NSString *SCIKindForSection(NSString *seg, NSString *sect, BOOL abs) {
    if (abs) return @"absolute";
    if ([seg isEqualToString:@"__TEXT"] && [sect isEqualToString:@"__text"]) return @"function";
    if ([seg isEqualToString:@"__TEXT"] && [sect isEqualToString:@"__cstring"]) return @"string";
    if ([seg isEqualToString:@"__TEXT"] && [sect isEqualToString:@"__const"]) return @"const";
    if ([seg hasPrefix:@"__DATA"]) return @"data";
    return [NSString stringWithFormat:@"%@,%@", seg ?: @"?", sect ?: @"?"];
}

static BOOL SCISymbolLooksMobileConfigKey(NSString *name, NSString *kind, NSUInteger symbolSize) {
    if (!name.length || symbolSize < 8 || symbolSize > 512 || (symbolSize % 8) != 0) return NO;
    if (![kind isEqualToString:@"const"] && ![kind isEqualToString:@"data"] && ![kind isEqualToString:@"string"]) return NO;
    // Lowercase FBShared config-key symbols (for example ig_stories_...)
    // are param-specifier data, not C functions. Uppercase enum/model symbols
    // may also contain "Internal" in their name, but are not MobileConfig keys.
    NSArray<NSString *> *prefixes = @[@"ig_", @"fb_", @"xplat_", @"direct_", @"reels_", @"stories_", @"messaging_"];
    for (NSString *prefix in prefixes) if ([name hasPrefix:prefix]) return YES;
    return NO;
}

static NSString *SCIProfileForSymbol(NSString *name, BOOL isFunction, NSString *kind, NSUInteger symbolSize) {
    if (!isFunction) {
        return SCISymbolLooksMobileConfigKey(name, kind, symbolSize) ? kProfileMCKeyForce : kProfileNone;
    }
    if ([SCIForceAllowedBoolFunctions() containsObject:name]) return kProfileBoolForce;
    if ([SCIObserveOnlyBoolFunctions() containsObject:name]) return kProfileBoolObserve;
    return kProfileNone;
}

static NSString *SCIReasonForSymbol(NSString *name, NSString *kind, NSString *profile, BOOL resolvable) {
    if (![kind isEqualToString:@"function"]) {
        if ([profile isEqualToString:kProfileMCKeyForce]) return @"FBShared MobileConfig/EasyGating key symbol; Force YES applies typed MobileConfig overrides for its param specifier(s).";
        if ([name hasPrefix:@"ig_"]) return @"FBShared key/data symbol without validated param-spec shape; enum only.";
        return @"Not a __TEXT,__text function; not C-hookable.";
    }
    if (!resolvable) return @"Function export is not resolvable by dlsym in this process.";
    if ([profile isEqualToString:kProfileBoolForce]) return @"Known single-purpose bool function; observe and Force YES allowed.";
    if ([profile isEqualToString:kProfileBoolObserve]) return @"Known bool reader; observe-only. Global Force would affect many keys or crash hot path.";
    if (SCISymbolLooksBoolLike(name)) return @"Looks bool-like, but ABI/profile is not validated; hook blocked.";
    return @"Function symbol, but return type/signature is unknown; hook blocked.";
}

static BOOL SCICanHookProfile(NSString *profile) {
    return [profile isEqualToString:kProfileBoolObserve] || [profile isEqualToString:kProfileBoolForce];
}

static BOOL SCICanForceProfile(NSString *profile) {
    return [profile isEqualToString:kProfileBoolForce] || [profile isEqualToString:kProfileMCKeyForce];
}

static BOOL SCIIsMCKeyProfile(NSString *profile) {
    return [profile isEqualToString:kProfileMCKeyForce];
}

static NSArray<SCICImport *> *SCIEnumerateFBSharedExportsForImage(uint32_t imageIndex) {
    const struct mach_header *mh0 = _dyld_get_image_header(imageIndex);
    const char *imageName = _dyld_get_image_name(imageIndex);
    if (!mh0 || !SCIImageNameIsFBShared(imageName) || mh0->magic != MH_MAGIC_64) return @[];

    const struct mach_header_64 *mh = (const struct mach_header_64 *)mh0;
    const uint8_t *cmdp = (const uint8_t *)(mh + 1);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    NSMutableArray<NSValue *> *sections = [NSMutableArray array];

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmdp;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmdp;
            if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) linkedit = seg;
            const struct section_64 *sec = (const struct section_64 *)(seg + 1);
            for (uint32_t si = 0; si < seg->nsects; si++) {
                SCISectionInfo info;
                memset(&info, 0, sizeof(info));
                strlcpy(info.segname, sec[si].segname, sizeof(info.segname));
                strlcpy(info.sectname, sec[si].sectname, sizeof(info.sectname));
                info.flags = sec[si].flags;
                [sections addObject:[NSValue valueWithBytes:&info objCType:@encode(SCISectionInfo)]];
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)cmdp;
        }
        if (lc->cmdsize == 0) break;
        cmdp += lc->cmdsize;
    }

    if (!linkedit || !symtab || symtab->nsyms == 0 || symtab->stroff == 0 || symtab->strsize == 0) return @[];

    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);

    uint64_t *exportAddrs = calloc(symtab->nsyms ? symtab->nsyms : 1, sizeof(uint64_t));
    uint32_t exportAddrCount = 0;
    for (uint32_t ai = 0; ai < symtab->nsyms; ai++) {
        struct nlist_64 n = symbols[ai];
        if ((n.n_type & N_STAB) != 0 || (n.n_type & N_EXT) == 0) continue;
        uint8_t type = n.n_type & N_TYPE;
        if (type != N_SECT || n.n_value == 0) continue;
        if (n.n_un.n_strx == 0 || n.n_un.n_strx >= symtab->strsize) continue;
        NSString *clean = SCICleanExportName(strings + n.n_un.n_strx);
        if (!clean.length) continue;
        exportAddrs[exportAddrCount++] = n.n_value;
    }
    qsort(exportAddrs, exportAddrCount, sizeof(uint64_t), SCICompareU64);

    NSMutableArray<SCICImport *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        struct nlist_64 n = symbols[i];
        if ((n.n_type & N_STAB) != 0) continue;
        if ((n.n_type & N_EXT) == 0) continue;
        uint8_t type = n.n_type & N_TYPE;
        if (type != N_SECT && type != N_ABS) continue;
        if (n.n_un.n_strx == 0 || n.n_un.n_strx >= symtab->strsize) continue;

        NSString *name = SCICleanExportName(strings + n.n_un.n_strx);
        if (!name.length || [seen containsObject:name]) continue;
        [seen addObject:name];

        BOOL abs = (type == N_ABS);
        SCISectionInfo info;
        memset(&info, 0, sizeof(info));
        if (!abs && n.n_sect > 0 && n.n_sect <= sections.count) {
            [sections[n.n_sect - 1] getValue:&info];
        }
        NSString *seg = @"ABS";
        NSString *sect = @"ABS";
        if (!abs) {
            NSString *segValue = [NSString stringWithUTF8String:info.segname];
            NSString *sectValue = [NSString stringWithUTF8String:info.sectname];
            seg = segValue.length ? segValue : @"?";
            sect = sectValue.length ? sectValue : @"?";
        }
        NSString *kind = SCIKindForSection(seg, sect, abs);
        BOOL isFunction = [kind isEqualToString:@"function"];
        uint64_t nextAddr = (!abs && n.n_value) ? SCINextAddressAfter(exportAddrs, exportAddrCount, n.n_value) : 0;
        NSUInteger symbolSize = (nextAddr > n.n_value && (nextAddr - n.n_value) < 4096) ? (NSUInteger)(nextAddr - n.n_value) : 0;
        BOOL resolvable = dlsym(RTLD_DEFAULT, name.UTF8String) != NULL;
        NSString *profile = SCIProfileForSymbol(name, isFunction, kind, symbolSize);

        SCICImport *item = [SCICImport new];
        item.symbolName = name;
        item.imageName = @"FBSharedFramework export";
        item.symbolKind = kind;
        item.hookProfile = profile;
        item.resolvable = resolvable;
        item.functionSymbol = isFunction;
        item.boolLike = SCISymbolLooksBoolLike(name);
        item.forceBlacklisted = SCISymbolIsForceBlacklisted(name);
        item.mobileConfigKeySymbol = SCIIsMCKeyProfile(profile);
        item.mobileConfigParamCount = item.mobileConfigKeySymbol ? (symbolSize / 8) : 0;
        item.hookable = resolvable && SCICanHookProfile(profile);
        item.forceAllowed = resolvable && SCICanForceProfile(profile) && (!item.forceBlacklisted || item.mobileConfigKeySymbol);
        item.safetyReason = SCIReasonForSymbol(name, kind, profile, resolvable);
        [out addObject:item];
    }
    if (exportAddrs) free(exportAddrs);
    return out;
}

static NSArray<SCICImport *> *SCIAllFBSharedExports(void) {
    static NSArray<SCICImport *> *exports;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, SCICImport *> *byName = [NSMutableDictionary dictionary];
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            for (SCICImport *item in SCIEnumerateFBSharedExportsForImage(i)) {
                byName[item.symbolName] = item;
            }
        }
        exports = [[byName allValues] sortedArrayUsingComparator:^NSComparisonResult(SCICImport *a, SCICImport *b) {
            if (a.hookable != b.hookable) return a.hookable ? NSOrderedAscending : NSOrderedDescending;
            return [a.symbolName compare:b.symbolName options:NSCaseInsensitiveSearch];
        }];
        CLOG("FBShared export enumeration complete: %lu symbols", (unsigned long)exports.count);
    });
    return exports ?: @[];
}

static SCICImport *SCIExportForName(NSString *name) {
    if (!name.length) return nil;
    for (SCICImport *item in SCIAllFBSharedExports()) {
        if ([item.symbolName isEqualToString:name]) return item;
    }
    return nil;
}

static NSMutableDictionary *SCIMutableDictPref(NSString *key) {
    NSDictionary *d = [SCIUtils getDictPref:key];
    return [d isKindOfClass:NSDictionary.class] ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static NSString *SCIKeyForSymbol(NSString *name) { return [@"C#" stringByAppendingString:(name ?: @"")]; }

static NSDictionary *SCIKeyOverrideEntryForName(NSString *name) {
    id v = [SCIUtils getDictPref:kCKeyOverridesKey][SCIKeyForSymbol(name)];
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}

static NSNumber *SCIOverrideForName(NSString *name) {
    NSDictionary *keyEntry = SCIKeyOverrideEntryForName(name);
    id kv = keyEntry[@"value"];
    if ([kv isKindOfClass:NSNumber.class]) return kv;
    id v = [SCIUtils getDictPref:kCOverridesKey][SCIKeyForSymbol(name)];
    return [v isKindOfClass:NSNumber.class] ? v : nil;
}

static BOOL SCIObserveForName(NSString *name) {
    id v = [SCIUtils getDictPref:kCObserveKey][SCIKeyForSymbol(name)];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : NO;
}

static NSArray<NSString *> *SCIParamIDStringsForMCKeySymbol(NSString *name) {
    SCICImport *item = SCIExportForName(name);
    if (!item.mobileConfigKeySymbol || !item.resolvable || item.mobileConfigParamCount == 0 || item.mobileConfigParamCount > 64) return @[];
    const void *ptr = dlsym(RTLD_DEFAULT, name.UTF8String);
    if (!ptr) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    const uint8_t *bytes = (const uint8_t *)ptr;
    for (NSUInteger i = 0; i < item.mobileConfigParamCount; i++) {
        uint64_t v = 0;
        memcpy(&v, bytes + (i * sizeof(uint64_t)), sizeof(uint64_t));
        if (!v) continue;
        uint64_t hi = v >> 32;
        if (hi == 0 || hi > 0x0fffffffULL) continue;
        NSString *s = [NSString stringWithFormat:@"%llu", (unsigned long long)v];
        if (![ids containsObject:s]) [ids addObject:s];
    }
    return ids;
}

static void SCIApplyMCKeyOverrideEntry(NSDictionary *entry, BOOL enabled) {
    NSArray *ids = entry[@"paramIDs"];
    if (![ids isKindOfClass:NSArray.class]) return;
    [SCIUtils setPref:@YES forKey:@"sci_mc_runtime_browser_enabled"];
    [SCIUtils setPref:@YES forKey:@"sci_mc_runtime_manual_overrides_enabled"];
    SCIInstallMobileConfigRuntimeHooksIfNeeded();
    for (id obj in ids) {
        unsigned long long pid = strtoull([[obj description] UTF8String], NULL, 10);
        if (!pid) continue;
        if (enabled) [SCIMobileConfigRuntime setManualOverride:@YES paramID:pid type:@"bool"];
        else [SCIMobileConfigRuntime removeManualOverrideForParamID:pid type:@"bool"];
    }
}

static BOOL SCISetMCKeyForce(NSNumber *value, NSString *name) {
    if (!name.length) return NO;
    SCICImport *item = SCIExportForName(name);
    if (!item.mobileConfigKeySymbol || !item.forceAllowed) return NO;
    NSMutableDictionary *d = SCIMutableDictPref(kCKeyOverridesKey);
    NSString *key = SCIKeyForSymbol(name);
    if (value) {
        NSArray<NSString *> *ids = SCIParamIDStringsForMCKeySymbol(name);
        if (!ids.count) return NO;
        NSDictionary *entry = @{ @"value": @YES, @"paramIDs": ids, @"symbol": name, @"kind": @"fbshared-mc-key" };
        d[key] = entry;
        [SCIUtils setPref:d forKey:kCKeyOverridesKey];
        [SCIUtils setPref:@YES forKey:kCMasterKey];
        SCIApplyMCKeyOverrideEntry(entry, YES);
        return YES;
    }
    NSDictionary *old = d[key];
    if ([old isKindOfClass:NSDictionary.class]) SCIApplyMCKeyOverrideEntry(old, NO);
    [d removeObjectForKey:key];
    [SCIUtils setPref:d forKey:kCKeyOverridesKey];
    return YES;
}

static BOOL SCICSymbolCanInstallHook(NSString *name) {
    SCICImport *item = SCIExportForName(name);
    return item.hookable;
}

static BOOL SCICSymbolCanForce(NSString *name) {
    SCICImport *item = SCIExportForName(name);
    return item.forceAllowed;
}

static BOOL SCIInstallHookForName(NSString *name) {
    if (!SCICSymbolCanInstallHook(name)) return NO;

    @synchronized([SCICSymbolEngine class]) {
        int existing = slotIndexForName(name.UTF8String);
        if (existing >= 0) return YES;
        if (g_slot_count >= MAX_C_HOOKS) return NO;
        int idx = g_slot_count++;
        g_slots[idx].name = strdup(name.UTF8String);
        g_slots[idx].orig = NULL;
        atomic_store(&g_slots[idx].force, -1);
        atomic_store(&g_slots[idx].hits, 0);
        atomic_store(&g_slots[idx].observed, -1);
        g_slots[idx].installed = false;

        NSNumber *forced = SCIOverrideForName(name);
        if (forced && SCICSymbolCanForce(name)) atomic_store(&g_slots[idx].force, forced.boolValue ? 1 : 0);

        struct rebinding rb = { name.UTF8String, g_replacements[idx], (void **)&g_slots[idx].orig };
        int rc = rebind_symbols(&rb, 1);
        if (rc != 0 || !g_slots[idx].orig) {
            CLOG("rebind no consumer import %s rc=%d", name.UTF8String, rc);
            free((void *)g_slots[idx].name);
            memset(&g_slots[idx], 0, sizeof(SCIHookSlot));
            g_slot_count--;
            return NO;
        }
        g_slots[idx].installed = true;
        CLOG("rebound FBShared export %s slot=%d", name.UTF8String, idx);
        return YES;
    }
}

static void SCIPushForceToCache(NSString *name, NSNumber *value) {
    int idx = slotIndexForName(name.UTF8String);
    if (idx < 0) return;
    if (!SCICSymbolCanForce(name)) {
        atomic_store(&g_slots[idx].force, -1);
    } else {
        atomic_store(&g_slots[idx].force, value ? (value.boolValue ? 1 : 0) : -1);
    }
}

@implementation SCICImport
- (NSString *)overrideKey { return SCIKeyForSymbol(self.symbolName); }
- (NSNumber *)override { return [SCICSymbolEngine overrideForSymbolName:self.symbolName]; }
- (BOOL)observing { return [SCICSymbolEngine isObserving:self.symbolName]; }
- (BOOL)hookInstalled { return [SCICSymbolEngine hookInstalledForSymbolName:self.symbolName]; }
- (NSUInteger)observedCallCount { return [SCICSymbolEngine callCountForSymbolName:self.symbolName]; }
- (NSNumber *)observedValue { return [SCICSymbolEngine observedValueForSymbolName:self.symbolName]; }
@end

@implementation SCICSymbolEngine

+ (NSArray<SCICImport *> *)searchImports:(NSString *)query limit:(NSUInteger)limit {
    NSArray<SCICImport *> *all = SCIAllFBSharedExports();
    if (limit == 0) limit = 200;
    NSString *q = query.lowercaseString ?: @"";
    NSMutableArray<SCICImport *> *out = [NSMutableArray arrayWithCapacity:MIN(limit, (NSUInteger)200)];
    for (SCICImport *item in all) {
        if (q.length && [item.symbolName.lowercaseString rangeOfString:q].location == NSNotFound && [item.symbolKind.lowercaseString rangeOfString:q].location == NSNotFound) continue;
        [out addObject:item];
        if (out.count >= limit) break;
    }
    return out;
}

+ (NSUInteger)totalImportCount { return SCIAllFBSharedExports().count; }
+ (NSUInteger)hookableImportCount {
    NSUInteger n = 0;
    for (SCICImport *item in SCIAllFBSharedExports()) if (item.hookable) n++;
    return n;
}
+ (BOOL)masterEnabled { return [SCIUtils getBoolPref:kCMasterKey]; }

+ (BOOL)hasPersistedHooks {
    NSDictionary *forces = [SCIUtils getDictPref:kCOverridesKey];
    NSDictionary *obs = [SCIUtils getDictPref:kCObserveKey];
    NSDictionary *keyForces = [SCIUtils getDictPref:kCKeyOverridesKey];
    return [self masterEnabled] && (forces.count > 0 || obs.count > 0 || keyForces.count > 0);
}

+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name { return SCIOverrideForName(name); }

+ (BOOL)setForce:(NSNumber *)value forSymbolName:(NSString *)name {
    if (!name.length) return NO;
    SCICImport *item = SCIExportForName(name);
    if (item.mobileConfigKeySymbol) return SCISetMCKeyForce(value, name);
    if (!SCICSymbolCanForce(name)) return NO;

    NSMutableDictionary *d = SCIMutableDictPref(kCOverridesKey);
    NSString *key = SCIKeyForSymbol(name);
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [SCIUtils setPref:d forKey:kCOverridesKey];
    if (value) [SCIUtils setPref:@YES forKey:kCMasterKey];
    if (!SCIInstallHookForName(name)) return NO;
    SCIPushForceToCache(name, value);
    return YES;
}

+ (BOOL)setObserve:(BOOL)observe forSymbolName:(NSString *)name {
    if (!name.length) return NO;
    if (!SCICSymbolCanInstallHook(name)) return NO;

    NSMutableDictionary *d = SCIMutableDictPref(kCObserveKey);
    NSString *key = SCIKeyForSymbol(name);
    if (observe) d[key] = @YES; else [d removeObjectForKey:key];
    [SCIUtils setPref:d forKey:kCObserveKey];
    if (observe) return SCIInstallHookForName(name);
    return YES;
}

+ (BOOL)isObserving:(NSString *)name { return SCIObserveForName(name); }

+ (NSUInteger)callCountForSymbolName:(NSString *)name {
    int idx = slotIndexForName(name.UTF8String);
    return idx >= 0 ? atomic_load(&g_slots[idx].hits) : 0;
}

+ (nullable NSNumber *)observedValueForSymbolName:(NSString *)name {
    int idx = slotIndexForName(name.UTF8String);
    if (idx < 0) return nil;
    signed char v = atomic_load(&g_slots[idx].observed);
    return v < 0 ? nil : @(v != 0);
}

+ (BOOL)hookInstalledForSymbolName:(NSString *)name { return slotIndexForName(name.UTF8String) >= 0; }
+ (BOOL)isForceBlacklistedSymbolName:(NSString *)name { return SCISymbolIsForceBlacklisted(name); }
+ (BOOL)isBoolLikeSymbolName:(NSString *)name { return SCISymbolLooksBoolLike(name); }
+ (BOOL)isHookableSymbolName:(NSString *)name { return SCICSymbolCanInstallHook(name); }
+ (BOOL)isForceAllowedSymbolName:(NSString *)name { return SCICSymbolCanForce(name); }
+ (BOOL)isMobileConfigKeySymbolName:(NSString *)name { SCICImport *item = SCIExportForName(name); return item.mobileConfigKeySymbol; }
+ (NSUInteger)mobileConfigParamCountForSymbolName:(NSString *)name { SCICImport *item = SCIExportForName(name); return item.mobileConfigParamCount; }
+ (NSString *)safetyReasonForSymbolName:(NSString *)name {
    SCICImport *item = SCIExportForName(name);
    return item.safetyReason ?: @"Unknown or unavailable symbol.";
}

+ (NSArray<NSString *> *)internalGateSymbolNames {
    return @[
        @"IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18"
    ];
}

+ (NSArray<NSString *> *)forceInternalReadersEnabled:(BOOL)enabled {
    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *name in [self internalGateSymbolNames]) {
        BOOL changed = [self setForce:(enabled ? @YES : nil) forSymbolName:name];
        if (changed) [ok addObject:name];
    }
    return ok;
}

+ (void)reinstallPersistedHooks {
    if (![self hasPersistedHooks]) { CLOG("no enabled persisted FBShared C hooks"); return; }

    NSDictionary *obs = [SCIUtils getDictPref:kCObserveKey];
    for (NSString *key in obs) {
        if (![key hasPrefix:@"C#"]) continue;
        id v = obs[key];
        NSString *name = [key substringFromIndex:2];
        if ([v isKindOfClass:NSNumber.class] && [v boolValue] && SCICSymbolCanInstallHook(name)) SCIInstallHookForName(name);
    }

    NSDictionary *keyForces = [SCIUtils getDictPref:kCKeyOverridesKey];
    for (NSString *key in keyForces) {
        id entry = keyForces[key];
        if ([entry isKindOfClass:NSDictionary.class]) SCIApplyMCKeyOverrideEntry(entry, YES);
    }

    NSDictionary *forces = [SCIUtils getDictPref:kCOverridesKey];
    for (NSString *key in forces) {
        if (![key hasPrefix:@"C#"]) continue;
        NSString *name = [key substringFromIndex:2];
        id v = forces[key];
        if (![v isKindOfClass:NSNumber.class]) continue;
        if (!SCICSymbolCanForce(name)) continue;
        if (SCIInstallHookForName(name)) SCIPushForceToCache(name, v);
    }
}

@end
