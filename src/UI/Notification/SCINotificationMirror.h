#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Mirrors toasts into the iOS notification centre while IG is backgrounded so
// short-lived pills aren't missed. Pref gating, dedup/throttle and permission
// checks all live here.
@interface SCINotificationMirror : NSObject

// Main thread only.
+ (BOOL)appIsBackgrounded;

// Pref gating only — does not check app state.
+ (BOOL)shouldMirrorAction:(nullable NSString *)actionID;

// Safe to call from any thread.
+ (void)mirrorActionID:(nullable NSString *)actionID
                 title:(NSString *)title
              subtitle:(nullable NSString *)subtitle;

// Per-action mirror pref defaults (notif_mirror_<id> = "on"/"off").
+ (NSDictionary<NSString *, NSString *> *)defaultPerActionPrefs;

@end

NS_ASSUME_NONNULL_END
