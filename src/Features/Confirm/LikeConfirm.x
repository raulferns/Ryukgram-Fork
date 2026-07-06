#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// Reels like tap goes through a Swift class method on
// IGSundialViewerLikeButtonActionHandler since IG 426.
typedef void (*SciHandleTapFn)(Class, SEL, id, id, BOOL);
typedef void (*SciHandleTapCompFn)(Class, SEL, id, id, BOOL, id);
static SciHandleTapFn orig_sciHandleTap = NULL;
static SciHandleTapCompFn orig_sciHandleTapComp = NULL;

static void new_sciHandleTap(Class cls, SEL _cmd, id ctx, id btn, BOOL anim) {
    if (![SCIUtils getBoolPref:@"like_confirm_reels"]) {
        orig_sciHandleTap(cls, _cmd, ctx, btn, anim);
        return;
    }
    __strong id sCtx = ctx;
    __strong id sBtn = btn;
    [SCIUtils showConfirmation:^{
        @try { orig_sciHandleTap(cls, _cmd, sCtx, sBtn, anim); }
        @catch (__unused id e) {}
    } title:SCILocalized(@"Confirm like: Reels")];
}

// Copy the completion block — it's a stack block and won't survive the alert.
static void new_sciHandleTapComp(Class cls, SEL _cmd, id ctx, id btn, BOOL anim, id comp) {
    if (![SCIUtils getBoolPref:@"like_confirm_reels"]) {
        orig_sciHandleTapComp(cls, _cmd, ctx, btn, anim, comp);
        return;
    }
    __strong id sCtx = ctx;
    __strong id sBtn = btn;
    id sComp = comp ? [comp copy] : nil;
    [SCIUtils showConfirmation:^{
        @try { orig_sciHandleTapComp(cls, _cmd, sCtx, sBtn, anim, sComp); }
        @catch (__unused id e) {}
    } title:SCILocalized(@"Confirm like: Reels")];
}

__attribute__((constructor)) static void _sciHookReelsLikeHandler(void) {
    Class c = NSClassFromString(@"_TtC30IGSundialOverlayActionHandlers38IGSundialViewerLikeButtonActionHandler");
    if (!c) return;
    Class meta = object_getClass(c);
    SEL s1 = NSSelectorFromString(@"handleTapWithActionContext:likeButton:willPlayRingsCustomLikeAnimation:");
    SEL s2 = NSSelectorFromString(@"handleTapWithActionContext:likeButton:willPlayRingsCustomLikeAnimation:completion:");
    if (class_getClassMethod(c, s1))
        MSHookMessageEx(meta, s1, (IMP)new_sciHandleTap, (IMP *)&orig_sciHandleTap);
    if (class_getClassMethod(c, s2))
        MSHookMessageEx(meta, s2, (IMP)new_sciHandleTapComp, (IMP *)&orig_sciHandleTapComp);
}

#define CONFIRMPOSTLIKE(orig)                                                                    \
    if ([SCIUtils getBoolPref:@"like_confirm"])                                                  \
        [SCIUtils showConfirmation:^(void) { orig; } title:SCILocalized(@"Confirm like: Posts")]; \
    else return orig;

#define CONFIRMREELSLIKE(orig)                                                                    \
    if ([SCIUtils getBoolPref:@"like_confirm_reels"])                                             \
        [SCIUtils showConfirmation:^(void) { orig; } title:SCILocalized(@"Confirm like: Reels")]; \
    else return orig;

// Liking posts
%hook IGUFIButtonBarView
- (void)_onLikeButtonPressed:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)_onLikeButtonPressed {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end
%hook IGFeedPhotoView
- (void)_onDoubleTap:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)_onDoubleTap {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end
%hook IGVideoPlayerOverlayContainerView
- (void)_handleDoubleTapGesture:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end

// Liking reels
%hook IGSundialViewerVideoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
%end
%hook IGSundialViewerPhotoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
- (void)swift_photoCell:(id)arg1 didObserveDoubleTapWithLocationInfo:(id)arg2 gestureRecognizer:(id)arg3 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
%end
%hook IGSundialViewerCarouselCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
- (void)carouselCell:(id)arg1 didObserveDoubleTapWithLocationInfo:(id)arg2 gestureRecognizer:(id)arg3 {
    if ([SCIUtils getBoolPref:@"like_confirm_reels"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Reels")];
    } else {
        return %orig;
    }
}
%end

// Liking comments
%hook IGCommentCellController
- (void)commentCell:(id)arg1 didTapLikeButton:(id)arg2 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)commentCell:(id)arg1 didTapLikedByButtonForUser:(id)arg2 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)commentCellDidLongPressOnLikeButton:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)commentCellDidEndLongPressOnLikeButton:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
- (void)commentCellDidDoubleTap:(id)arg1 {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end
%hook IGFeedItemPreviewCommentCell
- (void)_didTapLikeButton {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end

// Story like/emoji confirm handled by SCIStoryInteractionPipeline.

// DM like button
%hook IGDirectThreadViewController
- (void)_didTapLikeButton {
    if ([SCIUtils getBoolPref:@"like_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
            %orig;
        } title:SCILocalized(@"Confirm like: Posts")];
    } else {
        return %orig;
    }
}
%end
