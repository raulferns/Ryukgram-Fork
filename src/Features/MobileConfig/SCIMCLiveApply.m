// SCIMCLiveApply.m — RyukGram-Fork
#import "SCIMCLiveApply.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// --- C++ overrides-table ABI (resolved by dlsym; symbols exported by FBShared) ---
// getOrCreateOverridesTable returns shared_ptr<FBMobileConfigOverridesTable> BY
// VALUE (16 bytes: stored ptr + control block) via the x8 sret register. A 16-byte
// struct-return typedef makes the compiler emit exactly that ABI.
typedef struct { void *ptr; void *ctrl; } SCISharedPtr16;
typedef SCISharedPtr16 (*SCIGetTableFn)(void *manager, bool create);
typedef void (*SCIUpdateBoolFn)(void *table, uint64_t paramID, bool value, bool persist);
typedef void (*SCIRemoveFn)(void *table, uint64_t paramID, bool persist);

static const char *kGetTableSym =
    "_ZN12mobileconfig21FBMobileConfigManager25getOrCreateOverridesTableEb";
static const char *kUpdateBoolSym =
    "_ZN12mobileconfig28FBMobileConfigOverridesTable22updateOverrideForParamEybb";
static const char *kRemoveSym =
    "_ZN12mobileconfig28FBMobileConfigOverridesTable22removeOverrideForParamEyb";

static SCIGetTableFn   sGetTable   = NULL;
static SCIUpdateBoolFn sUpdateBool = NULL;
static SCIRemoveFn     sRemove     = NULL;
static dispatch_once_t sSymOnce;

static void SCIResolveSymbols(void) {
    dispatch_once(&sSymOnce, ^{
        sGetTable   = (SCIGetTableFn)   dlsym(RTLD_DEFAULT, kGetTableSym);
        sUpdateBool = (SCIUpdateBoolFn) dlsym(RTLD_DEFAULT, kUpdateBoolSym);
        sRemove     = (SCIRemoveFn)     dlsym(RTLD_DEFAULT, kRemoveSym);
    });
}

// --- live manager resolution (chain confirmed by the id-name-map diagnostic) ---
// FBMobileConfigFBTGlobalSessionManager.sharedInstance
//   -> currentSessionContextManagerHolder
//   -> holder._mcFbtManager               (FBMobileConfigFBTContextManager)
//   -> fbt._mobileconfig                   (IGMobileConfigContextManager)
//   -> ctx._configManager                  (weak_ptr<IFBMobileConfigManager>, raw)
static id SCIIvarObject(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static void *SCIResolveLiveManager(void) {
    @try {
        Class gsm = objc_getClass("FBMobileConfigFBTGlobalSessionManager");
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (!gsm || ![gsm respondsToSelector:sharedSel]) return NULL;
        id shared = ((id (*)(id, SEL))objc_msgSend)(gsm, sharedSel);
        SEL holderSel = NSSelectorFromString(@"currentSessionContextManagerHolder");
        if (![shared respondsToSelector:holderSel]) return NULL;
        id holder = ((id (*)(id, SEL))objc_msgSend)(shared, holderSel);
        if (!holder) return NULL;

        id fbt = SCIIvarObject(holder, "_mcFbtManager");
        if (!fbt) {
            SEL s = NSSelectorFromString(@"mcFbtManager");
            if ([holder respondsToSelector:s]) fbt = ((id (*)(id, SEL))objc_msgSend)(holder, s);
        }
        if (!fbt) return NULL;

        id ctx = SCIIvarObject(fbt, "_mobileconfig");
        if (!ctx) return NULL;

        Ivar iv = class_getInstanceVariable(object_getClass(ctx), "_configManager");
        if (!iv) return NULL;
        ptrdiff_t off = ivar_getOffset(iv);
        // _configManager is a C++ weak_ptr (raw bytes, not an ObjC object): the
        // first pointer-sized word is the managed FBMobileConfigManager*.
        void *raw = *(void **)((char *)(__bridge void *)ctx + off);
        return raw;
    } @catch (__unused id e) {
        return NULL;
    }
}

// Fetch the live overrides-table raw pointer. The returned shared_ptr's stored
// pointer aliases a table owned by the manager (getOrCreate), so it stays valid
// for the manager's lifetime; we use the raw pointer and don't retain the ref.
static void *SCILiveOverridesTable(SCIMCLiveResult *outErr) {
    SCIResolveSymbols();
    if (!sGetTable) { if (outErr) *outErr = SCIMCLiveNoSymbol; return NULL; }
    void *manager = SCIResolveLiveManager();
    if (!manager) { if (outErr) *outErr = SCIMCLiveNoManager; return NULL; }
    SCISharedPtr16 sp = sGetTable(manager, true);
    if (!sp.ptr) { if (outErr) *outErr = SCIMCLiveNoTable; return NULL; }
    if (outErr) *outErr = SCIMCLiveOK;
    return sp.ptr;
}

@implementation SCIMCLiveApply

+ (NSString *)wiringStatus {
    SCIResolveSymbols();
    if (!sGetTable || !sUpdateBool) return @"no symbols";
    return SCIResolveLiveManager() ? @"ready" : @"no manager";
}

+ (SCIMCLiveResult)setOverrideForParamID:(uint64_t)paramID value:(BOOL)value {
    SCIMCLiveResult err = SCIMCLiveOK;
    void *table = SCILiveOverridesTable(&err);
    if (!table) return err;
    if (!sUpdateBool) return SCIMCLiveNoSymbol;
    sUpdateBool(table, paramID, value ? true : false, /*persist=*/true);
    return SCIMCLiveOK;
}

+ (SCIMCLiveResult)clearOverrideForParamID:(uint64_t)paramID {
    SCIMCLiveResult err = SCIMCLiveOK;
    void *table = SCILiveOverridesTable(&err);
    if (!table) return err;
    if (!sRemove) return SCIMCLiveNoSymbol;
    sRemove(table, paramID, /*persist=*/true);
    return SCIMCLiveOK;
}

+ (NSString *)applyIsEmployeeProbe {
    // config 56474 / param 0 -> 64-bit MC param hash read from the IG binary's
    // _ig_is_employee descriptor.
    const uint64_t kIsEmployeeParamID = 0x8102c800010921ULL;
    SCIMCLiveResult r = [self setOverrideForParamID:kIsEmployeeParamID value:YES];
    switch (r) {
        case SCIMCLiveOK:        return @"applied ig_is_employee=true live (relaunch not required). If internal gating flips, the paramID space is confirmed.";
        case SCIMCLiveNoManager: return @"no live FBMobileConfigManager (open the app past login first).";
        case SCIMCLiveNoTable:   return @"getOrCreateOverridesTable returned null.";
        case SCIMCLiveNoSymbol:  return @"required FBShared C++ symbol not found (build/link changed).";
    }
    return @"unknown";
}

@end
