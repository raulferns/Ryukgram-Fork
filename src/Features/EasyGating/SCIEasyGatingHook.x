// SCIEasyGatingHook.x
//
// fishhook dos 4 gates C boolean exportados por FBSharedFramework e
// importados pelo Instagram via GOT — mesma estratégia do SCIInternalUseGateHook.x.
//
// TODOS OS 4 TARGETS CONFIRMADOS COMO IMPORTS DO INSTAGRAM (val=0x0 no GOT estático):
//   EasyGatingGetBoolean_Internal_DoNotUseOrMock
//   EasyGatingPlatformGetBoolean
//   EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock
//   MCQEasyGatingGetBooleanInternalDoNotUseOrMock
//
// SEGURANÇA DE RE-ENTRANT:
//   Os hooks leem apenas static BOOL C. Esses são escritos no %ctor / KVO e
//   NUNCA de dentro de um hook. Sem risco de NSUserDefaults recursivo.
//
// ASSINATURAS — derivadas de disassembly do FBSharedFramework (arm64):
//
//  EasyGatingGetBoolean_Internal_DoNotUseOrMock(x0=ctx, x1=key, x2=default:BOOL, x3=extra)
//      Wrapper fino; salva x2/x3 via helper thunk e tail-calls EasyGatingPlatformGetBoolean.
//      Disasm: helper @ 0x4fcac faz  mov x21,x2 / mov x20,x3 → preservação cross-BL.
//
//  EasyGatingPlatformGetBoolean(x0=ctx, x1=key, x2=default:BOOL)
//      Implementação central. Se x0==NULL retorna x2 diretamente (mov x19,x2; cbz x0,...).
//
//  EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock(x0, x1, x2, x3=auth_ctx)
//      4 parâmetros; salva x3→x21 antes de BL helpers internos.
//
//  MCQEasyGatingGetBooleanInternalDoNotUseOrMock(x0=ctx, w1=dispatch_code:int32, x2, x3, x4)
//      Usa w1 como índice numa jump-table (ldrh w9,[x8,x11,lsl#1]; br x10).
//      Cada case despacha para um getter booleano específico (slotIds observados:
//      0x98, 0x3e, 0xdd, 0x1e2, 0x1d5, 0x1f2, 0x1bd, 0x153, 0x25a, 0x376, 0x370…).

#import <Foundation/Foundation.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>

#define SCILOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] EasyGate " fmt,##__VA_ARGS__)

// ── Pref keys ──────────────────────────────────────────────────────────────
// Mesma convenção do SCIInternalUseGateHook.x: leitura ObjC apenas no %ctor / KVO.
static NSString * const kEasyAll      = @"sci_force_easy_gating_all";
static NSString * const kEasyInternal = @"sci_force_easy_gating_internal";
static NSString * const kEasyPlatform = @"sci_force_easy_gating_platform";
static NSString * const kEasyAuth     = @"sci_force_easy_gating_auth";
static NSString * const kEasyMCQ      = @"sci_force_easy_gating_mcq";

// ── Cache C-only (sem ObjC dentro dos hooks) ────────────────────────────────
static volatile BOOL sCacheEasyAll      = NO;
static volatile BOOL sCacheEasyInternal = NO;
static volatile BOOL sCacheEasyPlatform = NO;
static volatile BOOL sCacheEasyAuth     = NO;
static volatile BOOL sCacheEasyMCQ      = NO;

static void SCIRefreshEasyGatingCache(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL all = [ud boolForKey:kEasyAll] || [ud boolForKey:@"sci_force_all_mc_gates"];
    sCacheEasyAll      = all;
    sCacheEasyInternal = all || [ud boolForKey:kEasyInternal];
    sCacheEasyPlatform = all || [ud boolForKey:kEasyPlatform];
    sCacheEasyAuth     = all || [ud boolForKey:kEasyAuth];
    sCacheEasyMCQ      = all || [ud boolForKey:kEasyMCQ];
    SCILOG("cache refreshed — all=%d internal=%d platform=%d auth=%d mcq=%d",
           (int)sCacheEasyAll,
           (int)sCacheEasyInternal, (int)sCacheEasyPlatform,
           (int)sCacheEasyAuth, (int)sCacheEasyMCQ);
}

