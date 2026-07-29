id config = [self bestDogfoodSettingsConfig];
    if (!top || !session || !config) {
        [self noteAction:@"Open Native Dogfood Settings"
                  status:@"missing native top/session/config"
                  detail:[self dogfoodNativeState]];
        return NO;
    }

    Class launcher =
        NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettings");
    if (!launcher) {
        launcher = NSClassFromString(
            @"_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    }

    SEL selector = NSSelectorFromString(
        @"openWithConfig:onViewController:userSession:");
    Method method = launcher
        ? class_getClassMethod(launcher, selector)
        : NULL;
    const char *encoding = method
        ? method_getTypeEncoding(method)
        : NULL;
    if (!method || !encoding ||
        strcmp(encoding, "v40@0:8@16@24@32") != 0) {
        [self noteAction:@"Open Native Dogfood Settings"
                  status:@"factory unavailable or ABI changed"
                  detail:encoding
                    ? [NSString stringWithUTF8String:encoding]
                    : @"missing"];
        return NO;
    }

    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            launcher, selector, config, top, session);
        [self noteAction:@"Open Native Dogfood Settings"
                  status:@"sent through validated factory"
                  detail:[self dogfoodNativeState]];
        return YES;
    } @catch (id exception) {
        [self noteAction:@"Open Native Dogfood Settings"
                  status:@"factory exception"
                  detail:exception];
        return NO;
    }
}

static NSString *(*orig_OpenDogfoodingSettingsVC)(id, SEL) = NULL;
static void (*orig_OpenInstagramDebugMenu)(id, SEL, id) = NULL;

static NSString *SCI_OpenDogfoodingSettingsVC(id self, SEL _cmd) {
    BOOL opened =
        [SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings];
    return opened
        ? @"opened native Dogfooding Settings through validated factory"
        : @"blocked: native Dogfooding Assistant provider/config unavailable";
}

static void SCI_OpenInstagramDebugMenu(
    id self, SEL _cmd, id completion
) {
    SCIInstallInternalGlobalHooksIfNeeded();
    if (orig_OpenInstagramDebugMenu) {
        orig_OpenInstagramDebugMenu(self, _cmd, completion);
    }
}

static void SCIInstallSafeDogfoodOpeners(void) {
    Class runtime = objc_getClass("SCIDogfoodObjectRuntime");
    Class runtimeMeta = runtime ? object_getClass(runtime) : Nil;
    SEL tryOpen = @selector(tryOpenNativeDogfoodSettings);
    Method tryOpenMethod = runtimeMeta
        ? class_getInstanceMethod(runtimeMeta, tryOpen)
        : NULL;
    if (!orig_TryOpenNativeDogfoodSettings &&
        (SCIEncodingMatches(tryOpenMethod, "B16@0:8") ||
         SCIEncodingMatches(tryOpenMethod, "c16@0:8"))) {
        MSHookMessageEx(
            runtimeMeta, tryOpen,
            (IMP)SCI_TryOpenNativeDogfoodSettings,
            (IMP *)&orig_TryOpenNativeDogfoodSettings);
    }

    Class menus = objc_getClass("SCIInternalMenusLauncher");
    Class menusMeta = menus ? object_getClass(menus) : Nil;

    SEL openSettings =
        NSSelectorFromString(@"openDogfoodingSettingsVC");
    Method openMethod = menusMeta
        ? class_getInstanceMethod(menusMeta, openSettings)
        : NULL;
    if (!orig_OpenDogfoodingSettingsVC &&
        SCIEncodingMatches(openMethod, "@16@0:8")) {
        MSHookMessageEx(
            menusMeta, openSettings,
            (IMP)SCI_OpenDogfoodingSettingsVC,
            (IMP *)&orig_OpenDogfoodingSettingsVC);
    }

    SEL openDebug = NSSelectorFromString(
        @"openInstagramDebugMenuWithCompletion:");
    Method debugMethod = menusMeta
        ? class_getInstanceMethod(menusMeta, openDebug)
        : NULL;
    if (!orig_OpenInstagramDebugMenu &&
        SCIEncodingMatches(debugMethod, "v24@0:8@16")) {
        MSHookMessageEx(
            menusMeta, openDebug,
            (IMP)SCI_OpenInstagramDebugMenu,
            (IMP *)&orig_OpenInstagramDebugMenu);
    }
}

BOOL SCIInstallInternalGlobalHooksIfNeeded(void) {
    BOOL employeeOn = SCIEmployeeInternalMasterOn();
    BOOL menuOn = SCIInternalMenuOn();
    if (!employeeOn && !menuOn) return YES;

    SCIInstallEmployeeIdentityHooksIfNeeded();
    SCIInstallMobileConfigEmployeeHooks();
    SCIInstallBugMenuPayloadSafety();
    SCIInstallSafeDogfoodOpeners();

    BOOL mcReady = !employeeOn ||
        (orig_MCGetBool &&
         orig_MCGetBoolDefault &&
         orig_MCGetBoolOptions &&
         orig_MCGetBoolOptionsDefault &&
         orig_MCGetBoolNoLog &&
         orig_MCGetBoolNoLogDefault);
    BOOL menuReady = !menuOn ||
        orig_SafeBugMenuCurrent ||
        orig_SafeBugMenuLegacy;
    BOOL openerReady = !menuOn ||
        (orig_TryOpenNativeDogfoodSettings &&
         orig_OpenDogfoodingSettingsVC &&
         orig_OpenInstagramDebugMenu);
    return mcReady && menuReady && openerReady;
}
