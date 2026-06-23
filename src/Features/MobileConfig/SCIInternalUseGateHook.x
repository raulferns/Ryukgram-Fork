// SCIInternalUseGateHook.x
//
// Hard-stub C gates for imported BOOL-returning FBShared/Instagram functions.
//
// Why this file is intentionally boring:
//  • No Objective-C/defaults in the replacement hot path.
//  • No call to %orig/orig for forced symbols.
//  • Each enabled import is rebound to a tiny arm64 stub equivalent to:
//        mov w0, #1
//        ret
//  • Only symbols whose prefs are ON are rebound. OFF symbols are not touched.
//  • Crash guard is armed before any GOT/fishhook mutation.
//
// This mirrors the only pattern that stayed stable for IGMobileConfigBoolean:
// force the return value at the imported-function boundary, do not run FBShared's
// reader, and do not perform runtime work from inside the C hook.

#import <Foundation/Foundation.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>
#import "../../Utils.h"
#import "../Dogfooding/SCIInternalGatePrefs.h"

#define SCILOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] CStub " fmt,##__VA_ARGS__)

// ── Pref keys ──────────────────────────────────────────────────────────────
static NSString * const kMCMasterLegacy = @"sci_force_all_mc_gates";
static NSString * const kMCMaster       = @"sci_force_mc_internal_use_all";
static NSString * const kMCBool         = @"sci_force_mc_internal_use_boolean";
static NSString * const kInternalApp    = @"sci_force_ig_internal_apps_installed_after_ios18";
static NSString * const kMinos          = @"sci_force_minos_dogfood_mek_encryption";

static NSString * const kEasyAll        = @"sci_force_easy_gating_all";
static NSString * const kEasyInternal   = @"sci_force_easy_gating_internal";
static NSString * const kEasyAuth       = @"sci_force_easy_gating_auth";
static NSString * const kEasyMCQ        = @"sci_force_easy_gating_mcq";
static NSString * const kEasyPlatform   = @"sci_force_easy_gating_platform"; // no validated import in this build

static NSString * const kSessionedAll   = @"sci_force_sessioned_mc_all";
static NSString * const kMSGCBoolean    = @"sci_force_msgc_sessioned_boolean";
static NSString * const kMCIExpBool     = @"sci_force_mci_experiment_boolean";
static NSString * const kMCIExtBool     = @"sci_force_mci_extension_boolean";

static inline BOOL SCIPrefOn(NSUserDefaults *ud, NSString *key) {
    return key.length && [ud boolForKey:key];
}

// One tiny replacement for every BOOL gate. It is intentionally naked so there
// is no prologue, no stack touch, no ObjC, no callout, and no ABI dependency on
// incoming arguments. Every caller expects a BOOL in w0.
//
// `bti c` gives a valid Branch Target Identification landing pad on arm64e;
// on CPUs/OS paths where BTI is not enforced it behaves as a harmless hint.
__attribute__((naked, noinline, used)) static void SCIAlwaysTrueBoolW0Stub(void) {
    __asm__ volatile(
        ".inst 0xd503245f\n" // bti c
        "mov w0, #1\n"
        "ret\n"
    );
}

static void SCIAddRebind(struct rebinding *rbs, size_t *count, const char *symbol) {
    if (!symbol || !count || *count >= 16) return;
    rbs[*count].name = symbol;
    rbs[*count].replacement = (void *)SCIAlwaysTrueBoolW0Stub;
    rbs[*count].replaced = NULL; // never call orig in hard-stub mode
    (*count)++;
    SCILOG("armed hard stub %{public}s", symbol);
}

// ── EasyGating: modo CALL-ORIG (espelha o stub_bool_i estável do MobileConfig) ──
//
// O hard-stub acima (mov w0,#1; ret) NÃO chama o orig. Para MobileConfig/Minos/MSGC
// isso é estável (você confirmou: "libera tudo e não crasha"). Mas o
// EasyGating*_Internal_DoNotUseOrMock CRASHA com hard-stub porque pular o orig pula
// a inicialização preguiçosa/side-effects do gate. A correção é exatamente o que o
// hook estável do MobileConfig internal-use bool faz em SCICSymbolStub.m (stub_bool_i):
// CHAMAR o orig primeiro (deixa o framework rodar tudo), descartar o valor real e
// retornar YES. ABI validada: retornam BOOL em w0; não há gate-id forçável nos args
// (só default), então o force é global "libera tudo que passa" — mas seguro.
typedef bool (*SCIEGBoolFn)(void*,void*,void*,void*,void*,void*,void*,void*);
static SCIEGBoolFn orig_eg_internal = NULL;
static SCIEGBoolFn orig_eg_auth     = NULL;
static SCIEGBoolFn orig_eg_mcq      = NULL;

