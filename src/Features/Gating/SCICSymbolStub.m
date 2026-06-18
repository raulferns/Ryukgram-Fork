#import "SCICSymbolStub.h"
#import "../../Utils.h"
#import "../../../modules/fishhook/fishhook.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

#define SLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] CStub " fmt,##__VA_ARGS__)

static NSString *const kForceOverrides = @"sci_csym_stub_overrides";       // { name: @(1|0) }
static NSString *const kTypedOverrides = @"sci_csym_stub_typed_overrides"; // { name: { kind, value } }
static NSString *const kObserveOverrides = @"sci_csym_stub_observe";       // { name: @YES }
static NSString *const kParamBoolOverrides = @"sci_csym_param_bool_overrides"; // { DATA symbol: @(1|0) }

typedef NS_ENUM(NSInteger, SCICStubProfile) {
    SCICStubProfileUnknown = 0,
    SCICStubProfileIGMobileConfigBoolean,
    SCICStubProfileIGMobileConfigInteger,
    SCICStubProfileIGMobileConfigString,
    SCICStubProfileEasyGatingBoolean,
    SCICStubProfileEasyGatingAuthBoolean,
    SCICStubProfileEasyGatingInt32,
    SCICStubProfileEasyGatingInt64,
    SCICStubProfileEasyGatingDouble,
    SCICStubProfileEasyGatingCopyString,
    SCICStubProfileMSGCSessionedBoolean,
    SCICStubProfileNoArgBool,
    SCICStubProfileTALIdToName,
    SCICStubProfileVoidAction,
};

typedef NS_ENUM(NSInteger, SCICReturnKind) {
    SCICReturnKindUnknown = 0,
    SCICReturnKindBool,
    SCICReturnKindInt64,
    SCICReturnKindDouble,
    SCICReturnKindString,
    SCICReturnKindAction,
};


static NSArray<NSString *> *SCIParamDescriptorSymbols(void) {
    static NSArray<NSString *> *syms = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        syms = @[
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
        ];
    });
    return syms;
}

static BOOL SCIParamDescriptorSymbolKnown(NSString *name) {
    return [SCIParamDescriptorSymbols() containsObject:name ?: @""];
}

typedef struct {
    char name[128];
    void *addr;
    atomic_int force; // -1 none, 0/1 forced
    atomic_uint hits;
} SCIParamDescriptorSlot;

#define MAX_PARAM_DESCRIPTOR_STUBS 32
static SCIParamDescriptorSlot g_param_slots[MAX_PARAM_DESCRIPTOR_STUBS];
static int g_param_slot_count = 0;

static SCIParamDescriptorSlot *param_slot_for_name(const char *name) {
    if (!name) return NULL;
    for (int i = 0; i < g_param_slot_count; i++) if (strcmp(g_param_slots[i].name, name) == 0) return &g_param_slots[i];
    return NULL;
}

static NSDictionary *SCIParamBoolPref(void) { NSDictionary *d = [SCIUtils getDictPref:kParamBoolOverrides]; return [d isKindOfClass:NSDictionary.class] ? d : @{}; }

static void SCIParamDescriptorRefreshCache(void) {
    NSDictionary *prefs = SCIParamBoolPref();
    for (int i = 0; i < g_param_slot_count; i++) {
        NSString *key = [NSString stringWithUTF8String:g_param_slots[i].name] ?: @"";
        id v = prefs[key];
        atomic_store(&g_param_slots[i].force, [v isKindOfClass:NSNumber.class] ? ([v boolValue] ? 1 : 0) : -1);
        if (!g_param_slots[i].addr) {
            void *p = dlsym(RTLD_DEFAULT, g_param_slots[i].name);
            if (!p) {
                NSString *under = [@"_" stringByAppendingString:key];
                p = dlsym(RTLD_DEFAULT, under.UTF8String);
            }
            g_param_slots[i].addr = p;
        }
    }
}

static void SCIParamDescriptorInstallSlotsForPersisted(void) {
    NSDictionary *prefs = SCIParamBoolPref();
    for (NSString *name in prefs.allKeys) {
        if (!SCIParamDescriptorSymbolKnown(name) || param_slot_for_name(name.UTF8String)) continue;
        if (g_param_slot_count >= MAX_PARAM_DESCRIPTOR_STUBS) break;
        SCIParamDescriptorSlot *slot = &g_param_slots[g_param_slot_count++];
        memset(slot, 0, sizeof(*slot));
        strncpy(slot->name, name.UTF8String, sizeof(slot->name)-1);
        atomic_store(&slot->force, [prefs[name] boolValue] ? 1 : 0);
        atomic_store(&slot->hits, 0);
        slot->addr = dlsym(RTLD_DEFAULT, slot->name);
        if (!slot->addr) {
            NSString *under = [@"_" stringByAppendingString:name];
            slot->addr = dlsym(RTLD_DEFAULT, under.UTF8String);
        }
    }
}

static int SCIParamDescriptorForcedValueForMobileConfigBoolArgs(void *a0, void *a1, void *a2, void *a3) {
    (void)a1; (void)a3;
    SCIParamDescriptorInstallSlotsForPersisted();
    SCIParamDescriptorRefreshCache();
    for (int i = 0; i < g_param_slot_count; i++) {
        int f = atomic_load(&g_param_slots[i].force);
        if (f < 0 || !g_param_slots[i].addr) continue;
        if (a0 == g_param_slots[i].addr || a2 == g_param_slots[i].addr) {
            atomic_fetch_add(&g_param_slots[i].hits, 1);
            return f;
        }
    }
    return -1;
}

