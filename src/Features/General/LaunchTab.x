// Force launch into a chosen tab (messages_only inbox, or the launch_tab pref).
// IG restores its last tab asynchronously, so we coerce the surface setter until
// the user's first deliberate tab tap rather than forcing the tab just once.

#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *sciDesiredSurfaceString(void) {
    if ([SCIUtils getBoolPref:@"messages_only"]) return @"DIRECT";
    NSString *p = [SCIUtils getStringPref:@"launch_tab"];
    if ([p isEqualToString:@"feed"])    return @"FEED";
    if ([p isEqualToString:@"explore"]) return @"SEARCH";
    if ([p isEqualToString:@"reels"])   return @"CLIPS";
    if ([p isEqualToString:@"inbox"])   return @"DIRECT";
    if ([p isEqualToString:@"profile"]) return @"PROFILE";
    return nil;
}

static const void *kSCILaunchLockReleasedKey = &kSCILaunchLockReleasedKey;

static BOOL sciLaunchLockReleased(id ctrl) {
    return [objc_getAssociatedObject(ctrl, &kSCILaunchLockReleasedKey) boolValue];
}

void sciReleaseLaunchTabLock(id ctrl) {
    objc_setAssociatedObject(ctrl, &kSCILaunchLockReleasedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id sciSurfaceObjectForString(id ctrl, NSString *want) {
    if (!want) return nil;
    NSArray *surfaces = nil;
    if ([ctrl respondsToSelector:@selector(allTabBarSurfaces)])
        surfaces = [ctrl allTabBarSurfaces];
    if (![surfaces isKindOfClass:[NSArray class]])
        surfaces = [SCIUtils getIvarForObj:ctrl name:"_tabBarSurfaces"];
    for (id s in surfaces) {
        if ([s respondsToSelector:@selector(tabStringFromSurfaceIntent)] &&
            [[s tabStringFromSurfaceIntent] isEqualToString:want])
            return s;
    }
    return nil;
}

static id sciCoerceSurface(id ctrl, id surface) {
    NSString *want = sciDesiredSurfaceString();
    if (!want || sciLaunchLockReleased(ctrl)) return surface;
    if (![surface respondsToSelector:@selector(tabStringFromSurfaceIntent)]) return surface;
    NSString *got = [surface tabStringFromSurfaceIntent];
    if ([got isEqualToString:want]) return surface;
    id desired = sciSurfaceObjectForString(ctrl, want);
    return desired ?: surface;
}

%hook IGTabBarController

- (void)setSelectedTabBarSurface:(id)surface animated:(BOOL)animated animateIndicator:(BOOL)animateIndicator {
    %orig(sciCoerceSurface(self, surface), animated, animateIndicator);
}

- (void)setSelectedTabBarSurface:(id)surface animated:(BOOL)animated {
    %orig(sciCoerceSurface(self, surface), animated);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    static BOOL forced = NO;
    if (forced) return;
    NSString *want = sciDesiredSurfaceString();
    if (!want) return;
    forced = YES;
    // Only force when IG never set the surface itself — otherwise coercion
    // already handled it and re-selecting mid-appearance is a redundant transition.
    id cur = [self respondsToSelector:@selector(selectedTabBarSurface)] ? [self selectedTabBarSurface] : nil;
    NSString *curStr = [cur respondsToSelector:@selector(tabStringFromSurfaceIntent)] ? [cur tabStringFromSurfaceIntent] : nil;
    if ([curStr isEqualToString:want]) return;
    id desired = sciSurfaceObjectForString(self, want);
    if (desired)
        [self setSelectedTabBarSurface:desired animated:NO animateIndicator:NO];
}

- (void)_timelineButtonPressed      {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_exploreButtonPressed       {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_discoverVideoButtonPressed {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_directInboxButtonPressed   {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_profileButtonPressed       {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_cameraButtonPressed        {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_newsButtonPressed          {
	sciReleaseLaunchTabLock(self);
	%orig;
}
- (void)_streamsButtonPressed       {
	sciReleaseLaunchTabLock(self);
	%orig;
}

%end
