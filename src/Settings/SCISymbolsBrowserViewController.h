// SCISymbolsBrowserViewController.h
// ABI-aware Mach-O browser for Instagram/FBShared symbols.

#import "SCIBaseSettingsListViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCICSymbolsBrowserMode) {
    SCICSymbolsBrowserModeObjCMethods = 0,
    SCICSymbolsBrowserModeCFunctions = 1,
    SCICSymbolsBrowserModeDataParams = 2,
    SCICSymbolsBrowserModeSwiftDisassembly = 3,
};

@interface SCISymbolsBrowserViewController : SCIBaseSettingsListViewController <UISearchBarDelegate>
- (instancetype)initWithMode:(SCICSymbolsBrowserMode)mode;
@end

NS_ASSUME_NONNULL_END
