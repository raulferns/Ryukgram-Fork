#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Liquid Glass is a presentation concern of RyukGram's own UI. Instagram's
/// Lucent/Prism experiments remain completely separate from this layer.
FOUNDATION_EXPORT BOOL RYGLiquidGlassIsAvailable(void);

/// Creates a public UIKit UIGlassEffect surface on iOS 26+, with a system
/// material fallback on older releases and an opaque accessibility fallback
/// when Reduce Transparency is enabled.
FOUNDATION_EXPORT UIVisualEffectView *RYGLiquidGlassView(BOOL interactive,
                                                        BOOL clearStyle,
                                                        UIColor * _Nullable tintColor);

/// Updates the tint of a view returned by RYGLiquidGlassView.
FOUNDATION_EXPORT void RYGLiquidGlassSetTint(UIVisualEffectView *view,
                                             UIColor * _Nullable tintColor);

/// Uses the SDK 26 public glass button configurations while preserving visible
/// content and native menu behavior. It never imposes a fixed menu width.
FOUNDATION_EXPORT void RYGLiquidGlassConfigureButton(UIButton *button,
                                                     BOOL prominent);

/// Compatibility helper for older RyukGram screens that still assign a custom
/// titleView. It now returns a plain, single-line label; the actual Liquid Glass
/// material belongs to UINavigationBar on iOS 26 rather than to a second pill.
FOUNDATION_EXPORT UIView *RYGLiquidGlassNavigationTitleView(NSString *title);

/// Configures a RyukGram-owned navigation controller to use system navigation
/// chrome. When linked against SDK 26.5, UIKit supplies native Liquid Glass to
/// navigation/tool bars and UIBarButtonItems automatically.
FOUNDATION_EXPORT void RYGLiquidGlassConfigureNavigationController(UINavigationController *navigationController);

/// Applies the shared RyukGram UI policy. Content stays on semantic system
/// backgrounds, native navigation chrome owns the glass, and standalone custom
/// controls use public SDK 26 glass configurations where appropriate.
FOUNDATION_EXPORT void RYGLiquidGlassApplyToViewController(UIViewController *controller);

/// True for RyukGram-owned controllers (including navigation containers whose
/// visible/root controller is RyukGram-owned).
FOUNDATION_EXPORT BOOL RYGIsOwnedViewController(UIViewController *controller);

NS_ASSUME_NONNULL_END
