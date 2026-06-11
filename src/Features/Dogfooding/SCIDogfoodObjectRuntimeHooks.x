#import "SCIDogfoodObjectRuntime.h"
#import <objc/runtime.h>
#import <substrate.h>

static NSMutableSet<NSString *> *sSCIDFInstalled;
static void SCIHookDF(Class cls, NSString *selName, IMP newImp, IMP *origOut) {
    if (!cls || !selName.length || !newImp || !origOut) return;
    SEL sel = NSSelectorFromString(selName);
    if (!class_getInstanceMethod(cls, sel)) return;
    if (!sSCIDFInstalled) sSCIDFInstalled = [NSMutableSet new];
    NSString *key = [NSString stringWithFormat:@"I:%@:%@", NSStringFromClass(cls), selName];
    if ([sSCIDFInstalled containsObject:key]) return;
    [sSCIDFInstalled addObject:key];
    MSHookMessageEx(cls, sel, newImp, origOut);
}

static void SCIHookDFClass(Class cls, NSString *selName, IMP newImp, IMP *origOut) {
    if (!cls || !selName.length || !newImp || !origOut) return;
    SEL sel = NSSelectorFromString(selName);
    if (!class_getClassMethod(cls, sel)) return;
    Class meta = object_getClass(cls);
    if (!meta) return;
    if (!sSCIDFInstalled) sSCIDFInstalled = [NSMutableSet new];
    NSString *key = [NSString stringWithFormat:@"C:%@:%@", NSStringFromClass(cls), selName];
    if ([sSCIDFInstalled containsObject:key]) return;
    [sSCIDFInstalled addObject:key];
    MSHookMessageEx(meta, sel, newImp, origOut);
}

static BOOL SCIClassNameInterestingForDogfoodRuntime(NSString *cn) {
    NSString *s = cn.lowercaseString ?: @"";
    return [s containsString:@"dogfood"] ||
           [s containsString:@"mobileconfig"] ||
           [s containsString:@"settings2"] ||
           [s containsString:@"settingscreen"] ||
           [s containsString:@"settingdatamodel"] ||
           [s containsString:@"settingsviewcontroller"] ||
           [s containsString:@"permissionsgating"] ||
           [s containsString:@"upperfunnelgating"] ||
           [s containsString:@"facebookuserinfo"] ||
           [s containsString:@"baseuser"] ||
           [s containsString:@"userlauncherset"];
}

static Class SCIClassByNames(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) cls = objc_getClass(name.UTF8String);
        if (cls) return cls;
    }
    return Nil;
}

static id (*orig_df_dog_init)(id, SEL, id, id, id);
static id new_df_dog_init(id self, SEL _cmd, id launcherSet, id networker, id logger) {
    id obj = orig_df_dog_init ? orig_df_dog_init(self, _cmd, launcherSet, networker, logger) : self;
    [SCIDogfoodObjectRuntime noteObject:obj role:@"IGDogfooderProd" source:NSStringFromSelector(_cmd)];
    [SCIDogfoodObjectRuntime noteObject:launcherSet role:@"IGUserLauncherSet" source:@"IGDogfooderProd._launcherSet"];
    [SCIDogfoodObjectRuntime noteObject:networker role:@"IGAPIClient/networker" source:@"IGDogfooderProd._networker"];
    [SCIDogfoodObjectRuntime noteObject:logger role:@"IGDogfoodingLogger" source:@"IGDogfooderProd._logger"];
    return obj;
}

static void (*orig_df_dog_updates)(id, SEL, id);
static void new_df_dog_updates(id self, SEL _cmd, id completion) {
    [SCIDogfoodObjectRuntime noteObject:self role:@"IGDogfooderProd" source:NSStringFromSelector(_cmd)];
    if (orig_df_dog_updates) orig_df_dog_updates(self, _cmd, completion);
}

static void (*orig_df_dog_build)(id, SEL, id, BOOL, id);
static void new_df_dog_build(id self, SEL _cmd, id build, BOOL useCache, id completion) {
    [SCIDogfoodObjectRuntime noteObject:self role:@"IGDogfooderProd" source:NSStringFromSelector(_cmd)];
    if (orig_df_dog_build) orig_df_dog_build(self, _cmd, build, useCache, completion);
}
static void (*orig_df_dog_trigger)(id, SEL, NSInteger, id);
static void new_df_dog_trigger(id self, SEL _cmd, NSInteger mode, id completion) {
    [SCIDogfoodObjectRuntime noteObject:self role:@"IGDogfooderProd" source:NSStringFromSelector(_cmd)];
    if (orig_df_dog_trigger) orig_df_dog_trigger(self, _cmd, mode, completion);
}

