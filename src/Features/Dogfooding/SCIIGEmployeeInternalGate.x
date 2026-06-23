// SCIIGEmployeeInternalGate.x
//
// PEÇA QUE FALTAVA para as rows internal/dogfood aparecerem NATURALMENTE no IG.
//
// Espelha EXATAMENTE o FBTweak. No FBTweak, ligar Employee/Internal mostra as
// entradas internas porque ele força, no boundary do import C:
//     FBShouldEnableInternalSettings -> YES   (fishhook)
//     isEmployee getters             -> YES   (MSHookMessageEx / %hook)
//
// No Instagram o equivalente central é FUNÇÃO C, e o RyukGram NÃO a forçava:
// em SCICSymbolStub.m, "ig_is_employee" / "ig_is_employee_or_test_user" estão na
// lista SCIParamDescriptorSymbols() (tratados como DADO/param-descriptor) e não
// têm case em SCIStubProfileForSymbol() -> caem em SCICReturnKindUnknown e são
// PULADOS no rebind. Resultado: o getter ObjC era forçado, mas o gate C central
// (que o app realmente consulta) nunca. Por isso "não funcionava".
//
// VALIDADO no exec/framework NOVOS desta conversa (parser Mach-O próprio + capstone,
// sem LIEF):
//   • ig_is_employee_or_test_user  -> stub @ 0x109d1ac48 (adrp/ldr GOT/br),
//        GOT slot 0x10dd6b000+0xe98, caller real @ 0x107fafdc0 (bl, x1=contexto).
//   • ig_is_employee               -> stub @ 0x109d2c450, GOT slot 0x10dd83000+0x80.
//   • Ambos importados pelo executável Instagram -> rebind_symbols (GOT __DATA)
//     pega todos os call sites. SIDELOAD-SAFE (não toca __TEXT).
//   • Getters ObjC de employee no binário novo:
//        IGAdPlatformLogger_objc  -isEmployee   (já forçado por SCIDevInternalGates.x)
//        _TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift -isEmployee
//        (variante Swift — NÃO era forçada por nada; coberta aqui)
//
// PADRÃO FBTweak (FBTInternalImports.m): flag latched no %ctor; instala só se a
// pref está ON; o replacement retorna YES SEMPRE e NUNCA chama orig -> a ABININa
// real (args) é irrelevante, BOOL repl(void){return YES;} é seguro no arm64
// (retorno em w0). Ligar/desligar o gate C exige restart (igual aos C gates do
// RyukGram). O getter Swift é live.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>

#define IGEMP_LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeInternal " fmt, ##__VA_ARGS__)

// Master OU pref específica — mesma semântica do sciDevGate de SCIDevInternalGates.x,
// pra reaproveitar o MESMO toggle que você já tem no Dev menu.
static BOOL SCIIGEmployeeGateOn(void) {
    return [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"]
        || [SCIUtils getBoolPref:@"sci_force_ig_is_employee"];
}

// ── 1) fishhook nos gates C centrais (return YES sempre; orig nunca chamado) ──
static BOOL (*orig_ig_is_employee)(void) = NULL;
static BOOL (*orig_ig_is_employee_or_test_user)(void) = NULL;

static BOOL sci_ig_is_employee_repl(void) { return YES; }
static BOOL sci_ig_is_employee_or_test_user_repl(void) { return YES; }

// ── 2) swizzle do getter Swift (live). O ObjC já é coberto por SCIDevInternalGates.x ──
%group SCIIGEmployeeSwiftGroup
%hook IGAdPlatformLogger_swift
- (BOOL)isEmployee { return SCIIGEmployeeGateOn() ? YES : %orig; }
%end
%end

%ctor {
    @autoreleasepool {
        if (!SCIIGEmployeeGateOn()) return;   // %ctor barato: só lê pref e decide

        // (a) gate C central — o equivalente do FBShouldEnableInternalSettings.
        //     Sem nome com underscore: fishhook adiciona o '_' sozinho.
        struct rebinding rbs[] = {
            { "ig_is_employee",
              (void *)sci_ig_is_employee_repl,
              (void **)&orig_ig_is_employee },
            { "ig_is_employee_or_test_user",
              (void *)sci_ig_is_employee_or_test_user_repl,
              (void **)&orig_ig_is_employee_or_test_user },
        };
        int rc = rebind_symbols(rbs, 2);
        IGEMP_LOG("C gates rebind rc=%d (emp=%p ortest=%p)",
                  rc, (void *)orig_ig_is_employee, (void *)orig_ig_is_employee_or_test_user);

        // (b) getter Swift de employee, se a classe existir neste build.
        Class sw = objc_getClass("_TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift");
        if (sw) {
            %init(SCIIGEmployeeSwiftGroup, IGAdPlatformLogger_swift = sw);
            IGEMP_LOG("swift isEmployee hook armed on %{public}s", class_getName(sw));
        } else {
            IGEMP_LOG("swift IGAdPlatformLogger class not present in this build");
        }
    }
}
