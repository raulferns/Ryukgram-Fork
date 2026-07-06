// SCIEmployeeInternal.x
// =====================================================================
// UM HOOK, UM TOGGLE — Employee / Internal (KEYSTONE)
// =====================================================================
// Espelha 1:1 o FBTEmployeeMode.x + FBTInternalImports.m do FBTweak, revalidado
// no exec/framework NOVOS do Instagram (parser ObjC + chained-fixup + capstone).
// Ligar `sci_employee_internal` força os getters/símbolos CONHECIDOS de
// employee/internal a retornarem YES — entradas internal/dogfood aparecem
// naturalmente, sem opener forçado.
//
// Alvos validados no binário novo (varredura completa de getters em exec + framework):
//   C imports (GOT, fishhook-safe; stub adrp/ldr/br + caller real confirmados):
//       ig_is_employee
//       ig_is_employee_or_test_user
//   ObjC getters -isEmployee:
//       IGFacebookUserInfo        (FBSharedFramework) <- CHECK CENTRAL de funcionário
//       IGAdPlatformLogger_objc   (Instagram exec)
//   Swift @objc -isEmployee:
//       _TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift
//   Bug reporter menu (a entrada "Internal Settings" mora dentro dele):
//       -[_TtC17IGBugReporterMenu29IGBugReportMenuViewController
//         initWith...style:q64 internalSettingsAvailabilityStatus:q72
//         showInternalSettings:B80 showLoggedOutInternalSettings:B84
//         showShakeToReportPreferenceToggle:B88]
//
// Sideload-safe: só MSHookMessageEx/%hook (ObjC/Swift @objc) + fishhook (GOT C import).
// Nunca __TEXT inline. %ctor barato: lê 1 pref e instala só se ON.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>

#define EILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeInternal " fmt, ##__VA_ARGS__)

static inline BOOL EIOn(void) { return [SCIUtils getBoolPref:@"sci_employee_internal"]; }

// ── (1) C imports: ig_is_employee* -> YES (latched; orig nunca chamado) ──
static BOOL (*orig_ig_is_employee)(void) = NULL;
static BOOL (*orig_ig_is_employee_or_test_user)(void) = NULL;
static BOOL ei_ig_is_employee(void) { return YES; }
static BOOL ei_ig_is_employee_or_test_user(void) { return YES; }

// ── (2) Getters ObjC conhecidos -> YES (resolvidos por nome; safe se ausentes) ──
%group SCIEmployeeObjCGroup
%hook IGFacebookUserInfo
- (BOOL)isEmployee {
	return EIOn() ? YES : %orig;
}
%end
%hook IGAdPlatformLogger_objc
- (BOOL)isEmployee {
	return EIOn() ? YES : %orig;
}
%end
%end

// ── (3) Getter Swift @objc -> YES (classe mangled, alias em runtime) ──
%group SCIEmployeeSwiftGroup
%hook IGAdPlatformLogger_swift
- (BOOL)isEmployee {
	return EIOn() ? YES : %orig;
}
%end
%end

// ── (4) Bug reporter menu init: força a entrada Internal Settings ──
%ctor {
    @autoreleasepool {
        if (!EIOn()) return;   // %ctor barato: 1 pref read

        // (1) C gates — equivalente do FBShouldEnableInternalSettings
        struct rebinding rbs[] = {
            { "ig_is_employee",              (void *)ei_ig_is_employee,              (void **)&orig_ig_is_employee },
            { "ig_is_employee_or_test_user", (void *)ei_ig_is_employee_or_test_user, (void **)&orig_ig_is_employee_or_test_user },
        };
        int rc = rebind_symbols(rbs, 2);

        // (2) Getters ObjC conhecidos (Logos pula os que não existirem)
        %init(SCIEmployeeObjCGroup);

        // (3) Getter Swift (classe mangled via alias runtime)
        Class swCls = objc_getClass("_TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift");
        if (swCls) %init(SCIEmployeeSwiftGroup, IGAdPlatformLogger_swift = swCls);

        BOOL haveFB = objc_getClass("IGFacebookUserInfo") != nil;
        EILOG("installed rc=%d fbUserInfo=%d swift=%d", rc, haveFB, swCls!=nil);
    }
}
