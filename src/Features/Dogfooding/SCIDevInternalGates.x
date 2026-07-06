#import "../../Utils.h"
#import <objc/runtime.h>
#import <substrate.h>

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
- (BOOL)isEmployee {
	return sciDevGate(@"sci_force_ig_is_employee") ? YES : %orig;
}
%end

%hook IGFeaturedUserInfo
- (BOOL)shouldShowInternalBadge {
	return sciDevGate(@"sci_force_ig_featured_internal_badge") ? YES : %orig;
}
%end

%hook IGDirectInboxThreadCellViewModel
- (BOOL)shouldShowInternalBadge {
	return sciDevGate(@"sci_force_ig_inbox_internal_badge") ? YES : %orig;
}
%end

%hook IGCreationActionBarButton
- (BOOL)shouldShowInternalLabel {
	return sciDevGate(@"sci_force_ig_creation_internal_label") ? YES : %orig;
}
%end

%hook IGLaunchHorizonViewController
- (BOOL)shouldShowDebugInfo {
	return sciDevGate(@"sci_force_ig_launch_debug_info") ? YES : %orig;
}
%end

%end

%group SCIDevLaunchV2Group
%hook LaunchHorizonViewControllerV2
- (BOOL)shouldShowDebugInfo {
	return sciDevGate(@"sci_force_ig_launch_debug_info_v2") ? YES : %orig;
}
%end
%end

%group SCIStoryDebugUnderlayGroup
%hook IGStoryOpaqueDebugUnderlayViewFactory
+ (BOOL)shouldShowDebugUnderlay {
	return sciDevGate(@"sci_force_ig_story_debug_underlay") ? YES : %orig;
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
	}
}
