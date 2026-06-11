// SCIExperimentalNavHook.x
//
// Corrige IGExperimentalNavigationSelectionViewController (Swift, FBSharedFramework).
//
// DIAGNÓSTICO FLEX (instâncias live, todas com ivars nil):
//   Class:   _TtC33IGExperimentalNavigationSelection47IGExperimentalNavigationSelectionViewController
//   Ivars:   navigationState  @offset 1048  (tipo: IGExperimentalNavigationState, nil)
//            userSession      @offset 1056  (nil — por isso a seleção de rows não funciona)
//            isLiquidGlassToggleEnabled @offset 1064
//            liquidGlassToggleSwitch    @offset 1072
//   Methods: initWith:(id)  liquidGlassToggleChanged:(id)
//            tableView:didSelectRowAtIndexPath:
//
// PROBLEMAS IDENTIFICADOS:
//   1. initWith: recebe nil como navigationState → ambos os ivars ficam nil
//   2. liquidGlassToggleChanged: chama [userSession ...] → crash silencioso (nil)
//   3. tableView:didSelectRowAtIndexPath: checa navigationState → não faz nada se nil
//
// O QUE ESTE HOOK FAZ:
//   A. Injeta userSession do SCIDogfoodObjectRuntime em initWith: e viewWillAppear:
//   B. Cria IGExperimentalNavigationState minimal em initWith: para habilitar row selection
//   C. Bypassa o nil-userSession em liquidGlassToggleChanged: chamando
//      IGLiquidGlassNavigationExperimentHelper.shared.overrideIsEnabled: diretamente
//      (o mesmo caminho que SCIInternalSettingsApplier usa)
//   D. Persiste o estado do toggle em NSUserDefaults e restaura no próximo open
//   E. Auto-aplica LiquidGlass no launch se o toggle estava ON
//   F. Loga seleção de rows para diagnóstico do navigationState

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import "SCIDogfoodObjectRuntime.h"
#import "SCIInstallOnce.h"

#define NAVLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCINavHook] " fmt,##__VA_ARGS__)

// Nomes de classe Swift mangled — confirmados via análise dos imports do Instagram.
// NSClassFromString usa o nome mangled; não assumir que o nome curto funciona.
static NSString * const kNavVCClass    = @"_TtC33IGExperimentalNavigationSelection47IGExperimentalNavigationSelectionViewController";
static NSString * const kNavStateClass = @"_TtC33IGExperimentalNavigationSelection29IGExperimentalNavigationState";

// Chave NSUserDefaults para persistência do toggle LiquidGlass da nav.
static NSString * const kNavLG = @"sci_nav_liquidglass_enabled";

// ── Helpers de acesso a ivar ───────────────────────────────────────────────
// Busca ivar por nome, percorrendo toda a hierarquia de classes.
static Ivar sciFindIvar(id obj, NSString *name) {
    if (!obj || !name) return NULL;
    const char *cname = name.UTF8String;
    Class c = object_getClass(obj);
    while (c) {
        Ivar iv = class_getInstanceVariable(c, cname);
        if (iv) return iv;
        c = class_getSuperclass(c);
    }
    return NULL;
}

// Lê um ivar id de forma segura.
static id sciGetIvar(id obj, NSString *name) {
    Ivar iv = sciFindIvar(obj, name);
    if (!iv) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused id e) { return nil; }
}

// Escreve um ivar id de forma segura (usa object_setIvar → ARC-safe).
static void sciSetIvar(id obj, NSString *name, id value) {
    Ivar iv = sciFindIvar(obj, name);
    if (!iv) { NAVLOG("ivar '%{public}@' não encontrado em %{public}s",
                      name, object_getClassName(obj)); return; }
    @try { object_setIvar(obj, iv, value); }
    @catch (id e) { NAVLOG("setIvar '%{public}@' threw: %{public}@", name, e); }
}

// ── LiquidGlass helper (mesmo caminho do SCIInternalSettingsApplier) ───────
static void sciApplyLiquidGlass(BOOL on) {
    Class H = NSClassFromString(@"IGLiquidGlassNavigationExperimentHelper");
    if (!H) H = NSClassFromString(@"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper");
    if (!H) { NAVLOG("LiquidGlassHelper class não encontrada"); return; }
    
    SEL sh = NSSelectorFromString(@"shared");
    id shared = [H respondsToSelector:sh] ? ((id(*)(id,SEL))objc_msgSend)(H, sh) : nil;
    if (!shared) { NAVLOG("LiquidGlassHelper.shared=nil"); return; }
    
    SEL override = NSSelectorFromString(@"overrideIsEnabled:");
    if ([shared respondsToSelector:override]) {
        @try { ((void(*)(id,SEL,BOOL))objc_msgSend)(shared, override, on); }
        @catch (id e) { NAVLOG("overrideIsEnabled: threw: %{public}@", e); }
    }
    if (on) {
        for (NSString *sel in @[@"overrideIsGlassRenderingOptimizationEnabled:",
                                @"overrideLegibilityBlurEnabled:"]) {
            SEL s = NSSelectorFromString(sel);
            if ([shared respondsToSelector:s]) {
                @try { ((void(*)(id,SEL,BOOL))objc_msgSend)(shared, s, YES); }
                @catch (__unused id e) {}
            }
        }
    }
    NAVLOG("LiquidGlass override=%d OK", (int)on);
}

