// Chokepoint for gating any RyukGram entry point behind a passcode group.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCILockGate : NSObject

// Runs `block` once `groupID` is unlocked. Synchronous if already unlocked.
+ (void)runGated:(NSString *)groupID
             from:(nullable UIViewController *)presenter
             then:(void (^)(void))block;

// Gates then presents `contentVC` via SCIPopupChrome with a SCILockSurfaceGuard
// attached so the VC re-prompts if the group relocks while open.
+ (void)presentLockedVC:(UIViewController *)contentVC
                forGroup:(NSString *)groupID
                    from:(nullable UIViewController *)presenter;

+ (void)presentLockedVC:(UIViewController *)contentVC
                forGroup:(NSString *)groupID
                    from:(nullable UIViewController *)presenter
              sourceView:(nullable UIView *)sourceView;

// Always prompts for the passcode regardless of session state. Used for
// sensitive toggles (lock/unlock chat, change passcode).
+ (void)forceAuthWithTitle:(NSString *)title
                   subtitle:(nullable NSString *)subtitle
                       from:(nullable UIViewController *)presenter
                        then:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
