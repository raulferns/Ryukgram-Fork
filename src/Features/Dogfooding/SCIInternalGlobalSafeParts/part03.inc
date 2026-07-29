static void SCI_SafeBugMenuViewDidLoad(id self, SEL _cmd) {
    SCIApplyBugMenuState(self, NO);
    if (orig_SafeBugMenuViewDidLoad) {
        orig_SafeBugMenuViewDidLoad(self, _cmd);
    }
    SCIApplyBugMenuState(self, YES);
    SCICaptureDogfoodDependencies(self);
}

static void SCI_SafeBugMenuViewDidAppear(
    id self, SEL _cmd, BOOL animated
) {
    SCIApplyBugMenuState(self, NO);
    if (orig_SafeBugMenuViewDidAppear) {
        orig_SafeBugMenuViewDidAppear(self, _cmd, animated);
    }
    SCIApplyBugMenuState(self, YES);
    SCICaptureDogfoodDependencies(self);
}

static void SCI_SafeBugMenuDidSelect(
    id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath
) {
    UITableViewCell *cell =
        [tableView cellForRowAtIndexPath:indexPath];
    NSString *title = SCIBugMenuCellTitle(cell);

    if (SCIIsDogfoodAssistantTitle(title) &&
        !SCIDogfoodAssistantPayloadAvailable()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [SCIDogfoodObjectRuntime noteAction:@"Dogfooding Assistant"
            status:@"blocked: XPlugins socket provider is empty"
            detail:@"hash=0x7FBC8058; unavailable initializer was not called"];
        SCIApplyBugMenuState(self, YES);
        return;
    }

    if (SCIIsDogfoodAssistantTitle(title)) {
        SCICaptureDogfoodDependencies(self);
    }

    SCIApplyBugMenuState(self, NO);
    if (orig_SafeBugMenuDidSelect) {
        orig_SafeBugMenuDidSelect(self, _cmd, tableView, indexPath);
    }
    SCIApplyBugMenuState(self, NO);
}

static void SCIInstallBugMenuPayloadSafety(void) {
    if (!SCIInternalMenuOn()) return;

    SCIInstallEmployeeIdentityHooksIfNeeded();

    Class cls = objc_getClass(
        "_TtC17IGBugReporterMenu29IGBugReportMenuViewController");
    if (!cls) cls = objc_getClass("IGBugReportMenuViewController");
    if (!cls) return;

    SEL legacySelector = NSSelectorFromString(
        @"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:");
    Method legacyMethod =
        class_getInstanceMethod(cls, legacySelector);
    if (!orig_SafeBugMenuLegacy &&
        SCIEncodingMatches(
            legacyMethod,
            "@92@0:8@16@24@32@40@48@56q64q72B80B84B88")) {
        MSHookMessageEx(
            cls, legacySelector, (IMP)SCI_SafeBugMenuLegacy,
            (IMP *)&orig_SafeBugMenuLegacy);
    }

    SEL currentSelector = NSSelectorFromString(
        @"initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:showDogfoodingAssistant:maisaUXVariantRawValue:");
    Method currentMethod =
        class_getInstanceMethod(cls, currentSelector);
    if (!orig_SafeBugMenuCurrent &&
        SCIEncodingMatches(
            currentMethod,
            "@104@0:8@16@24@32@40@48@56q64q72B80B84B88B92q96")) {
        MSHookMessageEx(
            cls, currentSelector, (IMP)SCI_SafeBugMenuCurrent,
            (IMP *)&orig_SafeBugMenuCurrent);
    }

    Method loadMethod =
        class_getInstanceMethod(cls, @selector(viewDidLoad));
    if (!orig_SafeBugMenuViewDidLoad &&
        SCIEncodingMatches(loadMethod, "v16@0:8")) {
        MSHookMessageEx(
            cls, @selector(viewDidLoad),
            (IMP)SCI_SafeBugMenuViewDidLoad,
            (IMP *)&orig_SafeBugMenuViewDidLoad);
    }

    Method appearMethod =
        class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (!orig_SafeBugMenuViewDidAppear &&
        SCIEncodingMatches(appearMethod, "v20@0:8B16")) {
        MSHookMessageEx(
            cls, @selector(viewDidAppear:),
            (IMP)SCI_SafeBugMenuViewDidAppear,
            (IMP *)&orig_SafeBugMenuViewDidAppear);
    }

    SEL select = @selector(tableView:didSelectRowAtIndexPath:);
    Method selectMethod = class_getInstanceMethod(cls, select);
    if (!orig_SafeBugMenuDidSelect &&
        SCIEncodingMatches(selectMethod, "v32@0:8@16@24")) {
        MSHookMessageEx(
            cls, select, (IMP)SCI_SafeBugMenuDidSelect,
            (IMP *)&orig_SafeBugMenuDidSelect);
    }

    IGSLOG("Bug Reporter hooks legacy=%d current=%d load=%d appear=%d select=%d",
           orig_SafeBugMenuLegacy != NULL,
           orig_SafeBugMenuCurrent != NULL,
           orig_SafeBugMenuViewDidLoad != NULL,
           orig_SafeBugMenuViewDidAppear != NULL,
           orig_SafeBugMenuDidSelect != NULL);
}

static BOOL (*orig_TryOpenNativeDogfoodSettings)(id, SEL) = NULL;

static BOOL SCI_TryOpenNativeDogfoodSettings(id self, SEL _cmd) {
    if (!SCIDogfoodAssistantPayloadAvailable()) {
        [self noteAction:@"Open Native Dogfood Settings"
                  status:@"blocked: XPlugins socket provider is empty"
                  detail:@"hash=0x7FBC8058; no sentinel bridge and no unavailable initializer"];
        return NO;
    }
    UIViewController *top = [self topViewController];
    id session = [self activeUserSession];