static void (*orig_uivc_viewDidLoad)(id, SEL);
static void new_uivc_viewDidLoad(id self, SEL _cmd) {
    if (SCIClassNameInterestingForDogfoodRuntime(NSStringFromClass(object_getClass(self)))) {
        [SCIDogfoodObjectRuntime noteObject:self role:@"viewController" source:NSStringFromSelector(_cmd)];
    }
    if (orig_uivc_viewDidLoad) orig_uivc_viewDidLoad(self, _cmd);
}

static void (*orig_uivc_viewDidAppear)(id, SEL, BOOL);
static void new_uivc_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    NSString *cn = NSStringFromClass(object_getClass(self));
    if (SCIClassNameInterestingForDogfoodRuntime(cn)) {
        [SCIDogfoodObjectRuntime noteObject:self role:@"visibleViewController" source:NSStringFromSelector(_cmd)];
    }
    if ([cn.lowercaseString containsString:@"settings"]) {
        [SCIDogfoodObjectRuntime noteSettingsObject:self role:@"settingsVC" source:@"UIViewController.viewDidAppear:"];
        if ([self isKindOfClass:UIViewController.class]) [SCIDogfoodObjectRuntime injectRowsIntoSettingsIfPossibleFromViewController:(UIViewController *)self];
    }
    if (orig_uivc_viewDidAppear) orig_uivc_viewDidAppear(self, _cmd, animated);
}

static id (*orig_ctx_user_init)(id, SEL, id, id);
static id new_ctx_user_init(id self, SEL _cmd, id sessionID, id manager) {
    id obj = orig_ctx_user_init ? orig_ctx_user_init(self, _cmd, sessionID, manager) : self;
    [SCIDogfoodObjectRuntime noteObject:obj role:@"IGMobileConfigUserSessionContextManager" source:NSStringFromSelector(_cmd)];
    return obj;
}
static void (*orig_dogfirst_begin)(id, SEL, id, id, id);
static void new_dogfirst_begin(id self, SEL _cmd, id mainAppVC, id pandoGraphQLService, id dogfooder) {
    [SCIDogfoodObjectRuntime noteObject:self role:@"DogfoodingFirstCoordinator" source:NSStringFromSelector(_cmd)];
    [SCIDogfoodObjectRuntime noteObject:mainAppVC role:@"mainAppViewController" source:@"DogfoodingFirstCoordinator.didBeginSession.mainAppVC"];
    [SCIDogfoodObjectRuntime noteObject:pandoGraphQLService role:@"pandoGraphQLService" source:@"DogfoodingFirstCoordinator.didBeginSession.pandoGraphQLService"];
    [SCIDogfoodObjectRuntime noteObject:dogfooder role:@"dogfooder" source:@"DogfoodingFirstCoordinator.didBeginSession.dogfooder"];
    if (orig_dogfirst_begin) orig_dogfirst_begin(self, _cmd, mainAppVC, pandoGraphQLService, dogfooder);
}

static id (*orig_autofill_init)(id, SEL, id);
static id new_autofill_init(id self, SEL _cmd, id userSession) {
    id obj = orig_autofill_init ? orig_autofill_init(self, _cmd, userSession) : self;
    [SCIDogfoodObjectRuntime noteObject:obj role:@"AutofillInternalSettings" source:NSStringFromSelector(_cmd)];
    [SCIDogfoodObjectRuntime noteLiveUserSession:userSession source:@"AutofillInternalSettings.initWithUserSession:"];
    return obj;
}

static void (*orig_df_settings_open)(id, SEL, id, id, id);
static void new_df_settings_open(id self, SEL _cmd, id config, id viewController, id userSession) {
    [SCIDogfoodObjectRuntime noteDogfoodConfig:config userSession:userSession source:@"IGDogfoodingSettings.openWithConfig:onViewController:userSession:"];
    [SCIDogfoodObjectRuntime noteObject:viewController role:@"dogfoodSettingsPresenter" source:NSStringFromSelector(_cmd)];
    if (orig_df_settings_open) orig_df_settings_open(self, _cmd, config, viewController, userSession);
}

