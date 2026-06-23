#import "SCIUIKit26LiquidGlass.h"
#import <objc/message.h>

void SCIUIKit26ConfigureSearchNavigationItem(UINavigationItem *navigationItem) {
    if (!navigationItem) return;

    if (@available(iOS 26.0, *)) {
        // Keep UIKit in charge of placement. Do not force IntegratedButton/4;
        // that was the source of the bottom/nested search regression.
        SEL setPlacement = NSSelectorFromString(@"setPreferredSearchBarPlacement:");
        if ([navigationItem respondsToSelector:setPlacement]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(navigationItem, setPlacement, 0);
        }
    }

    UISearchController *searchController = navigationItem.searchController;
    if (searchController.searchBar) {
        SCIUIKit26ConfigureSearchBar(searchController.searchBar);
    }
}
