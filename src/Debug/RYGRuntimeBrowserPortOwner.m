#import "RYGPortedRuntimeBrowserViewController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Route every legacy Developer topic entrypoint that previously pushed the
// class-drill-down browser into the WATweaks-style flat typed runtime browser.
// Keeping the selector means old experimental/topic code does not need to know
// which concrete browser implementation owns the port.
static void RYGPushPortedRuntimeBrowser(id self, SEL _cmd, NSString *title, NSString *query, BOOL bulk) {
    (void)_cmd;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *owner = (UIViewController *)self;
    RYGPortedRuntimeBrowserViewController *browser = [[RYGPortedRuntimeBrowserViewController alloc]
        initWithTitle:(title.length ? title : @"Runtime Browser")
        initialQuery:(query ?: @"")
        allowsBulkVisibilityOverride:bulk];
    if (owner.navigationController) [owner.navigationController pushViewController:browser animated:YES];
    else {
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:browser];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [owner presentViewController:navigation animated:YES completion:nil];
    }
}

static void RYGInstallRuntimeBrowserPortRoute(void) {
    Class topic = NSClassFromString(@"RYGDeveloperTopicViewController");
    SEL selector = NSSelectorFromString(@"pushRuntimeBrowserWithTitle:query:bulk:");
    if (!topic || !selector) return;
    Method method = class_getInstanceMethod(topic, selector);
    if (!method || method_getNumberOfArguments(method) != 5) return;
    const char *types = method_getTypeEncoding(method);
    class_replaceMethod(topic, selector, (IMP)RYGPushPortedRuntimeBrowser, types ?: "v@:@@B");
}

__attribute__((constructor(245))) static void RYGRuntimeBrowserPortOwnerCtor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        RYGInstallRuntimeBrowserPortRoute();
        // The class is part of this dylib, but +load order can still place this
        // owner before the topic class registration on some builds.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RYGInstallRuntimeBrowserPortRoute(); });
    });
}