// ── Injetar userSession e navigationState ─────────────────────────────────
static void sciInjectDependencies(id vc) {
    if (!vc) return;
    
    // userSession
    if (!sciGetIvar(vc, @"userSession")) {
        id session = [SCIDogfoodObjectRuntime activeUserSession];
        if (session) {
            sciSetIvar(vc, @"userSession", session);
            NAVLOG("userSession injetado");
        } else {
            NAVLOG("userSession=nil no runtime — abra depois do login");
        }
    }
    
    // navigationState — tentar criar instância mínima se nil
    // IGExperimentalNavigationState é Swift; [new] pode funcionar se tem init() sem args.
    if (!sciGetIvar(vc, @"navigationState")) {
        Class nsClass = NSClassFromString(kNavStateClass);
        if (nsClass) {
            @try {
                id navState = [nsClass new];
                if (navState) {
                    sciSetIvar(vc, @"navigationState", navState);
                    NAVLOG("navigationState injetado: %{public}s", object_getClassName(navState));
                } else {
                    NAVLOG("navigationState [new] retornou nil");
                }
            } @catch (id e) {
                NAVLOG("navigationState [new] threw: %{public}@ — row selection ficará quebrado", e);
            }
        } else {
            NAVLOG("IGExperimentalNavigationState class não encontrada");
        }
    }
}

// ── Hook: classe Swift com nome mangled ────────────────────────────────────
// Logos resolve %hook pelo nome de runtime exato (NSClassFromString internamente).

%hook _TtC33IGExperimentalNavigationSelection47IGExperimentalNavigationSelectionViewController

// initWith: recebe o navigationState (ou nil). Injeta dependências após orig.
- (id)initWith:(id)arg {
    // Log o tipo para entender o que o caller fornece (caso arg não seja nil em outros contextos)
    if (arg) NAVLOG("initWith: arg=%{public}s", object_getClassName(arg));
    else     NAVLOG("initWith: arg=nil (navigationState não fornecido pelo caller)");
    
    id result = %orig(arg);
    if (result) sciInjectDependencies(result);
    return result;
}

// Segunda chance — session pode ainda não ter sido capturado no init
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    sciInjectDependencies(self);
    
    // Restaurar estado visual do toggle a partir do NSUserDefaults
    @try {
        BOOL saved = [[NSUserDefaults standardUserDefaults] boolForKey:kNavLG];
        id sw = sciGetIvar(self, @"liquidGlassToggleSwitch");
        if ([sw isKindOfClass:[UISwitch class]]) {
            [(UISwitch *)sw setOn:saved animated:NO];
        }
    } @catch (__unused id e) {}
}

// liquidGlassToggleChanged: — BYPASS ao nil userSession.
// Aplica IGLiquidGlassNavigationExperimentHelper diretamente + persiste.
- (void)liquidGlassToggleChanged:(id)sender {
    BOOL isOn = [sender isKindOfClass:[UISwitch class]] && [(UISwitch *)sender isOn];
    NAVLOG("toggle=%d", (int)isOn);
    
    // Persistir para próximo launch
    [[NSUserDefaults standardUserDefaults] setBool:isOn forKey:kNavLG];
    
    // Aplicar diretamente (independente de userSession)
    sciApplyLiquidGlass(isOn);
    
    // Tentar %orig — pode funcionar agora que userSession foi injetado
    @try { %orig(sender); } @catch (__unused id e) {}
}

// tableView:didSelectRowAtIndexPath: — log para investigar o que navigationState precisa.
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id navState = sciGetIvar(self, @"navigationState");
    id session  = sciGetIvar(self, @"userSession");
    NAVLOG("row s=%ld r=%ld  navState=%{public}s  session=%{public}s",
           (long)indexPath.section, (long)indexPath.row,
           navState ? object_getClassName(navState) : "nil",
           session  ? object_getClassName(session)  : "nil");
    %orig(tableView, indexPath);
}

%end

// ── Bootstrap — auto-aplica LiquidGlass se estava ON no último uso ─────────
%ctor {
    @autoreleasepool {
        // SCI-FIX 2026-06-11: replaced a blind +5s dispatch_after that messaged a
        // possibly-unrealized Swift helper (LiquidGlass nav) — a deferred-block
        // EXC_BAD_ACCESS vector — with a single deterministic apply at
        // UIApplicationDidBecomeActive (UI built, helper realized). Pref gate first.
        if (![[NSUserDefaults standardUserDefaults] boolForKey:kNavLG]) return;
        SCIInstallOnceOnActive(^{
            if ([[NSUserDefaults standardUserDefaults] boolForKey:kNavLG]) {
                sciApplyLiquidGlass(YES);
            }
        });
    }
}
