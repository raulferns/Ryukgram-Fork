#import "SCIDogfoodObjectRuntime.h"
#import "SCIDogfooding.h"
#import "SCILauncherOverride.h"
#import "SCIDogfoodStubRuntime.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSMapTable<id, NSMutableDictionary *> *sSCIObjMeta;
static NSMutableArray<NSDictionary *> *sSCIRecentActions;
static NSMutableArray<NSDictionary *> *sSCIDogfoodingSettingChanges;
static dispatch_queue_t sSCIQueue;
static BOOL sSCIInstalled;
static __weak id sSCICapturedUserSession;
static __weak id sSCICapturedDogfoodSettingsConfig;
static NSTimeInterval sSCILastUserSessionNote;

static NSString *SCISafeString(id v) {
    if (!v || v == (id)kCFNull) return @"";
    @try { return [[v description] copy] ?: @""; } @catch (__unused id e) { return @"<exception>"; }
}

static NSString *SCIAddr(id obj) { return obj ? [NSString stringWithFormat:@"%p", obj] : @""; }

static BOOL SCIClassNameContains(id obj, NSString *needle) {
    if (!obj || !needle.length) return NO;
    NSString *name = NSStringFromClass(object_getClass(obj)) ?: @"";
    return [name containsString:needle];
}

static UIViewController *SCIPresentationAnchor(UIViewController *vc) {
    if (!vc) return nil;
    UIViewController *top = vc;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) return ((UINavigationController *)top).topViewController ?: top;
    if ([top isKindOfClass:UITabBarController.class]) return ((UITabBarController *)top).selectedViewController ?: top;
    return top;
}

static NSArray<NSString *> *SCIInterestingIvarNames(void) {
    static NSArray *a; static dispatch_once_t once; dispatch_once(&once, ^{
        a = @[@"_launcherSet", @"launcherSet", @"_logger", @"logger", @"_networker", @"networker", @"_emptyContext", @"emptyContext",
              @"_sessionID", @"sessionID", @"_userID", @"userID", @"_user", @"user", @"_userSession", @"userSession",
              @"_config", @"config", @"_tableView", @"tableView", @"_itemOverrides", @"itemOverrides", @"_needsReload", @"needsReload",
              @"_userCallbacks", @"_globalUserCallbacks", @"_emergencyPushObj", @"_sections", @"sections", @"_items", @"items",
              @"_options", @"options", @"_overrideOptions", @"overrideOptions", @"_item", @"item", @"_dataModel", @"dataModel",
              @"_viewModel", @"viewModel", @"_screen", @"screen", @"_screenView", @"screenView", @"_collectionView",
              @"collectionView", @"_session", @"session", @"_scopedNetworker", @"scopedNetworker", @"_mobileConfig", @"mobileConfig",
              @"_settings", @"settings", @"permissionsMessagingControlCache", @"permissionsFeatureControlCache"];
    }); return a;
}

static BOOL SCIShouldFollowChildren(id object, NSString *role, NSString *source) {
    NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", NSStringFromClass(object_getClass(object)) ?: @"", role ?: @"", source ?: @""];
    NSString *low = hay.lowercaseString;
    if ([low containsString:@"getbool:"] || [low containsString:@"getstring:"] || [low containsString:@"getint64:"] || [low containsString:@"getdouble:"]) return NO;
    return [low containsString:@"dogfood"] || [low containsString:@"autofill"] || [low containsString:@"usersession"] ||
           [low containsString:@"launcher"] || [low containsString:@"settings"] || [low containsString:@"notes"] ||
           [low containsString:@"mobileconfigusersessioncontextmanager"] || [low containsString:@"foausersession"];
}

static BOOL SCIIsObjectEncoding(const char *enc) { return enc && enc[0] == '@'; }
static BOOL SCIIsNativeEncoding(const char *enc) {
    if (!enc) return NO; NSString *s = [NSString stringWithUTF8String:enc];
    return [s containsString:@"shared_ptr"] || [s containsString:@"weak_ptr"] || [s containsString:@"unordered_map"] || [s containsString:@"mutex"] || [s containsString:@"atomic"] || [s containsString:@"unique_ptr"];
}

static Ivar SCIFindIvar(Class cls, const char *name) {
    for (Class c = cls; c; c = class_getSuperclass(c)) { Ivar iv = class_getInstanceVariable(c, name); if (iv) return iv; }
    return NULL;
}

static id SCIObjIvar(id obj, const char *name) {
    if (!obj || !name) return nil; Ivar iv = SCIFindIvar(object_getClass(obj), name); if (!iv) return nil;
    if (!SCIIsObjectEncoding(ivar_getTypeEncoding(iv))) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused id e) { return nil; }
}

static id SCIPrimitiveIvarValue(id obj, Ivar iv) {
    if (!obj || !iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc) return nil;
    ptrdiff_t off = ivar_getOffset(iv);
    uint8_t *base = (__bridge void *)obj;
    @try {
        switch (enc[0]) {
            case 'B': return @(*(BOOL *)(base + off));
            case 'c': return @(*(char *)(base + off));
            case 'C': return @(*(unsigned char *)(base + off));
            case 's': return @(*(short *)(base + off));
            case 'S': return @(*(unsigned short *)(base + off));
            case 'i': return @(*(int *)(base + off));
            case 'I': return @(*(unsigned int *)(base + off));
            case 'l': return @(*(long *)(base + off));
            case 'L': return @(*(unsigned long *)(base + off));
            case 'q': return @(*(long long *)(base + off));
            case 'Q': return @(*(unsigned long long *)(base + off));
            case 'f': return @(*(float *)(base + off));
            case 'd': return @(*(double *)(base + off));
            default: return nil;
        }
    } @catch (__unused id e) {
        return nil;
    }
}


