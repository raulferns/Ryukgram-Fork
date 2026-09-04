#import "RYGDeveloperTopicViewController.h"
#import "RYGRuntimeValueStore.h"
#import "../UI/RYGLiquidGlass.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>

/*
 * Restores the exact Story Tray / Throwback runtime gating model that was used
 * by experimental5, but routes it through the durable typed runtime store that
 * was ported from WATweaks dogfood2.
 *
 * Important differences from the previous dogfood implementation:
 *   - Throwback hooks the proven no-argument BOOL getter `isEnabled`, not the
 *     helper setter `overrideIsEnabled:`.
 *   - Story Tray is the experimental5 bundle of six Homecoming getters plus
 *     IGNavConfiguration.enableStoriesTabHeaderButton.
 *   - Changes are persisted before hook installation. A class that has not yet
 *     been realized simply leaves a pending override; the dyld callback retries
 *     persisted hooks when another image is loaded.
 *   - The topic UI uses UISwitch controls instead of the wide tri-state UIMenu.
 */

static NSString *const kRYGLegacyStoryTrayBundlePref = @"ryg_dev_story_tray_bundle_enabled_v2";
static NSString *const kRYGLegacyThrowbackPref = @"ryg_dev_glass_throwback_enabled";
static const void *kRYGLegacyFeatureSwitchRowKey = &kRYGLegacyFeatureSwitchRowKey;

static NSString *const kRYGThrowbackClass = @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper";
static NSString *const kRYGThrowbackSelector = @"isEnabled";

static NSArray<NSDictionary *> *RYGLegacyStorySpecs(void) {
    static NSArray<NSDictionary *> *specs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *homecoming = @"_TtC18IGNavConfiguration25IGHomecomingConfiguration";
        specs = @[
            @{@"class":homecoming, @"selector":@"isStoriesTrayOnAllTabsEnabled", @"title":@"Stories tray on all tabs"},
            @{@"class":homecoming, @"selector":@"showCinemaStoriesTrayOnSwipeUp", @"title":@"Cinema stories tray on swipe up"},
            @{@"class":homecoming, @"selector":@"isDynamicTabStoryGridEnabled", @"title":@"Dynamic tab story grid"},
            @{@"class":homecoming, @"selector":@"isVerticalStoriesTray", @"title":@"Vertical stories tray"},
            @{@"class":homecoming, @"selector":@"isFeedCullingOnStoriesAccessEnabled", @"title":@"Feed culling on stories access"},
            @{@"class":homecoming, @"selector":@"isHomecomingStoriesAccessFaceClusterEnabled", @"title":@"Stories access face cluster"},
            @{@"class":@"_TtC18IGNavConfiguration18IGNavConfiguration", @"selector":@"enableStoriesTabHeaderButton", @"title":@"Stories tab header button"},
        ];
    });
    return specs;
}

static BOOL RYGLegacyInstallBool(NSString *className, NSString *selectorName, NSNumber *value) {
    if (!className.length || !selectorName.length) return NO;
    if (value) {
        RYGRuntimeValueSetOverride(className, selectorName, NO, @"B", value);
        return RYGRuntimeValueInstallHook(className, selectorName, NO, @"B");
    }
    RYGRuntimeValueClearOverride(className, selectorName, NO);
    return YES;
}

static NSUInteger RYGLegacyApplyStoryBundle(BOOL enabled) {
    NSUInteger installed = 0;
    for (NSDictionary *spec in RYGLegacyStorySpecs()) {
        NSString *className = spec[@"class"];
        NSString *selectorName = spec[@"selector"];
        if (enabled) {
            if (RYGLegacyInstallBool(className, selectorName, @YES)) installed++;
        } else {
            RYGLegacyInstallBool(className, selectorName, nil);
        }
    }
    return installed;
}

static BOOL RYGLegacyStoryBundleIsFullyForcedOn(void) {
    for (NSDictionary *spec in RYGLegacyStorySpecs()) {
        id value = RYGRuntimeValueOverride(spec[@"class"], spec[@"selector"], NO);
        if (![value respondsToSelector:@selector(boolValue)] || ![value boolValue]) return NO;
    }
    return YES;
}

static void RYGLegacyRestorePersistedFeatureState(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kRYGLegacyStoryTrayBundlePref]) {
        RYGLegacyApplyStoryBundle(YES);
    }
    if ([defaults boolForKey:kRYGLegacyThrowbackPref]) {
        RYGLegacyInstallBool(kRYGThrowbackClass, kRYGThrowbackSelector, @YES);
    }
    (void)RYGRuntimeValueReinstallPersistedHooks();
}

