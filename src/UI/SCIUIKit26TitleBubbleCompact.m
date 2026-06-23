#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SCIUIKit26TitleBubbleView : UIVisualEffectView
- (void)configureWithTitle:(NSString *)title;
@end

static void SCICompactTuneTitleLabels(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        label.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.70;
        label.lineBreakMode = NSLineBreakByClipping;
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    }
    for (UIView *subview in view.subviews) SCICompactTuneTitleLabels(subview);
    [view invalidateIntrinsicContentSize];
    [view setNeedsLayout];
}

@implementation SCIUIKit26TitleBubbleView (SCICompactTitleBubble)

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(configureWithTitle:));
    Method replacement = class_getInstanceMethod(self, @selector(sci_compact_configureWithTitle:));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

- (void)sci_compact_configureWithTitle:(NSString *)title {
    [self sci_compact_configureWithTitle:title];
    SCICompactTuneTitleLabels(self);
}

@end
