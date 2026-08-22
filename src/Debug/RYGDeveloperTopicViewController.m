#import "RYGDeveloperTopicViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeLiveObserver.h"
#import "RYGEasyGatingRuntime.h"
#import "RYGFastRuntimeBrowserViewController.h"
#import "../Features/ExpFlags/RYGMobileConfig.h"
#import "../UI/RYGLiquidGlass.h"
#import "../UI/RYGPopupChrome.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <string.h>

static NSString *const kRYGInternalMenuPref = @"ryg_dev_internal_menu_enabled";
static NSString *const kRYGDogfoodModePref = @"ryg_dev_dogfood_mode_enabled";
static NSString *const kRYGDogfoodOwnedMCStatePref = @"ryg_dev_dogfood_owned_mc_state_v3";
static NSString *const kRYGPrismSetterModePref = @"ryg_dev_prism_setter_mode";
static NSString *const kRYGRedesignSetterModePref = @"ryg_dev_redesign_setter_mode";
static NSString *const kRYGGlassSwizzlePref = @"ryg_dev_glass_swizzle_enabled";
static NSString *const kRYGGlassThrowbackPref = @"ryg_dev_glass_throwback_enabled";
static NSString *const kRYGGlassNavigationPref = @"ryg_dev_glass_navigation_enabled";
static NSString *const kRYGEasyGatingOverridesKey = @"ryg_easy_gating_platform_bool_overrides_v2";
static const void *kRYGDeveloperControlKindKey = &kRYGDeveloperControlKindKey;

static IMP gRYGBugMenuOriginal;
static IMP gRYGBugMenuLegacyOriginal;
static IMP gRYGDogfoodSettingsInitOriginal;
static IMP gRYGDogfoodSettingsOpenOriginal;
static IMP gRYGDogfoodLauncherOriginal;
static IMP gRYGPrismSetterOriginal;
static IMP gRYGRedesignSetterOriginal;

static id gRYGDogfoodConfig;
static id gRYGDogfoodUserSession;
static id gRYGDogfoodLauncherClient;
static id gRYGDogfoodLauncherSession;
static NSString *gRYGDogfoodLauncherName;
static NSDictionary *gRYGDogfoodLauncherParameters;
static NSInteger gRYGPrismSetterMode = -1;
static NSInteger gRYGRedesignSetterMode = -1;

#pragma mark - ABI helpers

