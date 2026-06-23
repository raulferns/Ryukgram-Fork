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

// Native Dogfooding Settings opener — REVALIDADO no binário NOVO do Instagram
// enviado nesta conversa (parser ObjC + chained-fixup + disassemble). Espelha
// exatamente o FBInternalSettingsViewControllerFromSession do FBTweak: em vez
// de ESPERAR capturar um config que nunca vem, CRIA o config e chama a factory
// nativa do próprio app.
//
// Entrypoints confirmados no exec novo:
//   +[IGDogfoodingSettings openWithConfig:onViewController:userSession:]
//       classe Swift registrada: _TtC20IGDogfoodingSettings20IGDogfoodingSettings
//   -[IGDogfoodingSettingsViewController initWithConfig:userSession:]  (fallback)
//       classe Swift registrada: _TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController
//   IGDogfoodingSettingsConfig: instanceStart=8 instanceSize=8, 0 ivars ->
//       [[cls alloc] init] é um config vazio VÁLIDO. Disassembly via Capstone/llvm-objdump of initWithConfig:userSession:
//       (0x10684fa10) shows retain(config), retain(userSession), then transfer
//       to Swift init storage. ObjC metadata shows IGDogfoodingSettingsConfig
//       has instanceSize=8 and zero ivars/methods/properties, so [[alloc] init]
//       is the expected empty config object.
//
// Sideload-safe: só chamada ObjC direta (NSClassFromString+alloc/init+msgSend),
// nada de inline patch / fishhook. Mesmo perfil do opener do FB.
+ (NSString *)openDogfoodingSettingsVC {
    id session = [self session];
    if (!session) return @"no live user session (open after login)";

    Class cfgCls = NSClassFromString(@"IGDogfoodingSettingsConfig");
    if (!cfgCls) return @"IGDogfoodingSettingsConfig not found in this build";

    id config = nil;
    @try {
        config = [[cfgCls alloc] init];
    } @catch (id e) {
        return [NSString stringWithFormat:@"config init threw: %@", e];
    }
    if (!config) return @"IGDogfoodingSettingsConfig init returned nil";

    UIViewController *top = [self topVC];

    // Caminho A (preferido): a factory do app monta E apresenta sozinha,
    // igual ao FBInternalSettingsViewControllerFromSession.
    Class factory = NSClassFromString(@"_TtC20IGDogfoodingSettings20IGDogfoodingSettings");
    SEL openSel = NSSelectorFromString(@"openWithConfig:onViewController:userSession:");
    if (factory && [factory respondsToSelector:openSel]) {
        @try {
            ((void(*)(id,SEL,id,id,id))objc_msgSend)(factory, openSel, config, top, session);
            MLOG("dogfooding settings opened via factory");
            return @"opened native Dogfooding Settings";
        } @catch (id e) {
            MLOG("factory threw, trying VC init fallback");
        }
    }

    // Caminho B (fallback): monta a VC pelo init designado e apresenta como sheet.
    Class vcCls = NSClassFromString(@"_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController");
    SEL initSel = NSSelectorFromString(@"initWithConfig:userSession:");
    if (vcCls && [vcCls instancesRespondToSelector:initSel]) {
        @try {
            UIViewController *vc = ((id(*)(id,SEL,id,id))objc_msgSend)([vcCls alloc], initSel, config, session);
            if ([vc isKindOfClass:UIViewController.class]) {
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                nav.modalPresentationStyle = UIModalPresentationPageSheet;
                if (!vc.navigationItem.leftBarButtonItem && [vc respondsToSelector:NSSelectorFromString(@"closeButtonTapped")]) {
                    vc.navigationItem.leftBarButtonItem =
                        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                      target:vc
                                                                      action:NSSelectorFromString(@"closeButtonTapped")];
                }
                [top presentViewController:nav animated:YES completion:nil];
                MLOG("dogfooding settings opened via VC init");
                return @"opened native Dogfooding Settings (VC)";
            }
        } @catch (id e) {
            return [NSString stringWithFormat:@"threw: %@", e];
        }
    }
    return @"IGDogfoodingSettings entrypoints not found in this build";
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