static NSString *SCIStubBlacklistReason(NSString *name) {
    static NSDictionary *bl = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bl = @{
            @"MCDDasmNativeGetMobileConfigBooleanV2DvmAdapter": @"hot-path + x30/LR/PAC; can crash on return",
            @"MCDDasmNativeGetMobileConfigInt64V2DvmAdapter": @"hot-path + x30/LR/PAC",
            @"MCDDasmNativeGetMobileConfigStringV2DvmAdapter": @"hot-path + x30/LR/PAC",
            @"MCIExperimentCacheGetMobileConfigBoolean": @"hot-path MCI; use DATA/param filter or observe-only browser, not generic force",
            @"MCIExperimentCacheGetMobileConfigInt64": @"hot-path MCI; use DATA/param filter or observe-only browser",
            @"MCIExtensionExperimentCacheGetMobileConfigBoolean": @"hot-path MCI; use DATA/param filter or observe-only browser, not generic force",
            @"MCIExtensionExperimentCacheGetMobileConfigInt64": @"hot-path MCI; use DATA/param filter or observe-only browser",
            @"MCIExtensionExperimentCacheGetMobileConfigString": @"hot-path MCI; use DATA/param filter or observe-only browser",
            @"IGDirectOneWayGatingGetBoolValue": @"x30/LR/PAC reader; force blocked",
            @"MCIStatsIncrement": @"stats counter; never hook/force",
            @"FBHandleFailedProductionAssertInternal": @"production assert helper; never hook/force",
        };
    });
    return bl[name];
}

