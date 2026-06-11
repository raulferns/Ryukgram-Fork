// SCIInternalUseGateHook.x
//
// CRASH HISTORY:
//   Run 226: unconditional rebind of MobileConfig ACTION functions caused a C
//            function pointer to land where IG expected an ObjC object → crash
//            in objc_retain. Fixed: only rebind BOOL-returning gates.
//
//   Run 229: stack overflow (depth 4751) during dyld init.
//            my_MCBool called gateOn() → [NSUserDefaults boolForKey:] → IG's
//            custom pref domain calls IGMobileConfigBooleanValueForInternalUse
//            internally → our hook → gateOn() → NSUserDefaults → ∞
//
// ROOT CAUSE: calling NSUserDefaults (or ANY ObjC message) inside a fishhook
// replacement for a function that NSUserDefaults itself calls internally.
//
// FIX: hooks read only plain C static BOOLs. Those are written once at
// %ctor time from NSUserDefaults and never touched again from inside a hook.
// A KVO observer on NSUserDefaults refreshes the cache when the user changes
// a setting — so live toggles still work without re-entry risk.

#import <Foundation/Foundation.h>
#import "../../../modules/fishhook/fishhook.h"
#import <os/log.h>

#define SCILOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] MCGate " fmt,##__VA_ARGS__)

// ── Pref keys ──────────────────────────────────────────────────────────────
static NSString * const kBool        = @"sci_force_mc_internal_use_boolean";
static NSString * const kInternalApp = @"sci_force_ig_internal_apps_installed_after_ios18";
static NSString * const kMinos       = @"sci_force_minos_dogfood_mek_encryption";

// ── C-only cache (NO ObjC, NO NSUserDefaults inside hooks) ─────────────────
// Written at %ctor and whenever the user flips a toggle (KVO).
// Hooks read these atomically — zero risk of re-entrant NSUserDefaults call.
static volatile BOOL sCacheBool        = NO;
static volatile BOOL sCacheInternalApp = NO;
static volatile BOOL sCacheMinos       = NO;

static void SCIRefreshHookCache(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL all = [ud boolForKey:@"sci_force_mc_internal_use_all"] || [ud boolForKey:@"sci_force_all_mc_gates"];
    sCacheBool        = all || [ud boolForKey:kBool];
    sCacheInternalApp = all || [ud boolForKey:kInternalApp];
    sCacheMinos       = all || [ud boolForKey:kMinos];
    SCILOG("cache refreshed — bool=%d apps=%d minos=%d",
           (int)sCacheBool, (int)sCacheInternalApp, (int)sCacheMinos);
}

// ── Originals ──────────────────────────────────────────────────────────────
typedef BOOL (*MCBoolFn_t)(id, BOOL, void *);
typedef BOOL (*SimpleBoolFn_t)(void);

static MCBoolFn_t        orig_MCBool        = NULL;
static SimpleBoolFn_t    orig_InternalApps  = NULL;
static SimpleBoolFn_t    orig_Minos         = NULL;

// ── Hook implementations — plain C, zero ObjC ─────────────────────────────
static BOOL my_MCBool(id session, BOOL def, void *p) {
    if (sCacheBool) return YES;
    return orig_MCBool ? orig_MCBool(session, def, p) : def;
}
static BOOL my_InternalApps(void) {
    if (sCacheInternalApp) return YES;
    return orig_InternalApps ? orig_InternalApps() : NO;
}
static BOOL my_Minos(void) {
    if (sCacheMinos) return YES;
    return orig_Minos ? orig_Minos() : NO;
}

// ── KVO observer — refreshes cache on settings change ─────────────────────
@interface SCIMCGateObserver : NSObject @end
@implementation SCIMCGateObserver
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)c context:(void *)ctx {
    SCIRefreshHookCache();
}
@end
static SCIMCGateObserver *sObserver = nil;

static void SCIInstallKVOObserver(void) {
    sObserver = [SCIMCGateObserver new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[kBool, kInternalApp, kMinos,
                            @"sci_force_mc_internal_use_all", @"sci_force_all_mc_gates"]) {
        [ud addObserver:sObserver forKeyPath:key
               options:NSKeyValueObservingOptionNew context:NULL];
    }
}

// ── Install ────────────────────────────────────────────────────────────────
void SCIInstallMobileConfigInternalUseGateIfNeeded(void) {
    static BOOL done = NO;

    // Read prefs before installing hooks. If every pref is OFF, do not touch GOT/fishhook.
    SCIRefreshHookCache();
    BOOL any = sCacheBool || sCacheInternalApp || sCacheMinos;
    if (!any) {
        SCILOG("skip install: all prefs disabled");
        return;
    }

    if (done) return;
    done = YES;

    struct rebinding r[] = {
        {"IGMobileConfigBooleanValueForInternalUse",
         (void *)my_MCBool, (void **)&orig_MCBool},
        {"IGAppIsInstagramInternalAppsInstalledAndNotHiddenAfteriOS18",
         (void *)my_InternalApps, (void **)&orig_InternalApps},
        {"MEBIsMinosDogfoodMekEncryptionVersionEnabled",
         (void *)my_Minos, (void **)&orig_Minos},
    };
    int rc = rebind_symbols(r, sizeof(r) / sizeof(r[0]));
    SCILOG("rebind_symbols=%d (0=ok)", rc);

    SCIInstallKVOObserver();
}

%ctor {
    @autoreleasepool {
        SCIInstallMobileConfigInternalUseGateIfNeeded();
    }
}
