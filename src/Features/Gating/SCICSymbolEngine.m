// SCICSymbolEngine.m
#import "SCICSymbolEngine.h"
#import "../../Utils.h"
#import "../../../modules/fishhook/fishhook.h"
#import <objc/runtime.h>
#import <os/log.h>
#import <stdatomic.h>

#define CLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] CSym " fmt,##__VA_ARGS__)

static NSString *const kCOverridesKey = @"sci_c_symbol_overrides";       // { "C#name": @(1) }
static NSString *const kCIDOverridesKey = @"sci_c_symbol_id_overrides";  // { "C#name": { "412": @(1) } }
static NSString *const kCMasterKey = @"sci_c_symbol_force_enabled";

// ───────────────────────────────────────────────────────────────────────────
// Static C cache (hot path). No Obj-C, no NSUserDefaults inside replacements.
// ───────────────────────────────────────────────────────────────────────────

#define MAX_SYMS 32
#define MAX_IDS_PER_SYM 256

typedef struct {
	const char *name;          // import symbol name (without leading underscore)
	SCICAbiFamily family;
	atomic_int force;          // -1 = no global override, 0 = force NO, 1 = force YES
	atomic_uint hits;          // call count since launch
	// captured gating IDs (families w0/w1) and their forced/observed values
	atomic_int id_count;
	int32_t ids[MAX_IDS_PER_SYM];
	atomic_schar id_force[MAX_IDS_PER_SYM];     // -1 none, 0 NO, 1 YES
	atomic_schar id_observed[MAX_IDS_PER_SYM];  // -1 unknown, 0/1 last real value
	void *orig;                // original function pointer (filled by fishhook)
} SCICSlot;

static SCICSlot g_slots[MAX_SYMS];
static int g_slot_count = 0;

static SCICSlot *slot_for_name_c(const char *name) {
	for (int i = 0; i < g_slot_count; i++)
		if (strcmp(g_slots[i].name, name) == 0) return &g_slots[i];
	return NULL;
}

// Record a gating ID for a slot, return its index (or -1 if full). Lock-free-ish:
// only the (single) caller path writes; duplicates tolerated rarely.
static int slot_note_id(SCICSlot *s, int32_t gid, int real_value) {
	int n = atomic_load(&s->id_count);
	for (int i = 0; i < n; i++) {
		if (s->ids[i] == gid) {
			if (real_value >= 0) atomic_store(&s->id_observed[i], (signed char)real_value);
			return i;
		}
	}
	if (n >= MAX_IDS_PER_SYM) return -1;
	s->ids[n] = gid;
	atomic_store(&s->id_force[n], -1);
	atomic_store(&s->id_observed[n], real_value >= 0 ? (signed char)real_value : -1);
	atomic_store(&s->id_count, n + 1);
	return n;
}

// Decide final return value for a slot given a (possibly captured) gating id.
// Returns: -1 = passthrough (use orig), 0/1 = forced value.
static int slot_decision(SCICSlot *s, int has_id, int32_t gid, int real_value) {
	if (has_id) {
		int n = atomic_load(&s->id_count);
		for (int i = 0; i < n; i++) {
			if (s->ids[i] == gid) {
				int f = atomic_load(&s->id_force[i]);
				if (f >= 0) return f;
				break;
			}
		}
	}
	(void)real_value;
	int gf = atomic_load(&s->force);
	if (gf >= 0) return gf;
	return -1;
}

// ───────────────────────────────────────────────────────────────────────────
// Typed replacements per ABI family.
// We always call orig first to (a) keep app state consistent and (b) capture the
// real value, then apply the override decision.
// ───────────────────────────────────────────────────────────────────────────

// Family OpaqueBool: BOOL f(a,b,c,d,e,f,g,h)  — we pass through up to 8 ptr-args.
#define DEFINE_OPAQUE(slotvar) \
static bool repl_opaque_##slotvar(void *a0,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6,void *a7){ \
	SCICSlot *s=&g_slots[slotvar]; atomic_fetch_add(&s->hits,1); \
	bool real=false; \
	if(s->orig){ bool(*o)(void*,void*,void*,void*,void*,void*,void*,void*)=(void*)s->orig; real=o(a0,a1,a2,a3,a4,a5,a6,a7);} \
	int d=slot_decision(s,0,0,real?1:0); \
	return d<0 ? real : (d!=0); \
}

