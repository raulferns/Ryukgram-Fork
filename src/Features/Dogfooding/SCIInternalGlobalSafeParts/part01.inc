// Payload availability can change after constructor time when the exporting
// image/session graph becomes available. Query the real provider each time;
// these checks are only used on installation/status and on the two exact MC IDs.
static BOOL SCIInternalOnlyPayloadAvailable(void) {
    return SCIXPluginsPayloadAvailable(kSCIInternalOnlyPluginHash);
}

static BOOL SCIDogfoodAssistantPayloadAvailable(void) {
    return SCIXPluginsPayloadAvailable(kSCIDogfoodSocketPluginHash);
}

static BOOL SCIShouldForceMCParam(SCIMCBoolParam param) {
    if (!SCIEmployeeInternalMasterOn()) return NO;
    if (param.raw == kSCIEmployeeOrTestUserMC) return YES;
    if (param.raw == kSCIDogfoodingAssistantMC) {
        return SCIDogfoodAssistantPayloadAvailable();
    }
    return NO;
}

static BOOL (*orig_MCGetBool)(id, SEL, SCIMCBoolParam) = NULL;
static BOOL (*orig_MCGetBoolDefault)(id, SEL, SCIMCBoolParam, BOOL) = NULL;
static BOOL (*orig_MCGetBoolOptions)(id, SEL, SCIMCBoolParam, id) = NULL;
static BOOL (*orig_MCGetBoolOptionsDefault)(id, SEL, SCIMCBoolParam, id, BOOL) = NULL;
static BOOL (*orig_MCGetBoolNoLog)(id, SEL, SCIMCBoolParam) = NULL;
static BOOL (*orig_MCGetBoolNoLogDefault)(id, SEL, SCIMCBoolParam, BOOL) = NULL;

static BOOL SCI_MCGetBool(id self, SEL _cmd, SCIMCBoolParam param) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBool ? orig_MCGetBool(self, _cmd, param) : NO;
}

static BOOL SCI_MCGetBoolDefault(id self, SEL _cmd, SCIMCBoolParam param,
                                 BOOL fallback) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBoolDefault
        ? orig_MCGetBoolDefault(self, _cmd, param, fallback)
        : fallback;
}

static BOOL SCI_MCGetBoolOptions(id self, SEL _cmd, SCIMCBoolParam param,
                                 id options) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBoolOptions
        ? orig_MCGetBoolOptions(self, _cmd, param, options)
        : NO;
}

static BOOL SCI_MCGetBoolOptionsDefault(id self, SEL _cmd,
                                        SCIMCBoolParam param, id options,
                                        BOOL fallback) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBoolOptionsDefault
        ? orig_MCGetBoolOptionsDefault(self, _cmd, param, options, fallback)
        : fallback;
}

static BOOL SCI_MCGetBoolNoLog(id self, SEL _cmd, SCIMCBoolParam param) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBoolNoLog
        ? orig_MCGetBoolNoLog(self, _cmd, param)
        : NO;
}

static BOOL SCI_MCGetBoolNoLogDefault(id self, SEL _cmd,
                                      SCIMCBoolParam param, BOOL fallback) {
    if (SCIShouldForceMCParam(param)) return YES;
    return orig_MCGetBoolNoLogDefault
        ? orig_MCGetBoolNoLogDefault(self, _cmd, param, fallback)
        : fallback;
}

static void SCIInstallMobileConfigEmployeeHooks(void) {
    if (!SCIEmployeeInternalMasterOn()) return;

    Class cls = objc_getClass("FBMobileConfigContextManager");
    if (!cls) return;

#define SCI_HOOK_MC(selectorName, expectedEncoding, replacement, original) do { \
    SEL selector = NSSelectorFromString(selectorName); \
    Method method = class_getInstanceMethod(cls, selector); \
    if (!(original) && SCIEncodingMatches(method, expectedEncoding)) { \
        MSHookMessageEx(cls, selector, (IMP)(replacement), (IMP *)&(original)); \
    } \
} while (0)

    SCI_HOOK_MC(@"getBool:",
        "B24@0:8{mc_bool_param_t=Q}16",
        SCI_MCGetBool, orig_MCGetBool);
    SCI_HOOK_MC(@"getBool:withDefault:",
        "B28@0:8{mc_bool_param_t=Q}16B24",
        SCI_MCGetBoolDefault, orig_MCGetBoolDefault);
    SCI_HOOK_MC(@"getBool:withOptions:",
        "B32@0:8{mc_bool_param_t=Q}16@24",
        SCI_MCGetBoolOptions, orig_MCGetBoolOptions);
    SCI_HOOK_MC(@"getBool:withOptions:withDefault:",
        "B36@0:8{mc_bool_param_t=Q}16@24B32",
        SCI_MCGetBoolOptionsDefault, orig_MCGetBoolOptionsDefault);
    SCI_HOOK_MC(@"getBoolWithoutLogging:",
        "B24@0:8{mc_bool_param_t=Q}16",
        SCI_MCGetBoolNoLog, orig_MCGetBoolNoLog);
    SCI_HOOK_MC(@"getBoolWithoutLogging:withDefault:",
        "B28@0:8{mc_bool_param_t=Q}16B24",
        SCI_MCGetBoolNoLogDefault, orig_MCGetBoolNoLogDefault);

#undef SCI_HOOK_MC

    NSUInteger count = 0;
    count += orig_MCGetBool != NULL;
    count += orig_MCGetBoolDefault != NULL;
    count += orig_MCGetBoolOptions != NULL;
    count += orig_MCGetBoolOptionsDefault != NULL;
    count += orig_MCGetBoolNoLog != NULL;
    count += orig_MCGetBoolNoLogDefault != NULL;
    IGSLOG("MC employee hooks=%lu/6 internalPayload=%d assistantPayload=%d",
           (unsigned long)count,
           SCIInternalOnlyPayloadAvailable(),
           SCIDogfoodAssistantPayloadAvailable());
}

static BOOL SCIWriteBoolIvar(id object, const char *name, BOOL value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;

    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding ||
        (encoding[0] != 'B' && encoding[0] != 'c' && encoding[0] != 'C')) {
        return NO;
    }

    BOOL normalized = value ? YES : NO;
    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    memcpy(bytes + ivar_getOffset(ivar), &normalized, sizeof(normalized));
    return YES;
}

static BOOL SCIWriteIntegerIvar(id object, const char *name, NSInteger value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;

    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding || (encoding[0] != 'q' && encoding[0] != 'Q')) return NO;

    uint8_t *bytes = (uint8_t *)(__bridge void *)object;
    memcpy(bytes + ivar_getOffset(ivar), &value, sizeof(value));
    return YES;
}

static UITableView *SCIBugMenuTableView(id controller) {
    if (!controller) return nil;
    Ivar ivar = class_getInstanceVariable([controller class], "tableView");
    if (!ivar) ivar = class_getInstanceVariable([controller class], "_tableView");
    if (!ivar) return nil;
    id value = object_getIvar(controller, ivar);
    return [value isKindOfClass:UITableView.class] ? value : nil;
}
