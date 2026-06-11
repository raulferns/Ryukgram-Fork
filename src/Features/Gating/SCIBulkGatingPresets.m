// SCIBulkGatingPresets.m
//
// Aplica/remove overrides do Feature Gating em massa.
// Todos os nomes de classe/seletor foram verificados via:
//   • disassembly do FBSharedFramework + Instagram arm64 (lief)
//   • __objc_methname scan (confirma seletores presentes na imagem)
//   • __cstring scan (confirma nomes de classe ObjC e mangled Swift)
//   • screenshots FLEX do Feature Gatings (confirma "forced ON via getter hook")
//
// Regra de segurança (sideload): usa exclusivamente setRuntimeBoolOverride:/
// setDirectBoolOverride: via MSHookMessageEx em __DATA IMP tables.
// NUNCA MSHookFunction em __TEXT pages.

#import "SCIBulkGatingPresets.h"
#import "SCIGatingCatalog.h"
#import "../../SCIPrefObserver.h"

#define SRBO(cls, sel, cm, val) \
    [SCIGatingCatalog setRuntimeBoolOverride:(val) class:(cls) selector:(sel) classMethod:(cm)]
#define CRBO(cls, sel, cm) \
    [SCIGatingCatalog clearRuntimeBoolOverrideForClass:(cls) selector:(sel) classMethod:(cm)]

// Defaults key para o seletor de wordmark
static NSString *const kWordmarkKey = @"sci_ig_wordmark_variant";



@implementation SCIBulkGatingPresets

// ─── Liquid Glass ────────────────────────────────────────────────────────────

+ (void)applyLiquidGlass:(BOOL)on {

    // ① IGDSLauncherConfig — ObjC, instance methods, 11 flags
    //    Confirmados via __objc_methname scan de FBSharedFramework
    // NOTE (SCI-FIX 2026-06-11): selectors verified against the *class method list*
    // of IGDSLauncherConfig (IGDSLauncherConfig_FULL_header.c / real-getters dump),
    // NOT against global strings/xrefs. The following three were marked "confirmado"
    // but are NOT methods of IGDSLauncherConfig in build 433.0.283 — they exist as
    // selector strings elsewhere in the image but resolve to nil on this class, so
    // setRuntimeBoolOverride: was a silent no-op. Removed:
    //   - isLiquidGlassEnabled
    //   - isLiquidGlassToggleEnabled
    //   - isOptimizeLiquidGlassGlyphRenderingEnabled
    NSString *ds = @"IGDSLauncherConfig";
    for (NSString *s in @[
        @"canUseInternalLiquidGlassDebugger",
        @"isLiquidGlassCGContextBlurEnabled",
        @"isLiquidGlassEaseInOutBlurEnabled",
        @"isLiquidGlassIconBarButtonEnabled",
        @"isLiquidGlassInAppNotificationEnabled",
        @"isLiquidGlassNavigationContentStylePinningEnabled",
        @"isLiquidGlassToastEnabled",
        @"isLiquidGlassToastPeekEnabled",
    ]) { on ? SRBO(ds, s, NO, YES) : CRBO(ds, s, NO); }

    // ② IGDSAlertDialogLiquidGlass — Swift, CLASS method +isEnabled
    //    Mangled: _TtC(26)IGDSAlertDialogLiquidGlass(26)IGDSAlertDialogLiquidGlass
    NSString *alert = @"_TtC26IGDSAlertDialogLiquidGlass26IGDSAlertDialogLiquidGlass";
    on ? SRBO(alert, @"isEnabled", YES, YES) : CRBO(alert, @"isEnabled", YES);

    // ③ IGLiquidGlass — Swift, CLASS method +isEnabled
    //    Mangled: _TtC(13)IGLiquidGlass(13)IGLiquidGlass
    NSString *lgCls = @"_TtC13IGLiquidGlass13IGLiquidGlass";
    on ? SRBO(lgCls, @"isEnabled", YES, YES) : CRBO(lgCls, @"isEnabled", YES);

    // ④ IGLiquidGlassNavigationExperimentHelper — Swift, instance methods, 5 flags
    //    Mangled: _TtC(29)IGLiquidGlassExperimentHelper(39)IGLiquidGlassNavigationExperimentHelper
    NSString *nh = @"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper";
    for (NSString *s in @[
        @"isEnabled",
        @"isGlassRenderingOptimizationEnabled",
        @"isHomeFeedHeaderEnabled",
        @"isProfileOtherNavBarHeightMatchSelf",
    ]) { on ? SRBO(nh, s, NO, YES) : CRBO(nh, s, NO); }
    // isProfileSegmentedTabsGlassDisabled → forçar OFF quando LiquidGlass ON
    on ? SRBO(nh, @"isProfileSegmentedTabsGlassDisabled", NO, NO)
       : CRBO(nh, @"isProfileSegmentedTabsGlassDisabled", NO);

    // ⑤ IGLiquidGlassInteractiveTabBar — ObjC, instance methods, 6 flags
    //    Confirmados via __objc_methname + screenshots FLEX
    NSString *itb = @"IGLiquidGlassInteractiveTabBar";
    for (NSString *s in @[
        @"accessoryButtonEnabled",
        @"isAccessoryButtonVisible",
        @"isDebuggerEnabled",
        @"isHapticsEnabled",
        @"isPanGestureEnabled",
        @"syncConfigWithBarAppearance",
    ]) { on ? SRBO(itb, s, NO, YES) : CRBO(itb, s, NO); }
}

