#import "RYGMobileConfig.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>

// Native MobileConfig path authority.
//
// Binary evidence from the 2026-08-23 Instagram/FBShared pair:
//
// FBSharedFramework:
//   -FBMobileConfigContextManager getOverridesTablePath @16@0:8
//   -IGMobileConfigContextManager getOverridesTablePath @16@0:8
//
// Instagram executable:
//   +[FBMobileConfigFBTGlobalSessionManager sharedInstance] @16@0:8
//   -currentSessionContextManagerHolder                    @16@0:8
//   -[FBMobileConfigFBTContextManagerHolder mcFbtManager]  @16@0:8
//   -[FBMobileConfigFBTContextManager mobileconfig]        @16@0:8
//
// This gives us the ACTIVE session's native MobileConfig context manager with
// no App Group guessing and no cold-launch getter hook. The one-shot getBool:
// observer below is only an on-demand fallback when the FBT session chain has
// not been initialized yet.

static os_unfair_lock gRYGMCNativeAuthorityLock = OS_UNFAIR_LOCK_INIT;
static id gRYGMCObservedManager;
static IMP gRYGMCCaptureFBUpstream;
static IMP gRYGMCCaptureIGUpstream;
static BOOL gRYGMCCaptureFBInstalled;
static BOOL gRYGMCCaptureIGInstalled;

static const char *RYGMCUnqualifiedType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RYGMCObjectNoArgMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    const char *type = RYGMCUnqualifiedType(ret);
    return type && *type == '@';
}

static id RYGMCCallObjectNoArg(id receiver, BOOL classMethod, const char *selectorName) {
    if (!receiver || !selectorName) return nil;
    SEL selector = sel_registerName(selectorName);
    Method method = classMethod
        ? class_getClassMethod((Class)receiver, selector)
        : class_getInstanceMethod([receiver class], selector);
    if (!RYGMCObjectNoArgMethod(method)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static BOOL RYGMCGetterMethodLooksCompatible(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char ret[32] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    const char *returnType = RYGMCUnqualifiedType(ret);
    if (!returnType || !strchr("BcC", *returnType)) return NO;
    char arg[96] = {0};
    method_getArgumentType(method, 2, arg, sizeof(arg));
    const char *argumentType = RYGMCUnqualifiedType(arg);
    if (!argumentType || !*argumentType) return NO;
    if (*argumentType == 'Q' || *argumentType == 'q') return YES;
    return *argumentType == '{' && (strstr(argumentType, "=Q}") || strstr(argumentType, "=q}"));
}

static BOOL RYGMCPathMethodLooksCompatible(Method method) {
    return RYGMCObjectNoArgMethod(method);
}

static void RYGMCRetainObservedManager(id manager) {
    if (!manager) return;
    os_unfair_lock_lock(&gRYGMCNativeAuthorityLock);
    gRYGMCObservedManager = manager;
    os_unfair_lock_unlock(&gRYGMCNativeAuthorityLock);
}

static id RYGMCCurrentObservedManager(void) {
    os_unfair_lock_lock(&gRYGMCNativeAuthorityLock);
    id manager = gRYGMCObservedManager;
    os_unfair_lock_unlock(&gRYGMCNativeAuthorityLock);
    return manager;
}

static id RYGMCActiveSessionContextManager(void) {
    Class globalClass = objc_lookUpClass("FBMobileConfigFBTGlobalSessionManager");
    if (!globalClass) return nil;
    id global = RYGMCCallObjectNoArg((id)globalClass, YES, "sharedInstance");
    if (!global) return nil;
    id holder = RYGMCCallObjectNoArg(global, NO, "currentSessionContextManagerHolder");
    if (!holder) return nil;
    id fbtManager = RYGMCCallObjectNoArg(holder, NO, "mcFbtManager");
    if (!fbtManager) return nil;
    id manager = RYGMCCallObjectNoArg(fbtManager, NO, "mobileconfig");
    if (!manager) return nil;
    Method pathMethod = class_getInstanceMethod([manager class], sel_registerName("getOverridesTablePath"));
    return RYGMCPathMethodLooksCompatible(pathMethod) ? manager : nil;
}

static void RYGMCUninstallCapture(Class cls, SEL selector, IMP wrapper, IMP upstream, BOOL *installedFlag) {
    if (!cls || !selector || !upstream) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (method && method_getImplementation(method) == wrapper)
        (void)method_setImplementation(method, upstream);
    if (installedFlag) *installedFlag = NO;
}

static BOOL RYGMCCaptureFBGetBool(id self, SEL cmd, unsigned long long pid) {
    RYGMCRetainObservedManager(self);
    IMP upstream = gRYGMCCaptureFBUpstream;
    RYGMCUninstallCapture([self class], cmd, (IMP)RYGMCCaptureFBGetBool, upstream, &gRYGMCCaptureFBInstalled);
    return upstream ? ((BOOL (*)(id, SEL, unsigned long long))upstream)(self, cmd, pid) : NO;
}

static BOOL RYGMCCaptureIGGetBool(id self, SEL cmd, unsigned long long pid) {
    RYGMCRetainObservedManager(self);
    IMP upstream = gRYGMCCaptureIGUpstream;
    RYGMCUninstallCapture([self class], cmd, (IMP)RYGMCCaptureIGGetBool, upstream, &gRYGMCCaptureIGInstalled);
    return upstream ? ((BOOL (*)(id, SEL, unsigned long long))upstream)(self, cmd, pid) : NO;
}

static void RYGMCTryInstallCaptureForClass(const char *className,
                                            IMP wrapper,
                                            IMP *upstream,
                                            BOOL *installedFlag) {
    if (!className || !wrapper || !upstream || !installedFlag || RYGMCCurrentObservedManager()) return;
    Class cls = objc_lookUpClass(className);
    if (!cls) return;
    SEL getter = sel_registerName("getBool:");
    Method getterMethod = class_getInstanceMethod(cls, getter);
    Method pathMethod = class_getInstanceMethod(cls, sel_registerName("getOverridesTablePath"));
    if (!RYGMCGetterMethodLooksCompatible(getterMethod) || !RYGMCPathMethodLooksCompatible(pathMethod)) return;
    IMP current = method_getImplementation(getterMethod);
    if (!current) return;
    if (current == wrapper) { *installedFlag = YES; return; }
    *upstream = current;
    (void)method_setImplementation(getterMethod, wrapper);
    *installedFlag = method_getImplementation(getterMethod) == wrapper;
}

static void RYGMCTryInstallOneShotManagerCapture(void) {
    if (RYGMCCurrentObservedManager()) return;
    RYGMCTryInstallCaptureForClass("FBMobileConfigContextManager",
                                   (IMP)RYGMCCaptureFBGetBool,
                                   &gRYGMCCaptureFBUpstream,
                                   &gRYGMCCaptureFBInstalled);
    RYGMCTryInstallCaptureForClass("IGMobileConfigContextManager",
                                   (IMP)RYGMCCaptureIGGetBool,
                                   &gRYGMCCaptureIGUpstream,
                                   &gRYGMCCaptureIGInstalled);
}

static NSString *RYGMCNativeDataDirectoryFromValue(id value) {
    NSString *path = nil;
    if ([value isKindOfClass:NSURL.class]) path = [(NSURL *)value path];
    else if ([value isKindOfClass:NSString.class]) path = value;
    if ([path hasPrefix:@"file://"]) path = [NSURL URLWithString:path].path;
    path = path.stringByStandardizingPath;
    if (!path.length) return nil;
    if ([path.pathExtension.lowercaseString isEqualToString:@"data"]) return path;
    NSString *parent = path.stringByDeletingLastPathComponent;
    return [parent.pathExtension.lowercaseString isEqualToString:@"data"] ? parent : nil;
}

static NSString *RYGMCValidatedNativeDirectory(NSString *path) {
    path = path.stringByStandardizingPath;
    if (!path.length || ![path.pathExtension.lowercaseString isEqualToString:@"data"]) return nil;
    BOOL isDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory])
        return isDirectory ? path : nil;
    return nil;
}