static const char *RYGDevSkipQualifiers(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGDevBoolType(const char *type) {
    type = RYGDevSkipQualifiers(type);
    return type && strchr("BcC", *type) != NULL;
}

static BOOL RYGDevMethodReturns(Method method, char expected) {
    if (!method) return NO;
    char encoded[96] = {0};
    method_getReturnType(method, encoded, sizeof(encoded));
    const char *type = RYGDevSkipQualifiers(encoded);
    if (!type || !*type) return NO;
    if (expected == '@') return *type == '@';
    if (expected == 'v') return *type == 'v';
    if (expected == 'B') return RYGDevBoolType(type);
    return NO;
}

static BOOL RYGDevArgumentMatches(Method method, unsigned int index, char expected) {
    if (!method || index >= method_getNumberOfArguments(method)) return NO;
    char encoded[96] = {0};
    method_getArgumentType(method, index, encoded, sizeof(encoded));
    const char *type = RYGDevSkipQualifiers(encoded);
    if (!type || !*type) return NO;
    if (expected == '@') return *type == '@';
    if (expected == 'B') return RYGDevBoolType(type);
    if (expected == 'Q') return *type == 'q' || *type == 'Q';
    return NO;
}

static Method RYGDevDirectMethod(Class owner, SEL selector) {
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

static RYGRuntimeArgumentKind RYGDevArgumentKind(Method method) {
    if (!method || !RYGDevMethodReturns(method, 'B')) return (RYGRuntimeArgumentKind)-1;
    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return RYGRuntimeArgumentNone;
    if (count != 3) return (RYGRuntimeArgumentKind)-1;
    char encoded[96] = {0};
    method_getArgumentType(method, 2, encoded, sizeof(encoded));
    const char *type = RYGDevSkipQualifiers(encoded);
    if (!type || !*type) return (RYGRuntimeArgumentKind)-1;
    if (*type == '@') return RYGRuntimeArgumentObject;
    if (*type == 'q' || *type == 'Q') return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static RYGRuntimeBoolMethod *RYGDevExactBoolMethod(NSString *className, NSString *selectorName, BOOL classMethod) {
    if (!className.length || !selectorName.length) return nil;
    Class cls = objc_lookUpClass(className.UTF8String);
    if (!cls) return nil;
    Class owner = classMethod ? object_getClass(cls) : cls;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = RYGDevDirectMethod(owner, selector);
    RYGRuntimeArgumentKind kind = RYGDevArgumentKind(method);
    if (!method || kind < RYGRuntimeArgumentNone || kind > RYGRuntimeArgumentInteger) return nil;
    RYGRuntimeBoolMethod *row = [RYGRuntimeBoolMethod new];
    row.className = className;
    row.selectorName = selectorName;
    row.classMethod = classMethod;
    row.argumentKind = kind;
    const char *types = method_getTypeEncoding(method);
    row.typeEncoding = types ? [NSString stringWithUTF8String:types] : @"";
    const char *image = class_getImageName(cls);
    row.imagePath = image ? [NSString stringWithUTF8String:image] : @"";
    return row;
}

#pragma mark - Exact native hooks

typedef id (*RYGBugMenuInitFn)(id, SEL, id, id, id, id, id, id, long long, long long, BOOL, BOOL, BOOL, BOOL, long long);
typedef id (*RYGBugMenuLegacyInitFn)(id, SEL, id, id, id, id, id, id, long long, long long, BOOL, BOOL, BOOL);

static BOOL RYGBugMenuFullSignatureMatches(Method method) {
    if (!method || method_getNumberOfArguments(method) != 15 || !RYGDevMethodReturns(method, '@')) return NO;
    for (unsigned int index = 2; index <= 7; index++) if (!RYGDevArgumentMatches(method, index, '@')) return NO;
    if (!RYGDevArgumentMatches(method, 8, 'Q') || !RYGDevArgumentMatches(method, 9, 'Q')) return NO;
    for (unsigned int index = 10; index <= 13; index++) if (!RYGDevArgumentMatches(method, index, 'B')) return NO;
    return RYGDevArgumentMatches(method, 14, 'Q');
}

static BOOL RYGBugMenuLegacySignatureMatches(Method method) {
    if (!method || method_getNumberOfArguments(method) != 13 || !RYGDevMethodReturns(method, '@')) return NO;
    for (unsigned int index = 2; index <= 7; index++) if (!RYGDevArgumentMatches(method, index, '@')) return NO;
    if (!RYGDevArgumentMatches(method, 8, 'Q') || !RYGDevArgumentMatches(method, 9, 'Q')) return NO;
    for (unsigned int index = 10; index <= 12; index++) if (!RYGDevArgumentMatches(method, index, 'B')) return NO;
    return YES;
}

static id RYGBugMenuInit(id self, SEL cmd, id deviceSession, id userSession, id reliabilityLogging,
                         id navChain, id endpoint, id entryPoint, long long style, long long availability,
                         BOOL showInternal, BOOL showLoggedOutInternal, BOOL showShake, BOOL showDogfood,
                         long long maisaVariant) {
    if (userSession) gRYGDogfoodUserSession = userSession;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults boolForKey:kRYGInternalMenuPref] || [defaults boolForKey:kRYGDogfoodModePref];
    RYGBugMenuInitFn original = (RYGBugMenuInitFn)gRYGBugMenuOriginal;
    return original ? original(self, cmd, deviceSession, userSession, reliabilityLogging, navChain, endpoint, entryPoint,
                               style, availability,
                               enabled ? YES : showInternal,
                               enabled ? YES : showLoggedOutInternal,
                               enabled ? YES : showShake,
                               enabled ? YES : showDogfood,
                               maisaVariant) : nil;
}

static id RYGBugMenuLegacyInit(id self, SEL cmd, id deviceSession, id userSession, id reliabilityLogging,
                               id navChain, id endpoint, id entryPoint, long long style, long long availability,
                               BOOL showInternal, BOOL showLoggedOutInternal, BOOL showShake) {
    if (userSession) gRYGDogfoodUserSession = userSession;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = [defaults boolForKey:kRYGInternalMenuPref] || [defaults boolForKey:kRYGDogfoodModePref];
    RYGBugMenuLegacyInitFn original = (RYGBugMenuLegacyInitFn)gRYGBugMenuLegacyOriginal;
    return original ? original(self, cmd, deviceSession, userSession, reliabilityLogging, navChain, endpoint, entryPoint,
                               style, availability,
                               enabled ? YES : showInternal,
                               enabled ? YES : showLoggedOutInternal,
                               enabled ? YES : showShake) : nil;
}

static void RYGInstallBugMenuHooks(void) {
    Class cls = objc_lookUpClass("_TtC17IGBugReporterMenu29IGBugReportMenuViewController");
    if (!cls) return;
    if (!gRYGBugMenuOriginal) {
        SEL selector = NSSelectorFromString(@"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:showDogfoodingAssistant:maisaUXVariantRawValue:");
        Method method = class_getInstanceMethod(cls, selector);
        if (RYGBugMenuFullSignatureMatches(method)) MSHookMessageEx(cls, selector, (IMP)RYGBugMenuInit, &gRYGBugMenuOriginal);
    }
    if (!gRYGBugMenuLegacyOriginal) {
        SEL selector = NSSelectorFromString(@"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:");
        Method method = class_getInstanceMethod(cls, selector);
        if (RYGBugMenuLegacySignatureMatches(method)) MSHookMessageEx(cls, selector, (IMP)RYGBugMenuLegacyInit, &gRYGBugMenuLegacyOriginal);
    }
}

typedef id (*RYGDogfoodSettingsInitFn)(id, SEL, id, id);
typedef void (*RYGDogfoodSettingsOpenFn)(id, SEL, id, id, id);
typedef BOOL (*RYGDogfoodLauncherFn)(id, SEL, id, id, id);

static id RYGDogfoodSettingsInit(id self, SEL cmd, id config, id userSession) {
    if (config) gRYGDogfoodConfig = config;
    if (userSession) gRYGDogfoodUserSession = userSession;
    RYGDogfoodSettingsInitFn original = (RYGDogfoodSettingsInitFn)gRYGDogfoodSettingsInitOriginal;
    return original ? original(self, cmd, config, userSession) : nil;
}

static void RYGDogfoodSettingsOpen(id self, SEL cmd, id config, id viewController, id userSession) {
    if (config) gRYGDogfoodConfig = config;
    if (userSession) gRYGDogfoodUserSession = userSession;
    RYGDogfoodSettingsOpenFn original = (RYGDogfoodSettingsOpenFn)gRYGDogfoodSettingsOpenOriginal;
    if (original) original(self, cmd, config, viewController, userSession);
}

static BOOL RYGDogfoodLauncherCapture(id self, SEL cmd, id userSession, id launcherName, id parameters) {
    if (self) gRYGDogfoodLauncherClient = self;
    if (userSession) gRYGDogfoodLauncherSession = userSession;
    if ([launcherName isKindOfClass:NSString.class]) gRYGDogfoodLauncherName = [launcherName copy];
    if ([parameters isKindOfClass:NSDictionary.class]) gRYGDogfoodLauncherParameters = [parameters copy];
    RYGDogfoodLauncherFn original = (RYGDogfoodLauncherFn)gRYGDogfoodLauncherOriginal;
    return original ? original(self, cmd, userSession, launcherName, parameters) : NO;
}

static void RYGInstallDogfoodCaptureHooks(void) {
    Class controller = objc_lookUpClass("_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController");
    if (!gRYGDogfoodSettingsInitOriginal && controller) {
        SEL selector = NSSelectorFromString(@"initWithConfig:userSession:");
        Method method = class_getInstanceMethod(controller, selector);
        if (method && method_getNumberOfArguments(method) == 4 && RYGDevMethodReturns(method, '@') &&
            RYGDevArgumentMatches(method, 2, '@') && RYGDevArgumentMatches(method, 3, '@'))
            MSHookMessageEx(controller, selector, (IMP)RYGDogfoodSettingsInit, &gRYGDogfoodSettingsInitOriginal);
    }

    Class opener = objc_lookUpClass("_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    Class meta = opener ? object_getClass(opener) : Nil;
    if (!gRYGDogfoodSettingsOpenOriginal && meta) {
        SEL selector = NSSelectorFromString(@"openWithConfig:onViewController:userSession:");
        Method method = RYGDevDirectMethod(meta, selector);
        if (method && method_getNumberOfArguments(method) == 5 && RYGDevMethodReturns(method, 'v') &&
            RYGDevArgumentMatches(method, 2, '@') && RYGDevArgumentMatches(method, 3, '@') && RYGDevArgumentMatches(method, 4, '@'))
            MSHookMessageEx(meta, selector, (IMP)RYGDogfoodSettingsOpen, &gRYGDogfoodSettingsOpenOriginal);
    }

    Class launcher = objc_lookUpClass("_TtC35IGDogfoodingAssistantLauncherClient35IGDogfoodingAssistantLauncherClient");
    if (!gRYGDogfoodLauncherOriginal && launcher) {
        SEL selector = NSSelectorFromString(@"overrideLauncherWithUserSession:launcherName:parametersToValues:");
        Method method = RYGDevDirectMethod(launcher, selector);
        if (method && method_getNumberOfArguments(method) == 5 && RYGDevMethodReturns(method, 'B') &&
            RYGDevArgumentMatches(method, 2, '@') && RYGDevArgumentMatches(method, 3, '@') && RYGDevArgumentMatches(method, 4, '@'))
            MSHookMessageEx(launcher, selector, (IMP)RYGDogfoodLauncherCapture, &gRYGDogfoodLauncherOriginal);
    }
}

typedef void (*RYGBoolSetterFn)(id, SEL, BOOL);

static void RYGPrismSetter(id self, SEL cmd, BOOL enabled) {
    RYGBoolSetterFn original = (RYGBoolSetterFn)gRYGPrismSetterOriginal;
    if (original) original(self, cmd, gRYGPrismSetterMode < 0 ? enabled : (gRYGPrismSetterMode != 0));
}

static void RYGRedesignSetter(id self, SEL cmd, BOOL enabled) {
    RYGBoolSetterFn original = (RYGBoolSetterFn)gRYGRedesignSetterOriginal;
    if (original) original(self, cmd, gRYGRedesignSetterMode < 0 ? enabled : (gRYGRedesignSetterMode != 0));
}

static BOOL RYGInstallBoolSetterHook(NSString *className, NSString *selectorName, IMP replacement, IMP *original) {
    if (*original) return YES;
    Class cls = objc_lookUpClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls ? RYGDevDirectMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !RYGDevMethodReturns(method, 'v') || !RYGDevArgumentMatches(method, 2, 'B')) return NO;
    MSHookMessageEx(cls, selector, replacement, original);
    return *original != NULL;
}

#pragma mark - Native helper persistence

static id RYGSharedHelper(NSString *className) {
    Class cls = objc_lookUpClass(className.UTF8String);
    SEL selector = NSSelectorFromString(@"shared");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    return method && method_getNumberOfArguments(method) == 2 && RYGDevMethodReturns(method, '@')
        ? ((id (*)(id, SEL))objc_msgSend)((id)cls, selector) : nil;
}

static NSNumber *RYGNativeHelperEnabled(NSString *className) {
    id helper = RYGSharedHelper(className);
    SEL selector = NSSelectorFromString(@"isEnabled");
    Method method = helper ? RYGDevDirectMethod([helper class], selector) : NULL;
    return method && method_getNumberOfArguments(method) == 2 && RYGDevMethodReturns(method, 'B')
        ? @(((BOOL (*)(id, SEL))objc_msgSend)(helper, selector)) : nil;
}

static BOOL RYGSetNativeHelperBool(NSString *className, NSString *selectorName, BOOL enabled) {
    id helper = RYGSharedHelper(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = helper ? RYGDevDirectMethod([helper class], selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 3 || !RYGDevMethodReturns(method, 'v') || !RYGDevArgumentMatches(method, 2, 'B')) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(helper, selector, enabled);
    return YES;
}

static void RYGRestoreHelperPreference(NSString *preference, NSString *className, NSString *selectorName) {
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:preference];
    if (![raw isKindOfClass:NSNumber.class]) return;
    (void)RYGSetNativeHelperBool(className, selectorName, [(NSNumber *)raw boolValue]);
}

#pragma mark - Explicit dogfood MobileConfig action

static NSString *RYGDogfoodMCIdentity(unsigned int configNumber, unsigned int paramIndex) {
    return [NSString stringWithFormat:@"%u:%u", configNumber, paramIndex];
}

static NSDictionary *RYGDogfoodOwnedMCState(void) {
    id value = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRYGDogfoodOwnedMCStatePref];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static BOOL RYGDogfoodCandidateName(NSString *name) {
    NSString *value = name.lowercaseString ?: @"";
    return [value containsString:@"dogfood"] || [value containsString:@"employee"] || [value containsString:@"internal"];
}

static BOOL RYGIsDogfoodCoreCandidate(RYGMCParam *param, NSString *configName) {
    NSString *paramName = param.name.lowercaseString ?: @"";
    NSString *config = configName.lowercaseString ?: @"";
    if ([config containsString:@"ig_is_employee"] &&
        ([paramName isEqualToString:@"is_employee"] || [paramName isEqualToString:@"is_employee_or_employee_test_account"])) return YES;
    if ([config containsString:@"dogfooding_assistant"] && [paramName containsString:@"show_in_bug_report_menu"]) return YES;
    return [config containsString:@"dogfooding_first_client"] && [paramName isEqualToString:@"is_enabled"];
}

static NSUInteger RYGApplyDogfoodCoreMobileConfig(BOOL enabled, NSUInteger *availableCount) {
    // Deliberately called only from an explicit user action. Nothing in startup
    // or Developer viewDidLoad resolves the MobileConfig catalogue.
    RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
    [mobileConfig prepare];
    NSMutableDictionary *owned = [RYGDogfoodOwnedMCState() mutableCopy];
    NSUInteger available = 0;
    NSUInteger changed = 0;

    for (RYGMCConfig *config in mobileConfig.allConfigs) {
        BOOL configNameMatches = RYGDogfoodCandidateName(config.name);
        for (RYGMCParam *param in config.params) {
            if (!param.isRuntimeBacked || param.type != RYGMCTypeBool || !param.name.length) continue;
            if (!configNameMatches && !RYGDogfoodCandidateName(param.name)) continue;
            if (!RYGIsDogfoodCoreCandidate(param, config.name)) continue;
            available++;
            NSString *identity = RYGDogfoodMCIdentity(param.configNumber, param.paramIndex);

            if (enabled) {
                NSDictionary *ownership = [owned[identity] isKindOfClass:NSDictionary.class] ? owned[identity] : nil;
                if (!ownership) {
                    NSMutableDictionary *record = [NSMutableDictionary dictionary];
                    BOOL hadOverride = [mobileConfig overrideStateFor:param] == RYGMCOverrideSet;
                    record[@"hadOverride"] = @(hadOverride);
                    id previous = [mobileConfig overrideValueFor:param];
                    if (hadOverride && previous) record[@"previousValue"] = previous;
                    record[@"label"] = param.name ?: identity;
                    ownership = record.copy;
                }
                if ([mobileConfig setOverride:@YES for:param]) {
                    owned[identity] = ownership;
                    changed++;
                }
            } else {
                NSDictionary *ownership = [owned[identity] isKindOfClass:NSDictionary.class] ? owned[identity] : nil;
                if (!ownership) continue;
                BOOL hadOverride = [ownership[@"hadOverride"] boolValue];
                id previous = ownership[@"previousValue"];
                if (hadOverride && previous) {
                    if ([mobileConfig setOverride:previous for:param]) {
                        [owned removeObjectForKey:identity];
                        changed++;
                    }
                } else {
                    [mobileConfig clearOverrideFor:param];
                    [owned removeObjectForKey:identity];
                    changed++;
                }
            }
        }
    }

    if (owned.count) [NSUserDefaults.standardUserDefaults setObject:owned.copy forKey:kRYGDogfoodOwnedMCStatePref];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kRYGDogfoodOwnedMCStatePref];
    if (availableCount) *availableCount = available;
    return changed;
}

#pragma mark - Presenters

static UIViewController *RYGTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) { keyWindow = window; break; }
        if (keyWindow) break;
    }
    UIViewController *top = keyWindow.rootViewController;
    BOOL changed = YES;
    while (changed && top) {
        changed = NO;
        if (top.presentedViewController && !top.presentedViewController.isBeingDismissed) { top = top.presentedViewController; changed = YES; continue; }
        if ([top isKindOfClass:UINavigationController.class] && ((UINavigationController *)top).visibleViewController) { top = ((UINavigationController *)top).visibleViewController; changed = YES; continue; }
        if ([top isKindOfClass:UITabBarController.class] && ((UITabBarController *)top).selectedViewController) { top = ((UITabBarController *)top).selectedViewController; changed = YES; }
    }
    return top;
}