static bool sci_eg_internal_repl(void*a0,void*a1,void*a2,void*a3,void*a4,void*a5,void*a6,void*a7){
    if (orig_eg_internal) (void)orig_eg_internal(a0,a1,a2,a3,a4,a5,a6,a7); // side-effects do orig
    return true;
}
static bool sci_eg_auth_repl(void*a0,void*a1,void*a2,void*a3,void*a4,void*a5,void*a6,void*a7){
    if (orig_eg_auth) (void)orig_eg_auth(a0,a1,a2,a3,a4,a5,a6,a7);
    return true;
}
static bool sci_eg_mcq_repl(void*a0,void*a1,void*a2,void*a3,void*a4,void*a5,void*a6,void*a7){
    if (orig_eg_mcq) (void)orig_eg_mcq(a0,a1,a2,a3,a4,a5,a6,a7);
    return true;
}

static void SCIAddRebindCallOrig(struct rebinding *rbs, size_t *count, const char *symbol, void *repl, void **origSlot) {
    if (!symbol || !count || *count >= 16) return;
    rbs[*count].name = symbol;
    rbs[*count].replacement = repl;
    rbs[*count].replaced = origSlot; // call-orig: fishhook preenche o orig
    (*count)++;
    SCILOG("armed call-orig stub %{public}s", symbol);
}

void SCIInstallMobileConfigInternalUseGateIfNeeded(void) {
    static BOOL done = NO;
    if (done) return;

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    // Crash guard must arm before any fishhook/GOT mutation. This is what lets
    // a failed launch clear the active dev C-gate prefs on the next launch.
    [SCIInternalGatePrefs installCrashGuardIfNeeded];

    BOOL mcAll = SCIPrefOn(ud, kMCMaster) || SCIPrefOn(ud, kMCMasterLegacy);
    BOOL easyAll = SCIPrefOn(ud, kEasyAll);
    BOOL sessionedAll = SCIPrefOn(ud, kSessionedAll);

    // Keep the old global MobileConfig master scoped to the three previously
    // stable gates only. It no longer drags EasyGating/MCI/MSGC into launch.
    BOOL forceMCBool      = mcAll || SCIPrefOn(ud, kMCBool);
    BOOL forceInternalApp = mcAll || SCIPrefOn(ud, kInternalApp);
    BOOL forceMinos       = mcAll || SCIPrefOn(ud, kMinos);

    BOOL forceEasyInternal = easyAll || SCIPrefOn(ud, kEasyInternal);
    BOOL forceEasyAuth     = easyAll || SCIPrefOn(ud, kEasyAuth);
    BOOL forceEasyMCQ      = easyAll || SCIPrefOn(ud, kEasyMCQ);
    BOOL forceEasyPlatform = easyAll || SCIPrefOn(ud, kEasyPlatform);

    BOOL forceMSGC   = sessionedAll || SCIPrefOn(ud, kMSGCBoolean);
    BOOL forceMCIExp = sessionedAll || SCIPrefOn(ud, kMCIExpBool);
    BOOL forceMCIExt = sessionedAll || SCIPrefOn(ud, kMCIExtBool);

    struct rebinding rbs[16];
    memset(rbs, 0, sizeof(rbs));
    size_t count = 0;

    if (forceMCBool)      SCIAddRebind(rbs, &count, "IGMobileConfigBooleanValueForInternalUse");
    if (forceInternalApp) SCIAddRebind(rbs, &count, "IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18");
    if (forceMinos)       SCIAddRebind(rbs, &count, "MEBIsMinosDogfoodMekEncryptionVersionEnabled");

    if (forceEasyInternal) SCIAddRebindCallOrig(rbs, &count, "EasyGatingGetBoolean_Internal_DoNotUseOrMock", (void *)sci_eg_internal_repl, (void **)&orig_eg_internal);
    if (forceEasyAuth)     SCIAddRebindCallOrig(rbs, &count, "EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock", (void *)sci_eg_auth_repl, (void **)&orig_eg_auth);
    if (forceEasyMCQ)      SCIAddRebindCallOrig(rbs, &count, "MCQEasyGatingGetBooleanInternalDoNotUseOrMock", (void *)sci_eg_mcq_repl, (void **)&orig_eg_mcq);
    // Current framework/exec validation does not show a stable EasyGatingPlatformGetBoolean import.
    // Leave the UI key crash-guarded but do not bind an unknown symbol.
    if (forceEasyPlatform) SCILOG("EasyGatingPlatform requested but no validated import; skip");

    if (forceMSGC)   SCIAddRebind(rbs, &count, "MSGCSessionedMobileConfigGetBoolean");
    if (forceMCIExp) SCIAddRebind(rbs, &count, "MCIExperimentCacheGetMobileConfigBoolean");
    if (forceMCIExt) SCIAddRebind(rbs, &count, "MCIExtensionExperimentCacheGetMobileConfigBoolean");

    if (!count) {
        SCILOG("skip install: no enabled C hard stubs");
        return;
    }

    done = YES;
    int rc = rebind_symbols(rbs, count);
    SCILOG("rebind_symbols count=%lu rc=%d", (unsigned long)count, rc);
}

%ctor {
    @autoreleasepool {
        SCIInstallMobileConfigInternalUseGateIfNeeded();
    }
}