static NSString *RYGMCDataDirectoryFromManager(id manager) {
    if (!manager) return nil;
    SEL selector = sel_registerName("getOverridesTablePath");
    Method method = class_getInstanceMethod([manager class], selector);
    if (!RYGMCPathMethodLooksCompatible(method)) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(manager, selector);
    return RYGMCValidatedNativeDirectory(RYGMCNativeDataDirectoryFromValue(value));
}

@interface RYGMobileConfig (RYGNativeAuthorityPrivate)
- (NSString *)ryg_nativeDataDirectory;
- (NSString *)ryg_authorityNativeDataDirectory;
@end

@implementation RYGMobileConfig (RYGNativeAuthority)

- (id)ryg_resolveActiveSessionManager {
    // Explicit browser/editor path only. This is intentionally not called from
    // a constructor or a MobileConfig getter hot path.
    id manager = RYGMCActiveSessionContextManager() ?: RYGMCCurrentObservedManager();
    if (manager) RYGMCRetainObservedManager(manager);
    if (!manager) RYGMCTryInstallOneShotManagerCapture();
    return manager;
}

- (NSString *)ryg_authorityNativeDataDirectory {
    // User-triggered resolution only. No MobileConfig manager discovery runs in
    // a cold-launch constructor.
    id manager = [self ryg_resolveActiveSessionManager];
    NSString *native = RYGMCDataDirectoryFromManager(manager ?: RYGMCCurrentObservedManager());
    if (native.length) return native;

    // Older/partially initialized builds may not have the FBT current-session
    // chain ready yet. Arm a one-shot observer for the next real getter; it does
    // no path/filesystem work and removes itself on first invocation.
    RYGMCTryInstallOneShotManagerCapture();

    NSString *previous = [self ryg_authorityNativeDataDirectory];
    return RYGMCValidatedNativeDirectory(previous);
}

@end

__attribute__((constructor(65470))) static void RYGMobileConfigInstallNativeAuthority(void) {
    Class cls = RYGMobileConfig.class;
    Method original = class_getInstanceMethod(cls, @selector(ryg_nativeDataDirectory));
    Method replacement = class_getInstanceMethod(cls, @selector(ryg_authorityNativeDataDirectory));
    if (original && replacement && method_getImplementation(original) != method_getImplementation(replacement))
        method_exchangeImplementations(original, replacement);
}