static BOOL RYGOpenDogfoodSettings(void) {
    RYGInstallDogfoodCaptureHooks();
    if (!gRYGDogfoodConfig || !gRYGDogfoodUserSession) return NO;
    Class cls = objc_lookUpClass("_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    SEL selector = NSSelectorFromString(@"openWithConfig:onViewController:userSession:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    UIViewController *top = RYGTopViewController();
    if (!top || !method || method_getNumberOfArguments(method) != 5 || !RYGDevMethodReturns(method, 'v') ||
        !RYGDevArgumentMatches(method, 2, '@') || !RYGDevArgumentMatches(method, 3, '@') || !RYGDevArgumentMatches(method, 4, '@')) return NO;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)((id)cls, selector, gRYGDogfoodConfig, top, gRYGDogfoodUserSession);
    return YES;
}

static BOOL RYGOpenDirectNotesDogfood(void) {
    UIViewController *top = RYGTopViewController();
    if (!top || !gRYGDogfoodUserSession) return NO;
    Class cls = objc_lookUpClass("_TtC31IGDirectNotesDogfoodingSettings42IGDirectNotesDogfoodingSettingsStaticFuncs");
    SEL selector = NSSelectorFromString(@"notesDogfoodingSettingsOpenOnViewController:userSession:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4 || !RYGDevMethodReturns(method, 'v') ||
        !RYGDevArgumentMatches(method, 2, '@') || !RYGDevArgumentMatches(method, 3, '@')) return NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)((id)cls, selector, top, gRYGDogfoodUserSession);
    return YES;
}

