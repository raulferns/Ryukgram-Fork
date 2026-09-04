#import "RYGMobileConfigToolsViewController.h"
#import "RYGMobileConfig.h"
#import "../../Settings/RYGSetting.h"
#import "../../Settings/RYGSymbol.h"
#import <objc/runtime.h>

static BOOL RYGStartupConfigsSurfaceAvailable(void) {
    Class cls = NSClassFromString(@"FBMobileConfigStartupConfigs");
    if (!cls) return NO;
    Method getInstance = class_getClassMethod(cls, NSSelectorFromString(@"getInstance"));
    Method setOverride = class_getInstanceMethod(cls, NSSelectorFromString(@"setOverrideForParam:andValue:"));
    Method removeOverride = class_getInstanceMethod(cls, NSSelectorFromString(@"removeOverrideForParam:"));
    return getInstance && method_getNumberOfArguments(getInstance) == 2 &&
           setOverride && method_getNumberOfArguments(setOverride) == 4 &&
           removeOverride && method_getNumberOfArguments(removeOverride) == 3;
}

@implementation RYGMobileConfigToolsViewController (RYGStatus)

- (void)ryg_status_rebuildSections {
    [self ryg_status_rebuildSections];

    NSArray *existing = nil;
    @try { existing = [self valueForKey:@"sections"]; } @catch (__unused id exception) {}
    if (!existing) return;

    RYGMobileConfig *mc = [RYGMobileConfig shared];
    NSUInteger overrides = mc.overrideCount;
    BOOL startupConfigs = RYGStartupConfigsSurfaceAvailable();
    NSString *nativeSubtitle = startupConfigs
        ? [NSString stringWithFormat:@"FBMobileConfigStartupConfigs is loaded. %lu typed override(s) are persisted and can be replayed through its validated ABI.",
           (unsigned long)overrides]
        : [NSString stringWithFormat:@"StartupConfigs is not loaded yet. %lu typed override(s) remain in RyukGram's exact getter store and can be retried later.",
           (unsigned long)overrides];

    NSString *persistSubtitle = @"RyukGram typed plist + portable JSON snapshot. Instagram's native mc_overrides.json is read-only and is not used as a writer target.";

    RYGSetting *native = [RYGSetting staticCellWithTitle:@"Native StartupConfigs writer"
                                                subtitle:nativeSubtitle
                                                    icon:[RYGSymbol symbolWithName:@"sliders"]];
    RYGSetting *disk = [RYGSetting staticCellWithTitle:@"Override persistence"
                                              subtitle:persistSubtitle
                                                  icon:[RYGSymbol symbolWithName:@"document"]];
    NSDictionary *status = [RYGSettingsViewController sectionWithHeader:@"Apply status"
                                                                  footer:@"Runtime application uses StartupConfigs and the exact getter-hook owner. JSON exists only for import/export."
                                                                    rows:@[native, disk]];

    NSMutableArray *sections = [NSMutableArray arrayWithObject:status];
    [sections addObjectsFromArray:existing];
    [self applySettingSections:sections.copy];
}

@end

__attribute__((constructor(160))) static void RYGInstallMobileConfigToolsStatus(void) {
    Class cls = RYGMobileConfigToolsViewController.class;
    Method original = class_getInstanceMethod(cls, @selector(rebuildSections));
    Method replacement = class_getInstanceMethod(cls, @selector(ryg_status_rebuildSections));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}
