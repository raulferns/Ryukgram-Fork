#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RYGPortedRuntimeBrowserViewController : UITableViewController
- (instancetype)init;
- (instancetype)initWithTitle:(NSString *)title initialQuery:(NSString *)initialQuery;
- (instancetype)initWithTitle:(NSString *)title
                 initialQuery:(NSString *)initialQuery
allowsBulkVisibilityOverride:(BOOL)allowsBulkVisibilityOverride;
@end

NS_ASSUME_NONNULL_END
