#import <UIKit/UIKit.h>

// Opens Instagram's own internal/dogfooding surfaces — but ONLY via entrypoints
// where Instagram itself constructs the (Swift) object graph. We never alloc/init
// a Swift VC ourselves: a failed Swift type-metadata check is an uncatchable
// `brk #1` trap (see crash post-mortem in the .m). Every method returns a short
// human-readable status string; a successful open starts with "opened".
@interface SCIInternalMenusLauncher : NSObject

// +notesDogfoodingSettingsOpenOnViewController:userSession: (class method, safe).
+ (NSString *)openDogfoodingNotesSettings;

// IG's openWithConfig:onViewController:userSession: using a config IG built.
// If no config was captured, falls back to Notes; never fabricates the config.
+ (NSString *)openDogfoodingSettingsVC;

// IGURLHandler internal-URL routing (IG builds the destination VC).
+ (NSString *)openInternalURLString:(NSString *)urlString;

// Tries the safe openers in order: Notes → DogfoodVC → URL handler.
+ (NSString *)openBestAvailableInternalMenu;

@end
