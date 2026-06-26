#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>

static unsigned long long sciGetMCParamID(const char *symbolName) {
    void **ptr = (void **)dlsym(RTLD_DEFAULT, symbolName);
    if (ptr && *ptr) {
        return *(unsigned long long *)(*ptr);
    }
    return 0;
}

static BOOL sciDevMaster(void) { return [SCIUtils getBoolPref:@"sci_force_ig_internal_employee"]; }
static BOOL sciDevGate(NSString *key) { return sciDevMaster() || [SCIUtils getBoolPref:key]; }
static BOOL sciDevAnyGateEnabled(void) {
	return sciDevMaster()
		|| [SCIUtils getBoolPref:@"sci_force_ig_is_employee"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_featured_internal_badge"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_inbox_internal_badge"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_creation_internal_label"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_launch_debug_info"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_launch_debug_info_v2"]
		|| [SCIUtils getBoolPref:@"sci_force_ig_story_debug_underlay"];
}

%group SCIDevInternalObjCGatesGroup

%hook IGAdPlatformLogger_objc
- (BOOL)isEmployee { return sciDevGate(@"sci_force_ig_is_employee") ? YES : %orig; }
%end

%hook IGFeaturedUserInfo
- (BOOL)shouldShowInternalBadge { return sciDevGate(@"sci_force_ig_featured_internal_badge") ? YES : %orig; }
%end

%hook IGDirectInboxThreadCellViewModel
- (BOOL)shouldShowInternalBadge { return sciDevGate(@"sci_force_ig_inbox_internal_badge") ? YES : %orig; }
%end

%hook IGCreationActionBarButton
- (BOOL)shouldShowInternalLabel { return sciDevGate(@"sci_force_ig_creation_internal_label") ? YES : %orig; }
%end

%hook IGLaunchHorizonViewController
- (BOOL)shouldShowDebugInfo { return sciDevGate(@"sci_force_ig_launch_debug_info") ? YES : %orig; }
%end

%end

%group SCIDevLaunchV2Group
%hook LaunchHorizonViewControllerV2
- (BOOL)shouldShowDebugInfo { return sciDevGate(@"sci_force_ig_launch_debug_info_v2") ? YES : %orig; }
%end
%end

%group SCIStoryDebugUnderlayGroup
%hook IGStoryOpaqueDebugUnderlayViewFactory
+ (BOOL)shouldShowDebugUnderlay { return sciDevGate(@"sci_force_ig_story_debug_underlay") ? YES : %orig; }
%end
%end

%group SCIDevMobileConfigContextGroup

%hook FBMobileConfigContext

- (BOOL)getBool:(unsigned long long)paramID {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withOptions:(id)options {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withDefault:(BOOL)def {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withOptions:(id)options withDefault:(BOOL)def {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

%end

%end

%group SCIDevMobileConfigAPIGroup

%hook FBMobileConfigAPI

- (BOOL)getBool:(unsigned long long)paramID {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withOptions:(id)options {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withDefault:(BOOL)def {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

- (BOOL)getBool:(unsigned long long)paramID withOptions:(id)options withDefault:(BOOL)def {
    static unsigned long long emp_pid = 0;
    static unsigned long long emp_test_pid = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emp_pid = sciGetMCParamID("ig_is_employee");
        emp_test_pid = sciGetMCParamID("ig_is_employee_or_test_user");
    });
    if (sciDevMaster()) {
        if ((emp_pid && paramID == emp_pid) || (emp_test_pid && paramID == emp_test_pid)) {
            return YES;
        }
    }
    return %orig;
}

%end

%end

%ctor {
	@autoreleasepool {
		if (!sciDevAnyGateEnabled()) return;

		%init(SCIDevInternalObjCGatesGroup);

		Class v2 = objc_getClass("_TtC16IGLaunchHorizon30LaunchHorizonViewControllerV2")
				?: objc_getClass("LaunchHorizonViewControllerV2");
		if (v2) %init(SCIDevLaunchV2Group, LaunchHorizonViewControllerV2 = v2);

		Class underlay = objc_getClass("_TtC20IGStoryDebugUnderlay37IGStoryOpaqueDebugUnderlayViewFactory")
				?: objc_getClass("IGStoryOpaqueDebugUnderlayViewFactory");
		if (underlay) %init(SCIStoryDebugUnderlayGroup, IGStoryOpaqueDebugUnderlayViewFactory = underlay);

		Class mcCtx = objc_getClass("FBMobileConfigContext");
		if (mcCtx) {
			%init(SCIDevMobileConfigContextGroup, FBMobileConfigContext = mcCtx);
		}
		Class mcAPI = objc_getClass("FBMobileConfigAPI");
		if (mcAPI) {
			%init(SCIDevMobileConfigAPIGroup, FBMobileConfigAPI = mcAPI);
		}
	}
}