static id SCICallSelectorNoArg(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(obj, sel); } @catch (__unused id e) { return nil; }
}

static id SCIValueForCandidate(id obj, NSArray<NSString *> *candidates) {
    if (!obj) return nil;
    for (NSString *name in candidates) {
        id v = SCICallSelectorNoArg(obj, name);
        if (v) return v;
        NSString *ivarName = [name hasPrefix:@"_"] ? name : [@"_" stringByAppendingString:name];
        v = SCIObjIvar(obj, ivarName.UTF8String);
        if (v) return v;
        v = SCIObjIvar(obj, name.UTF8String);
        if (v) return v;
    }
    return nil;
}

static NSString *SCIPrimitiveStringCandidate(id obj, NSArray<NSString *> *candidates) {
    if (!obj) return nil;
    for (NSString *name in candidates) {
        for (NSString *ivarName in @[name, [name hasPrefix:@"_"] ? [name substringFromIndex:1] : [@"_" stringByAppendingString:name]]) {
            Ivar iv = SCIFindIvar(object_getClass(obj), ivarName.UTF8String);
            id v = SCIPrimitiveIvarValue(obj, iv);
            if (v) return [v description];
        }
    }
    return nil;
}

static NSString *SCIStringCandidate(id obj, NSArray<NSString *> *candidates) {
    id v = SCIValueForCandidate(obj, candidates);
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) {
        NSString *sv = nil; @try { sv = [v stringValue]; } @catch (__unused id e) {}
        if (sv.length) return sv;
    }
    NSString *d = SCISafeString(v);
    return d.length ? d : nil;
}

static id SCIDogfoodValueCandidate(id item, id options, id toggleValue) {
    if (toggleValue) return toggleValue;
    id v = SCIValueForCandidate(options, @[@"value", @"selectedValue", @"currentValue", @"optionValue", @"parameterValue", @"overrideValue", @"enabled", @"isEnabled"]);
    if (v) return v;
    v = SCIValueForCandidate(item, @[@"value", @"defaultValue", @"selectedValue", @"currentValue", @"optionValue", @"parameterValue", @"overrideValue", @"enabled", @"isEnabled"]);
    return v;
}

static NSDictionary *SCIDogfoodPersistenceDescriptor(id item, id options, id toggleValue, NSString *source) {
    NSString *launcher = SCIStringCandidate(item, @[@"launcherName", @"launcher", @"launcherID", @"launcherId", @"gatekeeper", @"owner", @"configName"]);
    if (!launcher.length) launcher = SCIStringCandidate(options, @[@"launcherName", @"launcher", @"launcherID", @"launcherId", @"gatekeeper", @"owner", @"configName"]);
    NSString *parameter = SCIStringCandidate(item, @[@"parameterName", @"paramName", @"parameter", @"param", @"key", @"name", @"identifier", @"stableID", @"stableId"]);
    if (!parameter.length) parameter = SCIStringCandidate(options, @[@"parameterName", @"paramName", @"parameter", @"param", @"key", @"name", @"identifier", @"stableID", @"stableId"]);
    id value = SCIDogfoodValueCandidate(item, options, toggleValue);

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"time"] = @(NSDate.date.timeIntervalSince1970);
    d[@"source"] = source ?: @"";
    d[@"itemClass"] = item ? NSStringFromClass(object_getClass(item)) : @"";
    d[@"itemAddress"] = SCIAddr(item);
    d[@"item"] = SCISafeString(item);
    d[@"optionsClass"] = options ? NSStringFromClass(object_getClass(options)) : @"";
    d[@"optionsAddress"] = SCIAddr(options);
    d[@"options"] = SCISafeString(options);
    if (launcher.length) d[@"launcher"] = launcher;
    if (parameter.length) d[@"parameter"] = parameter;
    if (value) d[@"value"] = SCISafeString(value);
    d[@"valueClass"] = value ? NSStringFromClass(object_getClass(value)) : @"";
    d[@"canReplayLauncherOverride"] = @((launcher.length && parameter.length && value) ? YES : NO);
    return d;
}

static void SCISaveDogfoodingSettingChanges(void) {
    [[NSUserDefaults standardUserDefaults] setObject:sSCIDogfoodingSettingChanges ?: @[] forKey:@"sci_dogfooding_setting_changes"];
}

static void SCIEnsureStore(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{
        sSCIObjMeta = [NSMapTable weakToStrongObjectsMapTable];
        sSCIRecentActions = [NSMutableArray new];
        id saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"sci_dogfooding_setting_changes"];
        sSCIDogfoodingSettingChanges = [saved isKindOfClass:NSArray.class] ? [saved mutableCopy] : [NSMutableArray new];
        sSCIQueue = dispatch_queue_create("com.ryukgram.dogfood.object.runtime", DISPATCH_QUEUE_SERIAL);
    });
}

static NSArray *SCIMethodNames(Class cls, BOOL meta, NSUInteger limit) {
    if (!cls) return @[]; Class target = meta ? object_getClass(cls) : cls; unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count); NSMutableArray *out = [NSMutableArray array];
    for (unsigned int i = 0; methods && i < count && out.count < limit; i++) {
        SEL sel = method_getName(methods[i]); if (!sel) continue; NSString *n = NSStringFromSelector(sel);
        if (n.length) [out addObject:n];
    }
    if (methods) free(methods); return [out copy];
}

static NSArray *SCIPropertyNames(Class cls, NSUInteger limit) {
    if (!cls) return @[]; NSMutableArray *out = [NSMutableArray array];
    for (Class c = cls; c && out.count < limit; c = class_getSuperclass(c)) {
        unsigned int count = 0; objc_property_t *props = class_copyPropertyList(c, &count);
        for (unsigned int i = 0; props && i < count && out.count < limit; i++) {
            const char *n = property_getName(props[i]); const char *attrs = property_getAttributes(props[i]);
            if (n) [out addObject:@{ @"name": @(n), @"attrs": attrs ? @(attrs) : @"" }];
        }
        if (props) free(props);
    }
    return [out copy];
}

