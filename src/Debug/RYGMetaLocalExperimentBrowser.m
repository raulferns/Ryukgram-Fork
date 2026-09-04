#import "RYGMetaLocalExperimentBrowser.h"
#import "../Utils.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@implementation RYGMetaLocalExperimentBrowser

+ (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
        }
        if (keyWindow) break;
    }
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:UINavigationController.class]) {
        return ((UINavigationController *)top).visibleViewController ?: top;
    }
    if ([top isKindOfClass:UITabBarController.class]) {
        return ((UITabBarController *)top).selectedViewController ?: top;
    }
    return top;
}

+ (NSArray *)experimentConfigs {
    // The current build exposes the family-local source of truth directly.
    // Prefer its generated config set over allocating every protocol conformer,
    // which can mix LID and FDID configurations with the wrong generator.
    Class generatorClass = NSClassFromString(@"FDIDExperimentGenerator");
    SEL generate = NSSelectorFromString(@"generateConfigs");
    Method generateMethod = generatorClass ? class_getClassMethod(generatorClass, generate) : NULL;
    if (generateMethod && method_getNumberOfArguments(generateMethod) == 2) {
        char returnType[32] = {0};
        method_getReturnType(generateMethod, returnType, sizeof(returnType));
        if (returnType[0] == '@') {
            @try {
                id generated = ((id (*)(id, SEL))objc_msgSend)((id)generatorClass, generate);
                if ([generated isKindOfClass:NSArray.class] && [generated count]) return generated;
            } @catch (__unused id exception) {}
        }
    }

    Protocol *protocol = objc_getProtocol("MetaLocalExperimentConfigProtocol");
    if (!protocol) return @[];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @[];
    NSMutableArray *configs = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (!cls || !class_conformsToProtocol(cls, protocol)) continue;
        @try {
            id object = [[cls alloc] init];
            if (object) [configs addObject:object];
        } @catch (__unused id exception) {}
    }
    free(classes);
    return configs.copy;
}

+ (id)experimentGenerator {
    Class idProvider = NSClassFromString(@"OdinFamilyDeviceIDSignalProvider");
    SEL currentIDSelector = NSSelectorFromString(@"currentFamilyDeviceID");
    Method currentIDMethod = idProvider ? class_getClassMethod(idProvider, currentIDSelector) : NULL;
    id familyDeviceID = nil;
    if (currentIDMethod && method_getNumberOfArguments(currentIDMethod) == 2) {
        char returnType[32] = {0};
        method_getReturnType(currentIDMethod, returnType, sizeof(returnType));
        if (returnType[0] == '@') {
            @try { familyDeviceID = ((id (*)(id, SEL))objc_msgSend)((id)idProvider, currentIDSelector); }
            @catch (__unused id exception) {}
        }
    }

    Class cls = NSClassFromString(@"FDIDExperimentGenerator");
    SEL selector = NSSelectorFromString(@"initWithFamilyDeviceID:logger:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4) return nil;
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], selector, familyDeviceID, nil);
    } @catch (__unused id exception) {
        return nil;
    }
}

+ (void)dismissMetaLocalExperiment:(__unused id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        UINavigationController *navigation = [top isKindOfClass:UINavigationController.class]
            ? (UINavigationController *)top : top.navigationController;
        UIViewController *target = navigation ?: top;
        if (target.presentingViewController && !target.isBeingDismissed) {
            [target dismissViewControllerAnimated:YES completion:nil];
        } else if (navigation.viewControllers.count > 1) {
            [navigation popViewControllerAnimated:YES];
        }
    });
}

+ (void)installCloseButton:(UIViewController *)controller {
    if (!controller) return;
    UIImage *image = [UIImage systemImageNamed:@"chevron.left"];
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:image
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(dismissMetaLocalExperiment:)];
}

+ (void)presentFromCurrentViewController {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            [RYGUtils showErrorHUDWithDescription:@"No active presentation controller"];
            return;
        }

        Class listClass = NSClassFromString(@"MetaLocalExperimentListViewController");
        if (!listClass) {
            [RYGUtils showErrorHUDWithDescription:@"MetaLocalExperimentListViewController is not loaded"];
            return;
        }

        UIViewController *controller = nil;
        SEL initSelector = NSSelectorFromString(@"initWithExperimentConfigs:experimentGenerator:");
        @try {
            if ([listClass instancesRespondToSelector:initSelector]) {
                NSArray *configs = [self experimentConfigs];
                id generator = [self experimentGenerator];
                if (!configs.count || !generator) {
                    [RYGUtils showErrorHUDWithDescription:@"Family Local Experiment configs or FDID generator are unavailable"];
                    return;
                }
                controller = ((id (*)(id, SEL, id, id))objc_msgSend)([listClass alloc], initSelector, configs, generator);
            } else {
                controller = [[listClass alloc] init];
            }
        } @catch (__unused id exception) {}

        if (![controller isKindOfClass:UIViewController.class]) {
            [RYGUtils showErrorHUDWithDescription:@"MetaLocalExperiment native controller could not be initialized"];
            return;
        }

        SEL internalSelector = NSSelectorFromString(@"setIsSessionlessCaaInternal:");
        Method internalMethod = class_getInstanceMethod([controller class], internalSelector);
        if (internalMethod && method_getNumberOfArguments(internalMethod) == 3) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, internalSelector, YES);
        }

        [self installCloseButton:controller];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
        navigation.modalPresentationStyle = UIModalPresentationFullScreen;
        navigation.navigationBar.prefersLargeTitles = NO;
        [top presentViewController:navigation animated:YES completion:nil];
    });
}

@end
