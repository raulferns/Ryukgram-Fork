#import "RYGDeveloperTopicViewController.h"
#import "RYGDeveloperTypedFeatureViewController.h"
#import <objc/runtime.h>

@interface RYGDeveloperTopicViewController (RYGTypedFeaturePort)
- (void)ryg_typedPort_rebuildRows;
- (void)ryg_typedPort_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation RYGDeveloperTopicViewController (RYGTypedFeaturePort)

- (void)ryg_typedPort_rebuildRows {
    // After method exchange this invokes the original implementation first, so
    // every validated native control/action remains owned by the existing Topic.
    [self ryg_typedPort_rebuildRows];

    NSArray *originalRows = nil;
    @try { originalRows = [self valueForKey:@"rows"]; } @catch (__unused NSException *exception) { return; }
    if (![originalRows isKindOfClass:NSArray.class] || !originalRows.count) return;

    NSMutableArray *ported = [NSMutableArray arrayWithCapacity:originalRows.count];
    for (id raw in originalRows) {
        if (![raw isKindOfClass:NSDictionary.class]) { [ported addObject:raw]; continue; }
        NSDictionary *row = raw;
        NSString *kind = row[@"kind"];
        if (![kind isEqualToString:@"browser"]) { [ported addObject:row]; continue; }

        NSMutableDictionary *typed = [row mutableCopy];
        typed[@"kind"] = @"typedFeature";
        NSString *subtitle = row[@"subtitle"];
        if (!subtitle.length) subtitle = @"Resolved MobileConfig/runtime parameters · typed values only";
        typed[@"subtitle"] = subtitle;
        [ported addObject:typed.copy];
    }

    @try {
        [self setValue:ported.copy forKey:@"rows"];
        [self.tableView reloadData];
    } @catch (__unused NSException *exception) {}
}

- (void)ryg_typedPort_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = nil;
    @try { rows = [self valueForKey:@"rows"]; } @catch (__unused NSException *exception) {}
    if (indexPath.row >= 0 && (NSUInteger)indexPath.row < rows.count) {
        id raw = rows[(NSUInteger)indexPath.row];
        if ([raw isKindOfClass:NSDictionary.class]) {
            NSDictionary *row = raw;
            if ([row[@"kind"] isEqualToString:@"typedFeature"]) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                RYGDeveloperTypedFeatureViewController *controller = [[RYGDeveloperTypedFeatureViewController alloc]
                    initWithTitle:row[@"title"] ?: @"Feature Flags"
                            query:row[@"query"] ?: @""];
                [self.navigationController pushViewController:controller animated:YES];
                return;
            }
        }
    }
    [self ryg_typedPort_tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end

__attribute__((constructor(217))) static void RYGInstallDeveloperTypedFeaturePort(void) {
    @autoreleasepool {
        Class cls = RYGDeveloperTopicViewController.class;
        Method originalRebuild = class_getInstanceMethod(cls, NSSelectorFromString(@"rebuildRows"));
        Method portedRebuild = class_getInstanceMethod(cls, @selector(ryg_typedPort_rebuildRows));
        if (originalRebuild && portedRebuild) method_exchangeImplementations(originalRebuild, portedRebuild);

        Method originalSelect = class_getInstanceMethod(cls, @selector(tableView:didSelectRowAtIndexPath:));
        Method portedSelect = class_getInstanceMethod(cls, @selector(ryg_typedPort_tableView:didSelectRowAtIndexPath:));
        if (originalSelect && portedSelect) method_exchangeImplementations(originalSelect, portedSelect);
    }
}