static id (*orig_df_settings_vc_init)(id, SEL, id, id);
static id new_df_settings_vc_init(id self, SEL _cmd, id config, id userSession) {
    id obj = orig_df_settings_vc_init ? orig_df_settings_vc_init(self, _cmd, config, userSession) : self;
    [SCIDogfoodObjectRuntime noteDogfoodConfig:config userSession:userSession source:@"IGDogfoodingSettingsViewController.initWithConfig:userSession:"];
    [SCIDogfoodObjectRuntime noteObject:obj role:@"IGDogfoodingSettingsViewController" source:NSStringFromSelector(_cmd)];
    return obj;
}

static id (*orig_ctx_sessionless_init)(id, SEL, id, id);
static id new_ctx_sessionless_init(id self, SEL _cmd, id sessionID, id manager) {
    id obj = orig_ctx_sessionless_init ? orig_ctx_sessionless_init(self, _cmd, sessionID, manager) : self;
    [SCIDogfoodObjectRuntime noteObject:obj role:@"IGMobileConfigSessionlessContextManager" source:NSStringFromSelector(_cmd)];
    return obj;
}

static void SCIInstallDogfoodObjectHooks(void) {
    [SCIDogfoodObjectRuntime installIfNeeded];
    Class dog = NSClassFromString(@"IGDogfooderProd");
    SCIHookDF(dog, @"initWithLauncherSet:networker:logger:", (IMP)new_df_dog_init, (IMP *)&orig_df_dog_init);
    SCIHookDF(dog, @"checkAvailableAppUpdatesWithCompletion:", (IMP)new_df_dog_updates, (IMP *)&orig_df_dog_updates);
    SCIHookDF(dog, @"checkBuildStatusForBuild:useCacheResultIfAvailable:completion:", (IMP)new_df_dog_build, (IMP *)&orig_df_dog_build);
    SCIHookDF(dog, @"triggerUpdateWithMode:completion:", (IMP)new_df_dog_trigger, (IMP *)&orig_df_dog_trigger);

    // Do not hook UIViewController globally. That made the runtime browser lag and
    // polluted unrelated screens. Settings/VC discovery is now stub-first and
    // on-demand; named classes below still get captured safely.

    SCIHookDF(NSClassFromString(@"IGMobileConfigUserSessionContextManager"), @"initWithSessionID:manager:", (IMP)new_ctx_user_init, (IMP *)&orig_ctx_user_init);
    SCIHookDF(NSClassFromString(@"IGMobileConfigSessionlessContextManager"), @"initWithSessionID:manager:", (IMP)new_ctx_sessionless_init, (IMP *)&orig_ctx_sessionless_init);

    Class dfc = NSClassFromString(@"IGDogfoodingFirst.DogfoodingFirstCoordinator") ?: NSClassFromString(@"_TtC18IGDogfoodingFirst27DogfoodingFirstCoordinator");
    SCIHookDF(dfc, @"didBeginSessionWithMainAppViewController:pandoGraphQLService:dogfooder:", (IMP)new_dogfirst_begin, (IMP *)&orig_dogfirst_begin);

    Class autofill = NSClassFromString(@"AutofillInternalSettingsInstagram.IGAutofillInternalSettings") ?: NSClassFromString(@"_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings");
    SCIHookDF(autofill, @"initWithUserSession:", (IMP)new_autofill_init, (IMP *)&orig_autofill_init);

    Class dogSettings = SCIClassByNames(@[@"IGDogfoodingSettings.IGDogfoodingSettings", @"_TtC20IGDogfoodingSettings20IGDogfoodingSettings"]);
    SCIHookDFClass(dogSettings, @"openWithConfig:onViewController:userSession:", (IMP)new_df_settings_open, (IMP *)&orig_df_settings_open);

    Class dogSettingsVC = SCIClassByNames(@[@"IGDogfoodingSettings.IGDogfoodingSettingsViewController", @"_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController"]);
    SCIHookDF(dogSettingsVC, @"initWithConfig:userSession:", (IMP)new_df_settings_vc_init, (IMP *)&orig_df_settings_vc_init);
}

%ctor {
    @autoreleasepool {
        // Deferred off static-init phase: see SCIEasyGatingHook.x for full explanation.
        // Dogfood object hooks (MSHookMessageEx on MobileConfig context managers) are safe
        // to install post-launch; the objects they hook are created after UIApplicationMain.
        __block id _sciTok = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            if (_sciTok) { [[NSNotificationCenter defaultCenter] removeObserver:_sciTok]; _sciTok = nil; }
            // SCI-FIX 2026-06-11: single install; dropped redundant 2s/8s dispatch_after retries.
            SCIInstallDogfoodObjectHooks();
        }];
    }
}