static NSArray *SCIProtocolSummaries(Class cls, NSUInteger limit) {
    if (!cls) return @[]; unsigned int count = 0; Protocol *__unsafe_unretained *ps = class_copyProtocolList(cls, &count);
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned int i = 0; ps && i < count && out.count < limit; i++) {
        const char *n = protocol_getName(ps[i]); if (!n) continue;
        NSMutableDictionary *d = [@{ @"name": @(n) } mutableCopy];
        unsigned int mc = 0; struct objc_method_description *req = protocol_copyMethodDescriptionList(ps[i], YES, YES, &mc);
        NSMutableArray *ms = [NSMutableArray array];
        for (unsigned int j = 0; req && j < mc && ms.count < 50; j++) if (req[j].name) [ms addObject:NSStringFromSelector(req[j].name)];
        if (req) free(req); d[@"requiredInstanceMethods"] = ms;
        [out addObject:d];
    }
    if (ps) free(ps); return out;
}

static NSArray *SCIIvarSummaries(id obj, NSUInteger limit, BOOL follow) {
    if (!obj) return @[]; NSMutableArray *out = [NSMutableArray array]; Class cls = object_getClass(obj);
    for (Class c = cls; c && out.count < limit; c = class_getSuperclass(c)) {
        unsigned int count = 0; Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; ivars && i < count && out.count < limit; i++) {
            Ivar iv = ivars[i]; const char *n = ivar_getName(iv); const char *enc = ivar_getTypeEncoding(iv); ptrdiff_t off = ivar_getOffset(iv);
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"name"] = n ? @(n) : @""; d[@"type"] = enc ? @(enc) : @""; d[@"offset"] = @(off);
            if (SCIIsObjectEncoding(enc)) {
                id val = nil; @try { val = object_getIvar(obj, iv); } @catch (__unused id e) {}
                if (val) {
                    d[@"valueClass"] = NSStringFromClass(object_getClass(val)) ?: @""; d[@"valueAddress"] = SCIAddr(val); d[@"valueDescription"] = SCISafeString(val);
                    if (follow) {
                        NSString *nm = n ? [NSString stringWithUTF8String:n] : @"ivar";
                        if ([[SCIInterestingIvarNames() valueForKey:@"lowercaseString"] containsObject:nm.lowercaseString]) {
                            [SCIDogfoodObjectRuntime noteObject:val role:nm source:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), nm]];
                        }
                    }
                } else d[@"valueDescription"] = @"nil";
            } else if (SCIIsNativeEncoding(enc)) {
                d[@"valueDescription"] = @"native C++ ivar present; not dereferenced directly";
            } else {
                id primitive = SCIPrimitiveIvarValue(obj, iv);
                d[@"valueDescription"] = primitive ? [primitive description] : @"non-object ivar";
            }
            [out addObject:d];
        }
        if (ivars) free(ivars);
    }
    return [out copy];
}

static NSDictionary *SCISnapshot(id obj, NSDictionary *meta) {
    if (!obj) return @{}; Class cls = object_getClass(obj); NSString *clsName = NSStringFromClass(cls) ?: @"";
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = clsName; d[@"address"] = SCIAddr(obj); d[@"description"] = SCISafeString(obj);
    d[@"roles"] = meta[@"roles"] ?: @[]; d[@"sources"] = meta[@"sources"] ?: @[]; d[@"firstSeen"] = meta[@"firstSeen"] ?: @0; d[@"lastSeen"] = meta[@"lastSeen"] ?: @0;
    id session = SCIObjIvar(obj, "_sessionID"); if (session) d[@"sessionID"] = SCISafeString(session);
    if (!session) session = SCIValueForCandidate(obj, @[@"sessionID", @"_sessionID"]);
    if (session) d[@"sessionID"] = SCISafeString(session);
    id userID = SCIValueForCandidate(obj, @[@"userID", @"userId", @"pk", @"fbid", @"_userID"]);
    NSString *userIDString = SCIStringCandidate(userID, @[@"userID", @"userId", @"pk"]);
    if (!userIDString.length) userIDString = SCIStringCandidate(obj, @[@"userID", @"userId", @"pk", @"fbid", @"_userID"]);
    if (userIDString.length) d[@"userID"] = userIDString;
    NSString *isEmployee = SCIPrimitiveStringCandidate(obj, @[@"_isEmployee", @"isEmployee"]);
    if (isEmployee.length) d[@"isEmployee"] = isEmployee;
    id user = SCIValueForCandidate(obj, @[@"user", @"_user"]);
    if (user) d[@"user"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(user)), SCIAddr(user)];
    id userSession = SCIValueForCandidate(obj, @[@"userSession", @"_userSession"]);
    if (userSession) d[@"userSession"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(userSession)), SCIAddr(userSession)];
    id config = SCIValueForCandidate(obj, @[@"config", @"_config"]);
    if (config) d[@"config"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(config)), SCIAddr(config)];
    id launcher = SCIValueForCandidate(obj, @[@"launcherSet", @"_launcherSet"]);
    if (launcher) d[@"launcherSet"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(launcher)), SCIAddr(launcher)];
    id mc = nil; if ([obj respondsToSelector:@selector(mc)]) { @try { mc = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(mc)); } @catch (__unused id e) {} }
    if (mc) d[@"mc"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(mc)), SCIAddr(mc)];
    d[@"methods"] = SCIMethodNames(cls, NO, 160); d[@"classMethods"] = SCIMethodNames(cls, YES, 120); d[@"properties"] = SCIPropertyNames(cls, 120); d[@"protocols"] = SCIProtocolSummaries(cls, 40); d[@"ivars"] = SCIIvarSummaries(obj, 90, YES);
    return d;
}