// Family GatingId_w0: BOOL f(int32 gid, a1..a6). id in first int arg.
#define DEFINE_GID_W0(slotvar) \
static bool repl_gidw0_##slotvar(int32_t gid,void *a1,void *a2,void *a3,void *a4,void *a5,void *a6){ \
	SCICSlot *s=&g_slots[slotvar]; atomic_fetch_add(&s->hits,1); \
	bool real=false; \
	if(s->orig){ bool(*o)(int32_t,void*,void*,void*,void*,void*,void*)=(void*)s->orig; real=o(gid,a1,a2,a3,a4,a5,a6);} \
	slot_note_id(s,gid,real?1:0); \
	int d=slot_decision(s,1,gid,real?1:0); \
	return d<0 ? real : (d!=0); \
}

// Family GatingId_w1: BOOL f(void* a0, int32 gid, a2..a6). id in second arg.
#define DEFINE_GID_W1(slotvar) \
static bool repl_gidw1_##slotvar(void *a0,int32_t gid,void *a2,void *a3,void *a4,void *a5,void *a6){ \
	SCICSlot *s=&g_slots[slotvar]; atomic_fetch_add(&s->hits,1); \
	bool real=false; \
	if(s->orig){ bool(*o)(void*,int32_t,void*,void*,void*,void*,void*)=(void*)s->orig; real=o(a0,gid,a2,a3,a4,a5,a6);} \
	slot_note_id(s,gid,real?1:0); \
	int d=slot_decision(s,1,gid,real?1:0); \
	return d<0 ? real : (d!=0); \
}

// We declare a fixed set of replacement instances bound to slot indices 0..N.
// Slots are assigned in the same order as g_symbol_defs below.
DEFINE_GID_W0(0)   // EasyGatingGetBoolean_Internal_DoNotUseOrMock
DEFINE_GID_W0(1)   // EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock
DEFINE_GID_W1(2)   // MCQEasyGatingGetBooleanInternalDoNotUseOrMock
DEFINE_OPAQUE(3)   // IGMobileConfigBooleanValueForInternalUse
DEFINE_OPAQUE(4)   // MSGCSessionedMobileConfigGetBoolean
DEFINE_OPAQUE(5)   // MCIExperimentCacheGetMobileConfigBoolean
DEFINE_OPAQUE(6)   // MCIExtensionExperimentCacheGetMobileConfigBoolean
DEFINE_OPAQUE(7)   // GetMobileConfigBoolean
DEFINE_OPAQUE(8)   // EasyGatingPlatformGetBoolean
DEFINE_OPAQUE(9)   // IGDirectOneWayGatingGetBoolValue

// Definition table — order MUST match the DEFINE_* slot indices above.
typedef struct { const char *name; SCICAbiFamily fam; void *repl; const char *display; } SCICDef;
static SCICDef g_symbol_defs[] = {
	{ "EasyGatingGetBoolean_Internal_DoNotUseOrMock",                 SCICAbiFamilyGatingId_w0, (void*)repl_gidw0_0, "EasyGating (Internal)" },
	{ "EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock", SCICAbiFamilyGatingId_w0, (void*)repl_gidw0_1, "EasyGating (AuthData)" },
	{ "MCQEasyGatingGetBooleanInternalDoNotUseOrMock",                SCICAbiFamilyGatingId_w1, (void*)repl_gidw1_2, "MCQ EasyGating (Internal)" },
	{ "IGMobileConfigBooleanValueForInternalUse",                     SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_3, "MobileConfig (InternalUse)" },
	{ "MSGCSessionedMobileConfigGetBoolean",                          SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_4, "MobileConfig (Sessioned)" },
	{ "MCIExperimentCacheGetMobileConfigBoolean",                     SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_5, "MobileConfig (ExpCache)" },
	{ "MCIExtensionExperimentCacheGetMobileConfigBoolean",            SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_6, "MobileConfig (ExtExpCache)" },
	{ "GetMobileConfigBoolean",                                       SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_7, "MobileConfig (Get)" },
	{ "EasyGatingPlatformGetBoolean",                                 SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_8, "EasyGating (Platform)" },
	{ "IGDirectOneWayGatingGetBoolValue",                             SCICAbiFamilyOpaqueBool,  (void*)repl_opaque_9, "OneWayGating (Direct)" },
};
static const int g_def_count = (int)(sizeof(g_symbol_defs)/sizeof(g_symbol_defs[0]));

