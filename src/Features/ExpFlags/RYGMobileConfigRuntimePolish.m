#import "RYGFastMobileConfigBrowserViewController.h"
#import "RYGMobileConfigToolsViewController.h"
#import "RYGMobileConfig.h"
#import "../../Utils.h"
#import <objc/runtime.h>

static IMP gRYGMCDetailCellOriginal;
static IMP gRYGMCDetailSelectOriginal;
static IMP gRYGMCDetailSwipeOriginal;

static RYGMCParam *RYGMCPolishParamAt(id controller, NSIndexPath *indexPath) {
    if (!controller || !indexPath) return nil;
    NSArray *params = nil;
    @try { params = [controller valueForKey:@"visibleParams"]; } @catch (__unused NSException *exception) { return nil; }
    if (![params isKindOfClass:NSArray.class] || indexPath.row < 0 || (NSUInteger)indexPath.row >= params.count) return nil;
    id candidate = params[(NSUInteger)indexPath.row];
    return [candidate isKindOfClass:RYGMCParam.class] ? candidate : nil;
}

static BOOL RYGMCPolishEditable(RYGMCParam *param) {
    return param && param.isRuntimeBacked && RYGMCTypeIsRuntimeValue(param.type);
}

static UITableViewCell *RYGMCPolishDetailCell(id self, SEL cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = gRYGMCDetailCellOriginal
        ? ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))gRYGMCDetailCellOriginal)(self, cmd, tableView, indexPath)
        : nil;
    RYGMCParam *param = RYGMCPolishParamAt(self, indexPath);
    if (!cell || !param || RYGMCPolishEditable(param)) return cell;

    // A mapping label without a resolved runtime type is descriptive only. Do
    // not infer Boolean/number/string from its name or ask the user to guess.
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSString *existing = cell.detailTextLabel.text ?: @"";
    NSString *suffix = @"type unresolved · read-only mapping";
    cell.detailTextLabel.text = existing.length ? [NSString stringWithFormat:@"%@\n%@", existing, suffix] : suffix;
    cell.detailTextLabel.numberOfLines = 3;
    return cell;
}

static void RYGMCPolishDetailSelect(id self, SEL cmd, UITableView *tableView, NSIndexPath *indexPath) {
    RYGMCParam *param = RYGMCPolishParamAt(self, indexPath);
    if (param && !RYGMCPolishEditable(param)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [RYGUtils showToastForDuration:1.2 title:@"Read-only mapping" subtitle:@"Runtime type/backing has not been resolved"];
        return;
    }
    if (gRYGMCDetailSelectOriginal)
        ((void (*)(id, SEL, UITableView *, NSIndexPath *))gRYGMCDetailSelectOriginal)(self, cmd, tableView, indexPath);
}

static UISwipeActionsConfiguration *RYGMCPolishDetailSwipe(id self, SEL cmd, UITableView *tableView, NSIndexPath *indexPath) {
    RYGMCParam *param = RYGMCPolishParamAt(self, indexPath);
    if (param && !RYGMCPolishEditable(param)) return nil;
    return gRYGMCDetailSwipeOriginal
        ? ((UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))gRYGMCDetailSwipeOriginal)(self, cmd, tableView, indexPath)
        : nil;
}

@interface RYGFastMobileConfigBrowserViewController (RYGMCPolish)
- (void)ryg_mcPolish_viewDidLoad;
@end

@implementation RYGFastMobileConfigBrowserViewController (RYGMCPolish)
- (void)ryg_mcPolish_viewDidLoad {
    [self ryg_mcPolish_viewDidLoad];
    self.title = @"MobileConfig Runtime";
}
@end

@interface RYGMobileConfigToolsViewController (RYGMCPolish)
- (void)ryg_mcToolsPolish_viewDidLoad;
@end

@implementation RYGMobileConfigToolsViewController (RYGMCPolish)
- (void)ryg_mcToolsPolish_viewDidLoad {
    [self ryg_mcToolsPolish_viewDidLoad];
    self.title = @"MobileConfig Runtime";
}
@end

static void RYGMCExchange(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

__attribute__((constructor(218))) static void RYGInstallMobileConfigRuntimePolish(void) {
    @autoreleasepool {
        RYGMCExchange(RYGFastMobileConfigBrowserViewController.class,
                      @selector(viewDidLoad), @selector(ryg_mcPolish_viewDidLoad));
        RYGMCExchange(RYGMobileConfigToolsViewController.class,
                      @selector(viewDidLoad), @selector(ryg_mcToolsPolish_viewDidLoad));

        Class detail = objc_lookUpClass("RYGFastMCConfigDetailViewController");
        if (!detail) return;

        SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
        Method cellMethod = class_getInstanceMethod(detail, cellSelector);
        if (cellMethod) {
            gRYGMCDetailCellOriginal = method_getImplementation(cellMethod);
            method_setImplementation(cellMethod, (IMP)RYGMCPolishDetailCell);
        }

        SEL selectSelector = @selector(tableView:didSelectRowAtIndexPath:);
        Method selectMethod = class_getInstanceMethod(detail, selectSelector);
        if (selectMethod) {
            gRYGMCDetailSelectOriginal = method_getImplementation(selectMethod);
            method_setImplementation(selectMethod, (IMP)RYGMCPolishDetailSelect);
        }

        SEL swipeSelector = @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:);
        Method swipeMethod = class_getInstanceMethod(detail, swipeSelector);
        if (swipeMethod) {
            gRYGMCDetailSwipeOriginal = method_getImplementation(swipeMethod);
            method_setImplementation(swipeMethod, (IMP)RYGMCPolishDetailSwipe);
        }
    }
}