static BOOL RYGOpenDogfoodSessionBrowser(void) {
    UIViewController *top = RYGTopViewController();
    id session = gRYGDogfoodLauncherSession ?: gRYGDogfoodUserSession;
    if (!top || !gRYGDogfoodLauncherClient || !session) return NO;
    SEL selector = NSSelectorFromString(@"sessionBrowserViewController:userSession:");
    Method method = RYGDevDirectMethod([gRYGDogfoodLauncherClient class], selector);
    if (!method || method_getNumberOfArguments(method) != 4 || !RYGDevMethodReturns(method, '@') ||
        !RYGDevArgumentMatches(method, 2, '@') || !RYGDevArgumentMatches(method, 3, '@')) return NO;
    UIViewController *browser = ((id (*)(id, SEL, id, id))objc_msgSend)(gRYGDogfoodLauncherClient, selector, top, session);
    if (![browser isKindOfClass:UIViewController.class]) return NO;
    if (top.navigationController) [top.navigationController pushViewController:browser animated:YES];
    else [top presentViewController:[[UINavigationController alloc] initWithRootViewController:browser] animated:YES completion:nil];
    return YES;
}

#pragma mark - Controller

@interface RYGDeveloperTopicViewController ()
@property (nonatomic, assign) RYGDeveloperRuntimeSurface surface;
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
@end

