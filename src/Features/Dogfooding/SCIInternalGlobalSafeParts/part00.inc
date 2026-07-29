// SCIInternalGlobalSafe.x
// New-IG internal/employee bridge validated against:
// Instagram fa19f499c560b188d2802e3a1a36642209ee6e42d7639c1ebe010f14b2c4cd9b
// FBSharedFramework a79c110c59e7c16e5608227e12807583c1afcf80cb2a2e38302f147dbf99c12b
//
// Important: XPlugins hashes 0x64327C01 (internal_only) and 0x7FBC8058
// (Dogfooding Assistant socket) both resolve to the empty provider at
// Instagram+0x02BD80E4. A provider returns a 16-byte pair in x0/x1
// (data pointer, element count). Never replace it with a BOOL/sentinel pointer.

#import "../../../Utils.h"
#import "../SCIInternalGatePrefs.h"
#import "../SCIDogfoodObjectRuntime.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdint.h>
#import <string.h>

#define IGSLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] InternalGlobalSafe " fmt, ##__VA_ARGS__)

void SCIInstallEmployeeInternalHooksIfNeeded(void);
BOOL SCIInstallInternalGlobalHooksIfNeeded(void);

typedef struct {
    const void *data;
    uintptr_t count;
} SCIXPluginsDataPair;

typedef SCIXPluginsDataPair (*SCIXPluginsDataProvider)(void);
typedef void *(*SCIXPluginsGetDataFuncOrAbortFn)(uint32_t hash);

typedef struct {
    uint64_t raw;
} SCIMCBoolParam;

static const uint64_t kSCIEmployeeOrTestUserMC = 0x008100A700000134ULL;
static const uint64_t kSCIDogfoodingAssistantMC = 0x00810A8A000139D6ULL;
static const uint32_t kSCIInternalOnlyPluginHash = 0x64327C01U;
static const uint32_t kSCIDogfoodSocketPluginHash = 0x7FBC8058U;

static __thread BOOL sSCISuppressLegacyEmployeeMenuMutation = NO;

static BOOL SCIEmployeeInternalMasterOn(void) {
    return [SCIUtils getBoolPref:@"sci_employee_internal"] ||
           [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"] ||
           [SCIUtils getBoolPref:@"sci_force_ig_is_employee"];
}

static BOOL SCIInternalMenuOn(void) {
    return SCIEmployeeInternalMasterOn() ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"] ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_availability"];
}

static BOOL (*orig_EmployeeInternalMasterEnabled)(id, SEL) = NULL;

static BOOL SCI_EmployeeInternalMasterEnabled(id self, SEL _cmd) {
    if (sSCISuppressLegacyEmployeeMenuMutation) return NO;
    return orig_EmployeeInternalMasterEnabled
        ? orig_EmployeeInternalMasterEnabled(self, _cmd)
        : NO;
}

static BOOL SCIEncodingMatches(Method method, const char *expected) {
    if (!method || !expected) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding && strcmp(encoding, expected) == 0;
}

static void SCIInstallLegacyEmployeeSuppressionHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("SCIInternalGatePrefs");
    Class meta = cls ? object_getClass(cls) : Nil;
    SEL selector = @selector(employeeInternalMasterEnabled);
    Method method = meta ? class_getInstanceMethod(meta, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!method || !encoding ||
        (strcmp(encoding, "B16@0:8") != 0 && strcmp(encoding, "c16@0:8") != 0)) return;
    MSHookMessageEx(meta, selector, (IMP)SCI_EmployeeInternalMasterEnabled,
                    (IMP *)&orig_EmployeeInternalMasterEnabled);
    installed = orig_EmployeeInternalMasterEnabled != NULL;
}

static SCIXPluginsGetDataFuncOrAbortFn SCIResolveXPluginsGetter(void) {
    static SCIXPluginsGetDataFuncOrAbortFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "XPluginsGetDataFuncOrAbort");
        if (!symbol) symbol = MSFindSymbol(NULL, "_XPluginsGetDataFuncOrAbort");
        fn = (SCIXPluginsGetDataFuncOrAbortFn)symbol;
    });
    return fn;
}

static BOOL SCIXPluginsPayloadAvailable(uint32_t hash) {
    SCIXPluginsGetDataFuncOrAbortFn getter = SCIResolveXPluginsGetter();
    if (!getter) return NO;
    SCIXPluginsDataProvider provider = (SCIXPluginsDataProvider)getter(hash);
    if (!provider) return NO;
    SCIXPluginsDataPair pair = provider();
    return pair.data != NULL && pair.count != 0;
}