static void RYGLegacyImageAdded(const struct mach_header *header __unused, intptr_t slide __unused) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static BOOL scheduled = NO;
        if (scheduled) return;
        scheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(220 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            scheduled = NO;
            (void)RYGRuntimeValueReinstallPersistedHooks();
        });
    });
}

static NSInteger RYGLegacySurface(id controller) {
    @try {
        id value = [controller valueForKey:@"surface"];
        return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : NSNotFound;
    } @catch (__unused NSException *exception) {
        return NSNotFound;
    }
}

static NSArray<NSDictionary *> *RYGLegacyRows(id controller) {
    @try {
        id value = [controller valueForKey:@"rows"];
        return [value isKindOfClass:NSArray.class] ? value : @[];
    } @catch (__unused NSException *exception) {
        return @[];
    }
}

static void RYGLegacySetRows(id controller, NSArray<NSDictionary *> *rows) {
    @try { [controller setValue:rows ?: @[] forKey:@"rows"]; }
    @catch (__unused NSException *exception) {}
}

static NSDictionary *RYGLegacyRowAt(id controller, NSIndexPath *indexPath) {
    NSArray *rows = RYGLegacyRows(controller);
    if (indexPath.section != 0 || indexPath.row < 0 || (NSUInteger)indexPath.row >= rows.count) return nil;
    id row = rows[(NSUInteger)indexPath.row];
    return [row isKindOfClass:NSDictionary.class] ? row : nil;
}

@interface RYGDeveloperTopicViewController (RYGExperimentalFeaturePort)
- (void)ryg_exp5_rebuildRows;
- (UITableViewCell *)ryg_exp5_tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)ryg_exp5_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)ryg_exp5_featureSwitchChanged:(UISwitch *)sender;
@end

@implementation RYGDeveloperTopicViewController (RYGExperimentalFeaturePort)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalRows = class_getInstanceMethod(self, NSSelectorFromString(@"rebuildRows"));
        Method portRows = class_getInstanceMethod(self, @selector(ryg_exp5_rebuildRows));
        if (originalRows && portRows) method_exchangeImplementations(originalRows, portRows);

        Method originalCell = class_getInstanceMethod(self, @selector(tableView:cellForRowAtIndexPath:));
        Method portCell = class_getInstanceMethod(self, @selector(ryg_exp5_tableView:cellForRowAtIndexPath:));
        if (originalCell && portCell) method_exchangeImplementations(originalCell, portCell);

        Method originalSelect = class_getInstanceMethod(self, @selector(tableView:didSelectRowAtIndexPath:));
        Method portSelect = class_getInstanceMethod(self, @selector(ryg_exp5_tableView:didSelectRowAtIndexPath:));
        if (originalSelect && portSelect) method_exchangeImplementations(originalSelect, portSelect);
    });
}

- (void)ryg_exp5_rebuildRows {
    [self ryg_exp5_rebuildRows];

    NSInteger surface = RYGLegacySurface(self);
    if (surface == RYGDeveloperRuntimeSurfaceStories) {
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        [rows addObject:@{
            @"kind": @"exp5StoryMaster",
            @"title": @"Story Tray · experimental5 preset",
            @"subtitle": @"7 validated runtime getters · switch off restores native values"
        }];
        for (NSDictionary *spec in RYGLegacyStorySpecs()) {
            [rows addObject:@{
                @"kind": @"exp5StoryGate",
                @"title": spec[@"title"] ?: spec[@"selector"],
                @"subtitle": [NSString stringWithFormat:@"%@ · %@ · tap row = Native", spec[@"class"], spec[@"selector"]],
                @"class": spec[@"class"],
                @"selector": spec[@"selector"]
            }];
        }
        RYGLegacySetRows(self, rows.copy);
        [self.tableView reloadData];
        return;
    }

    if (surface == RYGDeveloperRuntimeSurfaceLiquidGlass) {
        NSMutableArray<NSDictionary *> *rows = [RYGLegacyRows(self) mutableCopy] ?: [NSMutableArray array];
        for (NSUInteger index = 0; index < rows.count; index++) {
            NSDictionary *row = rows[index];
            if ([row[@"kind"] isEqualToString:@"glass"] && [row[@"glass"] isEqualToString:@"throwback"]) {
                rows[index] = @{
                    @"kind": @"exp5Throwback",
                    @"title": @"Throwback Chrome",
                    @"subtitle": @"experimental5 · IGThrowbackChromeExperimentHelper · isEnabled"
                };
                break;
            }
        }
        RYGLegacySetRows(self, rows.copy);
        [self.tableView reloadData];
    }
}

