// SCICSymbolBrowserViewController.h
//
// Runtime browser for Instagram's C boolean readers (MobileConfig / EasyGating),
// imported from FBSharedFramework via GOT and hooked with fishhook. Lets you, in
// real time: enable global C-symbol forcing, turn diagnostic capture on, watch
// each reader's live call count and the gating IDs it was called with (plus the
// real value observed), and force either the whole symbol or a single captured
// ID. The per-ID force is the surgical path for unlocking the internal-settings
// gate without forcing every MobileConfig read.

#import "SCIBaseSettingsListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCICSymbolBrowserViewController : SCIBaseSettingsListViewController
- (instancetype)init;
@end

NS_ASSUME_NONNULL_END
