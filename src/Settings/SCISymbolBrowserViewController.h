// SCISymbolBrowserViewController.h
//
// Dynamic per-image symbol browser. Two instances are presented from the Dev
// menu: one for the Instagram executable, one for FBSharedFramework. Each lists
// classes (section header) with their hookable BOOL getters as switch rows whose
// state mirrors the LIVE getter value and whose toggle forces it (persisted +
// re-applied at launch by SCISymbolBrowserEngine).

#import "SCIBaseSettingsListViewController.h"
#import "../Features/Dogfooding/SCISymbolBrowserEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface SCISymbolBrowserViewController : SCIBaseSettingsListViewController <UISearchResultsUpdating>
- (instancetype)initWithImage:(SCISymbolImage)image;
@end

NS_ASSUME_NONNULL_END
