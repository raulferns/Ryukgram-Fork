#import "SCIInternalMenusLauncher.h"
#import "SCIDogfoodObjectRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

#define MLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] Menus " fmt,##__VA_ARGS__)

// ───────────────────────────────────────────────────────────────────────────
// CRASH POST-MORTEM (Instagram-2026-06-15-082650.ips):
//
//   EXC_BREAKPOINT (SIGTRAP) — a Swift CPU trap (`brk #1`), NOT an NSException.
//   Backtrace ran: UITableView _selectRowAtIndexPath → RyukGram.dylib → Instagram.
//   i.e. it fired on the menu tap while we were CONSTRUCTING a Swift VC.
//
//   Root cause, proven in the binary:
//     -[IGSearchDebugSettingsViewController initWithAnalyticsModule:listRedesignEnabled:]
//     tail-calls a Swift allocating-init thunk (0x100101e74) whose path is
//         blr x19 ; brk #1
//     — a type-metadata-checked init. The analyticsModule we fabricated via
//     +[IGAnalyticsModule moduleForName:] is NOT the exact Swift type the init's
//     metadata expects, so the check fails and traps.
//
//   CRITICAL: @try/@catch CANNOT catch a Swift `brk #1` trap. The only way to
//   not crash is to NOT call an init that can trap. So we construct NOTHING that
//   is a Swift VC ourselves. We only invoke entrypoints where INSTAGRAM ITSELF
//   builds the object graph:
//
//     ✓ +[IGDirectNotesDogfoodingSettingsStaticFuncs
//          notesDogfoodingSettingsOpenOnViewController:userSession:]  (class method)
//     ✓ tryOpenNativeDogfoodSettings — uses IG's own openWithConfig: with a config
//        that IG built (we never fabricate the config; nil → graceful fallback)
//     ✓ IGURLHandler internal-URL routing — IG builds whatever VC the route maps to
//
//   The previously-added Autofill / SearchDebug / StoryStore "direct construct"
//   openers are REMOVED: there is no safe way to alloc/init those Swift VCs
//   without a genuine IG-built dependency, and a failed metadata check is an
//   uncatchable trap.
// ───────────────────────────────────────────────────────────────────────────

static UIViewController *SCITopVC(void)  { return [SCIDogfoodObjectRuntime topViewController]; }
static id               SCISession(void) { return [SCIDogfoodObjectRuntime activeUserSession]; }

static UINavigationController *SCINavFor(UIViewController *vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:UINavigationController.class]) return (UINavigationController *)vc;
    return vc.navigationController;
}

@implementation SCIInternalMenusLauncher

// ── 1. Notes dogfooding (IG builds everything; only a class method call) ───

+ (NSString *)openDogfoodingNotesSettings {
    id session = SCISession();
    if (!session) return @"sem sessao ativa (abra apos o login)";
    Class C = NSClassFromString(@"IGDirectNotesDogfoodingSettingsStaticFuncs")
           ?: NSClassFromString(@"_TtC31IGDirectNotesDogfoodingSettings42IGDirectNotesDogfoodingSettingsStaticFuncs");
    if (!C) return @"classe IGDirectNotesDogfoodingSettingsStaticFuncs ausente";
    SEL s = NSSelectorFromString(@"notesDogfoodingSettingsOpenOnViewController:userSession:");
    if (![C respondsToSelector:s]) return @"selector notesDogfoodingSettingsOpen... ausente";
    UIViewController *top = SCITopVC();
    UIViewController *presenter = SCINavFor(top) ?: top;
    if (!presenter) return @"sem VC para apresentar";
    ((void(*)(id,SEL,id,id))objc_msgSend)(C, s, presenter, session);
    MLOG("Notes dogfooding opened");
    return @"opened Notes dogfooding settings";
}

// ── 2. Native Dogfooding Settings VC (IG-built config only; never fabricated) ─

+ (NSString *)openDogfoodingSettingsVC {
    BOOL ok = [SCIDogfoodObjectRuntime tryOpenNativeDogfoodSettings];
    return ok ? @"opened native Dogfooding Settings"
              : @"Dogfooding Settings VC indisponivel: o IG ainda nao construiu um "
                "IGDogfoodingSettingsConfig nesta sessao (nao da pra fabricar com seguranca). "
                "Caiu no fallback de Notes se possivel.";
}

// ── 3. Internal URL routing (IG builds the destination VC) ─────────────────

+ (NSString *)openInternalURLString:(NSString *)urlString {
    id session = SCISession();
    if (!session) return @"sem sessao ativa";
    Class C = NSClassFromString(@"IGURLHandler");
    SEL s = NSSelectorFromString(@"openInternalURL:presentationConfig:controller:animated:userSession:annotation:");
    if (!C || ![C respondsToSelector:s]) return @"IGURLHandler.openInternalURL ausente";
    UIViewController *top = SCITopVC();
    if (!top) return @"sem topVC";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return @"URL invalida";
    BOOL ok = ((BOOL(*)(id,SEL,id,id,id,BOOL,id,id))objc_msgSend)(C, s, url, nil, top, YES, session, nil);
    return ok ? [NSString stringWithFormat:@"opened: %@", urlString]
              : [NSString stringWithFormat:@"openInternalURL retornou NO para: %@", urlString];
}

// ── 4. Cascade over the SAFE openers only ──────────────────────────────────

+ (NSString *)openBestAvailableInternalMenu {
    NSString *r = [self openDogfoodingNotesSettings];
    if ([r hasPrefix:@"opened"]) return r;
    r = [self openDogfoodingSettingsVC];
    if ([r hasPrefix:@"opened"]) return r;
    r = [self openInternalURLString:@"instagram://internal_settings"];
    if ([r hasPrefix:@"opened"]) return r;
    return @"Nenhum menu interno seguro abriu. Confirme: logado? Notes dogfooding requer sessao.";
}

@end