static SCICStubProfile SCIStubProfileForSymbol(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length) return SCICStubProfileUnknown;
    if ([SCIStubBlacklistReason(name) length]) return SCICStubProfileUnknown;
    if ([name isEqualToString:@"IGMobileConfigBooleanValueForInternalUse"]) return SCICStubProfileIGMobileConfigBoolean;
    if ([name isEqualToString:@"IGMobileConfigIntegerValueForInternalUse"]) return SCICStubProfileIGMobileConfigInteger;
    if ([name isEqualToString:@"IGMobileConfigStringValueForInternalUse"]) return SCICStubProfileIGMobileConfigString;
    if ([name isEqualToString:@"EasyGatingGetBoolean_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingBoolean;
    if ([name isEqualToString:@"EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingAuthBoolean;
    if ([name isEqualToString:@"EasyGatingGetInt32_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingInt32;
    if ([name isEqualToString:@"MCQEasyGatingGetInt32InternalDoNotUseOrMock"]) return SCICStubProfileEasyGatingInt32;
    if ([name isEqualToString:@"EasyGatingGetInt64_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingInt64;
    if ([name isEqualToString:@"EasyGatingGetDouble_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingDouble;
    if ([name isEqualToString:@"EasyGatingCopyString_Internal_DoNotUseOrMock"]) return SCICStubProfileEasyGatingCopyString;
    if ([name isEqualToString:@"MSGCSessionedMobileConfigGetBoolean"]) return SCICStubProfileMSGCSessionedBoolean;
    if ([name isEqualToString:@"MEBIsMinosDogfoodMekEncryptionVersionEnabled"]) return SCICStubProfileNoArgBool;
    if ([name isEqualToString:@"IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18"]) return SCICStubProfileNoArgBool;
    if ([name isEqualToString:@"TALEventsGetIdToNameMappingForEventId"]) return SCICStubProfileTALIdToName;
    if ([name isEqualToString:@"MCIDatabaseTableToProcedureNameMapRegisterMappings"]) return SCICStubProfileVoidAction;
    if ([name isEqualToString:@"IGMobileConfigSetConfigOverrides"]) return SCICStubProfileVoidAction;
    if ([name isEqualToString:@"IGMobileConfigForceUpdateConfigs"]) return SCICStubProfileVoidAction;
    if ([name isEqualToString:@"IGMobileConfigTryUpdateConfigsWithCompletion"]) return SCICStubProfileVoidAction;
    return SCICStubProfileUnknown;
}

static SCICReturnKind SCIReturnKindForProfile(SCICStubProfile p) {
    switch (p) {
        case SCICStubProfileIGMobileConfigBoolean:
        case SCICStubProfileEasyGatingBoolean:
        case SCICStubProfileEasyGatingAuthBoolean:
        case SCICStubProfileMSGCSessionedBoolean:
        case SCICStubProfileNoArgBool:
            return SCICReturnKindBool;
        case SCICStubProfileIGMobileConfigInteger:
        case SCICStubProfileEasyGatingInt32:
        case SCICStubProfileEasyGatingInt64:
            return SCICReturnKindInt64;
        case SCICStubProfileEasyGatingDouble:
            return SCICReturnKindDouble;
        case SCICStubProfileIGMobileConfigString:
        case SCICStubProfileEasyGatingCopyString:
        case SCICStubProfileTALIdToName:
            return SCICReturnKindString;
        case SCICStubProfileVoidAction:
            return SCICReturnKindAction;
        default:
            return SCICReturnKindUnknown;
    }
}

static NSString *SCIReturnKindString(SCICReturnKind k) {
    switch (k) {
        case SCICReturnKindBool: return @"bool";
        case SCICReturnKindInt64: return @"int64";
        case SCICReturnKindDouble: return @"double";
        case SCICReturnKindString: return @"string";
        case SCICReturnKindAction: return @"action";
        default: return @"unknown";
    }
}

static BOOL SCIStubSymbolLooksBool(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    if (SCIReturnKindForProfile(SCIStubProfileForSymbol(name)) == SCICReturnKindBool) return YES;
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"boolean"] || [lower containsString:@"bool"] || [lower hasPrefix:@"is"] || [lower containsString:@"enabled"];
}

#define MAX_STUBS 96
typedef struct {
    char name[192];
    void *orig;
    SCICStubProfile profile;
    atomic_int forceBool;       // -1 passthrough, 0/1 forced
    atomic_int hasTypedForce;   // 0/1
    atomic_llong forceInt64;
    _Atomic(double) forceDouble;
    void *forceString;          // retained CFString/NSString pointer
    atomic_uint hits;
    atomic_int observedBool;    // -1 unknown, 0/1 observed
    atomic_llong observedInt64;
    _Atomic(double) observedDouble;
    void *observedString;       // not retained; diagnostics only
} SCICStubSlot;
static SCICStubSlot g_slots[MAX_STUBS];
static int g_slot_count = 0;

static SCICStubSlot *slot_for(const char *name) {
    if (!name) return NULL;
    for (int i = 0; i < g_slot_count; i++) if (strcmp(g_slots[i].name, name) == 0) return &g_slots[i];
    return NULL;
}

static bool call_orig_bool(SCICStubSlot *s, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    (void)a4; (void)a5; (void)a6; (void)a7;
    if (!s || !s->orig) return false;
    switch (s->profile) {
        case SCICStubProfileIGMobileConfigBoolean: { bool (*o)(void *, bool, void *) = (void *)s->orig; return o(a0, ((uintptr_t)a1) != 0, a2); }
        case SCICStubProfileEasyGatingBoolean: { bool (*o)(uint32_t) = (void *)s->orig; return o((uint32_t)((uintptr_t)a0)); }
        case SCICStubProfileEasyGatingAuthBoolean: { bool (*o)(void *, void *, void *, void *) = (void *)s->orig; return o(a0, a1, a2, a3); }
        case SCICStubProfileMSGCSessionedBoolean: { bool (*o)(void *, void *, void *) = (void *)s->orig; return o(a0, a1, a2); }
        case SCICStubProfileNoArgBool: { bool (*o)(void) = (void *)s->orig; return o(); }
        default: return false;
    }
}

static int64_t call_orig_int64(SCICStubSlot *s, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
    if (!s || !s->orig) return 0;
    switch (s->profile) {
        case SCICStubProfileIGMobileConfigInteger: { int64_t (*o)(void *, int64_t, void *) = (void *)s->orig; return o(a0, (int64_t)((intptr_t)a1), a2); }
        case SCICStubProfileEasyGatingInt32: { int32_t (*o)(uint32_t) = (void *)s->orig; return (int64_t)o((uint32_t)((uintptr_t)a0)); }
        case SCICStubProfileEasyGatingInt64: { int64_t (*o)(uint32_t) = (void *)s->orig; return o((uint32_t)((uintptr_t)a0)); }
        default: return 0;
    }
}

static double call_orig_double(SCICStubSlot *s, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
    if (!s || !s->orig) return 0.0;
    switch (s->profile) {
        case SCICStubProfileEasyGatingDouble: { double (*o)(uint32_t) = (void *)s->orig; return o((uint32_t)((uintptr_t)a0)); }
        default: return 0.0;
    }
}

static void *call_orig_ptr(SCICStubSlot *s, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
    if (!s || !s->orig) return NULL;
    switch (s->profile) {
        case SCICStubProfileIGMobileConfigString: { void *(*o)(void *, void *, void *) = (void *)s->orig; return o(a0, a1, a2); }
        case SCICStubProfileEasyGatingCopyString: { void *(*o)(uint32_t) = (void *)s->orig; return o((uint32_t)((uintptr_t)a0)); }
        case SCICStubProfileTALIdToName: { void *(*o)(uint64_t) = (void *)s->orig; return o((uint64_t)((uintptr_t)a0)); }
        default: return NULL;
    }
}

static void call_orig_action(SCICStubSlot *s, void *a0, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7) {
    if (!s || !s->orig) return;
    void (*o)(void *, void *, void *, void *, void *, void *, void *, void *) = (void *)s->orig;
    o(a0, a1, a2, a3, a4, a5, a6, a7);
}

#define DEFINE_BOOL_STUB(i) \
static bool stub_bool_##i(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
    SCICStubSlot *s=&g_slots[i]; atomic_fetch_add(&s->hits,1); if(s->profile==SCICStubProfileIGMobileConfigBoolean){ int pf=SCIParamDescriptorForcedValueForMobileConfigBoolArgs(a0,a1,a2,a3); if(pf>=0){ atomic_store(&s->observedBool,pf?1:0); return pf!=0; }} bool real=call_orig_bool(s,a0,a1,a2,a3,a4,a5,a6,a7); atomic_store(&s->observedBool, real?1:0); int f=atomic_load(&s->forceBool); return f<0 ? real : (f!=0); }
#define DEFINE_INT64_STUB(i) \
static int64_t stub_i64_##i(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
    SCICStubSlot *s=&g_slots[i]; atomic_fetch_add(&s->hits,1); int64_t real=call_orig_int64(s,a0,a1,a2,a3,a4,a5,a6,a7); atomic_store(&s->observedInt64, real); return atomic_load(&s->hasTypedForce)?atomic_load(&s->forceInt64):real; }
#define DEFINE_DOUBLE_STUB(i) \
static double stub_double_##i(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
    SCICStubSlot *s=&g_slots[i]; atomic_fetch_add(&s->hits,1); double real=call_orig_double(s,a0,a1,a2,a3,a4,a5,a6,a7); atomic_store(&s->observedDouble, real); return atomic_load(&s->hasTypedForce)?atomic_load(&s->forceDouble):real; }
#define DEFINE_PTR_STUB(i) \
static void *stub_ptr_##i(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
    SCICStubSlot *s=&g_slots[i]; atomic_fetch_add(&s->hits,1); void *real=call_orig_ptr(s,a0,a1,a2,a3,a4,a5,a6,a7); s->observedString=real; if(!atomic_load(&s->hasTypedForce)||!s->forceString) return real; if(s->profile==SCICStubProfileEasyGatingCopyString) return (void *)CFRetain((CFTypeRef)s->forceString); return s->forceString; }
#define DEFINE_ACTION_STUB(i) \
static void stub_action_##i(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
    SCICStubSlot *s=&g_slots[i]; atomic_fetch_add(&s->hits,1); call_orig_action(s,a0,a1,a2,a3,a4,a5,a6,a7); }

#define DEFINE_ALL(i) DEFINE_BOOL_STUB(i) DEFINE_INT64_STUB(i) DEFINE_DOUBLE_STUB(i) DEFINE_PTR_STUB(i) DEFINE_ACTION_STUB(i)
DEFINE_ALL(0)  DEFINE_ALL(1)  DEFINE_ALL(2)  DEFINE_ALL(3)  DEFINE_ALL(4)  DEFINE_ALL(5)  DEFINE_ALL(6)  DEFINE_ALL(7)
DEFINE_ALL(8)  DEFINE_ALL(9)  DEFINE_ALL(10) DEFINE_ALL(11) DEFINE_ALL(12) DEFINE_ALL(13) DEFINE_ALL(14) DEFINE_ALL(15)
DEFINE_ALL(16) DEFINE_ALL(17) DEFINE_ALL(18) DEFINE_ALL(19) DEFINE_ALL(20) DEFINE_ALL(21) DEFINE_ALL(22) DEFINE_ALL(23)
DEFINE_ALL(24) DEFINE_ALL(25) DEFINE_ALL(26) DEFINE_ALL(27) DEFINE_ALL(28) DEFINE_ALL(29) DEFINE_ALL(30) DEFINE_ALL(31)
DEFINE_ALL(32) DEFINE_ALL(33) DEFINE_ALL(34) DEFINE_ALL(35) DEFINE_ALL(36) DEFINE_ALL(37) DEFINE_ALL(38) DEFINE_ALL(39)
DEFINE_ALL(40) DEFINE_ALL(41) DEFINE_ALL(42) DEFINE_ALL(43) DEFINE_ALL(44) DEFINE_ALL(45) DEFINE_ALL(46) DEFINE_ALL(47)
DEFINE_ALL(48) DEFINE_ALL(49) DEFINE_ALL(50) DEFINE_ALL(51) DEFINE_ALL(52) DEFINE_ALL(53) DEFINE_ALL(54) DEFINE_ALL(55)
DEFINE_ALL(56) DEFINE_ALL(57) DEFINE_ALL(58) DEFINE_ALL(59) DEFINE_ALL(60) DEFINE_ALL(61) DEFINE_ALL(62) DEFINE_ALL(63)
DEFINE_ALL(64) DEFINE_ALL(65) DEFINE_ALL(66) DEFINE_ALL(67) DEFINE_ALL(68) DEFINE_ALL(69) DEFINE_ALL(70) DEFINE_ALL(71)
DEFINE_ALL(72) DEFINE_ALL(73) DEFINE_ALL(74) DEFINE_ALL(75) DEFINE_ALL(76) DEFINE_ALL(77) DEFINE_ALL(78) DEFINE_ALL(79)
DEFINE_ALL(80) DEFINE_ALL(81) DEFINE_ALL(82) DEFINE_ALL(83) DEFINE_ALL(84) DEFINE_ALL(85) DEFINE_ALL(86) DEFINE_ALL(87)
DEFINE_ALL(88) DEFINE_ALL(89) DEFINE_ALL(90) DEFINE_ALL(91) DEFINE_ALL(92) DEFINE_ALL(93) DEFINE_ALL(94) DEFINE_ALL(95)

#define ARR(kind) static void *g_##kind##_repls[MAX_STUBS] = {
#define ROW(kind,i) (void*)stub_##kind##_##i
ARR(bool) ROW(bool,0),ROW(bool,1),ROW(bool,2),ROW(bool,3),ROW(bool,4),ROW(bool,5),ROW(bool,6),ROW(bool,7),ROW(bool,8),ROW(bool,9),ROW(bool,10),ROW(bool,11),ROW(bool,12),ROW(bool,13),ROW(bool,14),ROW(bool,15),ROW(bool,16),ROW(bool,17),ROW(bool,18),ROW(bool,19),ROW(bool,20),ROW(bool,21),ROW(bool,22),ROW(bool,23),ROW(bool,24),ROW(bool,25),ROW(bool,26),ROW(bool,27),ROW(bool,28),ROW(bool,29),ROW(bool,30),ROW(bool,31),ROW(bool,32),ROW(bool,33),ROW(bool,34),ROW(bool,35),ROW(bool,36),ROW(bool,37),ROW(bool,38),ROW(bool,39),ROW(bool,40),ROW(bool,41),ROW(bool,42),ROW(bool,43),ROW(bool,44),ROW(bool,45),ROW(bool,46),ROW(bool,47),ROW(bool,48),ROW(bool,49),ROW(bool,50),ROW(bool,51),ROW(bool,52),ROW(bool,53),ROW(bool,54),ROW(bool,55),ROW(bool,56),ROW(bool,57),ROW(bool,58),ROW(bool,59),ROW(bool,60),ROW(bool,61),ROW(bool,62),ROW(bool,63),ROW(bool,64),ROW(bool,65),ROW(bool,66),ROW(bool,67),ROW(bool,68),ROW(bool,69),ROW(bool,70),ROW(bool,71),ROW(bool,72),ROW(bool,73),ROW(bool,74),ROW(bool,75),ROW(bool,76),ROW(bool,77),ROW(bool,78),ROW(bool,79),ROW(bool,80),ROW(bool,81),ROW(bool,82),ROW(bool,83),ROW(bool,84),ROW(bool,85),ROW(bool,86),ROW(bool,87),ROW(bool,88),ROW(bool,89),ROW(bool,90),ROW(bool,91),ROW(bool,92),ROW(bool,93),ROW(bool,94),ROW(bool,95) };
ARR(i64) ROW(i64,0),ROW(i64,1),ROW(i64,2),ROW(i64,3),ROW(i64,4),ROW(i64,5),ROW(i64,6),ROW(i64,7),ROW(i64,8),ROW(i64,9),ROW(i64,10),ROW(i64,11),ROW(i64,12),ROW(i64,13),ROW(i64,14),ROW(i64,15),ROW(i64,16),ROW(i64,17),ROW(i64,18),ROW(i64,19),ROW(i64,20),ROW(i64,21),ROW(i64,22),ROW(i64,23),ROW(i64,24),ROW(i64,25),ROW(i64,26),ROW(i64,27),ROW(i64,28),ROW(i64,29),ROW(i64,30),ROW(i64,31),ROW(i64,32),ROW(i64,33),ROW(i64,34),ROW(i64,35),ROW(i64,36),ROW(i64,37),ROW(i64,38),ROW(i64,39),ROW(i64,40),ROW(i64,41),ROW(i64,42),ROW(i64,43),ROW(i64,44),ROW(i64,45),ROW(i64,46),ROW(i64,47),ROW(i64,48),ROW(i64,49),ROW(i64,50),ROW(i64,51),ROW(i64,52),ROW(i64,53),ROW(i64,54),ROW(i64,55),ROW(i64,56),ROW(i64,57),ROW(i64,58),ROW(i64,59),ROW(i64,60),ROW(i64,61),ROW(i64,62),ROW(i64,63),ROW(i64,64),ROW(i64,65),ROW(i64,66),ROW(i64,67),ROW(i64,68),ROW(i64,69),ROW(i64,70),ROW(i64,71),ROW(i64,72),ROW(i64,73),ROW(i64,74),ROW(i64,75),ROW(i64,76),ROW(i64,77),ROW(i64,78),ROW(i64,79),ROW(i64,80),ROW(i64,81),ROW(i64,82),ROW(i64,83),ROW(i64,84),ROW(i64,85),ROW(i64,86),ROW(i64,87),ROW(i64,88),ROW(i64,89),ROW(i64,90),ROW(i64,91),ROW(i64,92),ROW(i64,93),ROW(i64,94),ROW(i64,95) };
ARR(double) ROW(double,0),ROW(double,1),ROW(double,2),ROW(double,3),ROW(double,4),ROW(double,5),ROW(double,6),ROW(double,7),ROW(double,8),ROW(double,9),ROW(double,10),ROW(double,11),ROW(double,12),ROW(double,13),ROW(double,14),ROW(double,15),ROW(double,16),ROW(double,17),ROW(double,18),ROW(double,19),ROW(double,20),ROW(double,21),ROW(double,22),ROW(double,23),ROW(double,24),ROW(double,25),ROW(double,26),ROW(double,27),ROW(double,28),ROW(double,29),ROW(double,30),ROW(double,31),ROW(double,32),ROW(double,33),ROW(double,34),ROW(double,35),ROW(double,36),ROW(double,37),ROW(double,38),ROW(double,39),ROW(double,40),ROW(double,41),ROW(double,42),ROW(double,43),ROW(double,44),ROW(double,45),ROW(double,46),ROW(double,47),ROW(double,48),ROW(double,49),ROW(double,50),ROW(double,51),ROW(double,52),ROW(double,53),ROW(double,54),ROW(double,55),ROW(double,56),ROW(double,57),ROW(double,58),ROW(double,59),ROW(double,60),ROW(double,61),ROW(double,62),ROW(double,63),ROW(double,64),ROW(double,65),ROW(double,66),ROW(double,67),ROW(double,68),ROW(double,69),ROW(double,70),ROW(double,71),ROW(double,72),ROW(double,73),ROW(double,74),ROW(double,75),ROW(double,76),ROW(double,77),ROW(double,78),ROW(double,79),ROW(double,80),ROW(double,81),ROW(double,82),ROW(double,83),ROW(double,84),ROW(double,85),ROW(double,86),ROW(double,87),ROW(double,88),ROW(double,89),ROW(double,90),ROW(double,91),ROW(double,92),ROW(double,93),ROW(double,94),ROW(double,95) };
ARR(ptr) ROW(ptr,0),ROW(ptr,1),ROW(ptr,2),ROW(ptr,3),ROW(ptr,4),ROW(ptr,5),ROW(ptr,6),ROW(ptr,7),ROW(ptr,8),ROW(ptr,9),ROW(ptr,10),ROW(ptr,11),ROW(ptr,12),ROW(ptr,13),ROW(ptr,14),ROW(ptr,15),ROW(ptr,16),ROW(ptr,17),ROW(ptr,18),ROW(ptr,19),ROW(ptr,20),ROW(ptr,21),ROW(ptr,22),ROW(ptr,23),ROW(ptr,24),ROW(ptr,25),ROW(ptr,26),ROW(ptr,27),ROW(ptr,28),ROW(ptr,29),ROW(ptr,30),ROW(ptr,31),ROW(ptr,32),ROW(ptr,33),ROW(ptr,34),ROW(ptr,35),ROW(ptr,36),ROW(ptr,37),ROW(ptr,38),ROW(ptr,39),ROW(ptr,40),ROW(ptr,41),ROW(ptr,42),ROW(ptr,43),ROW(ptr,44),ROW(ptr,45),ROW(ptr,46),ROW(ptr,47),ROW(ptr,48),ROW(ptr,49),ROW(ptr,50),ROW(ptr,51),ROW(ptr,52),ROW(ptr,53),ROW(ptr,54),ROW(ptr,55),ROW(ptr,56),ROW(ptr,57),ROW(ptr,58),ROW(ptr,59),ROW(ptr,60),ROW(ptr,61),ROW(ptr,62),ROW(ptr,63),ROW(ptr,64),ROW(ptr,65),ROW(ptr,66),ROW(ptr,67),ROW(ptr,68),ROW(ptr,69),ROW(ptr,70),ROW(ptr,71),ROW(ptr,72),ROW(ptr,73),ROW(ptr,74),ROW(ptr,75),ROW(ptr,76),ROW(ptr,77),ROW(ptr,78),ROW(ptr,79),ROW(ptr,80),ROW(ptr,81),ROW(ptr,82),ROW(ptr,83),ROW(ptr,84),ROW(ptr,85),ROW(ptr,86),ROW(ptr,87),ROW(ptr,88),ROW(ptr,89),ROW(ptr,90),ROW(ptr,91),ROW(ptr,92),ROW(ptr,93),ROW(ptr,94),ROW(ptr,95) };
ARR(action) ROW(action,0),ROW(action,1),ROW(action,2),ROW(action,3),ROW(action,4),ROW(action,5),ROW(action,6),ROW(action,7),ROW(action,8),ROW(action,9),ROW(action,10),ROW(action,11),ROW(action,12),ROW(action,13),ROW(action,14),ROW(action,15),ROW(action,16),ROW(action,17),ROW(action,18),ROW(action,19),ROW(action,20),ROW(action,21),ROW(action,22),ROW(action,23),ROW(action,24),ROW(action,25),ROW(action,26),ROW(action,27),ROW(action,28),ROW(action,29),ROW(action,30),ROW(action,31),ROW(action,32),ROW(action,33),ROW(action,34),ROW(action,35),ROW(action,36),ROW(action,37),ROW(action,38),ROW(action,39),ROW(action,40),ROW(action,41),ROW(action,42),ROW(action,43),ROW(action,44),ROW(action,45),ROW(action,46),ROW(action,47),ROW(action,48),ROW(action,49),ROW(action,50),ROW(action,51),ROW(action,52),ROW(action,53),ROW(action,54),ROW(action,55),ROW(action,56),ROW(action,57),ROW(action,58),ROW(action,59),ROW(action,60),ROW(action,61),ROW(action,62),ROW(action,63),ROW(action,64),ROW(action,65),ROW(action,66),ROW(action,67),ROW(action,68),ROW(action,69),ROW(action,70),ROW(action,71),ROW(action,72),ROW(action,73),ROW(action,74),ROW(action,75),ROW(action,76),ROW(action,77),ROW(action,78),ROW(action,79),ROW(action,80),ROW(action,81),ROW(action,82),ROW(action,83),ROW(action,84),ROW(action,85),ROW(action,86),ROW(action,87),ROW(action,88),ROW(action,89),ROW(action,90),ROW(action,91),ROW(action,92),ROW(action,93),ROW(action,94),ROW(action,95) };