static NSDictionary *SCILightSnapshot(id obj, NSDictionary *meta) {
    if (!obj) return @{};
    Class cls = object_getClass(obj);
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = NSStringFromClass(cls) ?: @"";
    d[@"address"] = SCIAddr(obj);
    d[@"description"] = SCISafeString(obj);
    d[@"roles"] = meta[@"roles"] ?: @[];
    d[@"sources"] = meta[@"sources"] ?: @[];
    d[@"firstSeen"] = meta[@"firstSeen"] ?: @0;
    d[@"lastSeen"] = meta[@"lastSeen"] ?: @0;
    id session = SCIObjIvar(obj, "_sessionID") ?: SCIValueForCandidate(obj, @[@"sessionID", @"_sessionID"]);
    if (session) d[@"sessionID"] = SCISafeString(session);
    NSString *userIDString = SCIStringCandidate(obj, @[@"userID", @"userId", @"pk", @"fbid", @"_userID"]);
    if (userIDString.length) d[@"userID"] = userIDString;
    id launcher = SCIValueForCandidate(obj, @[@"launcherSet", @"_launcherSet"]);
    if (launcher) d[@"launcherSet"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(launcher)), SCIAddr(launcher)];
    id userSession = SCIValueForCandidate(obj, @[@"userSession", @"_userSession"]);
    if (userSession) d[@"userSession"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(userSession)), SCIAddr(userSession)];
    id mc = nil; if ([obj respondsToSelector:@selector(mc)]) { @try { mc = ((id(*)(id,SEL))objc_msgSend)(obj, @selector(mc)); } @catch (__unused id e) {} }
    if (mc) d[@"mc"] = [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(mc)), SCIAddr(mc)];
    NSArray *ivars = SCIIvarSummaries(obj, 24, NO);
    d[@"ivars"] = ivars ?: @[];
    return d;
}

@implementation SCIDogfoodObjectRuntime

+ (void)installIfNeeded { SCIEnsureStore(); sSCIInstalled = YES; }

+ (void)noteObject:(id)object role:(NSString *)role source:(NSString *)source {
    if (!object) return;
    SCIEnsureStore();
    if (SCIClassNameContains(object, @"IGDogfoodingSettingsConfig")) sSCICapturedDogfoodSettingsConfig = object;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    @synchronized (sSCIObjMeta) {
        NSMutableDictionary *m = [sSCIObjMeta objectForKey:object];
        BOOL first = NO;
        if (!m) {
            first = YES;
            m = [@{ @"roles": [NSMutableArray array], @"sources": [NSMutableArray array], @"firstSeen": @(now), @"lastDeepScan": @0 } mutableCopy];
            [sSCIObjMeta setObject:m forKey:object];
        } else {
            NSTimeInterval last = [m[@"lastSeen"] doubleValue];
            if ((now - last) < 0.75) {
                NSMutableArray *roles = m[@"roles"];
                NSMutableArray *sources = m[@"sources"];
                if (role.length && ![roles containsObject:role]) [roles addObject:role];
                if (source.length && ![sources containsObject:source]) [sources addObject:source];
                return;
            }
        }
        m[@"lastSeen"] = @(now);
        NSMutableArray *roles = m[@"roles"];
        if (role.length && ![roles containsObject:role]) [roles addObject:role];
        NSMutableArray *sources = m[@"sources"];
        if (source.length && ![sources containsObject:source]) [sources addObject:source];

        if (!SCIShouldFollowChildren(object, role, source)) return;
        NSTimeInterval lastDeep = [m[@"lastDeepScan"] doubleValue];
        if (!first && (now - lastDeep) < 30.0) return;
        m[@"lastDeepScan"] = @(now);
        for (NSString *ivarName in SCIInterestingIvarNames()) {
            id child = SCIObjIvar(object, ivarName.UTF8String); if (!child) continue;
            NSString *childRole = [ivarName hasPrefix:@"_"] ? [ivarName substringFromIndex:1] : ivarName;
            NSMutableDictionary *cm = [sSCIObjMeta objectForKey:child];
            if (!cm) { cm = [@{ @"roles": [NSMutableArray array], @"sources": [NSMutableArray array], @"firstSeen": @(now), @"lastDeepScan": @0 } mutableCopy]; [sSCIObjMeta setObject:cm forKey:child]; }
            cm[@"lastSeen"] = @(now);
            NSMutableArray *cr = cm[@"roles"]; if (![cr containsObject:childRole]) [cr addObject:childRole];
            NSMutableArray *cs = cm[@"sources"]; NSString *src = [NSString stringWithFormat:@"%@.%@", NSStringFromClass(object_getClass(object)), ivarName]; if (![cs containsObject:src]) [cs addObject:src];
        }
    }
}

+ (void)noteLiveUserSession:(id)session source:(NSString *)source {
    if (!session) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (sSCICapturedUserSession == session && (now - sSCILastUserSessionNote) < 20.0) return;
    sSCICapturedUserSession = session;
    sSCILastUserSessionNote = now;
    [self noteObject:session role:@"activeUserSession" source:source ?: @"IGUserSession capture"];
}

+ (void)noteDogfoodConfig:(id)config userSession:(id)session source:(NSString *)source {
    if (config) {
        sSCICapturedDogfoodSettingsConfig = config;
        [self noteObject:config role:@"IGDogfoodingSettingsConfig" source:source ?: @"dogfood config capture"];
    }
    if (session) [self noteLiveUserSession:session source:source ?: @"dogfood config capture"];
}

