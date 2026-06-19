#import "SCIInternalMenusLauncher.h"
#import "SCIDogfoodObjectRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

#define MLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] Menus " fmt,##__VA_ARGS__)

@implementation SCIInternalMenusLauncher

+ (UIViewController *)topVC { return [SCIDogfoodObjectRuntime topViewController]; }
+ (id)session               { return [SCIDogfoodObjectRuntime activeUserSession]; }

// Return a navigation controller we can push onto, or nil.
+ (UINavigationController *)navFor:(UIViewController *)vc {
    if (!vc) return nil;
    if ([vc isKindOfClass:UINavigationController.class]) return (UINavigationController *)vc;
    return vc.navigationController;
}

// +[IGDirectNotesDogfoodingSettingsStaticFuncs
//       notesDogfoodingSettingsOpenOnViewController:userSession:]
// Signature v32@0:8@16@24 — takes (UIViewController *, userSession).
// Passes the nav controller when available so the method can push.
+ (NSString *)openDogfoodingNotesSettings {
    id session = [self session];
    if (!session) return @"no live user session (open after login)";

    Class C = NSClassFromString(@"IGDirectNotesDogfoodingSettingsStaticFuncs");
    if (!C) C = NSClassFromString(
        @"_TtC31IGDirectNotesDogfoodingSettings42IGDirectNotesDogfoodingSettingsStaticFuncs");
    if (!C) return @"IGDirectNotesDogfoodingSettingsStaticFuncs not found";

    SEL s = NSSelectorFromString(@"notesDogfoodingSettingsOpenOnViewController:userSession:");
    if (![C respondsToSelector:s]) return @"selector not found on class";

    UIViewController *top = [self topVC];
    // Prefer a navigation controller so the method can push
    UIViewController *presenter = [self navFor:top] ?: top;

    @try {
        ((void(*)(id,SEL,id,id))objc_msgSend)(C, s, presenter, session);
        MLOG("notes dogfooding opened");
        return @"opened Notes dogfooding settings";
    } @catch (id e) {
        return [NSString stringWithFormat:@"threw: %@", e];
    }
}

// Native Dogfooding Settings opener. Uses only dump-confirmed selectors and only
// calls the Swift entrypoint when the runtime has captured the real config object.
+ (NSString *)openDogfoodingSettingsVC {
    @try {
        BOOL ok = [SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings];
        return ok ? @"opened native Dogfooding Settings"
                  : @"native Dogfooding Settings unavailable: missing captured IGDogfoodingSettingsConfig/session; open an authorized native dogfood surface first";
    } @catch (id e) {
        return [NSString stringWithFormat:@"threw: %@", e];
    }
}

// +[IGURLHandler openInternalURL:presentationConfig:controller:animated:userSession:annotation:]
// Best-effort — tries common internal settings URL schemes.
+ (NSString *)openInternalURLString:(NSString *)urlString {
    id session = [self session];
    if (!session) return @"no live user session";
    Class C = NSClassFromString(@"IGURLHandler");
    SEL s = NSSelectorFromString(
        @"openInternalURL:presentationConfig:controller:animated:userSession:annotation:");
    if (!C || ![C respondsToSelector:s]) return @"IGURLHandler.openInternalURL not found";
    UIViewController *top = [self topVC];
    NSURL *url = [NSURL URLWithString:urlString];
    @try {
        BOOL ok = ((BOOL(*)(id,SEL,id,id,id,BOOL,id,id))objc_msgSend)(
            C, s, url, nil, top, YES, session, nil);
        return ok ? [NSString stringWithFormat:@"opened: %@", urlString]
                  : @"openInternalURL returned NO";
    } @catch (id e) {
        return [NSString stringWithFormat:@"threw: %@", e];
    }
}
@end