static NSDictionary *SCIDictPref(NSString *key) { NSDictionary *d = [SCIUtils getDictPref:key]; return [d isKindOfClass:NSDictionary.class] ? d : @{}; }
static NSString *SCIStringPref(id v) { return [v isKindOfClass:NSString.class] ? v : [v respondsToSelector:@selector(description)] ? [v description] : @""; }

static void SCIStubApplyTypedToSlot(SCICStubSlot *slot, NSDictionary *typed) {
    if (!slot) return;
    NSString *key = [NSString stringWithUTF8String:slot->name] ?: @"";
    NSDictionary *entry = [typed[key] isKindOfClass:NSDictionary.class] ? typed[key] : nil;
    SCICReturnKind rk = SCIReturnKindForProfile(slot->profile);
    if (!entry || rk == SCICReturnKindBool || rk == SCICReturnKindAction || rk == SCICReturnKindUnknown) { atomic_store(&slot->hasTypedForce, 0); return; }
    id value = entry[@"value"];
    atomic_store(&slot->hasTypedForce, 1);
    if (rk == SCICReturnKindInt64) atomic_store(&slot->forceInt64, (long long)[value longLongValue]);
    else if (rk == SCICReturnKindDouble) atomic_store(&slot->forceDouble, [value doubleValue]);
    else if (rk == SCICReturnKindString) {
        if (slot->forceString) CFRelease(slot->forceString);
        NSString *s = SCIStringPref(value) ?: @"";
        slot->forceString = (void *)CFBridgingRetain([s copy]);
    }
}