// ── Typedefs (matching ARM64 calling convention confirmado no disasm) ────────
//
// BOOL é unsigned char mas o compilador o passa em w0–w7 (32-bit).
// Usando BOOL no parâmetro garante que o compilador gera  w2 (e.g.) corretamente
// ao chamar o original; não interfere com x2 completo.

typedef BOOL (*EasyGatingInternal_t)(void *ctx, void *key, BOOL def, void *extra);
typedef BOOL (*EasyGatingPlatform_t)(void *ctx, void *key, BOOL def);
typedef BOOL (*EasyGatingAuth_t)(void *ctx, void *key, void *a2, void *authCtx);
typedef BOOL (*MCQEasyGating_t)(void *ctx, int32_t dispatchCode,
                                void *a2, void *a3, void *a4);

static EasyGatingInternal_t orig_EasyInternal = NULL;
static EasyGatingPlatform_t orig_EasyPlatform = NULL;
static EasyGatingAuth_t     orig_EasyAuth     = NULL;
static MCQEasyGating_t      orig_MCQEasy      = NULL;

// ── Replacements — zero ObjC, apenas leitura de static BOOL ────────────────

static BOOL my_EasyInternal(void *ctx, void *key, BOOL def, void *extra) {
    if (sCacheEasyInternal) return YES;
    return orig_EasyInternal ? orig_EasyInternal(ctx, key, def, extra) : def;
}

static BOOL my_EasyPlatform(void *ctx, void *key, BOOL def) {
    if (sCacheEasyPlatform) return YES;
    return orig_EasyPlatform ? orig_EasyPlatform(ctx, key, def) : def;
}

static BOOL my_EasyAuth(void *ctx, void *key, void *a2, void *authCtx) {
    if (sCacheEasyAuth) return YES;
    return orig_EasyAuth ? orig_EasyAuth(ctx, key, a2, authCtx) : NO;
}

static BOOL my_MCQEasy(void *ctx, int32_t code, void *a2, void *a3, void *a4) {
    if (sCacheEasyMCQ) return YES;
    return orig_MCQEasy ? orig_MCQEasy(ctx, code, a2, a3, a4) : NO;
}

// ── KVO — atualiza cache quando o usuário altera um toggle ─────────────────
@interface SCIEasyGatingKVOObserver : NSObject @end
@implementation SCIEasyGatingKVOObserver
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)c context:(void *)ctx {
    SCIRefreshEasyGatingCache();
}
@end
static SCIEasyGatingKVOObserver *sEasyObserver = nil;

static void SCIInstallEasyGatingKVO(void) {
    sEasyObserver = [SCIEasyGatingKVOObserver new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[kEasyAll, kEasyInternal, kEasyPlatform,
                            kEasyAuth, kEasyMCQ]) {
        [ud addObserver:sEasyObserver forKeyPath:key
               options:NSKeyValueObservingOptionNew context:NULL];
    }
}

// ── Instalação pública ─────────────────────────────────────────────────────
// Chamado do %ctor — seguro porque ainda não instalamos os hooks ao ler prefs.
void SCIInstallEasyGatingHooksIfNeeded(void) {
    static BOOL done = NO;

    SCIRefreshEasyGatingCache();
    BOOL any = sCacheEasyAll || sCacheEasyInternal || sCacheEasyPlatform || sCacheEasyAuth || sCacheEasyMCQ;
    if (!any) {
        SCILOG("skip install: all prefs disabled");
        return;
    }

    if (done) return;
    done = YES;

    struct rebinding r[] = {
        {"EasyGatingGetBoolean_Internal_DoNotUseOrMock",
         (void *)my_EasyInternal, (void **)&orig_EasyInternal},
        {"EasyGatingPlatformGetBoolean",
         (void *)my_EasyPlatform, (void **)&orig_EasyPlatform},
        {"EasyGatingGetBooleanUsingAuthDataContext_Internal_DoNotUseOrMock",
         (void *)my_EasyAuth, (void **)&orig_EasyAuth},
        {"MCQEasyGatingGetBooleanInternalDoNotUseOrMock",
         (void *)my_MCQEasy, (void **)&orig_MCQEasy},
    };
    int rc = rebind_symbols(r, sizeof(r) / sizeof(r[0]));
    SCILOG("rebind_symbols=%d (0=ok)", rc);

    SCIInstallEasyGatingKVO();
}

%ctor {
    @autoreleasepool {
        SCIInstallEasyGatingHooksIfNeeded();
    }
}
