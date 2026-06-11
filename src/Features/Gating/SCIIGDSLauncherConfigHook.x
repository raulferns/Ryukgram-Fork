// SCIIGDSLauncherConfigHook.x
//
// IGDSLauncherConfig BOOL getter hooks.
//
// Build rules:
// - This is a Logos .x file compiled as Objective-C, not Objective-C++.
// - Do NOT use extern "C" here.
// - SCIIGDSEnsureHooksInstalled must be a non-static C symbol because
//   SCIIGDSLauncherConfigViewController.m links against it.
//
// Runtime rules:
// - Clean install/startup must not install hooks.
// - Hooks are installed only when an IGDS pref is enabled, or when the user taps
//   Apply / toggles a switch in SCIIGDSLauncherConfigViewController.
// - Replacement blocks do not call NSUserDefaults or other ObjC preference APIs.
//   They read only static C BOOL cache values.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <os/log.h>

#define IGDS_LOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIIGDS] " fmt,##__VA_ARGS__)

typedef BOOL (*SCIIGDSForceFn_t)(void);

static NSMutableSet<NSString *> *sHookedNames;
static NSUInteger sHookCount = 0;

// Group cache
static volatile BOOL sAll = NO;
static volatile BOOL sLiquidGlass = NO;
static volatile BOOL sPrism = NO;

// LiquidGlass detail cache
static volatile BOOL sLGInAppNotification = NO;
static volatile BOOL sLGToast = NO;
static volatile BOOL sLGToastPeek = NO;
static volatile BOOL sLGIconBarButton = NO;
static volatile BOOL sLGNavStylePinning = NO;
static volatile BOOL sLGEaseInOut = NO;
static volatile BOOL sLGCGBlur = NO;
static volatile BOOL sLGDebugger = NO;
static volatile BOOL sLGContextMenu = NO;

// General/navigation cache
static volatile BOOL sNavRounded = NO;
static volatile BOOL sTransitionZoom = NO;
static volatile BOOL sNativeBottomsheet = NO;
static volatile BOOL sAsyncFont = NO;

// Wordmark cache. These are mutually exclusive at the UI level, but the hook
// keeps them as independent BOOLs because the underlying IGDS getters are independent.
static volatile BOOL sWordmark1a = NO;
static volatile BOOL sWordmark1aAlt = NO;
static volatile BOOL sWordmark1b = NO;
static volatile BOOL sWordmark1bAlt = NO;

static BOOL ForceAll(void) { return sAll; }
static BOOL ForceLiquidGlass(void) { return sAll || sLiquidGlass; }
static BOOL ForcePrism(void) { return sAll || sPrism; }
static BOOL ForceLGInAppNotification(void) { return ForceLiquidGlass() || sLGInAppNotification; }
static BOOL ForceLGToast(void) { return ForceLiquidGlass() || sLGToast; }
static BOOL ForceLGToastPeek(void) { return ForceLiquidGlass() || sLGToastPeek; }
static BOOL ForceLGIconBarButton(void) { return ForceLiquidGlass() || sLGIconBarButton; }
static BOOL ForceLGNavStylePinning(void) { return ForceLiquidGlass() || sLGNavStylePinning; }
static BOOL ForceLGEaseInOut(void) { return ForceLiquidGlass() || sLGEaseInOut; }
static BOOL ForceLGCGBlur(void) { return ForceLiquidGlass() || sLGCGBlur; }
static BOOL ForceLGDebugger(void) { return ForceLiquidGlass() || sLGDebugger; }
static BOOL ForceLGContextMenu(void) { return ForceLiquidGlass() || sLGContextMenu; }
static BOOL ForceNavRounded(void) { return sAll || sNavRounded; }
static BOOL ForceTransitionZoom(void) { return sAll || sTransitionZoom; }
static BOOL ForceNativeBottomsheet(void) { return sAll || sNativeBottomsheet; }
static BOOL ForceAsyncFont(void) { return sAll || sAsyncFont; }
static BOOL ForceWordmark1a(void) { return sWordmark1a; }
static BOOL ForceWordmark1aAlt(void) { return sWordmark1aAlt; }
static BOOL ForceWordmark1b(void) { return sWordmark1b; }
static BOOL ForceWordmark1bAlt(void) { return sWordmark1bAlt; }

