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
+ (NSString *)openInternalURLString:(nullable NSString *)urlString {
    return [self openInternalURLString:urlString controller:nil];
}

+ (NSString *)openInternalURLString:(nullable NSString *)urlString controller:(nullable UIViewController *)controller {
    id session = [self session];
    if (!session) return @"no live user session";
    Class C = NSClassFromString(@"IGURLHandler");
    SEL s = NSSelectorFromString(
        @"openInternalURL:presentationConfig:controller:animated:userSession:annotation:");
    if (!C || ![C respondsToSelector:s]) return @"IGURLHandler.openInternalURL not found";
    
    UIViewController *top = controller ?: [self topVC];
    if (!top) return @"no presenter view controller";
    
    NSArray<NSString *> *uris;
    if (urlString && urlString.length > 0) {
        uris = @[urlString];
    } else {
        uris = @[
            @"instagram://internal_settings",
            @"instagram://settings_devoptions",
            @"instagram://developer_options",
            //@"instagram://settings/developer_options",
            //@"instagram://settings/internal",
            @"instagram://debug",
            @"instagram://debug_settings",
            //@"instagram://settings/debug",
            //@"instagram://settings/account/dev_options",
            //@"instagram://settings/dev_options"
        ];
    }
    
    NSMutableArray<NSString *> *errors = [NSMutableArray new];
    for (NSString *uri in uris) {
        NSURL *url = [NSURL URLWithString:uri];
        @try {
            BOOL ok = ((BOOL(*)(id,SEL,id,id,id,BOOL,id,id))objc_msgSend)(
                C, s, url, nil, top, YES, session, nil);
            if (ok) {
                MLOG("Successfully opened internal URL: %{public}@", uri);
                return [NSString stringWithFormat:@"opened: %@", uri];
            } else {
                [errors addObject:[NSString stringWithFormat:@"%@ (returned NO)", uri]];
            }
        } @catch (id e) {
            [errors addObject:[NSString stringWithFormat:@"%@ (threw: %@)", uri, e]];
        }
    }
    
    return [NSString stringWithFormat:@"All URIs failed: %@", [errors componentsJoinedByString:@", "]];
}
@end