+ (BOOL)isLiquidGlassActive {
    NSNumber *v = [SCIGatingCatalog runtimeBoolOverrideStateForClass:@"IGDSLauncherConfig"
                                                            selector:@"isLiquidGlassEnabled"
                                                         classMethod:NO];
    return v != nil && v.boolValue;
}

// ─── Status Bar Old School ────────────────────────────────────────────────────

+ (void)applyStatusBarOldSchool:(BOOL)on {
    // IGThrowbackChromeExperimentHelper — módulo IGLiquidGlassExperimentHelper
    // Mangled: _TtC(29)IGLiquidGlassExperimentHelper(33)IGThrowbackChromeExperimentHelper
    // Carregado dinamicamente em runtime; não presente nos binários estáticos analisados.
    // setRuntimeBoolOverride: faz no-op silencioso se classe não encontrada via objc_getClass.
    NSString *cls = @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper";
    on ? SRBO(cls, @"isEnabled", NO, YES) : CRBO(cls, @"isEnabled", NO);
}

+ (BOOL)isStatusBarOldSchoolActive {
    NSString *cls = @"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper";
    NSNumber *v = [SCIGatingCatalog runtimeBoolOverrideStateForClass:cls
                                                            selector:@"isEnabled"
                                                         classMethod:NO];
    return v != nil && v.boolValue;
}

// ─── Story Tray ───────────────────────────────────────────────────────────────

+ (void)applyStoryTray:(BOOL)on {
    // IGNavConfiguration.IGHomecomingConfiguration — Swift, instance methods, 6 flags
    // Mangled: _TtC(18)IGNavConfiguration(25)IGHomecomingConfiguration
    // Confirmados via __objc_methname scan + screenshots FLEX:
    //   isStoriesTrayOnAllTabsEnabled ✓  showCinemaStoriesTrayOnSwipeUp ✓
    //   isDynamicTabStoryGridEnabled ✓   isVerticalStoriesTray ✓ (NOVO)
    //   isFeedCullingOnStoriesAccessEnabled ✓ (NOVO)
    //   isHomecomingStoriesAccessFaceClusterEnabled ✓ (NOVO)
    NSString *hc = @"_TtC18IGNavConfiguration25IGHomecomingConfiguration";
    for (NSString *s in @[
        @"isStoriesTrayOnAllTabsEnabled",
        @"showCinemaStoriesTrayOnSwipeUp",
        @"isDynamicTabStoryGridEnabled",
        @"isVerticalStoriesTray",
        @"isFeedCullingOnStoriesAccessEnabled",
        @"isHomecomingStoriesAccessFaceClusterEnabled",
    ]) { on ? SRBO(hc, s, NO, YES) : CRBO(hc, s, NO); }

    // IGNavConfiguration base — Swift, instance method (NOVO)
    // Mangled: _TtC(18)IGNavConfiguration(18)IGNavConfiguration
    // enableStoriesTabHeaderButton confirmado via __objc_methname + FLEX
    NSString *nc = @"_TtC18IGNavConfiguration18IGNavConfiguration";
    on ? SRBO(nc, @"enableStoriesTabHeaderButton", NO, YES)
       : CRBO(nc, @"enableStoriesTabHeaderButton", NO);
}