static void ensure_slots_initialized(void) {
	if (g_slot_count) return;
	for (int i = 0; i < g_def_count && i < MAX_SYMS; i++) {
		SCICSlot *s = &g_slots[i];
		s->name = g_symbol_defs[i].name;
		s->family = g_symbol_defs[i].fam;
		atomic_store(&s->force, -1);
		atomic_store(&s->hits, 0);
		atomic_store(&s->id_count, 0);
		s->orig = NULL;
		g_slot_count++;
	}
}

// ───────────────────────────────────────────────────────────────────────────
// Override persistence helpers (UI side; not on hot path).
// ───────────────────────────────────────────────────────────────────────────

static void push_global_override_to_cache(NSString *name, NSNumber *val) {
	const char *cn = name.UTF8String;
	SCICSlot *s = slot_for_name_c(cn);
	if (!s) return;
	atomic_store(&s->force, val ? (val.boolValue ? 1 : 0) : -1);
}

static void push_id_override_to_cache(NSString *name, int32_t gid, NSNumber *val) {
	SCICSlot *s = slot_for_name_c(name.UTF8String);
	if (!s) return;
	int idx = slot_note_id(s, gid, -1);
	if (idx < 0) return;
	atomic_store(&s->id_force[idx], val ? (val.boolValue ? 1 : 0) : -1);
}

@implementation SCICSymbol
- (NSString *)overrideKey { return [NSString stringWithFormat:@"C#%@", self.symbolName]; }
- (NSNumber *)override { return [SCICSymbolEngine overrideForSymbolName:self.symbolName]; }
- (BOOL)hookInstalled {
	SCICSlot *s = slot_for_name_c(self.symbolName.UTF8String);
	return s && s->orig != NULL;
}
- (NSUInteger)observedCallCount { return [SCICSymbolEngine callCountForSymbolName:self.symbolName]; }
- (NSArray<NSNumber *> *)observedIDs { return [SCICSymbolEngine observedIDsForSymbolName:self.symbolName]; }
@end

@implementation SCICSymbolEngine

+ (NSArray<SCICSymbol *> *)allSymbols {
	ensure_slots_initialized();
	NSMutableArray *out = [NSMutableArray array];
	for (int i = 0; i < g_def_count; i++) {
		SCICSymbol *sym = [SCICSymbol new];
		sym.symbolName  = @(g_symbol_defs[i].name);
		sym.displayName = @(g_symbol_defs[i].display);
		sym.originImage = @"FBSharedFramework";
		sym.abiFamily   = g_symbol_defs[i].fam;
		[out addObject:sym];
	}
	return out;
}

+ (BOOL)masterEnabled { return [SCIUtils getBoolPref:kCMasterKey]; }

+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name {
	NSDictionary *d = [SCIUtils getDictPref:kCOverridesKey];
	id v = d[[NSString stringWithFormat:@"C#%@", name]];
	return [v isKindOfClass:NSNumber.class] ? v : nil;
}

