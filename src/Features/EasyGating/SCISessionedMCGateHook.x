// SCISessionedMCGateHook.x
//
// fishhook de 3 funções BOOL do FBSharedFramework, todas confirmadas como IMPORTS
// do Instagram via GOT (val=0x0 no binário estático). Padrão idêntico ao
// SCIInternalUseGateHook.x e SCIEasyGatingHook.x.
//
// FUNÇÕES (confirmadas via análise dos imports do Instagram + disasm FBSharedFramework):
//
//  MSGCSessionedMobileConfigGetBoolean(x0=session, x1=key, x2=default:BOOL, x3=extra)
//      "Sessioned" = requer sessão de usuário ativa.
//      mov x21,x2; cbz x0→retorna x21 — padrão idêntico às EasyGating functions.
//
//  MCIExtensionExperimentCacheGetMobileConfigBoolean(x0=cache, x1=key, x2=default:BOOL)
//      mov x19,x2; cbz x0→retorna x19 — 3 params confirmados no disasm.
//
//  MCIExperimentCacheGetMobileConfigBoolean(x0=container, x1=key, x2=default:BOOL, x3=extra)
//      Wrapper que resolve o cache e tail-calls MCIExtension com 4 params.
//
// NOTA: o Symbols Browser marca estas como "C BOOL gate candidate: no" porque o
// heurístico de detecção automática não as classificou. Isso NÃO significa que
// não retornam BOOL — os nomes e a análise de disasm confirmam o retorno boolean.
//
// CRASH GUARD: hooks leem apenas static BOOL C — sem ObjC dentro dos hooks.

#import <Foundation/Foundation.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>

#define SCILOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] SessionedMC " fmt,##__VA_ARGS__)

// ── Pref keys ──────────────────────────────────────────────────────────────
static NSString * const kSMCAll      = @"sci_force_sessioned_mc_all";
static NSString * const kSMCSessioned = @"sci_force_msgc_sessioned_boolean";
static NSString * const kSMCExtension = @"sci_force_mci_extension_boolean";
static NSString * const kSMCExperiment = @"sci_force_mci_experiment_boolean";

// ── Cache C-only ───────────────────────────────────────────────────────────
static volatile BOOL sCacheSMCAll       = NO;
static volatile BOOL sCacheSMCSessioned = NO;
static volatile BOOL sCacheSMCExtension = NO;
static volatile BOOL sCacheSMCExperiment = NO;

static void SCIRefreshSMCCache(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL all = [ud boolForKey:kSMCAll] || [ud boolForKey:@"sci_force_all_mc_gates"];
    sCacheSMCAll       = all;
    sCacheSMCSessioned = all || [ud boolForKey:kSMCSessioned];
    sCacheSMCExtension = all || [ud boolForKey:kSMCExtension];
    sCacheSMCExperiment = all || [ud boolForKey:kSMCExperiment];
    SCILOG("cache refreshed — all=%d sessioned=%d extension=%d experiment=%d",
           (int)sCacheSMCAll, (int)sCacheSMCSessioned,
           (int)sCacheSMCExtension, (int)sCacheSMCExperiment);
}

// ── Typedefs ──────────────────────────────────────────────────────────────
// Assinaturas derivadas do disassembly do FBSharedFramework (arm64):

// MSGCSessionedMobileConfigGetBoolean(session, key, default, extra)
typedef BOOL (*MSGCSessionedBool_t)(void *, void *, BOOL, void *);

// MCIExtensionExperimentCacheGetMobileConfigBoolean(cache, key, default)
typedef BOOL (*MCIExtensionBool_t)(void *, void *, BOOL);

// MCIExperimentCacheGetMobileConfigBoolean(container, key, default, extra)
// Wrapper do anterior — passa 4 params ao MCIExtension.
typedef BOOL (*MCIExperimentBool_t)(void *, void *, BOOL, void *);

static MSGCSessionedBool_t  orig_MSGCSessioned  = NULL;
static MCIExtensionBool_t   orig_MCIExtension   = NULL;
static MCIExperimentBool_t  orig_MCIExperiment  = NULL;

// ── Replacements — zero ObjC ───────────────────────────────────────────────

static BOOL my_MSGCSessioned(void *session, void *key, BOOL def, void *extra) {
    if (sCacheSMCSessioned) return YES;
    return orig_MSGCSessioned ? orig_MSGCSessioned(session, key, def, extra) : def;
}

static BOOL my_MCIExtension(void *cache, void *key, BOOL def) {
    if (sCacheSMCExtension) return YES;
    return orig_MCIExtension ? orig_MCIExtension(cache, key, def) : def;
}

static BOOL my_MCIExperiment(void *container, void *key, BOOL def, void *extra) {
    if (sCacheSMCExperiment) return YES;
    return orig_MCIExperiment ? orig_MCIExperiment(container, key, def, extra) : def;
}

// ── KVO ────────────────────────────────────────────────────────────────────
@interface SCISMCGateObserver : NSObject @end
@implementation SCISMCGateObserver
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)c context:(void *)ctx {
    SCIRefreshSMCCache();
}
@end
static SCISMCGateObserver *sSMCObserver = nil;

static void SCIInstallSMCKVO(void) {
    sSMCObserver = [SCISMCGateObserver new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[kSMCAll, kSMCSessioned, kSMCExtension, kSMCExperiment]) {
        [ud addObserver:sSMCObserver forKeyPath:key
               options:NSKeyValueObservingOptionNew context:NULL];
    }
}

// ── Instalação ─────────────────────────────────────────────────────────────
void SCIInstallSessionedMCGateHooksIfNeeded(void) {
    static BOOL done = NO;

    SCIRefreshSMCCache();
    BOOL any = sCacheSMCAll || sCacheSMCSessioned || sCacheSMCExtension || sCacheSMCExperiment;
    if (!any) {
        SCILOG("skip install: all prefs disabled");
        return;
    }

    if (done) return;
    done = YES;

    struct rebinding r[] = {
        {"MSGCSessionedMobileConfigGetBoolean",
         (void *)my_MSGCSessioned, (void **)&orig_MSGCSessioned},
        {"MCIExtensionExperimentCacheGetMobileConfigBoolean",
         (void *)my_MCIExtension, (void **)&orig_MCIExtension},
        {"MCIExperimentCacheGetMobileConfigBoolean",
         (void *)my_MCIExperiment, (void **)&orig_MCIExperiment},
    };
    int rc = rebind_symbols(r, sizeof(r) / sizeof(r[0]));
    SCILOG("rebind_symbols=%d (0=ok)", rc);

    SCIInstallSMCKVO();
}

%ctor {
    @autoreleasepool {
        SCIInstallSessionedMCGateHooksIfNeeded();
    }
}
