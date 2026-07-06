#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../../Utils.h"

// Native Instagram internal-settings gate (CONSOLIDADO).
//
// Validado no Instagram enviado com LIEF + Capstone + parser de __objc_classlist:
//   classe registrada como _TtC17IGBugReporterMenu29IGBugReportMenuViewController
//   (nome PURO "IGBugReportMenuViewController" NAO existe no runtime -> %hook por
//   nome puro dava objc_getClass()==nil e o hook nunca instalava). Por isso este
//   arquivo resolve pela classe MANGLED via objc_getClass + MSHookMessageEx, que e
//   o mecanismo que funciona (mesmo do SCIEmployeeInternal.x).
//
// -initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:
//  entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:
//  showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:
//
// ABI/types confirmada byte a byte no binario: @92@0:8@16@24@32@40@48@56q64q72B80B84B88
//   self@0 _cmd:8 deviceSession@16 userSession@24 reliabilityLogging@32 navChain@40
//   endpoint@48 entryPoint@56 style q64 availabilityStatus q72
//   showInternalSettings B80 showLoggedOut B84 showShake B88
//
// availabilityStatus é enum Swift (IGInternalSettingsAvailabilityStatus), sem
// reflection metadata acessivel estaticamente -- o valor "disponivel" NAO foi
// provado por disassembly (codigo consumidor com outlining pesado). Por isso o
// valor e AJUSTAVEL em runtime via stepper (pref sci_internal_settings_availability_value)
// e so aplicado se o toggle sci_force_internal_settings_availability estiver on.
//
// Toggles SEPARADOS de proposito (para isolar comportamento em runtime):
//   sci_employee_internal              -> forca os 3 BOOLs (caminho employee)
//   sci_force_internal_settings_menu   -> forca os 3 BOOLs (caminho menu)
//   sci_force_internal_settings_loggedout -> tambem forca o loggedOut BOOL
//   sci_force_internal_settings_availability + _value -> sobrescreve o enum
//
// Todos gated por pref barata no %ctor. Crash guard: os toggles estao em
// SCIInternalGatePrefs allGateKeys, entao reconcileCrashGuardOnLaunch os desativa
// se o launch anterior travou antes de ficar estavel.

static inline BOOL SCIMenuGateOn(void) {
    return [SCIUtils getBoolPref:@"sci_employee_internal"] ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"];
}

static id (*orig_sciBugMenuInit)(id, SEL, id, id, id, id, id, id, long long, long long, BOOL, BOOL, BOOL) = NULL;

static id sci_bugMenuInit(id self, SEL _cmd,
        id deviceSession, id userSession, id reliabilityLogging, id navChain,
        id endpoint, id entryPoint, long long style, long long availabilityStatus,
        BOOL showInternalSettings, BOOL showLoggedOut, BOOL showShake) {

    // BOOLs: caminho seguro (nao dependem do valor incerto do enum).
    if ([SCIUtils getBoolPref:@"sci_employee_internal"] ||
        [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"]) {
        showInternalSettings = YES;
        showShake = YES;
    }
    if ([SCIUtils getBoolPref:@"sci_employee_internal"] ||
        [SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
        showLoggedOut = YES;
    }

    // availabilityStatus: so sobrescreve se o toggle estiver on (valor incerto).
    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
        availabilityStatus = (long long)[SCIUtils getDoublePref:@"sci_internal_settings_availability_value"];
    }

    return orig_sciBugMenuInit
        ? orig_sciBugMenuInit(self, _cmd, deviceSession, userSession, reliabilityLogging,
                              navChain, endpoint, entryPoint, style, availabilityStatus,
                              showInternalSettings, showLoggedOut, showShake)
        : self;
}

%ctor {
    @autoreleasepool {
        if (!SCIMenuGateOn() &&
            ![SCIUtils getBoolPref:@"sci_force_internal_settings_availability"]) {
            return;
        }

        // Classe registrada SO pelo nome mangled (confirmado na __objc_classlist).
        Class bug = objc_getClass("_TtC17IGBugReporterMenu29IGBugReportMenuViewController");
        if (!bug) return;

        SEL sel = NSSelectorFromString(@"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:");
        if (!class_getInstanceMethod(bug, sel)) return;

        MSHookMessageEx(bug, sel, (IMP)sci_bugMenuInit, (IMP *)&orig_sciBugMenuInit);
    }
}
