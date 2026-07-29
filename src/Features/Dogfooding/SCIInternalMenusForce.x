// Standalone "Internal & Dogfood Menus" enabler.
//
// This compatibility surface is post-launch/manual by design. It no longer
// installs constant, irreversible identity IMPs. Employee identity delegates to
// SCIEmployeeInternal, while the two local menu getters keep their original IMP
// and read the persisted preference live.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>
#import "../../Utils.h"
#import "SCIInternalMenusForce.h"

void SCIInstallEmployeeIdentityHooksIfNeeded(void);
void SCIRequestInternalGlobalHooksInstall(void);

static BOOL SCIInternalMenusOn(void) {
    return [SCIUtils getBoolPref:@"sci_internal_menus"];
}

static BOOL (*orig_SCIDebugFooterEnabled)(id, SEL) = NULL;
static BOOL (*orig_SCIIdentitySwitcherDogfood)(id, SEL) = NULL;

static BOOL SCIDebugFooterEnabled(id self, SEL _cmd) {
    if (SCIInternalMenusOn()) return YES;
    return orig_SCIDebugFooterEnabled
        ? orig_SCIDebugFooterEnabled(self, _cmd)
        : NO;
}

static BOOL SCIIdentitySwitcherDogfood(id self, SEL _cmd) {
    if (SCIInternalMenusOn()) return YES;
    return orig_SCIIdentitySwitcherDogfood
        ? orig_SCIIdentitySwitcherDogfood(self, _cmd)
        : NO;
}

static BOOL SCIInternalMenusBoolGetterMatches(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    const char *encoding = method_getTypeEncoding(method);
    return encoding &&
        (strcmp(encoding, "B16@0:8") == 0 ||
         strcmp(encoding, "c16@0:8") == 0 ||
         strcmp(encoding, "C16@0:8") == 0);
}

static BOOL SCIInstallInternalMenusBoolGetter(
    const char *className,
    const char *selectorName,
    IMP replacement,
    IMP *original
) {
    if (*original) return YES;

    Class cls = objc_getClass(className);
    if (!cls) return NO;

    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!SCIInternalMenusBoolGetterMatches(method)) return NO;

    MSHookMessageEx(cls, selector, replacement, original);
    return *original != NULL;
}

static NSUInteger SCIInstallInternalMenusLocalHooks(void) {
    NSUInteger installed = 0;

    installed += SCIInstallInternalMenusBoolGetter(
        "_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings",
        "getDebugFooterEnabled",
        (IMP)SCIDebugFooterEnabled,
        (IMP *)&orig_SCIDebugFooterEnabled);

    installed += SCIInstallInternalMenusBoolGetter(
        "_TtC24IGIdentitySwitcherGating30IGIdentitySwitcherGatingHelper",
        "isFbAcquisitionEpDogfoodModeEnabled",
        (IMP)SCIIdentitySwitcherDogfood,
        (IMP *)&orig_SCIIdentitySwitcherDogfood);

    return installed;
}

NSString *SCIInternalMenusForceApplyNow(void) {
    if (!SCIInternalMenusOn()) {
        return @"Internal & Dogfood Menus is OFF. Installed wrappers read the preference live and now forward to the original implementations.";
    }

    SCIInstallEmployeeIdentityHooksIfNeeded();
    NSUInteger localCount = SCIInstallInternalMenusLocalHooks();
    SCIRequestInternalGlobalHooksInstall();

    return [NSString stringWithFormat:
        @"Canonical employee/Internal Global hooks requested; %lu/2 local menu getter%@ installed for this session. No constant identity IMP is used.",
        (unsigned long)localCount,
        localCount == 1 ? @"" : @"s"];
}

%ctor {
    @autoreleasepool {
        // Deliberately no-op. The legacy menu toggle is manual/post-launch.
    }
}
