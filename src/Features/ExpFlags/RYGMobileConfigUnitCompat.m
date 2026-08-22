#import "RYGMobileConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

// The runtime parser stores a canonical PID, while the manager tells us which
// unit (0x40 or 0x80) Instagram actually used for a given ordinal/index. Keep
// the persisted canonical representation, but after native StartupConfigs writes
// remove the unobserved mirror unit so the on-disk/native override table matches
// the real session instead of blindly populating both namespaces.

typedef BOOL (*RYGSetOverrideIMP)(id, SEL, id, RYGMCParam *);
typedef void (*RYGReapplyOverridesIMP)(id, SEL);

static RYGSetOverrideIMP gRYGOriginalSetOverride;
static RYGReapplyOverridesIMP gRYGOriginalReapplyOverrides;

static unsigned long long RYGObservedPID(id owner, RYGMCParam *param) {
    if (!owner || !param.runtimeBacked || !param.paramID) return 0;
    SEL selector = NSSelectorFromString(@"bestParamIDFor:");
    Method method = class_getInstanceMethod([owner class], selector);
    if (!method || method_getNumberOfArguments(method) != 3) return param.paramID;
    char ret[16] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    const char *type = ret;
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type != 'Q' && *type != 'q') return param.paramID;
    unsigned long long value = ((unsigned long long (*)(id, SEL, RYGMCParam *))objc_msgSend)(owner, selector, param);
    return value ? value : param.paramID;
}

static unsigned long long RYGMirrorPID(unsigned long long pid) {
    if (!pid) return 0;
    unsigned long long type = (pid >> 48) & 0x0FULL;
    unsigned long long unit = (pid >> 48) & 0xF0ULL;
    unsigned long long mirrorUnit = unit == 0x80ULL ? 0x40ULL : 0x80ULL;
    return (pid & 0x0000FFFFFFFFFFFFULL) | ((mirrorUnit | type) << 48);
}

static void RYGRemoveUnobservedNativePID(id owner, RYGMCParam *param) {
    unsigned long long observed = RYGObservedPID(owner, param);
    if (!observed) return;
    unsigned long long mirror = RYGMirrorPID(observed);
    if (!mirror || mirror == observed) return;

    SEL selector = NSSelectorFromString(@"removeNativeForPid:");
    Method method = class_getInstanceMethod([owner class], selector);
    if (!method || method_getNumberOfArguments(method) != 3) return;
    char ret[16] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    const char *type = ret;
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type != 'B' && *type != 'c' && *type != 'C') return;
    (void)((BOOL (*)(id, SEL, unsigned long long))objc_msgSend)(owner, selector, mirror);
}

static BOOL RYGSetOverrideObservedUnit(id self, SEL _cmd, id value, RYGMCParam *param) {
    BOOL success = gRYGOriginalSetOverride ? gRYGOriginalSetOverride(self, _cmd, value, param) : NO;
    if (success) RYGRemoveUnobservedNativePID(self, param);
    return success;
}

static void RYGReapplyOverridesObservedUnit(id self, SEL _cmd) {
    if (gRYGOriginalReapplyOverrides) gRYGOriginalReapplyOverrides(self, _cmd);
    NSArray<RYGMCConfig *> *configs = [self allConfigs];
    for (RYGMCConfig *config in configs) {
        for (RYGMCParam *param in config.params) {
            if ([self overrideStateFor:param] == RYGMCOverrideSet) {
                RYGRemoveUnobservedNativePID(self, param);
            }
        }
    }
}

__attribute__((constructor)) static void RYGInstallMobileConfigUnitCompat(void) {
    Class cls = RYGMobileConfig.class;
    Method setMethod = class_getInstanceMethod(cls, @selector(setOverride:for:));
    Method reapplyMethod = class_getInstanceMethod(cls, @selector(reapplyOverridesToNativeTable));
    if (setMethod) {
        gRYGOriginalSetOverride = (RYGSetOverrideIMP)method_getImplementation(setMethod);
        method_setImplementation(setMethod, (IMP)RYGSetOverrideObservedUnit);
    }
    if (reapplyMethod) {
        gRYGOriginalReapplyOverrides = (RYGReapplyOverridesIMP)method_getImplementation(reapplyMethod);
        method_setImplementation(reapplyMethod, (IMP)RYGReapplyOverridesObservedUnit);
    }
}