+ (void)noteSettingsObject:(id)object role:(NSString *)role source:(NSString *)source { [self noteObject:object role:role ?: @"settings" source:source]; }

+ (void)noteAction:(NSString *)action status:(NSString *)status detail:(id)detail {
    SCIEnsureStore(); if (!action.length) return;
    NSDictionary *d = @{ @"time": @(NSDate.date.timeIntervalSince1970), @"action": action, @"status": status ?: @"", @"detail": detail ? SCISafeString(detail) : @"" };
    @synchronized (sSCIRecentActions) {
        [sSCIRecentActions insertObject:d atIndex:0];
        while (sSCIRecentActions.count > 80) [sSCIRecentActions removeLastObject];
    }
}


+ (void)noteDogfoodingSettingChangeWithItem:(id)item options:(id)options toggleValue:(id)toggleValue source:(NSString *)source {
    SCIEnsureStore();
    if (item) [self noteObject:item role:@"IGDogfoodingSettingsItem" source:source ?: @"dogfooding setting change"];
    if (options) [self noteObject:options role:@"IGDogfoodingSettingsOptions" source:source ?: @"dogfooding setting change"];
    NSDictionary *descriptor = SCIDogfoodPersistenceDescriptor(item, options, toggleValue, source);
    @synchronized (sSCIDogfoodingSettingChanges) {
        [sSCIDogfoodingSettingChanges insertObject:descriptor atIndex:0];
        while (sSCIDogfoodingSettingChanges.count > 120) [sSCIDogfoodingSettingChanges removeLastObject];
        SCISaveDogfoodingSettingChanges();
    }
    if ([descriptor[@"canReplayLauncherOverride"] boolValue]) {
        NSString *launcher = descriptor[@"launcher"];
        NSString *parameter = descriptor[@"parameter"];
        id rawValue = toggleValue ?: SCIDogfoodValueCandidate(item, options, nil);
        if (!rawValue && descriptor[@"value"]) rawValue = descriptor[@"value"];
        [SCILauncherOverride persistLauncher:launcher parameter:parameter value:rawValue ?: @YES];
        [self noteAction:@"Notes Dogfooding persistence" status:@"captured launcher override" detail:descriptor];
    } else {
        [self noteAction:@"Notes Dogfooding persistence" status:@"captured snapshot only" detail:descriptor];
    }
}

+ (NSArray<NSDictionary *> *)dogfoodingSettingChanges {
    SCIEnsureStore(); @synchronized (sSCIDogfoodingSettingChanges) { return [sSCIDogfoodingSettingChanges copy] ?: @[]; }
}

+ (UIViewController *)topViewController {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { key = w; break; }
        if (key) break;
    }
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    if ([top isKindOfClass:UINavigationController.class]) top = ((UINavigationController *)top).topViewController ?: top;
    if ([top isKindOfClass:UITabBarController.class]) top = ((UITabBarController *)top).selectedViewController ?: top;
    if (top) [self noteObject:top role:@"topViewController" source:@"SCIDogfoodObjectRuntime.topViewController"];
    return top;
}

+ (id)activeUserSession { id s = [SCIUtils activeUserSession] ?: sSCICapturedUserSession; if (s) [self noteObject:s role:@"activeUserSession" source:(s == sSCICapturedUserSession ? @"captured userID" : @"SCIUtils.activeUserSession")]; return s; }

static Class SCIFindSwiftClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (c) return c;
    c = objc_getClass(name.UTF8String);
    if (c) return c;
    NSString *dotPrefixed = [NSString stringWithFormat:@"IGDogfoodingSettings.%@", name];
    c = NSClassFromString(dotPrefixed);
    if (c) return c;
    NSString *mangled = [NSString stringWithFormat:@"_TtC20IGDogfoodingSettings%lu%@", (unsigned long)name.length, name];
    c = NSClassFromString(mangled);
    if (c) return c;
    c = objc_getClass(mangled.UTF8String);
    if (c) return c;
    return Nil;
}

+ (void)dumpAllDogfoodingClasses {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableArray *results = [NSMutableArray array];
        
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            NSString *className = NSStringFromClass(cls);
            if ([className containsString:@"DogfoodingSettings"] || [className containsString:@"DogfoodingSettingsConfig"] || [className containsString:@"DogfoodingSettingsSection"] || [className containsString:@"DogfoodingSettingsItem"] || [className containsString:@"DogfoodingSettingsOptions"]) {
                
                NSMutableArray *methodsArray = [NSMutableArray array];
                unsigned int mc = 0;
                Method *methods = class_copyMethodList(cls, &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    [methodsArray addObject:NSStringFromSelector(method_getName(methods[j]))];
                }
                if (methods) free(methods);
                
                NSMutableArray *classMethodsArray = [NSMutableArray array];
                Method *classMethods = class_copyMethodList(object_getClass(cls), &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    [classMethodsArray addObject:NSStringFromSelector(method_getName(classMethods[j]))];
                }
                if (classMethods) free(classMethods);

                NSMutableArray *propertiesArray = [NSMutableArray array];
                objc_property_t *properties = class_copyPropertyList(cls, &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    [propertiesArray addObject:[NSString stringWithUTF8String:property_getName(properties[j])]];
                }
                if (properties) free(properties);

                NSMutableArray *ivarsArray = [NSMutableArray array];
                Ivar *ivarList = class_copyIvarList(cls, &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    const char *name = ivar_getName(ivarList[j]);
                    const char *type = ivar_getTypeEncoding(ivarList[j]);
                    ptrdiff_t offset = ivar_getOffset(ivarList[j]);
                    [ivarsArray addObject:@{
                        @"name": name ? @(name) : @"",
                        @"type": type ? @(type) : @"",
                        @"offset": @(offset)
                    }];
                }
                if (ivarList) free(ivarList);

                Class superclass = class_getSuperclass(cls);
                NSDictionary *d = @{
                    @"class": className,
                    @"superclass": superclass ? NSStringFromClass(superclass) : @"None",
                    @"methods": methodsArray,
                    @"classMethods": classMethodsArray,
                    @"properties": propertiesArray,
                    @"ivars": ivarsArray
                };
                [results addObject:d];
                [self noteAction:@"dump-dogfooding" status:className detail:d];
            }
        }
        if (classes) free(classes);
        
        @try {
            NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *filePath = [docPath stringByAppendingPathComponent:@"ryukgram_dogfooding_dump.json"];
            NSData *data = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToFile:filePath atomically:YES];
            NSLog(@"[RyukGram] Dumped %lu dogfooding classes to %@", (unsigned long)results.count, filePath);
        } @catch (id ex) {
            NSLog(@"[RyukGram] Failed to write dump file: %@", ex);
        }
    });
}

