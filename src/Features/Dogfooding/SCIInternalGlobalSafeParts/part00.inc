// SCIInternalGlobalSafe.x
// New-IG internal/employee bridge validated against:
// Instagram fa19f499c560b188d2802e3a1a36642209ee6e42d7639c1ebe010f14b2c4cd9b
// FBSharedFramework a79c110c59e7c16e5608227e12807583c1afcf80cb2a2e38302f147dbf99c12b
//
// XPlugins hashes 0x64327C01 (internal_only) and 0x7FBC8058
// (Dogfooding Assistant socket) resolve to providers returning a 16-byte pair
// in x0/x1: (data pointer, element count). Never substitute BOOL/sentinel data.

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
#import <stdatomic.h>
#import <string.h>

#define IGSLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] InternalGlobalSafe " fmt, ##__VA_ARGS__)

void SCIInstallEmployeeIdentityHooksIfNeeded(void);
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

static _Atomic(uint64_t) sSCIXPluginsImageGeneration = 1;

static void SCIAdvanceXPluginsImageGeneration(void) {
    atomic_fetch_add_explicit(&sSCIXPluginsImageGeneration, 1,
                              memory_order_release);
}

static BOOL SCIEmployeeInternalMasterOn(void) {
    return [SCIUtils getBoolPref:@"sci_employee_internal"] ||
           [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"] ||
           [SCIUtils getBoolPref:@"sci_force_ig_is_employee"] ||
           [SCIUtils getBoolPref:@"sci_internal_menus"];
}

static BOOL SCIInternalMenuOn(void) {
    return SCIEmployeeInternalMasterOn() ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_menu"] ||
           [SCIUtils getBoolPref:@"sci_force_internal_settings_availability"];
}

static BOOL SCIEncodingMatches(Method method, const char *expected) {
    if (!method || !expected) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding && strcmp(encoding, expected) == 0;
}

// A constructor-time miss must not be cached forever, but repeatedly calling
// MSFindSymbol(NULL, ...) is also wasteful. Cache a negative result only for the
// current dyld image generation; any newly added image invalidates that miss.
static SCIXPluginsGetDataFuncOrAbortFn SCIResolveXPluginsGetter(void) {
    static _Atomic(uintptr_t) cachedAddress = 0;
    static _Atomic(uint64_t) failedGeneration = 0;

    uintptr_t cached = atomic_load_explicit(&cachedAddress, memory_order_acquire);
    if (cached) return (SCIXPluginsGetDataFuncOrAbortFn)cached;

    uint64_t generation = atomic_load_explicit(&sSCIXPluginsImageGeneration,
                                                memory_order_acquire);
    if (atomic_load_explicit(&failedGeneration, memory_order_acquire) == generation) {
        return NULL;
    }

    void *symbol = dlsym(RTLD_DEFAULT, "XPluginsGetDataFuncOrAbort");
    if (!symbol) symbol = MSFindSymbol(NULL, "_XPluginsGetDataFuncOrAbort");
    if (!symbol) {
        atomic_store_explicit(&failedGeneration, generation,
                              memory_order_release);
        return NULL;
    }

    uintptr_t resolved = (uintptr_t)symbol;
    uintptr_t expected = 0;
    atomic_compare_exchange_strong_explicit(&cachedAddress, &expected, resolved,
                                            memory_order_release,
                                            memory_order_relaxed);
    cached = atomic_load_explicit(&cachedAddress, memory_order_acquire);
    return (SCIXPluginsGetDataFuncOrAbortFn)cached;
}

static BOOL SCIXPluginsPayloadAvailable(uint32_t hash) {
    SCIXPluginsGetDataFuncOrAbortFn getter = SCIResolveXPluginsGetter();
    if (!getter) return NO;
    SCIXPluginsDataProvider provider = (SCIXPluginsDataProvider)getter(hash);
    if (!provider) return NO;
    SCIXPluginsDataPair pair = provider();
    return pair.data != NULL && pair.count != 0;
}
