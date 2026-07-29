#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Enables or disables the canonical Tier-2 employee identity source used by
/// IGUserIsEmployeeOrTestUserFragment. The implementation uses targeted
/// MSHookMessageEx hooks on verified object getters, adds only the employee
/// account badge (@0), and never modifies a signed __TEXT page. Installed hooks
/// return the untouched original collection whenever the toggle is disabled.
FOUNDATION_EXPORT void SCITier2EmployeeGateSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL SCITier2EmployeeGateEnabled(void);
FOUNDATION_EXPORT BOOL SCITier2EmployeeGateInstalled(void);

NS_ASSUME_NONNULL_END
