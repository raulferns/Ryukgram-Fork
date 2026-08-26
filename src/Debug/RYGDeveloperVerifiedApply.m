#import "RYGDeveloperTopicViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeHookManager.h"
#import "../UI/RYGLiquidGlass.h"
#import "../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

static NSString *const kRYGVerifiedStoryTrayPref = @"ryg_dev_story_tray_override";
static NSString *const kRYGVerifiedGlassSwizzlePref = @"ryg_dev_glass_swizzle_enabled";
static NSString *const kRYGVerifiedGlassThrowbackPref = @"ryg_dev_glass_throwback_enabled";
static NSString *const kRYGVerifiedGlassNavigationPref = @"ryg_dev_glass_navigation_enabled";

static const char *RYGVerifiedSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGVerifiedMethodReturns(Method method, char expected) {
    if (!method) return NO;
    char encoded[64] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGVerifiedSkipQualifiers(encoded);
    if (!type || !*type) return NO;
    if (expected == '@') return *type == '@';
    if (expected == 'v') return *type == 'v';
    if (expected == 'B') return strchr("BcC", *type) != NULL;
    return NO;
}

static BOOL RYGVerifiedObjectArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char encoded[64] = {0};
    method_getArgumentType(method, index, encoded, sizeof(encoded));
    const char *type = RYGVerifiedSkipQualifiers(encoded);
    return type && *type == '@';
}

static BOOL RYGVerifiedBoolArgument(Method method, unsigned int index) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char encoded[64] = {0};
    method_getArgumentType(method, index, encoded, sizeof(encoded));
    const char *type = RYGVerifiedSkipQualifiers(encoded);
    return type && strchr("BcC", *type) != NULL;
}

static Method RYGVerifiedDirectMethod(Class owner, SEL selector) {
    if (!owner || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    Method found = NULL;
    for (unsigned int index = 0; methods && index < count; index++) {
        if (method_getName(methods[index]) == selector) { found = methods[index]; break; }
    }
    if (methods) free(methods);
    return found;
}

static RYGRuntimeBoolMethod *RYGVerifiedStoryTrayGate(void) {
    NSString *className = @"_TtC27IGPersistentStoryTrayGating38IGPersistentStoryTrayGatingStaticFuncs";
    NSString *selectorName = @"isTrayAttachedToHeaderEnabled:";
    Class cls = objc_lookUpClass(className.UTF8String);
    Class owner = cls ? object_getClass(cls) : Nil;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = RYGVerifiedDirectMethod(owner, selector);
    if (!method || !RYGVerifiedMethodReturns(method, 'B') || method_getNumberOfArguments(method) != 3 || !RYGVerifiedObjectArgument(method, 2)) return nil;

    RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
    row.className = className;
    row.selectorName = selectorName;
    row.classMethod = YES;
    row.argumentKind = RYGRuntimeArgumentObject;
    const char *types = method_getTypeEncoding(method);
    row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
    const char *image = class_getImageName(cls);
    row.imagePath = image ? [NSString stringWithUTF8String:image] : @"";
    return row;
}

static id RYGVerifiedSharedHelper(NSString *className) {
    Class cls = className.length ? objc_lookUpClass(className.UTF8String) : Nil;
    if (!cls) return nil;
    for (NSString *name in @[@"shared", @"sharedInstance", @"getInstance", @"sharedHelper"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getClassMethod(cls, selector);
        if (!method || method_getNumberOfArguments(method) != 2 || !RYGVerifiedMethodReturns(method, '@')) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)((id)cls, selector);
        if (value) return value;
    }
    return nil;
}

static BOOL RYGVerifiedSetHelper(NSString *className, NSString *selectorName, BOOL enabled, NSNumber **readback) {
    id helper = RYGVerifiedSharedHelper(className);
    if (!helper) return NO;
    SEL setter = NSSelectorFromString(selectorName);
    Method setterMethod = class_getInstanceMethod([helper class], setter);
    if (!setterMethod || method_getNumberOfArguments(setterMethod) != 3 || !RYGVerifiedMethodReturns(setterMethod, 'v') || !RYGVerifiedBoolArgument(setterMethod, 2)) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(helper, setter, enabled);

    SEL getter = NSSelectorFromString(@"isEnabled");
    Method getterMethod = class_getInstanceMethod([helper class], getter);
    if (getterMethod && method_getNumberOfArguments(getterMethod) == 2 && RYGVerifiedMethodReturns(getterMethod, 'B')) {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(helper, getter);
        if (readback) *readback = @(value);
    }
    return YES;
}

static BOOL RYGVerifiedOpenStoryTrayDebug(UIViewController *presenter) {
    RYGRuntimeBoolMethod *gate = RYGVerifiedStoryTrayGate();
    if (!gate || !presenter) return NO;
    NSNumber *current = [RYGRuntimeHookManager overrideForKey:gate.overrideKey];
    if (!current) current = [RYGRuntimeHookManager observedNativeValueForKey:gate.overrideKey];
    if (!current) {
        (void)[RYGRuntimeHookManager observeMethod:gate];
        [RYGUtils showErrorHUDWithDescription:@"Story Tray native value has not been observed yet. Let Instagram evaluate the tray once, then reopen this menu."];
        return YES;
    }

    Class cls = objc_lookUpClass("_TtC25IGOverlayStoriesTrayDebug39IGOverlayStoriesTrayDebugViewController");
    SEL selector = NSSelectorFromString(@"presentFrom:currentlyEnabled:onApplyAndRestart:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 5 || !RYGVerifiedMethodReturns(method, 'v') ||
        !RYGVerifiedObjectArgument(method, 2) || !RYGVerifiedBoolArgument(method, 3) || !RYGVerifiedObjectArgument(method, 4)) return NO;

    void (^completion)(BOOL) = ^(BOOL enabled) {
        RYGRuntimeBoolMethod *resolved = RYGVerifiedStoryTrayGate();
        BOOL success = resolved && [RYGRuntimeHookManager setOverride:@(enabled) forMethod:resolved];
        NSNumber *readback = resolved ? [RYGRuntimeHookManager overrideForKey:resolved.overrideKey] : nil;
        if (!success || !readback || readback.boolValue != enabled) {
            [RYGUtils showErrorHUDWithDescription:@"Story Tray override hook was not installed; no success state was recorded."];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:@(enabled) forKey:kRYGVerifiedStoryTrayPref];
        [RYGUtils showToastForDuration:1.3 title:@"Story Tray override applied" subtitle:enabled ? @"Forced On" : @"Forced Off"];
    };
    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)((id)cls, selector, presenter, current.boolValue, completion);
    return YES;
}

