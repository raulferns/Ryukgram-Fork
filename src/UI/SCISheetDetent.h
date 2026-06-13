#import <UIKit/UIKit.h>
#import <objc/message.h>

// iOS 16's customDetentWithIdentifier:resolver:, reached by runtime dispatch so
// the call still compiles under the iOS 15 SDK (where the symbol is absent) and
// returns nil on iOS 15 at runtime — callers fall back to medium/large.
static inline UISheetPresentationControllerDetent *
SCICustomSheetDetent(NSString *identifier, CGFloat (^resolver)(CGFloat maxValue)) {
	Class cls = NSClassFromString(@"UISheetPresentationControllerDetent");
	SEL sel = NSSelectorFromString(@"customDetentWithIdentifier:resolver:");
	if (![cls respondsToSelector:sel]) return nil;
	UISheetPresentationControllerDetent *(*build)(Class, SEL, NSString *, CGFloat (^)(id)) =
		(UISheetPresentationControllerDetent *(*)(Class, SEL, NSString *, CGFloat (^)(id)))objc_msgSend;
	return build(cls, sel, identifier, ^CGFloat(id ctx) {
		CGFloat (*maxVal)(id, SEL) = (CGFloat (*)(id, SEL))objc_msgSend;
		return resolver(maxVal(ctx, NSSelectorFromString(@"maximumDetentValue")));
	});
}