static void SCISafeSetIvar(id obj, NSString *propName, ptrdiff_t offset, id value) {
    if (!obj) return;
    @try {
        [obj setValue:value forKey:propName];
    } @catch (id ex) {
        void **ptr = (void **)((char *)(__bridge void *)obj + offset);
        *ptr = (__bridge_retained void *)value;
    }
}

+ (id)bestDogfoodSettingsConfig {
    [self dumpAllDogfoodingClasses];
    id cfg = sSCICapturedDogfoodSettingsConfig;
    if (cfg) {
        [self noteObject:cfg role:@"IGDogfoodingSettingsConfig" source:@"bestDogfoodSettingsConfig.weak-cache"];
        return cfg;
    }
    cfg = [self liveInstanceOfClassNameContaining:@"IGDogfoodingSettingsConfig"];
    if (cfg) {
        sSCICapturedDogfoodSettingsConfig = cfg;
        [self noteObject:cfg role:@"IGDogfoodingSettingsConfig" source:@"bestDogfoodSettingsConfig.live-object-graph"];
        return cfg;
    }
    
    Class configCls = SCIFindSwiftClass(@"IGDogfoodingSettingsConfig");
    Class sectionCls = SCIFindSwiftClass(@"IGDogfoodingSettingsSection");
    Class itemCls = SCIFindSwiftClass(@"IGDogfoodingSettingsItem");
    
    if (configCls && sectionCls && itemCls) {
        @try {
            id item1 = [[itemCls alloc] init];
            SCISafeSetIvar(item1, @"title", 16, @"Toggle FLEX");
            SCISafeSetIvar(item1, @"value", 32, @YES);
            
            id item2 = [[itemCls alloc] init];
            SCISafeSetIvar(item2, @"title", 16, @"Logged Analytics Events");
            SCISafeSetIvar(item2, @"value", 32, @NO);
            
            id section = [[sectionCls alloc] init];
            SCISafeSetIvar(section, @"title", 16, @"FLEX & Analytics");
            SCISafeSetIvar(section, @"items", 24, @[item1, item2]);
            
            cfg = [[configCls alloc] init];
            SCISafeSetIvar(cfg, @"sections", 24, @[section]);
            
            if (cfg) {
                sSCICapturedDogfoodSettingsConfig = cfg;
                [self noteObject:cfg role:@"IGDogfoodingSettingsConfig" source:@"bestDogfoodSettingsConfig.fabricated_populated"];
                return cfg;
            }
        } @catch (id ex) {
            NSString *reason = [NSString stringWithFormat:@"Fabrication exception: %@", ex];
            [self noteAction:@"fabricate config" status:@"exception" detail:reason];
            NSLog(@"[RyukGram] %@", reason);
        }
    }
    return nil;
}

+ (id)bestDogfooder {
    __block id found = nil; SCIEnsureStore(); @synchronized (sSCIObjMeta) { NSEnumerator *e = [sSCIObjMeta keyEnumerator]; id obj = nil; while ((obj = [e nextObject])) { if ([NSStringFromClass(object_getClass(obj)) containsString:@"IGDogfooderProd"]) { found = obj; break; } } }
    if (found) [self noteObject:found role:@"bestDogfooder" source:@"bestDogfooder"];
    return found;
}

+ (id)bestLauncherSet {
    __block id found = nil; SCIEnsureStore(); @synchronized (sSCIObjMeta) {
        NSEnumerator *e = [sSCIObjMeta keyEnumerator]; id obj = nil; while ((obj = [e nextObject])) {
            NSString *cn = NSStringFromClass(object_getClass(obj));
            if ([cn containsString:@"IGMobileConfigUserSessionContextManager"] || [cn containsString:@"IGUserLauncherSet"]) { found = obj; break; }
            id ls = SCIValueForCandidate(obj, @[@"launcherSet", @"_launcherSet"]); if (ls) { found = ls; break; }
        }
    }
    if (found) [self noteObject:found role:@"bestLauncherSet" source:@"bestLauncherSet"];
    return found;
}

+ (nullable id)liveInstanceOfClass:(Class)cls {
    if (!cls) return nil;
    SCIEnsureStore();
    __block id found = nil;
    @synchronized (sSCIObjMeta) {
        NSEnumerator *e = [sSCIObjMeta keyEnumerator]; id obj = nil;
        while ((obj = [e nextObject])) {
            @try { if ([obj isKindOfClass:cls]) { found = obj; break; } } @catch (__unused id ex) {}
        }
    }
    return found;
}

+ (nullable id)liveInstanceOfClassNameContaining:(NSString *)needle {
    if (!needle.length) return nil;
    SCIEnsureStore();
    __block id found = nil;
    @synchronized (sSCIObjMeta) {
        NSEnumerator *e = [sSCIObjMeta keyEnumerator];
        id obj = nil;
        while ((obj = [e nextObject])) {
            @try {
                NSString *className = NSStringFromClass(object_getClass(obj));
                if ([className containsString:needle]) {
                    found = obj;
                    break;
                }
            } @catch (__unused id ex) {}
        }
    }
    return found;
}