@interface RYGDeveloperTopicViewController (RYGDeveloperVerifiedApply)
- (UIButton *)ryg_verified_runtimeButtonForMethod:(RYGRuntimeBoolMethod *)method;
- (void)ryg_verified_switchChanged:(UISwitch *)toggle;
- (void)ryg_verified_rebuildRows;
- (void)ryg_verified_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation RYGDeveloperTopicViewController (RYGDeveloperVerifiedApply)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct { SEL original; SEL replacement; } swaps[] = {
            {NSSelectorFromString(@"runtimeButtonForMethod:"), @selector(ryg_verified_runtimeButtonForMethod:)},
            {NSSelectorFromString(@"switchChanged:"), @selector(ryg_verified_switchChanged:)},
            {NSSelectorFromString(@"rebuildRows"), @selector(ryg_verified_rebuildRows)},
            {@selector(tableView:didSelectRowAtIndexPath:), @selector(ryg_verified_tableView:didSelectRowAtIndexPath:)},
        };
        for (NSUInteger index = 0; index < sizeof(swaps)/sizeof(swaps[0]); index++) {
            Method original = class_getInstanceMethod(self, swaps[index].original);
            Method replacement = class_getInstanceMethod(self, swaps[index].replacement);
            if (original && replacement) method_exchangeImplementations(original, replacement);
        }
    });
}