static void SCIStubRefreshCache(void) {
    SCIParamDescriptorRefreshCache();
    NSDictionary *ov = SCIDictPref(kForceOverrides);
    NSDictionary *typed = SCIDictPref(kTypedOverrides);
    for (int i = 0; i < g_slot_count; i++) {
        NSString *key = [NSString stringWithUTF8String:g_slots[i].name];
        id v = ov[key];
        if ([v isKindOfClass:NSNumber.class] && SCIReturnKindForProfile(g_slots[i].profile) == SCICReturnKindBool) atomic_store(&g_slots[i].forceBool, [v boolValue] ? 1 : 0);
        else atomic_store(&g_slots[i].forceBool, -1);
        SCIStubApplyTypedToSlot(&g_slots[i], typed);
    }
}

@implementation SCICSymbolStub

+ (BOOL)isBoolLikeSymbol:(NSString *)name { return SCIStubSymbolLooksBool(name); }
+ (BOOL)isHookableSymbol:(NSString *)name { SCICReturnKind k = SCIReturnKindForProfile(SCIStubProfileForSymbol(name)); return k != SCICReturnKindUnknown; }
+ (BOOL)isForceableSymbol:(NSString *)name { return SCIReturnKindForProfile(SCIStubProfileForSymbol(name)) == SCICReturnKindBool; }
+ (BOOL)isTypedForceableSymbol:(NSString *)name { SCICReturnKind k = SCIReturnKindForProfile(SCIStubProfileForSymbol(name)); return k == SCICReturnKindInt64 || k == SCICReturnKindDouble || k == SCICReturnKindString; }
+ (NSString *)returnKindForSymbol:(NSString *)name { return SCIReturnKindString(SCIReturnKindForProfile(SCIStubProfileForSymbol(name))); }
+ (NSString *)blacklistReasonForSymbol:(NSString *)name { return SCIStubBlacklistReason(name); }
+ (NSString *)notHookableReasonForSymbol:(NSString *)name { NSString *r = SCIStubBlacklistReason(name); if (r) return r; return [self isHookableSymbol:name] ? nil : @"ABI/profile not validated for C hook; list-only."; }
+ (NSString *)notForceableReasonForSymbol:(NSString *)name { NSString *r = SCIStubBlacklistReason(name); if (r) return r; if ([self isForceableSymbol:name] || [self isTypedForceableSymbol:name]) return nil; if ([[self returnKindForSymbol:name] isEqualToString:@"action"]) return @"action/registration hook: observe/log only unless arguments are mounted by a dedicated button."; return @"not forceable as BOOL; use typed force if available or DATA/param browser."; }