@implementation RYGDeveloperTopicViewController

+ (void)activatePersistedNativeFeatures {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *prism = [defaults objectForKey:kRYGPrismSetterModePref];
    NSNumber *redesign = [defaults objectForKey:kRYGRedesignSetterModePref];
    if ([prism isKindOfClass:NSNumber.class]) {
        gRYGPrismSetterMode = prism.integerValue;
        (void)RYGInstallBoolSetterHook(@"IGBloksFollowButtonView", @"setPrismEnabled:", (IMP)RYGPrismSetter, &gRYGPrismSetterOriginal);
    }
    if ([redesign isKindOfClass:NSNumber.class]) {
        gRYGRedesignSetterMode = redesign.integerValue;
        (void)RYGInstallBoolSetterHook(@"IGTableViewCell", @"setListRedesignOn:", (IMP)RYGRedesignSetter, &gRYGRedesignSetterOriginal);
    }

    RYGRestoreHelperPreference(kRYGGlassSwizzlePref, @"_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle", @"setIsEnabled:");
    RYGRestoreHelperPreference(kRYGGlassThrowbackPref, @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper", @"overrideIsEnabled:");
    RYGRestoreHelperPreference(kRYGGlassNavigationPref, @"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper", @"overrideIsEnabled:");

    BOOL internal = [defaults boolForKey:kRYGInternalMenuPref];
    BOOL dogfood = [defaults boolForKey:kRYGDogfoodModePref];
    if (internal || dogfood) RYGInstallBugMenuHooks();
    if (dogfood) RYGInstallDogfoodCaptureHooks();
    NSDictionary *easy = [defaults dictionaryForKey:kRYGEasyGatingOverridesKey];
    if (dogfood || easy.count) [RYGEasyGatingRuntime.shared installIfNeeded];
    // No MobileConfig prepare/reload/reapply occurs here.
}

- (instancetype)initWithSurface:(RYGDeveloperRuntimeSurface)surface {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _surface = surface;
        _rows = @[];
    }
    return self;
}

- (NSString *)surfaceTitle {
    switch (self.surface) {
        case RYGDeveloperRuntimeSurfacePrism: return @"Prism UI";
        case RYGDeveloperRuntimeSurfaceLiquidGlass: return @"Liquid Glass Throwback";
        case RYGDeveloperRuntimeSurfaceStories: return @"Story Tray / Story Grid";
        case RYGDeveloperRuntimeSurfaceConsumerSubs: return @"Subscriptions Runtime";
        case RYGDeveloperRuntimeSurfaceInternalOnly: return @"IG-only / Internal-only";
        case RYGDeveloperRuntimeSurfaceDirectDogfood: return @"Direct / Dogfooding";
        case RYGDeveloperRuntimeSurfaceBugReport: return @"Bug Report Menu";
        case RYGDeveloperRuntimeSurfaceSettingsRows: return @"Hidden Settings Rows";
    }
    return @"Developer";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self surfaceTitle];
    self.navigationItem.titleView = RYGLiquidGlassNavigationTitleView(self.title);
    self.view.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.backgroundColor = [RYGPopupChrome backgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;
    [RYGDeveloperTopicViewController activatePersistedNativeFeatures];
    [self rebuildRows];
    RYGLiquidGlassApplyToViewController(self);
}

