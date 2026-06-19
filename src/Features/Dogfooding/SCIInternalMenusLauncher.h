#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SCIInternalMenusLauncher : NSObject
// Presents IG's own internal/dogfooding menus using validated class-method
// entrypoints + the live user session/config observed from Instagram runtime.
+ (NSString *)openDogfoodingNotesSettings;     // +notesDogfoodingSettingsOpenOnViewController:userSession: (reliable)
+ (NSString *)openDogfoodingSettingsVC;        // +openWithConfig:onViewController:userSession: / initWithConfig:userSession: when config is captured
+ (NSString *)openInternalURLString:(NSString *)urlString; // +[IGURLHandler openInternalURL:...]
@end
NS_ASSUME_NONNULL_END