+ (NSArray<NSDictionary *> *)runtimeStubsMatching:(NSString *)query limit:(NSUInteger)limit {
    return [SCIDogfoodStubRuntime stubsMatching:query limit:limit];
}

+ (NSDictionary *)detailsForRuntimeStubClass:(NSString *)className {
    return [SCIDogfoodStubRuntime detailsForClassName:className ?: @""];
}
+ (NSArray<NSDictionary *> *)liveObjectGraph {
    SCIEnsureStore();
    NSMutableArray *arr = [NSMutableArray array];
    @synchronized (sSCIObjMeta) {
        NSEnumerator *e = [sSCIObjMeta keyEnumerator];
        id obj = nil;
        while ((obj = [e nextObject])) {
            NSDictionary *m = [sSCIObjMeta objectForKey:obj];
            NSDictionary *snap = SCILightSnapshot(obj, m);
            if (snap.count) [arr addObject:snap];
        }
    }
    [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeInterval av = [a[@"lastSeen"] doubleValue];
        NSTimeInterval bv = [b[@"lastSeen"] doubleValue];
        if (bv > av) return NSOrderedDescending;
        if (bv < av) return NSOrderedAscending;
        return [SCISafeString(a[@"class"]) localizedCaseInsensitiveCompare:SCISafeString(b[@"class"])];
    }];
    if (arr.count > 220) return [[arr subarrayWithRange:NSMakeRange(0, 220)] copy];
    return [arr copy];
}

+ (NSArray<NSDictionary *> *)settingsInjectionTargets {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in [self liveObjectGraph]) {
        NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@", d[@"class"] ?: @"", d[@"roles"] ?: @[], d[@"ivars"] ?: @[], d[@"sources"] ?: @[]].lowercaseString;
        if ([hay containsString:@"settings2"] || [hay containsString:@"settings"] || [hay containsString:@"settingdata"] || [hay containsString:@"settingscreen"]) [out addObject:d];
    }
    return out;
}

+ (NSArray<NSDictionary *> *)recentActions { SCIEnsureStore(); @synchronized (sSCIRecentActions) { return [sSCIRecentActions copy] ?: @[]; } }

+ (NSDictionary *)runtimeState {
    UIViewController *top = [self topViewController];
    id session = [self activeUserSession];
    id launcher = [self bestLauncherSet];
    id cfg = [self bestDogfoodSettingsConfig];
    NSString *sessionUserID = session ? SCIStringCandidate(session, @[@"userID", @"userId", @"pk", @"fbid", @"_userID"]) : nil;
    return @{ @"topViewController": top ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(top)), SCIAddr(top)] : @"nil",
              @"activeUserSession": session ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(session)), SCIAddr(session)] : @"nil",
              @"activeUserID": sessionUserID ?: @"",
              @"bestLauncherSet": launcher ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(launcher)), SCIAddr(launcher)] : @"nil",
              @"bestDogfoodSettingsConfig": cfg ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(cfg)), SCIAddr(cfg)] : @"nil",
              @"liveObjects": @([self liveObjectGraph].count),
              @"settingsTargets": @([self settingsInjectionTargets].count) };
}

+ (NSDictionary *)dogfoodNativeState {
    Class launcher = NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettings") ?: NSClassFromString(@"_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    Class vc = NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettingsViewController") ?: NSClassFromString(@"_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController");
    SEL openSel = @selector(openWithConfig:onViewController:userSession:);
    SEL initSel = @selector(initWithConfig:userSession:);
    id cfg = [self bestDogfoodSettingsConfig];
    id session = [self activeUserSession];
    UIViewController *top = [self topViewController];
    return @{
        @"launcherClass": launcher ? NSStringFromClass(launcher) : @"nil",
        @"launcherRespondsOpenWithConfig": @((launcher && [launcher respondsToSelector:openSel]) ? YES : NO),
        @"viewControllerClass": vc ? NSStringFromClass(vc) : @"nil",
        @"viewControllerRespondsInitWithConfig": @((vc && [vc instancesRespondToSelector:initSel]) ? YES : NO),
        @"config": cfg ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(cfg)), SCIAddr(cfg)] : @"nil",
        @"session": session ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(session)), SCIAddr(session)] : @"nil",
        @"topViewController": top ? [NSString stringWithFormat:@"%@ %@", NSStringFromClass(object_getClass(top)), SCIAddr(top)] : @"nil"
    };
}

+ (NSDictionary *)fullSnapshot { return [self fullSnapshotIncludingDetails:NO]; }
+ (NSDictionary *)fullSnapshotIncludingDetails:(BOOL)includeDetails {
    NSArray *objs = [self liveObjectGraph];
    if (includeDetails) {
        NSMutableArray *rich = [NSMutableArray array];
        for (NSDictionary *d in objs) { NSDictionary *detail = [self detailsForObjectAddress:d[@"address"] ?: @""]; if (detail.count) [rich addObject:detail]; else [rich addObject:d]; if (rich.count >= 40) break; }
        objs = rich;
    }
    return @{ @"state": [self runtimeState], @"objects": objs ?: @[], @"settingsTargets": [self settingsInjectionTargets], @"dogfoodingSettingChanges": [self dogfoodingSettingChanges], @"actions": [self recentActions] };
}
+ (NSDictionary *)detailsForObjectAddress:(NSString *)address {
    if (!address.length) return @{}; SCIEnsureStore();
    @synchronized (sSCIObjMeta) {
        NSEnumerator *e = [sSCIObjMeta keyEnumerator]; id obj = nil;
        while ((obj = [e nextObject])) {
            if ([SCIAddr(obj) isEqualToString:address]) return SCISnapshot(obj, [sSCIObjMeta objectForKey:obj]);
        }
    }
    return @{};
}
+ (void)clear { SCIEnsureStore(); @synchronized (sSCIObjMeta) { [sSCIObjMeta removeAllObjects]; } @synchronized (sSCIRecentActions) { [sSCIRecentActions removeAllObjects]; } @synchronized (sSCIDogfoodingSettingChanges) { [sSCIDogfoodingSettingChanges removeAllObjects]; } [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"sci_dogfooding_setting_changes"]; }

