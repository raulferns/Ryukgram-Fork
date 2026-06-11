#import "SCIDogfoodObjectRuntime.h"
#import "SCIEmployeeDefaults.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>

static id (*orig_iguser_userID)(id, SEL) = NULL;
static id (*orig_foauser_userID)(id, SEL) = NULL;

static id new_iguser_userID(id self, SEL _cmd) {
    id ret = orig_iguser_userID ? orig_iguser_userID(self, _cmd) : nil;
    @try { [SCIDogfoodObjectRuntime noteLiveUserSession:self source:@"IGUserSession.userID"]; [SCIEmployeeDefaults applyToUserSession:self source:@"IGUserSession.userID"]; } @catch (__unused id e) {}
    return ret;
}

static id new_foauser_userID(id self, SEL _cmd) {
    id ret = orig_foauser_userID ? orig_foauser_userID(self, _cmd) : nil;
    @try { [SCIDogfoodObjectRuntime noteLiveUserSession:self source:@"FOAUserSession.userID"]; [SCIEmployeeDefaults applyToUserSession:self source:@"FOAUserSession.userID"]; } @catch (__unused id e) {}
    return ret;
}

static void SCIInstallUserSessionHooks(void) {
    Class ig = NSClassFromString(@"IGUserSession");
    if (ig && [ig instancesRespondToSelector:@selector(userID)] && !orig_iguser_userID) {
        MSHookMessageEx(ig, @selector(userID), (IMP)new_iguser_userID, (IMP *)&orig_iguser_userID);
    }
    Class foa = NSClassFromString(@"FOAUserSession");
    if (foa && [foa instancesRespondToSelector:@selector(userID)] && !orig_foauser_userID) {
        MSHookMessageEx(foa, @selector(userID), (IMP)new_foauser_userID, (IMP *)&orig_foauser_userID);
    }
}

%ctor {
    @autoreleasepool {
        // Defer off static-init: see SCIEasyGatingHook.x for full explanation.
        // SCIEmployeeDefaults installs GLOBAL NSUserDefaults hooks; doing that during
        // dyld static init intercepts reads inside METARunPreApplicationMain.
        __block id _sciTok = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            if (_sciTok) { [[NSNotificationCenter defaultCenter] removeObserver:_sciTok]; _sciTok = nil; }
            // SCI-FIX 2026-06-11: single install at DidBecomeActive; dropped 0.5/2/5s ladder.
            [SCIEmployeeDefaults installHooksIfNeeded];
            SCIInstallUserSessionHooks();
        }];
    }
}