+ (BOOL)observeForSymbol:(NSString *)name { return [SCIDictPref(kObserveOverrides)[name ?: @""] boolValue]; }
+ (BOOL)setObserve:(BOOL)value forSymbol:(NSString *)name { if (![name isKindOfClass:NSString.class] || !name.length) return NO; if (value && ![self isHookableSymbol:name]) return NO; NSMutableDictionary *d = [SCIDictPref(kObserveOverrides) mutableCopy] ?: [NSMutableDictionary dictionary]; if (value) d[name]=@YES; else [d removeObjectForKey:name]; [SCIUtils setPref:d forKey:kObserveOverrides]; if (value) [self installStubForSymbol:name]; return YES; }
+ (NSArray<NSString *> *)observedSymbols { return SCIDictPref(kObserveOverrides).allKeys ?: @[]; }

+ (NSNumber *)forceForSymbol:(NSString *)name { id v=SCIDictPref(kForceOverrides)[name?:@""]; return [v isKindOfClass:NSNumber.class]?v:nil; }
+ (BOOL)setForce:(NSNumber *)value forSymbol:(NSString *)name { if (![name isKindOfClass:NSString.class] || !name.length) return NO; if (value && ![self isForceableSymbol:name]) return NO; NSMutableDictionary *d=[SCIDictPref(kForceOverrides) mutableCopy]?:[NSMutableDictionary dictionary]; if(value)d[name]=value; else [d removeObjectForKey:name]; [SCIUtils setPref:d forKey:kForceOverrides]; if(value)[self setObserve:YES forSymbol:name]; SCICStubSlot *s=slot_for(name.UTF8String); if(s) atomic_store(&s->forceBool, value?(value.boolValue?1:0):-1); if(value)[self installStubForSymbol:name]; return YES; }
+ (NSArray<NSString *> *)forcedSymbols { return SCIDictPref(kForceOverrides).allKeys ?: @[]; }