- (void)rebuildRows {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    switch (self.surface) {
        case RYGDeveloperRuntimeSurfacePrism:
            [rows addObject:@{@"kind":@"mode", @"mode":@"prism", @"title":@"Prism follow-button rendering", @"subtitle":@"IGBloksFollowButtonView · setPrismEnabled:"}];
            [rows addObject:@{@"kind":@"mode", @"mode":@"redesign", @"title":@"Prism list redesign", @"subtitle":@"IGTableViewCell · setListRedesignOn:"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"All Prism / IGDS / BSLDS gates", @"query":@"prism|igds|bslds"}];
            break;
        case RYGDeveloperRuntimeSurfaceLiquidGlass:
            [rows addObject:@{@"kind":@"glass", @"glass":@"swizzle", @"title":@"Liquid Glass Swizzle", @"subtitle":@"IGLiquidGlassSwizzleToggle · setIsEnabled:"}];
            [rows addObject:@{@"kind":@"glass", @"glass":@"throwback", @"title":@"Throwback Chrome", @"subtitle":@"IGThrowbackChromeExperimentHelper · overrideIsEnabled:"}];
            [rows addObject:@{@"kind":@"glass", @"glass":@"navigation", @"title":@"Liquid Glass Navigation", @"subtitle":@"IGLiquidGlassNavigationExperimentHelper · overrideIsEnabled:"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"All Liquid Glass / Throwback gates", @"query":@"liquidglass|throwback|glass"}];
            break;
        case RYGDeveloperRuntimeSurfaceStories: {
            NSArray *methods = @[
                RYGDevExactBoolMethod(@"_TtC27IGPersistentStoryTrayGating38IGPersistentStoryTrayGatingStaticFuncs", @"isTrayAttachedToHeaderEnabled:", YES) ?: NSNull.null,
                RYGDevExactBoolMethod(@"_TtC18IGNavConfiguration25IGHomecomingConfiguration", @"isDynamicTabStoryGridEnabled", NO) ?: NSNull.null,
                RYGDevExactBoolMethod(@"_TtC38IGStoryViewerRedesignExperimentHelpers38IGStoryViewerRedesignExperimentHelpers", @"isStoryViewerCardAnimationEnabledWithLauncherSet:", YES) ?: NSNull.null,
            ];
            for (id candidate in methods) if ([candidate isKindOfClass:RYGRuntimeBoolMethod.class]) {
                RYGRuntimeBoolMethod *method = candidate;
                [rows addObject:@{@"kind":@"runtime", @"title":method.selectorName ?: @"Story gate", @"subtitle":method.className ?: @"", @"method":method}];
            }
            [rows addObject:@{@"kind":@"browser", @"title":@"All Story Tray / Story Grid gates", @"query":@"storytray|storiestray|storygrid|storiesgrid"}];
            break;
        }
        case RYGDeveloperRuntimeSurfaceInternalOnly:
            [rows addObject:@{@"kind":@"internal", @"title":@"Expose Internal Settings", @"subtitle":@"Exact IGBugReportMenu initializer visibility arguments"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"IG-only / Internal-only Runtime", @"query":@"igonly|ig-only|internalonly|internal-only|employee|internal"}];
            break;
        case RYGDeveloperRuntimeSurfaceDirectDogfood:
            [rows addObject:@{@"kind":@"dogfood", @"title":@"Global Dogfooding Mode", @"subtitle":@"Exact native hooks + EasyGating; MobileConfig is applied only on this explicit action"}];
            [rows addObject:@{@"kind":@"action", @"action":@"dogfoodOpen", @"title":@"Open Dogfooding Settings"}];
            [rows addObject:@{@"kind":@"action", @"action":@"directNotes", @"title":@"Open Direct Notes Dogfooding"}];
            [rows addObject:@{@"kind":@"action", @"action":@"sessions", @"title":@"Dogfooding Assistant Sessions"}];
            [rows addObject:@{@"kind":@"action", @"action":@"mcApply", @"title":@"Apply resolved dogfood MobileConfig now", @"subtitle":@"On-demand; no startup catalogue scan"}];
            [rows addObject:@{@"kind":@"action", @"action":@"mcRestore", @"title":@"Restore RyukGram-owned dogfood MobileConfig"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"Dogfood / Employee / Internal Runtime", @"query":@"dogfood|employee|internal"}];
            break;
        case RYGDeveloperRuntimeSurfaceBugReport:
            [rows addObject:@{@"kind":@"internal", @"title":@"Expose every Bug Report row", @"subtitle":@"Internal + logged-out + shake + Dogfooding Assistant"}];
            [rows addObject:@{@"kind":@"action", @"action":@"sessions", @"title":@"Dogfooding Assistant Sessions"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"Bug Report hidden gates", @"query":@"bug|report|dogfood|internal"}];
            [rows addObject:@{@"kind":@"browser", @"title":@"Sandbox runtime", @"query":@"sandbox|foa"}];
            break;
        case RYGDeveloperRuntimeSurfaceSettingsRows:
            [rows addObject:@{@"kind":@"internal", @"title":@"Enable internal settings visibility"}];
            [rows addObject:@{@"kind":@"visibilityBrowser", @"title":@"All hidden Settings rows", @"query":@"ishidden|shouldhide|shouldshow|canshow|isvisible|isavailable|shoulddisplay"}];
            break;
        case RYGDeveloperRuntimeSurfaceConsumerSubs:
            [rows addObject:@{@"kind":@"browser", @"title":@"Subscriptions / Aura Runtime", @"query":@"consumersubs|igplus|aura|subscription"}];
            break;
    }
    self.rows = rows.copy;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"Persistence replays exact hook/setter identities only. Runtime discovery and MobileConfig catalogue work never run during app launch.";
}

