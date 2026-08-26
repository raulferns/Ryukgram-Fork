#import "RYGMobileConfigToolsViewController.h"
#import "RYGMobileConfig.h"
#import "RYGMobileConfigJSONIO.h"
#import "../../Utils.h"
#import <objc/runtime.h>

// Import/export policy is deliberately separate from native-path discovery.
// id_name_mapping import/export and mc_overrides export are valid from the
// canonical RyukGram cache even before the native context manager exposes its
// account-specific getOverridesTablePath. Only operations that promise to WRITE
// the native mc_overrides.json require a manager-backed path.

@interface RYGMobileConfigToolsViewController (RYGNativePathPolicyPrivate)
- (BOOL)syncNativeOrShowError:(NSString *)operation;
- (BOOL)ryg_policy_syncNativeOrShowError:(NSString *)operation;
@end

@implementation RYGMobileConfigToolsViewController (RYGNativePathPolicy)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"syncNativeOrShowError:"));
        Method replacement = class_getInstanceMethod(self, @selector(ryg_policy_syncNativeOrShowError:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (BOOL)ryg_policy_syncNativeOrShowError:(NSString *)operation {
    NSString *label = operation ?: @"MobileConfig sync";
    NSString *lower = label.lowercaseString ?: @"";

    // These operations do not logically depend on the native override file.
    // The mapping store and canonical override cache are sufficient sources.
    BOOL cacheOnlyIsValid = [lower containsString:@"mapping"] || [lower hasPrefix:@"export"];

    RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
    BOOL synced = [mobileConfig ryg_syncPersistedJSONToNativeDataDirectory];
    NSString *path = [mobileConfig ryg_nativeOverridesJSONPath];
    if (synced && path.length) return YES;
    if (cacheOnlyIsValid) return YES;

    NSString *message = nil;
    if (path.length) {
        message = [NSString stringWithFormat:@"%@ could not round-trip the native MobileConfig file at %@.", label, path];
    } else {
        message = [NSString stringWithFormat:@"%@ could not obtain the active MobileConfig manager's getOverridesTablePath yet. No App Group path was guessed.", label];
    }
    [RYGUtils showErrorHUDWithDescription:message];
    return NO;
}

@end