+ (BOOL)isStoryTrayActive {
    NSString *hc = @"_TtC18IGNavConfiguration25IGHomecomingConfiguration";
    NSNumber *v = [SCIGatingCatalog runtimeBoolOverrideStateForClass:hc
                                                            selector:@"isStoriesTrayOnAllTabsEnabled"
                                                         classMethod:NO];
    return v != nil && v.boolValue;
}

// ─── Instagram Wordmark ───────────────────────────────────────────────────────

+ (void)applyWordmark:(NSInteger)variant {
    // IGDSLauncherConfig — ObjC, instance methods, mutually exclusive flags
    // Confirmados via __objc_methname scan de FBSharedFramework
    // Mapas visuais (confirmados por screenshots FLEX + logo preview):
    //   variant 1 = isIGWordmark1aAltEnabled  → fonte arredondada moderna
    //   variant 2 = isIGWordmark1aEnabled     → itálica condensada
    //   variant 3 = isIGWordmark1bAltEnabled  → sans-serif limpa bold
    //   variant 4 = isIGWordmark1bEnabled     → geométrica condensada
    NSString *ds = @"IGDSLauncherConfig";
    NSArray<NSString *> *sels = @[
        @"isIGWordmark1aAltEnabled",
        @"isIGWordmark1aEnabled",
        @"isIGWordmark1bAltEnabled",
        @"isIGWordmark1bEnabled",
    ];
    for (NSUInteger i = 0; i < sels.count; i++) {
        BOOL active = (variant > 0 && (NSInteger)(i + 1) == variant);
        active ? SRBO(ds, sels[i], NO, YES) : CRBO(ds, sels[i], NO);
    }
}

+ (NSInteger)activeWordmarkVariant {
    NSString *ds = @"IGDSLauncherConfig";
    NSArray<NSString *> *sels = @[
        @"isIGWordmark1aAltEnabled",
        @"isIGWordmark1aEnabled",
        @"isIGWordmark1bAltEnabled",
        @"isIGWordmark1bEnabled",
    ];
    for (NSUInteger i = 0; i < sels.count; i++) {
        NSNumber *v = [SCIGatingCatalog runtimeBoolOverrideStateForClass:ds
                                                                selector:sels[i]
                                                             classMethod:NO];
        if (v != nil && v.boolValue) return (NSInteger)(i + 1);
    }
    return 0;
}

+ (void)installWordmarkPrefObserver {
    [SCIPrefObserver observeKey:kWordmarkKey handler:^{
        NSString *val = [[NSUserDefaults standardUserDefaults] stringForKey:kWordmarkKey];
        NSInteger variant = [[SCIBulkGatingPresets igWordmarkVariantMap][val ?: @"off"] integerValue];
        [SCIBulkGatingPresets applyWordmark:variant];
    }];
}


+ (NSArray<NSString *> *)igWordmarkModes {
    return @[@"off", @"1a_alt", @"1a", @"1b_alt", @"1b"];
}

+ (NSDictionary<NSString *, NSNumber *> *)igWordmarkVariantMap {
    return @{
        @"off": @0,
        @"1a_alt": @1,
        @"1a": @2,
        @"1b_alt": @3,
        @"1b": @4,
    };
}

+ (void)applyIGWordmarkMode:(NSString *)mode {
    NSString *m = [[self igWordmarkModes] containsObject:(mode ?: @"")] ? mode : @"off";
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kWordmarkKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSInteger variant = [[self igWordmarkVariantMap][m] integerValue];
    [self applyWordmark:variant];
}

+ (NSString *)currentIGWordmarkMode {
    NSString *m = [[NSUserDefaults standardUserDefaults] stringForKey:kWordmarkKey] ?: @"off";
    return [[self igWordmarkModes] containsObject:m] ? m : @"off";
}

@end