- (UIButton *)ryg_verified_runtimeButtonForMethod:(RYGRuntimeBoolMethod *)method {
    NSNumber *forced = [RYGRuntimeHookManager overrideForKey:method.overrideKey];
    NSNumber *native = [RYGRuntimeHookManager observedNativeValueForKey:method.overrideKey];
    NSString *title = forced ? (forced.boolValue ? @"Forced On" : @"Forced Off") : (native ? (native.boolValue ? @"Native On" : @"Native Off") : @"Native");
    __weak typeof(self) weakSelf = self;

    void (^apply)(NSNumber *) = ^(NSNumber *value) {
        BOOL success = [RYGRuntimeHookManager setOverride:value forMethod:method];
        NSNumber *readback = [RYGRuntimeHookManager overrideForKey:method.overrideKey];
        BOOL verified = value ? (readback && readback.boolValue == value.boolValue) : (readback == nil);
        if (!success || !verified) {
            [RYGUtils showErrorHUDWithDescription:[NSString stringWithFormat:@"Could not install %@ %@. ABI/owner validation failed; nothing was reported as applied.", method.classMethod ? @"+" : @"-", method.selectorName ?: @"BOOL"]];
        } else {
            [RYGUtils showToastForDuration:0.9 title:@"Runtime override verified" subtitle:value ? (value.boolValue ? @"Forced On" : @"Forced Off") : @"Native"];
        }
        [weakSelf.tableView reloadData];
    };

    UIAction *observe = [UIAction actionWithTitle:@"Observe native" image:nil identifier:nil handler:^(__unused UIAction *action) {
        if (![RYGRuntimeHookManager observeMethod:method]) [RYGUtils showErrorHUDWithDescription:@"Could not arm native observation for this ABI."];
        [weakSelf.tableView reloadData];
    }];
    UIAction *nativeAction = [UIAction actionWithTitle:@"Use Native" image:nil identifier:nil handler:^(__unused UIAction *action) { apply(nil); }];
    UIAction *on = [UIAction actionWithTitle:@"Force On" image:nil identifier:nil handler:^(__unused UIAction *action) { apply(@YES); }];
    UIAction *off = [UIAction actionWithTitle:@"Force Off" image:nil identifier:nil handler:^(__unused UIAction *action) { apply(@NO); }];
    nativeAction.state = forced ? UIMenuElementStateOff : UIMenuElementStateOn;
    on.state = forced && forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;
    off.state = forced && !forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIMenu *output = [UIMenu menuWithTitle:@"Output" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:@[nativeAction, on, off]];
    button.menu = [UIMenu menuWithTitle:method.selectorName ?: @"BOOL" image:nil identifier:nil options:0 children:@[observe, output]];
    button.showsMenuAsPrimaryAction = YES;
    RYGLiquidGlassConfigureButton(button, NO);
    UIButtonConfiguration *configuration = button.configuration;
    if (configuration) { configuration.title = title; configuration.baseForegroundColor = UIColor.labelColor; button.configuration = configuration; }
    else [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (void)ryg_verified_switchChanged:(UISwitch *)toggle {
    CGPoint point = [toggle convertPoint:CGPointMake(CGRectGetMidX(toggle.bounds), CGRectGetMidY(toggle.bounds)) toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    NSArray *rows = [self valueForKey:@"rows"] ?: @[];
    NSDictionary *row = (indexPath && indexPath.row < (NSInteger)rows.count) ? rows[(NSUInteger)indexPath.row] : nil;
    if (![[row objectForKey:@"kind"] isEqualToString:@"glass"]) {
        [self ryg_verified_switchChanged:toggle];
        return;
    }

    NSString *glass = row[@"glass"];
    NSString *className = nil;
    NSString *selectorName = nil;
    NSString *preference = nil;
    if ([glass isEqualToString:@"swizzle"]) {
        className = @"_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle";
        selectorName = @"setIsEnabled:";
        preference = kRYGVerifiedGlassSwizzlePref;
    } else if ([glass isEqualToString:@"throwback"]) {
        className = @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper";
        selectorName = @"overrideIsEnabled:";
        preference = kRYGVerifiedGlassThrowbackPref;
    } else {
        className = @"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper";
        selectorName = @"overrideIsEnabled:";
        preference = kRYGVerifiedGlassNavigationPref;
    }

    NSNumber *readback = nil;
    if (!RYGVerifiedSetHelper(className, selectorName, toggle.isOn, &readback)) {
        toggle.on = !toggle.isOn;
        [RYGUtils showErrorHUDWithDescription:[NSString stringWithFormat:@"%@ singleton/setter ABI is not available in this loaded build.", className ?: @"Liquid Glass helper"]];
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:preference];
    NSString *state = readback ? (readback.boolValue ? @"read back On" : @"read back Off") : @"setter invoked; no isEnabled getter exported";
    [RYGUtils showToastForDuration:1.0 title:@"Liquid Glass native setter applied" subtitle:state];
}

- (void)ryg_verified_rebuildRows {
    [self ryg_verified_rebuildRows];
    NSNumber *surface = [self valueForKey:@"surface"];
    if (surface.integerValue != RYGDeveloperRuntimeSurfaceStories) return;
    NSArray *current = [self valueForKey:@"rows"] ?: @[];
    for (NSDictionary *row in current) if ([row[@"action"] isEqualToString:@"rygStoryTrayDebug"]) return;
    NSMutableArray *rows = current.mutableCopy;
    [rows insertObject:@{@"kind":@"action", @"action":@"rygStoryTrayDebug", @"title":@"Open native Story Tray Debug", @"subtitle":@"Apply callback is verified through the exact Story Tray BOOL hook"} atIndex:0];
    [self setValue:rows.copy forKey:@"rows"];
    [self.tableView reloadData];
}

- (void)ryg_verified_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = [self valueForKey:@"rows"] ?: @[];
    NSDictionary *row = (indexPath && indexPath.row < (NSInteger)rows.count) ? rows[(NSUInteger)indexPath.row] : nil;
    if ([row[@"action"] isEqualToString:@"rygStoryTrayDebug"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (!RYGVerifiedOpenStoryTrayDebug(self)) [RYGUtils showErrorHUDWithDescription:@"The native Story Tray debug presenter ABI is not available in this Instagram build."];
        return;
    }
    [self ryg_verified_tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end

static void RYGVerifiedRestoreStoryPreference(void) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:kRYGVerifiedStoryTrayPref];
    if (![raw isKindOfClass:NSNumber.class]) return;
    RYGRuntimeBoolMethod *gate = RYGVerifiedStoryTrayGate();
    if (gate) (void)[RYGRuntimeHookManager setOverride:@([(NSNumber *)raw boolValue]) forMethod:gate];
}

__attribute__((constructor(235))) static void RYGInstallVerifiedDeveloperRestore(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                         object:nil
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RYGVerifiedRestoreStoryPreference(); });
        }];
    });
}