static void IGDSReadPrefs(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    sAll = [ud boolForKey:@"sci_igds_launcher_all"];
    sLiquidGlass = [ud boolForKey:@"sci_igds_liquidglass"] || [ud boolForKey:@"sci_apply_liquidglass"];
    sPrism = [ud boolForKey:@"sci_igds_prism"];

    sLGInAppNotification = [ud boolForKey:@"sci_igds_lg_inappnotif"];
    sLGToast = [ud boolForKey:@"sci_igds_lg_toast"];
    sLGToastPeek = [ud boolForKey:@"sci_igds_lg_toastpeek"];
    sLGIconBarButton = [ud boolForKey:@"sci_igds_lg_iconbarbtn"];
    sLGNavStylePinning = [ud boolForKey:@"sci_igds_lg_navstylepin"];
    sLGEaseInOut = [ud boolForKey:@"sci_igds_lg_easeinout"];
    sLGCGBlur = [ud boolForKey:@"sci_igds_lg_cgblur"];
    sLGDebugger = [ud boolForKey:@"sci_igds_lg_debugger"];
    sLGContextMenu = [ud boolForKey:@"sci_igds_nav_ctxmenu"];

    sNavRounded = [ud boolForKey:@"sci_igds_nav_rounded"];
    sTransitionZoom = [ud boolForKey:@"sci_igds_nav_tzoom"];
    sNativeBottomsheet = [ud boolForKey:@"sci_igds_nav_bottomsheet"];
    sAsyncFont = [ud boolForKey:@"sci_igds_async_font"];

    sWordmark1a = [ud boolForKey:@"sci_igds_wordmark_isIGWordmark1aEnabled"];
    sWordmark1aAlt = [ud boolForKey:@"sci_igds_wordmark_isIGWordmark1aAltEnabled"];
    sWordmark1b = [ud boolForKey:@"sci_igds_wordmark_isIGWordmark1bEnabled"];
    sWordmark1bAlt = [ud boolForKey:@"sci_igds_wordmark_isIGWordmark1bAltEnabled"];

    NSString *variant = [ud stringForKey:@"sci_ig_wordmark_variant"] ?: [ud stringForKey:@"sci_ig_wordmark_mode"];
    if ([variant isEqualToString:@"1a"]) sWordmark1a = YES;
    else if ([variant isEqualToString:@"1a_alt"]) sWordmark1aAlt = YES;
    else if ([variant isEqualToString:@"1b"]) sWordmark1b = YES;
    else if ([variant isEqualToString:@"1b_alt"]) sWordmark1bAlt = YES;
}

static BOOL IGDSAnyPrefEnabled(void) {
    return sAll || sLiquidGlass || sPrism ||
           sLGInAppNotification || sLGToast || sLGToastPeek || sLGIconBarButton ||
           sLGNavStylePinning || sLGEaseInOut || sLGCGBlur ||
           sLGDebugger || sLGContextMenu || sNavRounded || sTransitionZoom ||
           sNativeBottomsheet || sAsyncFont ||
           sWordmark1a || sWordmark1aAlt ||
           sWordmark1b || sWordmark1bAlt;
}

static BOOL MethodIsNoArgBool(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char ret[8] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    return ret[0] == 'B' || ret[0] == 'c' || ret[0] == 'C';
}

static void HookBoolGetter(Class cls, const char *selName, SCIIGDSForceFn_t forceFn) {
    if (!cls || !selName || !forceFn) return;
    SEL sel = NSSelectorFromString([NSString stringWithUTF8String:selName]);
    if (!sel) return;

    Method method = class_getInstanceMethod(cls, sel);
    if (!MethodIsNoArgBool(method)) return;

    NSString *name = [NSString stringWithFormat:@"%s#%s", class_getName(cls), selName];
    if ([sHookedNames containsObject:name]) return;

    __block IMP originalIMP = NULL;
    SCIIGDSForceFn_t capturedForce = forceFn;
    IMP replacement = imp_implementationWithBlock(^BOOL(id receiver) {
        if (capturedForce && capturedForce()) return YES;
        return originalIMP ? ((BOOL (*)(id, SEL))originalIMP)(receiver, sel) : NO;
    });

    MSHookMessageEx(cls, sel, replacement, &originalIMP);
    [sHookedNames addObject:name];
    sHookCount++;
}