- (UIButton *)modeButtonForKind:(NSString *)mode {
    BOOL prism = [mode isEqualToString:@"prism"];
    NSString *pref = prism ? kRYGPrismSetterModePref : kRYGRedesignSetterModePref;
    id raw = [NSUserDefaults.standardUserDefaults objectForKey:pref];
    NSInteger current = [raw isKindOfClass:NSNumber.class] ? [raw integerValue] : -1;
    NSString *title = current < 0 ? @"Native" : (current ? @"Forced On" : @"Forced Off");
    __weak typeof(self) weakSelf = self;
    void (^apply)(NSInteger) = ^(NSInteger value) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (value < 0) [defaults removeObjectForKey:pref];
        else [defaults setInteger:value forKey:pref];
        if (prism) {
            gRYGPrismSetterMode = value;
            if (value >= 0) (void)RYGInstallBoolSetterHook(@"IGBloksFollowButtonView", @"setPrismEnabled:", (IMP)RYGPrismSetter, &gRYGPrismSetterOriginal);
        } else {
            gRYGRedesignSetterMode = value;
            if (value >= 0) (void)RYGInstallBoolSetterHook(@"IGTableViewCell", @"setListRedesignOn:", (IMP)RYGRedesignSetter, &gRYGRedesignSetterOriginal);
        }
        [weakSelf.tableView reloadData];
    };
    UIAction *native = [UIAction actionWithTitle:@"Use Native" image:nil identifier:nil handler:^(__unused UIAction *a){ apply(-1); }];
    UIAction *on = [UIAction actionWithTitle:@"Force On" image:nil identifier:nil handler:^(__unused UIAction *a){ apply(1); }];
    UIAction *off = [UIAction actionWithTitle:@"Force Off" image:nil identifier:nil handler:^(__unused UIAction *a){ apply(0); }];
    native.state = current < 0 ? UIMenuElementStateOn : UIMenuElementStateOff;
    on.state = current == 1 ? UIMenuElementStateOn : UIMenuElementStateOff;
    off.state = current == 0 ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.menu = [UIMenu menuWithTitle:@"Output" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:@[native,on,off]];
    button.showsMenuAsPrimaryAction = YES;
    RYGLiquidGlassConfigureButton(button, NO);
    UIButtonConfiguration *configuration = button.configuration;
    if (configuration) { configuration.title = title; configuration.baseForegroundColor = UIColor.labelColor; button.configuration = configuration; }
    else [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UIButton *)runtimeButtonForMethod:(RYGRuntimeBoolMethod *)method {
    NSNumber *forced = method.overrideValue;
    NSNumber *native = method.liveValue;
    NSString *title = forced ? (forced.boolValue ? @"Forced On" : @"Forced Off") : (native ? (native.boolValue ? @"Native On" : @"Native Off") : @"Native");
    __weak typeof(self) weakSelf = self;
    UIAction *observe = [UIAction actionWithTitle:@"Observe native" image:nil identifier:nil handler:^(__unused UIAction *a){
        RYGRuntimeBeginLiveObservation(@[method]); [weakSelf.tableView reloadData];
    }];
    UIAction *nativeAction = [UIAction actionWithTitle:@"Use Native" image:nil identifier:nil handler:^(__unused UIAction *a){ [RYGRuntimeBrowserEngine setOverride:nil forMethod:method]; [weakSelf.tableView reloadData]; }];
    UIAction *on = [UIAction actionWithTitle:@"Force On" image:nil identifier:nil handler:^(__unused UIAction *a){ [RYGRuntimeBrowserEngine setOverride:@YES forMethod:method]; [weakSelf.tableView reloadData]; }];
    UIAction *off = [UIAction actionWithTitle:@"Force Off" image:nil identifier:nil handler:^(__unused UIAction *a){ [RYGRuntimeBrowserEngine setOverride:@NO forMethod:method]; [weakSelf.tableView reloadData]; }];
    nativeAction.state = forced ? UIMenuElementStateOff : UIMenuElementStateOn;
    on.state = forced && forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;
    off.state = forced && !forced.boolValue ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.menu = [UIMenu menuWithTitle:method.selectorName ?: @"BOOL" image:nil identifier:nil options:0 children:@[observe,[UIMenu menuWithTitle:@"Output" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:@[nativeAction,on,off]]]];
    button.showsMenuAsPrimaryAction = YES;
    RYGLiquidGlassConfigureButton(button, NO);
    UIButtonConfiguration *configuration = button.configuration;
    if (configuration) { configuration.title = title; configuration.baseForegroundColor = UIColor.labelColor; button.configuration = configuration; }
    else [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RYGDeveloperTopic"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RYGDeveloperTopic"];
    NSDictionary *row = self.rows[(NSUInteger)indexPath.row];
    NSString *kind = row[@"kind"];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = row[@"subtitle"];
    cell.detailTextLabel.numberOfLines = 3;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if ([kind isEqualToString:@"internal"] || [kind isEqualToString:@"dogfood"] || [kind isEqualToString:@"glass"]) {
        UISwitch *toggle = [UISwitch new];
        if ([kind isEqualToString:@"internal"]) toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:kRYGInternalMenuPref];
        else if ([kind isEqualToString:@"dogfood"]) toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:kRYGDogfoodModePref];
        else {
            NSString *glass = row[@"glass"];
            NSString *pref = [glass isEqualToString:@"swizzle"] ? kRYGGlassSwizzlePref : ([glass isEqualToString:@"throwback"] ? kRYGGlassThrowbackPref : kRYGGlassNavigationPref);
            id raw = [NSUserDefaults.standardUserDefaults objectForKey:pref];
            if ([raw isKindOfClass:NSNumber.class]) toggle.on = [raw boolValue];
            else {
                NSString *className = [glass isEqualToString:@"swizzle"] ? @"_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle" : ([glass isEqualToString:@"throwback"] ? @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper" : @"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper");
                toggle.on = [RYGNativeHelperEnabled(className) boolValue];
            }
        }
        toggle.onTintColor = [RYGUtils RYGColor_Primary];
        objc_setAssociatedObject(toggle, kRYGDeveloperControlKindKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:@"mode"]) {
        cell.accessoryView = [self modeButtonForKind:row[@"mode"]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:@"runtime"]) {
        RYGRuntimeBoolMethod *method = row[@"method"];
        cell.accessoryView = [self runtimeButtonForMethod:method];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle {
    NSDictionary *row = objc_getAssociatedObject(toggle, kRYGDeveloperControlKindKey);
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"internal"]) {
        [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:kRYGInternalMenuPref];
        if (toggle.isOn) RYGInstallBugMenuHooks();
        return;
    }
    if ([kind isEqualToString:@"dogfood"]) {
        [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:kRYGDogfoodModePref];
        if (toggle.isOn) {
            RYGInstallBugMenuHooks();
            RYGInstallDogfoodCaptureHooks();
            [RYGEasyGatingRuntime.shared installIfNeeded];
        }
        NSUInteger available = 0;
        NSUInteger changed = RYGApplyDogfoodCoreMobileConfig(toggle.isOn, &available);
        [RYGUtils showToastForDuration:1.5
                                 title:toggle.isOn ? @"Dogfooding enabled" : @"Dogfooding disabled"
                              subtitle:[NSString stringWithFormat:@"%lu/%lu resolved MobileConfig value(s) changed", (unsigned long)changed, (unsigned long)available]];
        return;
    }
    if ([kind isEqualToString:@"glass"]) {
        NSString *glass = row[@"glass"];
        NSString *pref = nil;
        NSString *className = nil;
        NSString *selectorName = nil;
        if ([glass isEqualToString:@"swizzle"]) {
            pref = kRYGGlassSwizzlePref;
            className = @"_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle";
            selectorName = @"setIsEnabled:";
        } else if ([glass isEqualToString:@"throwback"]) {
            pref = kRYGGlassThrowbackPref;
            className = @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper";
            selectorName = @"overrideIsEnabled:";
        } else {
            pref = kRYGGlassNavigationPref;
            className = @"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper";
            selectorName = @"overrideIsEnabled:";
        }
        if (!RYGSetNativeHelperBool(className, selectorName, toggle.isOn)) {
            toggle.on = !toggle.isOn;
            [RYGUtils showErrorHUDWithDescription:@"Native Liquid Glass helper is not loaded or its ABI changed"];
            return;
        }
        [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:pref];
    }
}

