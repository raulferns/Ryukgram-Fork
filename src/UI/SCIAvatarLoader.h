#import <UIKit/UIKit.h>

// Shared avatar provider for SCIIDList-style screens. Returns the cached
// rounded avatar (or a placeholder), loads via SCIImageCache and posts
// SCIAvatarLoadedNotification once the real image is ready.
extern NSString *const SCIAvatarLoadedNotification;

@interface SCIAvatarLoader : NSObject

// Entry dict: thread-shaped (avatarURL / isGroup / users[{pk, profilePicURL}])
// or user-shaped (pk / profilePicURL). Missing URLs backfill from the live
// direct cache or the IG API.
+ (UIImage *)avatarForEntry:(NSDictionary *)entry;

+ (UIImage *)avatarForURLString:(NSString *)urlString group:(BOOL)group;

@end
