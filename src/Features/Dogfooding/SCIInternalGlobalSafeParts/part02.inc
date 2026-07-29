
static NSString *SCITextInView(UIView *view) {
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) return ((UILabel *)view).text;
    for (UIView *child in view.subviews) {
        NSString *text = SCITextInView(child);
        if (text.length) return text;
    }
    return nil;
}

static NSString *SCIBugMenuCellTitle(UITableViewCell *cell) {
    NSString *title = cell.textLabel.text;
    if (!title.length) title = SCITextInView(cell.contentView);
    if (!title.length) title = cell.accessibilityLabel;
    return [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL SCIIsDogfoodAssistantTitle(NSString *title) {
    return title.length && [title caseInsensitiveCompare:@"Dogfooding Assistant"] == NSOrderedSame;
}

static void SCIApplyDogfoodAssistantSafety(id controller, BOOL reload) {
    if (!controller || SCIDogfoodAssistantPayloadAvailable()) return;
    BOOL changed = SCIWriteBoolIvar(controller, "showDogfoodingAssistant", NO);
    if (reload && changed) {
        UITableView *table = SCIBugMenuTableView(controller);
        [table reloadData];
        [table setNeedsLayout];
    }
}

typedef id (*SCIBugMenuLegacyIMP)(id, SEL, id, id, id, id, id, id, NSInteger, NSInteger, BOOL, BOOL, BOOL);
typedef id (*SCIBugMenuCurrentIMP)(id, SEL, id, id, id, id, id, id, NSInteger, NSInteger, BOOL, BOOL, BOOL, BOOL, NSInteger);

static SCIBugMenuLegacyIMP orig_SafeBugMenuLegacy = NULL;
static SCIBugMenuCurrentIMP orig_SafeBugMenuCurrent = NULL;
static void (*orig_SafeBugMenuViewDidLoad)(id, SEL) = NULL;
static void (*orig_SafeBugMenuViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_SafeBugMenuDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;

static id SCI_SafeBugMenuLegacy(id self, SEL _cmd, id deviceSession, id userSession,
    id reliabilityLogging, id navChain, id endpoint, id entryPoint,
    NSInteger style, NSInteger availabilityStatus, BOOL showInternalSettings,
    BOOL showLoggedOutInternalSettings, BOOL showShakeToReportPreferenceToggle) {
    if (SCIInternalMenuOn()) {
        availabilityStatus = 0;
        showInternalSettings = YES;
        showShakeToReportPreferenceToggle = YES;
    }
    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) showLoggedOutInternalSettings = YES;
    BOOL previous = sSCISuppressLegacyEmployeeMenuMutation;
    sSCISuppressLegacyEmployeeMenuMutation = YES;
    id result = nil;
    @try {
        if (orig_SafeBugMenuLegacy) result = orig_SafeBugMenuLegacy(self, _cmd, deviceSession, userSession,
            reliabilityLogging, navChain, endpoint, entryPoint, style, availabilityStatus,
            showInternalSettings, showLoggedOutInternalSettings, showShakeToReportPreferenceToggle);
    } @finally { sSCISuppressLegacyEmployeeMenuMutation = previous; }
    SCIApplyDogfoodAssistantSafety(result, NO);
    return result;
}

static id SCI_SafeBugMenuCurrent(id self, SEL _cmd, id deviceSession, id userSession,
    id reliabilityLogging, id navChain, id endpoint, id entryPoint,
    NSInteger style, NSInteger availabilityStatus, BOOL showInternalSettings,
    BOOL showLoggedOutInternalSettings, BOOL showShakeToReportPreferenceToggle,
    BOOL showDogfoodingAssistant, NSInteger maisaUXVariantRawValue) {
    if (SCIInternalMenuOn()) {
        availabilityStatus = 0;
        showInternalSettings = YES;
        showShakeToReportPreferenceToggle = YES;
    }
    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) showLoggedOutInternalSettings = YES;
    if (SCIEmployeeInternalMasterOn()) showDogfoodingAssistant = SCIDogfoodAssistantPayloadAvailable();
    BOOL previous = sSCISuppressLegacyEmployeeMenuMutation;
    sSCISuppressLegacyEmployeeMenuMutation = YES;
    id result = nil;
    @try {
        if (orig_SafeBugMenuCurrent) result = orig_SafeBugMenuCurrent(self, _cmd, deviceSession, userSession,
            reliabilityLogging, navChain, endpoint, entryPoint, style, availabilityStatus,
            showInternalSettings, showLoggedOutInternalSettings, showShakeToReportPreferenceToggle,
            showDogfoodingAssistant, maisaUXVariantRawValue);
    } @finally { sSCISuppressLegacyEmployeeMenuMutation = previous; }
    SCIApplyDogfoodAssistantSafety(result, NO);
    return result;
}