- (void)pushRuntimeBrowserWithTitle:(NSString *)title query:(NSString *)query bulk:(BOOL)bulk {
    RYGFastRuntimeBrowserViewController *browser = [[RYGFastRuntimeBrowserViewController alloc] initWithTitle:title ?: @"Runtime Browser" initialQuery:query ?: @"" allowsBulkVisibilityOverride:bulk];
    [self.navigationController pushViewController:browser animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.rows[(NSUInteger)indexPath.row];
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"browser"] || [kind isEqualToString:@"visibilityBrowser"]) {
        [self pushRuntimeBrowserWithTitle:row[@"title"] query:row[@"query"] bulk:[kind isEqualToString:@"visibilityBrowser"]];
        return;
    }
    if (![kind isEqualToString:@"action"]) return;
    NSString *action = row[@"action"];
    if ([action isEqualToString:@"dogfoodOpen"]) {
        if (!RYGOpenDogfoodSettings()) [RYGUtils showErrorHUDWithDescription:@"Dogfooding Settings context has not been observed yet"];
    } else if ([action isEqualToString:@"directNotes"]) {
        if (!RYGOpenDirectNotesDogfood()) [RYGUtils showErrorHUDWithDescription:@"Direct Notes dogfood user session has not been observed yet"];
    } else if ([action isEqualToString:@"sessions"]) {
        if (!RYGOpenDogfoodSessionBrowser()) [RYGUtils showErrorHUDWithDescription:@"Dogfooding Assistant launcher/session has not been observed yet"];
    } else if ([action isEqualToString:@"mcApply"] || [action isEqualToString:@"mcRestore"]) {
        BOOL apply = [action isEqualToString:@"mcApply"];
        NSUInteger available = 0;
        NSUInteger changed = RYGApplyDogfoodCoreMobileConfig(apply, &available);
        [RYGUtils showToastForDuration:1.5 title:apply ? @"Dogfood MobileConfig applied" : @"Dogfood MobileConfig restored" subtitle:[NSString stringWithFormat:@"%lu/%lu resolved value(s) changed", (unsigned long)changed, (unsigned long)available]];
    }
}

@end

static void RYGDeveloperRestoreOnceAfterLaunch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [RYGDeveloperTopicViewController activatePersistedNativeFeatures];
    });
}

__attribute__((constructor(215))) static void RYGDeveloperStateBootstrap(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) {
                RYGDeveloperRestoreOnceAfterLaunch();
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(750 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{ RYGDeveloperRestoreOnceAfterLaunch(); });
        });
    }
}
