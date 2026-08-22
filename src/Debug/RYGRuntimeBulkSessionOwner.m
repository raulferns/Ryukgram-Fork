#import "RYGFastRuntimeBrowserViewController.h"
#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeHookManager.h"
#import "../Utils.h"
#import <objc/runtime.h>

// Reveal All is intentionally process-local. Persisting every visibility match
// was the mechanism that could grow the startup replay set into hundreds or
// thousands of hooks. Individual Force On/Off choices still persist normally.

@implementation RYGFastRuntimeBrowserViewController (RYGRuntimeBulkSessionOwner)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"revealAllVisibilityRows"));
        Method replacement = class_getInstanceMethod(self, @selector(ryg_session_revealAllVisibilityRows));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ryg_session_revealAllVisibilityRows {
    UISegmentedControl *mode = [self valueForKey:@"modeControl"];
    if (!mode || mode.selectedSegmentIndex != 0) return;
    NSDictionary *selectorMatches = [self valueForKey:@"selectorMatches"];
    if (![selectorMatches isKindOfClass:NSDictionary.class] || !selectorMatches.count) return;

    NSUInteger changed = 0;
    for (id rawMembers in selectorMatches.allValues) {
        if (![rawMembers isKindOfClass:NSArray.class]) continue;
        for (id rawMember in (NSArray *)rawMembers) {
            if (![rawMember isKindOfClass:RYGRuntimeMemberRow.class]) continue;
            RYGRuntimeBoolMethod *method = [RYGRuntimeBrowserEngine boolMethodForMember:(RYGRuntimeMemberRow *)rawMember];
            if (!method) continue;
            NSString *lower = method.selectorName.lowercaseString ?: @"";
            NSString *name = [[lower componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                componentsJoinedByString:@""];
            NSNumber *desired = nil;
            if ([name hasPrefix:@"ishidden"] || [name hasPrefix:@"shouldhide"] || [name hasPrefix:@"hide"]) desired = @NO;
            else if ([name hasPrefix:@"shouldshow"] || [name hasPrefix:@"canshow"] ||
                     [name hasPrefix:@"isvisible"] || [name hasPrefix:@"isavailable"] ||
                     [name hasPrefix:@"shoulddisplay"]) desired = @YES;
            if (!desired) continue;
            if ([RYGRuntimeHookManager setSessionOverride:desired forMethod:method]) changed++;
        }
    }

    UITableView *table = [self valueForKey:@"tableView"];
    [table reloadData];
    [RYGUtils showToastForDuration:1.4
                             title:@"Settings visibility applied"
                          subtitle:[NSString stringWithFormat:@"%lu exact gate(s) · session only", (unsigned long)changed]];
}

@end
