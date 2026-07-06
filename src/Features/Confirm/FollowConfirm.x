#import "../../Utils.h"
#import "../../InstagramHeaders.h"

#define SCI_CONFIRM_FOLLOW(origCall) \
	if ([SCIUtils getBoolPref:@"follow_confirm"]) { \
		[SCIUtils showConfirmation:^{ origCall; } title:SCILocalized(@"Confirm follow")]; \
		return; \
	} \
	origCall;

%hook IGFollowController

- (void)_didPressFollowButton {
	if (self.user.followStatus == 2) {
		if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
		return;
	}
	%orig;
}

- (void)_performUnfollow {
	if ([SCIUtils getBoolPref:@"unfollow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm unfollow")];
		return;
	}
	%orig;
}

%end

%hook IGDiscoverPeopleButtonGroupView

- (void)_onFollowButtonTapped:(id)arg1 {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

- (void)_onFollowingButtonTapped:(id)arg1 {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

%hook IGHScrollAYMFCell

- (void)_didTapAYMFActionButton {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

%hook IGHScrollAYMFActionButton

- (void)_didTapTextActionButton {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

%hook IGUnifiedVideoFollowButton

- (void)_hackilyHandleOurOwnButtonTaps:(id)arg1 event:(id)arg2 {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

%hook IGProfileViewController

- (void)navigationItemsControllerDidTapHeaderFollowButton:(id)arg1 {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

%hook IGStorySectionController

- (void)followButtonTapped:(id)arg1 cell:(id)arg2 {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			%orig;
		} title:SCILocalized(@"Confirm follow")];
		return;
	}
	%orig;
}

%end

static void (*orig_listSectionController)(id, SEL, id, id);

static void hooked_listSectionController(id self, SEL _cmd, id arg1, id arg2) {
	if ([SCIUtils getBoolPref:@"follow_confirm"]) {
		[SCIUtils showConfirmation:^{
			if (orig_listSectionController) {
				orig_listSectionController(self, _cmd, arg1, arg2);
			}
		} title:SCILocalized(@"Confirm follow")];
		return;
	}

	if (orig_listSectionController) {
		orig_listSectionController(self, _cmd, arg1, arg2);
	}
}

%ctor {
	Class cls = objc_getClass("IGDirectDetailMembersKit.IGDirectThreadDetailsMembersListViewController");
	if (!cls) return;

	SEL sel = @selector(listSectionController:didTapHeaderButtonWithViewModel:);
	if (![cls instancesRespondToSelector:sel]) return;

	MSHookMessageEx(cls, sel, (IMP)hooked_listSectionController, (IMP *)&orig_listSectionController);
}