+ (NSDictionary<NSString *, id> *)typedForceForSymbol:(NSString *)name { id v=SCIDictPref(kTypedOverrides)[name?:@""]; return [v isKindOfClass:NSDictionary.class]?v:nil; }
+ (BOOL)setTypedForceValue:(id)value returnKind:(NSString *)returnKind forSymbol:(NSString *)name { if (![name isKindOfClass:NSString.class] || !name.length) return NO; if (value && ![self isTypedForceableSymbol:name]) return NO; NSMutableDictionary *d=[SCIDictPref(kTypedOverrides) mutableCopy]?:[NSMutableDictionary dictionary]; if(value)d[name]=@{@"kind":returnKind?:([self returnKindForSymbol:name]?:@"unknown"),@"value":value}; else [d removeObjectForKey:name]; [SCIUtils setPref:d forKey:kTypedOverrides]; if(value)[self setObserve:YES forSymbol:name]; SCICStubSlot *s=slot_for(name.UTF8String); if(s) SCIStubApplyTypedToSlot(s, d); if(value)[self installStubForSymbol:name]; return YES; }
+ (NSArray<NSString *> *)typedForcedSymbols { return SCIDictPref(kTypedOverrides).allKeys ?: @[]; }

+ (BOOL)hookInstalledForSymbol:(NSString *)name { SCICStubSlot *s=slot_for(name.UTF8String); return s && s->orig; }
+ (NSUInteger)callCountForSymbol:(NSString *)name { SCICStubSlot *s=slot_for(name.UTF8String); return s ? atomic_load(&s->hits) : 0; }
+ (NSNumber *)observedValueForSymbol:(NSString *)name { SCICStubSlot *s=slot_for(name.UTF8String); if(!s)return nil; int ov=atomic_load(&s->observedBool); return ov<0?nil:@(ov!=0); }
+ (id)observedTypedValueForSymbol:(NSString *)name { SCICStubSlot *s=slot_for(name.UTF8String); if(!s)return nil; SCICReturnKind k=SCIReturnKindForProfile(s->profile); if(k==SCICReturnKindInt64)return @(atomic_load(&s->observedInt64)); if(k==SCICReturnKindDouble)return @(atomic_load(&s->observedDouble)); if(k==SCICReturnKindString && s->observedString)return [NSString stringWithFormat:@"%p",s->observedString]; return nil; }
+ (void)refreshCacheFromDefaults { SCIStubRefreshCache(); }


