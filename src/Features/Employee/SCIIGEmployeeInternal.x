#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "../../Utils.h"
#import "../../../modules/fishhook/fishhook.h"

static BOOL gSCIIGEmployeeInternalEnabled = NO;

static BOOL (*orig_ig_is_employee)(void) = NULL;
static BOOL (*orig_ig_is_employee_or_test_user)(void) = NULL;

static BOOL sci_ig_is_employee_hook(void) {
    return gSCIIGEmployeeInternalEnabled ? YES : (orig_ig_is_employee ? orig_ig_is_employee() : NO);
}

static BOOL sci_ig_is_employee_or_test_user_hook(void) {
    return gSCIIGEmployeeInternalEnabled ? YES : (orig_ig_is_employee_or_test_user ? orig_ig_is_employee_or_test_user() : NO);
}

%group SCIIGEmployeeInternalObjC

%hook IGAdPlatformLogger_objc
- (BOOL)isEmployee { return gSCIIGEmployeeInternalEnabled ? YES : %orig; }
%end

%hook IGAdPlatformLogger
- (BOOL)isEmployee { return gSCIIGEmployeeInternalEnabled ? YES : %orig; }
%end

%end

static BOOL (*orig_swift_IGAdPlatformLogger_isEmployee)(id self, SEL _cmd) = NULL;
static BOOL sci_swift_IGAdPlatformLogger_isEmployee(id self, SEL _cmd) {
    return gSCIIGEmployeeInternalEnabled ? YES : (orig_swift_IGAdPlatformLogger_isEmployee ? orig_swift_IGAdPlatformLogger_isEmployee(self, _cmd) : NO);
}

static void SCIInstallSwiftEmployeeLoggerHook(void) {
    Class cls = objc_getClass("_TtC28IGAdInsertionLoggingKitSwift24IGAdPlatformLogger_swift");
    SEL sel = @selector(isEmployee);
    if (cls && class_getInstanceMethod(cls, sel)) {
        MSHookMessageEx(cls, sel, (IMP)sci_swift_IGAdPlatformLogger_isEmployee, (IMP *)&orig_swift_IGAdPlatformLogger_isEmployee);
    }
}

%ctor {
    // Unified visible toggle plus legacy alias so old enabled installs keep working.
    gSCIIGEmployeeInternalEnabled = [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"] || [SCIUtils getBoolPref:@"sci_force_ig_is_employee"];
    if (!gSCIIGEmployeeInternalEnabled) return;

    %init(SCIIGEmployeeInternalObjC);
    SCIInstallSwiftEmployeeLoggerHook();

    struct rebinding employeeRebindings[] = {
        {"ig_is_employee", (void *)sci_ig_is_employee_hook, (void **)&orig_ig_is_employee},
        {"ig_is_employee_or_test_user", (void *)sci_ig_is_employee_or_test_user_hook, (void **)&orig_ig_is_employee_or_test_user},
    };
    rebind_symbols(employeeRebindings, 2);
}
