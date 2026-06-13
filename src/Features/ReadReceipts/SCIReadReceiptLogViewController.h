#import <UIKit/UIKit.h>

@interface SCIReadReceiptLogViewController : UIViewController
// Presents the read-receipts log full-screen via SCIPopupChrome.
+ (void)presentFromViewController:(UIViewController *)presenter;
@end