static void IGDSInstall(void) {
    IGDSReadPrefs();
    if (!IGDSAnyPrefEnabled()) {
        IGDS_LOG("skip: all IGDS prefs disabled");
        return;
    }

    if (!sHookedNames) sHookedNames = [NSMutableSet set];

    Class cls = NSClassFromString(@"IGDSLauncherConfig") ?: objc_getClass("IGDSLauncherConfig");
    if (!cls) {
        IGDS_LOG("IGDSLauncherConfig not found yet");
        return;
    }

    // Base launcher gates (only forced by the master "Ativar tudo" switch).
    HookBoolGetter(cls, "canSupportLauncher", ForceAll);
    HookBoolGetter(cls, "isEligibleForLaunch", ForceAll);

    // LiquidGlass: this build exposes no master getter, only the specific ones.
    HookBoolGetter(cls, "isLiquidGlassInAppNotificationEnabled", ForceLGInAppNotification);
    HookBoolGetter(cls, "isLiquidGlassToastEnabled", ForceLGToast);
    HookBoolGetter(cls, "isLiquidGlassToastPeekEnabled", ForceLGToastPeek);
    HookBoolGetter(cls, "isLiquidGlassIconBarButtonEnabled", ForceLGIconBarButton);
    HookBoolGetter(cls, "isLiquidGlassNavigationContentStylePinningEnabled", ForceLGNavStylePinning);
    HookBoolGetter(cls, "isLiquidGlassEaseInOutBlurEnabled", ForceLGEaseInOut);
    HookBoolGetter(cls, "isLiquidGlassCGContextBlurEnabled", ForceLGCGBlur);
    HookBoolGetter(cls, "canUseInternalLiquidGlassDebugger", ForceLGDebugger);
    HookBoolGetter(cls, "isContextMenuMigrationEnabled", ForceLGContextMenu);

    // Prism: no master getter on this build either; hook every real Prism getter
    // so the "Prism" group / "Ativar tudo" actually flips the whole surface.
    HookBoolGetter(cls, "isPrismControlsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDefaultTooltipEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismToastsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismAlertDialogEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismAvatarRingEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismContextMenuEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismContextMenuRefactorEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismIndigoButtonEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismIndigoButtonM1DirectEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismIndigoActionCellsEnabled", ForcePrism);
    HookBoolGetter(cls, "isIGBPrismEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismOverflowMenuEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismOverflowMenuStampWidthIncreased", ForcePrism);
    HookBoolGetter(cls, "isPrismBottomSheetEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismCreationIconsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismMediaButtonsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismCommentsEmptyStateEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismAllUserAssetsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismFollowRelatedUserAssetsEnabled", ForcePrism);
    HookBoolGetter(cls, "_isPrismSecondaryNonUserIconsEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersUpdateEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersCommentsUpdateEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersEditReelEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersNotificationsUpdateEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersProfileUpdateEnabled", ForcePrism);
    HookBoolGetter(cls, "isPrismDividersShareSheetUpdateEnabled", ForcePrism);

    HookBoolGetter(cls, "isNavPushRoundedCornersEnabled", ForceNavRounded);
    HookBoolGetter(cls, "isTransitionZoomCustomizationEnabled", ForceTransitionZoom);
    HookBoolGetter(cls, "isNativeBottomsheetForiPhoneEnabled", ForceNativeBottomsheet);
    HookBoolGetter(cls, "isNativeBottomsheetForiPhoneOnAllSurfacesEnabled", ForceNativeBottomsheet);
    HookBoolGetter(cls, "isAsyncFontRegistrationEnabled", ForceAsyncFont);

    HookBoolGetter(cls, "isIGWordmark1aEnabled", ForceWordmark1a);
    HookBoolGetter(cls, "isIGWordmark1aAltEnabled", ForceWordmark1aAlt);
    HookBoolGetter(cls, "isIGWordmark1bEnabled", ForceWordmark1b);
    HookBoolGetter(cls, "isIGWordmark1bAltEnabled", ForceWordmark1bAlt);

    IGDS_LOG("hooks=%lu all=%d liquid=%d prism=%d", (unsigned long)sHookCount, (int)sAll, (int)sLiquidGlass, (int)sPrism);
}

void SCIIGDSEnsureHooksInstalled(void) { IGDSInstall(); }

%ctor {
    @autoreleasepool {
        // Startup-safe: do not install IGDS hooks before explicit user action.
        // SCIIGDSEnsureHooksInstalled() is called by the IGDS settings screen.
    }
}
