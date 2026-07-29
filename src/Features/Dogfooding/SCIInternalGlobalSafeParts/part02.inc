static NSString *SCITextInView(UIView *view) {
    if ([view isKindOfClass:UILabel.class] &&
        ((UILabel *)view).text.length) {
        return ((UILabel *)view).text;
    }
    for (UIView *child in view.subviews) {
        NSString *text = SCITextInView(child);
        if (text.length) return text;
    }
    return nil;
}

static NSString *SCIBugMenuCellTitle(UITableViewCell *cell) {
    if (!cell) return nil;
    NSString *title = cell.textLabel.text;
    if (!title.length) {
        id configuration = cell.contentConfiguration;
        SEL textSelector = sel_registerName("text");
        if ([configuration respondsToSelector:textSelector]) {
            @try {
                id value = ((id (*)(id, SEL))objc_msgSend)(
                    configuration, textSelector);
                if ([value isKindOfClass:NSString.class]) title = value;
            } @catch (__unused id exception) {}
        }
    }
    if (!title.length) title = SCITextInView(cell.contentView);
    if (!title.length) title = cell.accessibilityLabel;
    return [title stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL SCIIsDogfoodAssistantTitle(NSString *title) {
    return title.length &&
        [title caseInsensitiveCompare:@"Dogfooding Assistant"] == NSOrderedSame;
}

static BOOL SCIStringLooksLikeDogfoodDependency(NSString *value) {
    NSString *lower = value.lowercaseString ?: @"";
    return [lower containsString:@"dogfood"] ||
           [lower containsString:@"assistant"] ||
           [lower containsString:@"provider"] ||
           [lower containsString:@"socket"] ||
           [lower containsString:@"config"] ||
           [lower containsString:@"usersession"];
}

static void SCICollectDogfoodDependencies(
    id object,
    NSUInteger depth,
    NSMutableSet<NSValue *> *visited,
    NSMutableDictionary<NSString *, id> *found
) {
    if (!object || depth > 3) return;

    NSValue *address = [NSValue valueWithPointer:
        (__bridge const void *)object];
    if ([visited containsObject:address]) return;
    [visited addObject:address];

    Class cls = object_getClass(object);
    NSString *className = NSStringFromClass(cls) ?: @"";
    NSString *lowerClass = className.lowercaseString;

    if ([lowerClass containsString:@"dogfoodingsettingsconfig"]) {
        found[@"config"] = object;
    }
    if ([className isEqualToString:@"IGUserSession"] ||
        [lowerClass hasSuffix:@"usersession"]) {
        found[@"session"] = object;
    }

    if (depth == 3) return;

    for (Class current = cls; current;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; ivars && index < count; index++) {
            Ivar ivar = ivars[index];
            const char *encoding = ivar_getTypeEncoding(ivar);
            if (!encoding || encoding[0] != '@') continue;

            id child = nil;
            @try { child = object_getIvar(object, ivar); }
            @catch (__unused id exception) {}
            if (!child) continue;

            NSString *ivarName = ivar_getName(ivar)
                ? [NSString stringWithUTF8String:ivar_getName(ivar)]
                : @"";
            NSString *childClass =
                NSStringFromClass(object_getClass(child)) ?: @"";
            BOOL relevant = depth == 0 ||
                SCIStringLooksLikeDogfoodDependency(ivarName) ||
                SCIStringLooksLikeDogfoodDependency(childClass);
            if (relevant) {
                SCICollectDogfoodDependencies(
                    child, depth + 1, visited, found);
            }
        }
        if (ivars) free(ivars);
    }
}

static void SCICaptureDogfoodDependencies(id controller) {
    if (!controller ||
        !SCIEmployeeInternalMasterOn() ||
        !SCIDogfoodAssistantPayloadAvailable()) {
        return;
    }

    NSMutableDictionary<NSString *, id> *found =
        [NSMutableDictionary dictionary];
    SCICollectDogfoodDependencies(
        controller, 0, [NSMutableSet set], found);

    id session = found[@"session"] ?:
        [SCIDogfoodObjectRuntime activeUserSession];
    id config = found[@"config"];
    if (config) {
        [SCIDogfoodObjectRuntime noteDogfoodConfig:config
            userSession:session
            source:@"InternalGlobalSafe Bug Reporter dependency graph"];
    } else if (session) {
        [SCIDogfoodObjectRuntime noteLiveUserSession:session
            source:@"InternalGlobalSafe Bug Reporter dependency graph"];
    }
}

static BOOL SCIApplyBugMenuState(id controller, BOOL reload) {
    if (!controller || !SCIInternalMenuOn()) return NO;

    BOOL changed = NO;
    if (SCIShowInternalSettingsOn()) {
        changed |= SCIWriteIntegerIvar(
            controller,
            "internalSettingsAvailabilityStatus",
            SCIInternalSettingsAvailabilityStatus());
        changed |= SCIWriteBoolIvar(
            controller, "showInternalSettings", YES);
        changed |= SCIWriteBoolIvar(
            controller, "showShakeToReportPreferenceToggle", YES);
    }

    if (SCILoggedOutInternalSettingsOn()) {
        changed |= SCIWriteBoolIvar(
            controller, "showLoggedOutInternalSettings", YES);
    }

    BOOL assistantPayload = SCIDogfoodAssistantPayloadAvailable();
    if (!assistantPayload || SCIEmployeeInternalMasterOn()) {
        changed |= SCIWriteBoolIvar(
            controller,
            "showDogfoodingAssistant",
            SCIEmployeeInternalMasterOn() && assistantPayload);
    }

    if (reload && changed) {
        UITableView *table = SCIBugMenuTableView(controller);
        [table reloadData];
        [table setNeedsLayout];
    }
    return changed;
}

typedef id (*SCIBugMenuLegacyIMP)(
    id, SEL, id, id, id, id, id, id,
    NSInteger, NSInteger, BOOL, BOOL, BOOL
);
typedef id (*SCIBugMenuCurrentIMP)(
    id, SEL, id, id, id, id, id, id,
    NSInteger, NSInteger, BOOL, BOOL, BOOL, BOOL, NSInteger
);

static SCIBugMenuLegacyIMP orig_SafeBugMenuLegacy = NULL;
static SCIBugMenuCurrentIMP orig_SafeBugMenuCurrent = NULL;
static void (*orig_SafeBugMenuViewDidLoad)(id, SEL) = NULL;
static void (*orig_SafeBugMenuViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_SafeBugMenuDidSelect)(
    id, SEL, UITableView *, NSIndexPath *) = NULL;

static id SCI_SafeBugMenuLegacy(
    id self, SEL _cmd,
    id deviceSession, id userSession, id reliabilityLogging,
    id navChain, id endpoint, id entryPoint,
    NSInteger style, NSInteger availabilityStatus,
    BOOL showInternalSettings,
    BOOL showLoggedOutInternalSettings,
    BOOL showShakeToReportPreferenceToggle
) {
    if (SCIShowInternalSettingsOn()) {
        availabilityStatus = SCIInternalSettingsAvailabilityStatus();
        showInternalSettings = YES;
        showShakeToReportPreferenceToggle = YES;
    }
    if (SCILoggedOutInternalSettingsOn()) {
        showLoggedOutInternalSettings = YES;
    }
    if (SCIEmployeeInternalMasterOn()) {
        SCIInstallEmployeeIdentityHooksForObject(deviceSession);
        SCIInstallEmployeeIdentityHooksForObject(userSession);
        [SCIDogfoodObjectRuntime noteLiveUserSession:userSession
            source:@"InternalGlobalSafe Bug Reporter initializer"];
    }

    id result = orig_SafeBugMenuLegacy
        ? orig_SafeBugMenuLegacy(
            self, _cmd, deviceSession, userSession, reliabilityLogging,
            navChain, endpoint, entryPoint, style, availabilityStatus,
            showInternalSettings, showLoggedOutInternalSettings,
            showShakeToReportPreferenceToggle)
        : nil;
    SCIApplyBugMenuState(result, NO);
    SCICaptureDogfoodDependencies(result);
    return result;
}

static id SCI_SafeBugMenuCurrent(
    id self, SEL _cmd,
    id deviceSession, id userSession, id reliabilityLogging,
    id navChain, id endpoint, id entryPoint,
    NSInteger style, NSInteger availabilityStatus,
    BOOL showInternalSettings,
    BOOL showLoggedOutInternalSettings,
    BOOL showShakeToReportPreferenceToggle,
    BOOL showDogfoodingAssistant,
    NSInteger maisaUXVariantRawValue
) {
    if (SCIShowInternalSettingsOn()) {
        availabilityStatus = SCIInternalSettingsAvailabilityStatus();
        showInternalSettings = YES;
        showShakeToReportPreferenceToggle = YES;
    }
    if (SCILoggedOutInternalSettingsOn()) {
        showLoggedOutInternalSettings = YES;
    }

    BOOL assistantPayload = SCIDogfoodAssistantPayloadAvailable();
    if (!assistantPayload || SCIEmployeeInternalMasterOn()) {
        showDogfoodingAssistant =
            SCIEmployeeInternalMasterOn() && assistantPayload;
    }

    if (SCIEmployeeInternalMasterOn()) {
        SCIInstallEmployeeIdentityHooksForObject(deviceSession);
        SCIInstallEmployeeIdentityHooksForObject(userSession);
        [SCIDogfoodObjectRuntime noteLiveUserSession:userSession
            source:@"InternalGlobalSafe Bug Reporter initializer"];
    }

    id result = orig_SafeBugMenuCurrent
        ? orig_SafeBugMenuCurrent(
            self, _cmd, deviceSession, userSession, reliabilityLogging,
            navChain, endpoint, entryPoint, style, availabilityStatus,
            showInternalSettings, showLoggedOutInternalSettings,
            showShakeToReportPreferenceToggle, showDogfoodingAssistant,
            maisaUXVariantRawValue)
        : nil;
    SCIApplyBugMenuState(result, NO);
    SCICaptureDogfoodDependencies(result);
    return result;
}