- (UITableViewCell *)ryg_exp5_tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self ryg_exp5_tableView:tableView cellForRowAtIndexPath:indexPath];
    NSDictionary *row = RYGLegacyRowAt(self, indexPath);
    NSString *kind = row[@"kind"];
    if (![kind isEqualToString:@"exp5StoryMaster"] &&
        ![kind isEqualToString:@"exp5StoryGate"] &&
        ![kind isEqualToString:@"exp5Throwback"]) return cell;

    UISwitch *toggle = [UISwitch new];
    toggle.onTintColor = [RYGUtils RYGColor_Primary];
    objc_setAssociatedObject(toggle, kRYGLegacyFeatureSwitchRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [toggle addTarget:self action:@selector(ryg_exp5_featureSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    if ([kind isEqualToString:@"exp5StoryMaster"]) {
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:kRYGLegacyStoryTrayBundlePref] || RYGLegacyStoryBundleIsFullyForcedOn();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:@"exp5Throwback"]) {
        id value = RYGRuntimeValueOverride(kRYGThrowbackClass, kRYGThrowbackSelector, NO);
        toggle.on = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : [NSUserDefaults.standardUserDefaults boolForKey:kRYGLegacyThrowbackPref];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        id value = RYGRuntimeValueOverride(row[@"class"], row[@"selector"], NO);
        toggle.on = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
        NSString *state = value ? ([value boolValue] ? @"Forced ON" : @"Forced OFF") : @"Native";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@ · tap row = Native", row[@"class"], row[@"selector"], state];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)ryg_exp5_featureSwitchChanged:(UISwitch *)sender {
    NSDictionary *row = objc_getAssociatedObject(sender, kRYGLegacyFeatureSwitchRowKey);
    NSString *kind = row[@"kind"];

    if ([kind isEqualToString:@"exp5StoryMaster"]) {
        [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:kRYGLegacyStoryTrayBundlePref];
        NSUInteger installed = RYGLegacyApplyStoryBundle(sender.isOn);
        [self.tableView reloadData];
        [RYGUtils showToastForDuration:1.4
                                 title:sender.isOn ? @"Story Tray preset enabled" : @"Story Tray preset restored"
                              subtitle:sender.isOn
            ? [NSString stringWithFormat:@"7 overrides persisted · %lu hooked now", (unsigned long)installed]
            : @"The 7 experimental5 overrides now use native values"];
        return;
    }

    if ([kind isEqualToString:@"exp5Throwback"]) {
        [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:kRYGLegacyThrowbackPref];
        BOOL hooked = RYGLegacyInstallBool(kRYGThrowbackClass, kRYGThrowbackSelector, sender.isOn ? @YES : nil);
        [self.tableView reloadData];
        if (sender.isOn && !hooked) {
            [RYGUtils showToastForDuration:1.4 title:@"Throwback persisted" subtitle:@"Getter not loaded yet; hook remains pending and will retry"];
        }
        return;
    }

    if ([kind isEqualToString:@"exp5StoryGate"]) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:kRYGLegacyStoryTrayBundlePref];
        BOOL hooked = RYGLegacyInstallBool(row[@"class"], row[@"selector"], @(sender.isOn));
        [self.tableView reloadData];
        if (!hooked) {
            [RYGUtils showToastForDuration:1.2 title:@"Override persisted" subtitle:@"Getter not loaded yet; Apply/reload will retry"];
        }
    }
}

- (void)ryg_exp5_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = RYGLegacyRowAt(self, indexPath);
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"exp5StoryGate"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:kRYGLegacyStoryTrayBundlePref];
        RYGLegacyInstallBool(row[@"class"], row[@"selector"], nil);
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if ([kind isEqualToString:@"exp5Throwback"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:kRYGLegacyThrowbackPref];
        RYGLegacyInstallBool(kRYGThrowbackClass, kRYGThrowbackSelector, nil);
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    [self ryg_exp5_tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end

__attribute__((constructor(218))) static void RYGExperimental5FeatureBootstrap(void) {
    @autoreleasepool {
        _dyld_register_func_for_add_image(RYGLegacyImageAdded);
        dispatch_async(dispatch_get_main_queue(), ^{
            RYGLegacyRestorePersistedFeatureState();
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                RYGLegacyRestorePersistedFeatureState();
            }];
        });
    }
}