+ (BOOL)isParamDescriptorSymbol:(NSString *)name { return SCIParamDescriptorSymbolKnown(name); }
+ (NSNumber *)forceForParamDescriptorSymbol:(NSString *)name { id v = SCIParamBoolPref()[name ?: @""]; return [v isKindOfClass:NSNumber.class] ? v : nil; }
+ (BOOL)setParamDescriptorForce:(NSNumber *)value forSymbol:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length || !SCIParamDescriptorSymbolKnown(name)) return NO;
    NSMutableDictionary *d = [SCIParamBoolPref() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) d[name] = value; else [d removeObjectForKey:name];
    [SCIUtils setPref:d forKey:kParamBoolOverrides];
    if (value && ![self hookInstalledForSymbol:@"IGMobileConfigBooleanValueForInternalUse"]) [self installStubForSymbol:@"IGMobileConfigBooleanValueForInternalUse"];
    if (value && !param_slot_for_name(name.UTF8String) && g_param_slot_count < MAX_PARAM_DESCRIPTOR_STUBS) {
        SCIParamDescriptorSlot *slot = &g_param_slots[g_param_slot_count++];
        memset(slot, 0, sizeof(*slot));
        strncpy(slot->name, name.UTF8String, sizeof(slot->name)-1);
    }
    SCIParamDescriptorRefreshCache();
    return YES;
}
+ (NSArray<NSString *> *)forcedParamDescriptorSymbols { return SCIParamBoolPref().allKeys ?: @[]; }


+ (void *)replacementForKind:(SCICReturnKind)kind index:(int)idx { if(idx<0||idx>=MAX_STUBS)return NULL; if(kind==SCICReturnKindBool)return g_bool_repls[idx]; if(kind==SCICReturnKindInt64)return g_i64_repls[idx]; if(kind==SCICReturnKindDouble)return g_double_repls[idx]; if(kind==SCICReturnKindString)return g_ptr_repls[idx]; if(kind==SCICReturnKindAction)return g_action_repls[idx]; return NULL; }

+ (NSUInteger)installStubsForSymbols:(NSSet<NSString *> *)wanted { if(![wanted isKindOfClass:NSSet.class]||wanted.count==0)return 0; NSDictionary *forced=SCIDictPref(kForceOverrides); NSDictionary *typed=SCIDictPref(kTypedOverrides); struct rebinding rebs[MAX_STUBS]; int nreb=0; for(NSString *name in wanted){ if(nreb>=MAX_STUBS||g_slot_count>=MAX_STUBS)break; if(![name isKindOfClass:NSString.class]||!name.length)continue; SCICStubProfile profile=SCIStubProfileForSymbol(name); SCICReturnKind kind=SCIReturnKindForProfile(profile); if(kind==SCICReturnKindUnknown){SLOG("skip non-hookable %{public}s",name.UTF8String);continue;} if(slot_for(name.UTF8String)){SCIStubRefreshCache();continue;} NSString *under=[@"_" stringByAppendingString:name]; if(dlsym(RTLD_DEFAULT,name.UTF8String)==NULL&&dlsym(RTLD_DEFAULT,under.UTF8String)==NULL){SLOG("skip %{public}s — not resolvable via dlsym",name.UTF8String);continue;} SCICStubSlot *slot=&g_slots[g_slot_count]; memset(slot,0,sizeof(*slot)); strncpy(slot->name,name.UTF8String,sizeof(slot->name)-1); slot->profile=profile; atomic_store(&slot->forceBool,-1); atomic_store(&slot->hasTypedForce,0); atomic_store(&slot->hits,0); atomic_store(&slot->observedBool,-1); id v=forced[name]; if([v isKindOfClass:NSNumber.class]&&kind==SCICReturnKindBool)atomic_store(&slot->forceBool,[v boolValue]?1:0); SCIStubApplyTypedToSlot(slot,typed); slot->orig=NULL; rebs[nreb].name=slot->name; rebs[nreb].replacement=[self replacementForKind:kind index:g_slot_count]; rebs[nreb].replaced=(void **)&slot->orig; g_slot_count++; nreb++; SLOG("runtime rebind %{public}s kind=%{public}s forceBool=%d typed=%d",name.UTF8String,SCIReturnKindString(kind).UTF8String,atomic_load(&slot->forceBool),atomic_load(&slot->hasTypedForce)); } if(nreb==0)return 0; int rc=rebind_symbols(rebs,nreb); SLOG("runtime rebind_symbols installed=%d rc=%d",nreb,rc); return (NSUInteger)nreb; }
+ (BOOL)installStubForSymbol:(NSString *)name { if(![name isKindOfClass:NSString.class]||!name.length)return NO; if(![self isHookableSymbol:name])return NO; if(slot_for(name.UTF8String)){SCIStubRefreshCache();return YES;} return [self installStubsForSymbols:[NSSet setWithObject:name]]>0; }
+ (void)reinstallPersistedStubs { NSMutableSet *wanted=[NSMutableSet set]; [wanted addObjectsFromArray:SCIDictPref(kObserveOverrides).allKeys?:@[]]; [wanted addObjectsFromArray:SCIDictPref(kForceOverrides).allKeys?:@[]]; [wanted addObjectsFromArray:SCIDictPref(kTypedOverrides).allKeys?:@[]];
    if (SCIParamBoolPref().count) [wanted addObject:@"IGMobileConfigBooleanValueForInternalUse"]; if(wanted.count==0){SLOG("no persisted stubs");return;} [self installStubsForSymbols:wanted]; }

@end