+ (BOOL)tryOpenNotesDogfooding { [self noteAction:@"Open Notes Dogfooding" status:@"attempt" detail:[self runtimeState]]; @try { [SCIDogfooding presentNotesDogfoodingSettings]; [self noteAction:@"Open Notes Dogfooding" status:@"sent" detail:nil]; return YES; } @catch (id e) { [self noteAction:@"Open Notes Dogfooding" status:@"exception" detail:e]; return NO; } }
+ (BOOL)tryOpenMetaLocalExperimentBrowser { [self noteAction:@"Open MetaLocalExperiment" status:@"attempt" detail:[self runtimeState]]; @try { [SCIDogfooding presentMetaLocalExperimentBrowser]; [self noteAction:@"Open MetaLocalExperiment" status:@"sent" detail:nil]; return YES; } @catch (id e) { [self noteAction:@"Open MetaLocalExperiment" status:@"exception" detail:e]; return NO; } }

+ (BOOL)tryOpenNativeDogfoodSettings {
    UIViewController *top = SCIPresentationAnchor([self topViewController]);
    id session = [self activeUserSession];
    id cfg = [self bestDogfoodSettingsConfig];

    if (!top || !session) {
        [self noteAction:@"Open Native Dogfood Settings" status:@"missing top/session" detail:[self dogfoodNativeState]];
        return NO;
    }
    if (!cfg) {
        // The native Dogfooding Settings VC requires an IGDogfoodingSettingsConfig,
        // which is Swift-opaque (no constructible ObjC init) and is only built by IG
        // once the employee/internal gate is on. We cannot fabricate it. Until IG
        // builds one (and our capture observer stores it), fall back to the
        // config-free Notes dogfooding opener so the launcher still lands the user in
        // a real dogfood surface instead of failing.
        [self noteAction:@"Open Native Dogfood Settings" status:@"no captured config; falling back to Notes dogfooding" detail:[self dogfoodNativeState]];
        if ([self tryOpenNotesDogfooding]) return YES;
        [self noteAction:@"Open Native Dogfood Settings" status:@"missing native config" detail:[self dogfoodNativeState]];
        return NO;
    }

    Class launcher = NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettings") ?: NSClassFromString(@"_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    SEL openSel = @selector(openWithConfig:onViewController:userSession:);
    if (launcher && [launcher respondsToSelector:openSel]) {
        @try {
            ((void(*)(id,SEL,id,id,id))objc_msgSend)(launcher, openSel, cfg, top, session);
            [self noteAction:@"Open Native Dogfood Settings" status:@"sent openWithConfig" detail:[self dogfoodNativeState]];
            return YES;
        } @catch (id e) {
            [self noteAction:@"Open Native Dogfood Settings" status:@"openWithConfig exception" detail:e];
        }
    }

    Class vcCls = NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettingsViewController") ?: NSClassFromString(@"_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController");
    SEL initSel = @selector(initWithConfig:userSession:);
    if (vcCls && [vcCls isSubclassOfClass:UIViewController.class] && [vcCls instancesRespondToSelector:initSel]) {
        @try {
            UIViewController *vc = ((id(*)(id,SEL,id,id))objc_msgSend)([vcCls alloc], initSel, cfg, session);
            if (![vc isKindOfClass:UIViewController.class]) {
                [self noteAction:@"Open Native Dogfood Settings" status:@"init returned non-VC" detail:[self dogfoodNativeState]];
                return NO;
            }
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [top presentViewController:nav animated:YES completion:nil];
            [self noteAction:@"Open Native Dogfood Settings" status:@"presented initWithConfig" detail:[self dogfoodNativeState]];
            return YES;
        } @catch (id e) {
            [self noteAction:@"Open Native Dogfood Settings" status:@"initWithConfig exception" detail:e];
        }
    }

    [self noteAction:@"Open Native Dogfood Settings" status:@"unavailable" detail:[self dogfoodNativeState]];
    return NO;
}

+ (void)injectRowsIntoSettingsIfPossibleFromViewController:(UIViewController *)vc {
    if (!vc) return;
    NSString *cn = NSStringFromClass(object_getClass(vc)).lowercaseString;
    if (![cn containsString:@"settings"] && ![cn containsString:@"setting"]) return;
    [self noteSettingsObject:vc role:@"settingsVC" source:@"settings target observed"];
    // Deliberately do not draw the old floating RyukGram/Dogfood/Notes bar here.
    // It was visually wrong and it polluted Settings screens. The Auto-FLEX panel
    // now only records native Settings2/data-model targets; real row injection must
    // be added once a stable Settings2 row factory is confirmed.
    [self noteAction:@"Settings target observed" status:@"no overlay injected" detail:NSStringFromClass(object_getClass(vc))];
}

+ (void)sciOpenDogfoodFromInjectedRow { [self tryOpenNativeDogfoodSettings]; }
+ (void)sciOpenNotesFromInjectedRow { [self tryOpenNotesDogfooding]; }
+ (void)sciOpenRyukSettingsFromInjectedRow { UIWindow *w = UIApplication.sharedApplication.keyWindow; if (w) [SCIUtils showSettingsVC:w]; }

@end