+ (void)setOverride:(nullable NSNumber *)value forSymbolName:(NSString *)name {
	NSMutableDictionary *d = [[SCIUtils getDictPref:kCOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *k = [NSString stringWithFormat:@"C#%@", name];
	if (value) d[k] = value; else [d removeObjectForKey:k];
	[SCIUtils setPref:d forKey:kCOverridesKey];
	push_global_override_to_cache(name, value);
}

+ (nullable NSNumber *)overrideForSymbolName:(NSString *)name gatingID:(int32_t)gatingID {
	NSDictionary *all = [SCIUtils getDictPref:kCIDOverridesKey];
	NSDictionary *perSym = all[[NSString stringWithFormat:@"C#%@", name]];
	id v = perSym[[NSString stringWithFormat:@"%d", gatingID]];
	return [v isKindOfClass:NSNumber.class] ? v : nil;
}

+ (void)setOverride:(nullable NSNumber *)value forSymbolName:(NSString *)name gatingID:(int32_t)gatingID {
	NSMutableDictionary *all = [[SCIUtils getDictPref:kCIDOverridesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *symKey = [NSString stringWithFormat:@"C#%@", name];
	NSMutableDictionary *perSym = [all[symKey] mutableCopy] ?: [NSMutableDictionary dictionary];
	NSString *idKey = [NSString stringWithFormat:@"%d", gatingID];
	if (value) perSym[idKey] = value; else [perSym removeObjectForKey:idKey];
	all[symKey] = perSym;
	[SCIUtils setPref:all forKey:kCIDOverridesKey];
	push_id_override_to_cache(name, gatingID, value);
}

+ (NSUInteger)callCountForSymbolName:(NSString *)name {
	SCICSlot *s = slot_for_name_c(name.UTF8String);
	return s ? atomic_load(&s->hits) : 0;
}

+ (NSArray<NSNumber *> *)observedIDsForSymbolName:(NSString *)name {
	SCICSlot *s = slot_for_name_c(name.UTF8String);
	if (!s) return @[];
	NSMutableArray *out = [NSMutableArray array];
	int n = atomic_load(&s->id_count);
	for (int i = 0; i < n; i++) [out addObject:@(s->ids[i])];
	return out;
}

+ (nullable NSNumber *)observedValueForSymbolName:(NSString *)name gatingID:(int32_t)gatingID {
	SCICSlot *s = slot_for_name_c(name.UTF8String);
	if (!s) return nil;
	int n = atomic_load(&s->id_count);
	for (int i = 0; i < n; i++) {
		if (s->ids[i] == gatingID) {
			signed char ov = atomic_load(&s->id_observed[i]);
			return ov < 0 ? nil : @(ov != 0);
		}
	}
	return nil;
}

// Install fishhook rebindings for symbols that have any persisted override
// (global or per-ID). Idempotent; the %ctor calls this once.
+ (void)reinstallPersistedHooks {
	ensure_slots_initialized();
	if (![self masterEnabled]) { CLOG("master off; skipping C-symbol hooks"); return; }

	// Load persisted overrides into the static cache first.
	NSDictionary *globals = [SCIUtils getDictPref:kCOverridesKey];
	for (NSString *k in globals) {
		if (![k hasPrefix:@"C#"]) continue;
		NSString *name = [k substringFromIndex:2];
		id v = globals[k];
		if ([v isKindOfClass:NSNumber.class]) push_global_override_to_cache(name, v);
	}
	NSDictionary *idOverrides = [SCIUtils getDictPref:kCIDOverridesKey];
	for (NSString *symKey in idOverrides) {
		if (![symKey hasPrefix:@"C#"]) continue;
		NSString *name = [symKey substringFromIndex:2];
		NSDictionary *perSym = idOverrides[symKey];
		if (![perSym isKindOfClass:NSDictionary.class]) continue;
		for (NSString *idKey in perSym) {
			id v = perSym[idKey];
			if ([v isKindOfClass:NSNumber.class]) push_id_override_to_cache(name, (int32_t)idKey.intValue, v);
		}
	}

	// Build the rebinding list for any slot that has an override OR is requested
	// for diagnostics (a slot is rebound if it has a global force, any id force,
	// or a diagnostic flag). To keep things predictable we rebind a slot when it
	// has any override; diagnostics-only capture is opt-in via a separate pref.
	BOOL diagAll = [SCIUtils getBoolPref:@"sci_c_symbol_diag_all"];

	struct rebinding rebs[MAX_SYMS];
	int nreb = 0;
	for (int i = 0; i < g_slot_count; i++) {
		SCICSlot *s = &g_slots[i];
		BOOL hasGlobal = atomic_load(&s->force) >= 0;
		BOOL hasID = NO;
		int idn = atomic_load(&s->id_count);
		for (int j = 0; j < idn; j++) if (atomic_load(&s->id_force[j]) >= 0) { hasID = YES; break; }
		if (!hasGlobal && !hasID && !diagAll) continue;
		rebs[nreb].name = g_symbol_defs[i].name;
		rebs[nreb].replacement = g_symbol_defs[i].repl;
		rebs[nreb].replaced = (void **)&s->orig;
		nreb++;
		CLOG("rebinding %{public}s (family %ld)", g_symbol_defs[i].name, (long)s->family);
	}
	if (nreb == 0) { CLOG("no C-symbol overrides to install"); return; }
	int rc = rebind_symbols(rebs, nreb);
	CLOG("rebind_symbols installed=%d rc=%d", nreb, rc);
}

@end
