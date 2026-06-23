#import "SCISearchBarStyler.h"
#import "../Utils.h"

@implementation SCISearchBarStyler

+ (BOOL)shouldUseNativeGlass {
	return [SCIUtils getBoolPref:@"liquid_glass_buttons"];
}

+ (UIColor *)searchFieldColor {
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
		return tc.userInterfaceStyle == UIUserInterfaceStyleDark
			? [UIColor colorWithRed:58.0 / 255.0 green:58.0 / 255.0 blue:60.0 / 255.0 alpha:1.0]
			: [UIColor colorWithRed:232.0 / 255.0 green:232.0 / 255.0 blue:237.0 / 255.0 alpha:1.0];
	}];
}

+ (UIColor *)placeholderColor {
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
		return tc.userInterfaceStyle == UIUserInterfaceStyleDark
			? [UIColor colorWithWhite:0.72 alpha:1.0]
			: [UIColor colorWithWhite:0.42 alpha:1.0];
	}];
}

+ (void)resetSearchBar:(UISearchBar *)searchBar {
	if (!searchBar) return;

	searchBar.backgroundImage = nil;
	searchBar.barTintColor = nil;
	searchBar.backgroundColor = UIColor.clearColor;

	UITextField *field = searchBar.searchTextField;
	field.borderStyle = UITextBorderStyleRoundedRect;
	field.backgroundColor = nil;
	field.layer.backgroundColor = nil;
	field.layer.cornerRadius = 0.0;
	field.layer.masksToBounds = NO;
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
	if (!searchBar) return;

	if ([self shouldUseNativeGlass]) {
		[self resetSearchBar:searchBar];
		return;
	}

	UITextField *field = searchBar.searchTextField;
	if (!field) return;

	UIColor *fill = [self searchFieldColor];
	UIColor *placeholder = [self placeholderColor];

	searchBar.searchBarStyle = UISearchBarStyleMinimal;
	searchBar.backgroundImage = UIImage.new;
	searchBar.barTintColor = UIColor.clearColor;
	searchBar.backgroundColor = UIColor.clearColor;
	searchBar.translucent = YES;

	field.borderStyle = UITextBorderStyleNone;
	field.backgroundColor = fill;
	field.textColor = UIColor.labelColor;
	field.tintColor = SCIUtils.SCIColor_Primary;
	field.layer.backgroundColor = [fill resolvedColorWithTraitCollection:searchBar.traitCollection].CGColor;
	field.layer.cornerRadius = 18.0;
	field.layer.cornerCurve = kCACornerCurveContinuous;
	field.layer.masksToBounds = YES;
	field.clipsToBounds = YES;

	field.leftView.tintColor = placeholder;
	field.rightView.tintColor = placeholder;

	NSString *text = field.attributedPlaceholder.string ?: field.placeholder ?: SCILocalized(@"Search");
	field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:text attributes:@{
		NSForegroundColorAttributeName: placeholder
	}];
}

@end
