// SCICSymbolBrowserViewController.h
// Real runtime browser for Instagram/FBShared C imports. Search-driven UI;
// observe-only by default; force is explicit and blocked for known MCI crashers.

#import "SCIBaseSettingsListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCICSymbolBrowserViewController : SCIBaseSettingsListViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
