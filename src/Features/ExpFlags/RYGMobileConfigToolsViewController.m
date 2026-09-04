#import "RYGMobileConfigToolsViewController.h"
#import "RYGFastMobileConfigBrowserViewController.h"
#import "RYGMobileConfig.h"
#import "RYGMobileConfigJSONIO.h"
#import "../../Utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, RYGMCImportOperation) {
    RYGMCImportOperationNone = 0,
    RYGMCImportOperationOverrides,
};

@interface RYGMobileConfigToolsViewController () <UIDocumentPickerDelegate>
@property (nonatomic, assign) RYGMCImportOperation pendingImportOperation;
@end

@implementation RYGMobileConfigToolsViewController

- (instancetype)init { return [super initWithTitle:@"MobileConfig Runtime"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    [RYGMobileConfig.shared prepare];
    [self rebuildSections];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)rebuildSections {
    __weak typeof(self) weakSelf = self;

    RYGSetting *browser = [RYGSetting navigationCellWithTitle:@"MobileConfig Runtime Browser"
                                                     subtitle:@"Typed parameters from Instagram's live exported table"
                                                         icon:[RYGSymbol symbolWithName:@"sliders"]
                                               viewController:[RYGFastMobileConfigBrowserViewController new]];

    RYGSetting *importOverrides = [RYGSetting buttonCellWithTitle:@"Import runtime snapshot / overrides"
                                                         subtitle:@"Typed snapshot restores its explicit overrides only; canonical overrides are also accepted"
                                                             icon:[RYGSymbol symbolWithName:@"download"]
                                                           action:^{ [weakSelf presentJSONPicker:RYGMCImportOperationOverrides]; }];
    RYGSetting *exportSnapshot = [RYGSetting buttonCellWithTitle:@"Export current runtime configuration"
                                                        subtitle:@"Every live typed PID, effective value and explicit override"
                                                            icon:[RYGSymbol symbolWithName:@"share"]
                                                          action:^{ [weakSelf exportRuntimeSnapshot]; }];
    RYGSetting *exportOverrides = [RYGSetting buttonCellWithTitle:@"Export active runtime overrides"
                                                         subtitle:@"Portable JSON snapshot; Instagram files remain read-only"
                                                             icon:[RYGSymbol symbolWithName:@"share"]
                                                           action:^{ [weakSelf exportOverrides]; }];
    RYGSetting *applyOverrides = [RYGSetting buttonCellWithTitle:@"Apply active typed overrides"
                                                        subtitle:@"FBMobileConfigStartupConfigs + exact persisted getter hooks"
                                                            icon:[RYGSymbol symbolWithName:@"arrow.clockwise"]
                                                          action:^{
        RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
        [mobileConfig reapplyOverridesToNativeTable];
        [RYGUtils showToastForDuration:1.5 title:@"Runtime overrides applied" subtitle:[NSString stringWithFormat:@"%lu active", (unsigned long)mobileConfig.overrideCount]];
    }];
    RYGSetting *clearOverrides = [RYGSetting buttonCellWithTitle:@"Clear overrides"
                                                        subtitle:@""
                                                            icon:[RYGSymbol symbolWithName:@"trash"]
                                                          action:^{ [weakSelf confirmClearOverrides]; }];
    clearOverrides.titleColor = UIColor.systemRedColor;

    NSString *footer = @"The runtime parameter table and stable typed IDs are authoritative. id_name_mapping.json is no longer a browser dependency; names, when available, are optional labels. The app-owned mc_overrides.json is never overwritten.";

    [self applySettingSections:@[
        [RYGSettingsViewController sectionWithHeader:nil footer:nil rows:@[browser]],
        [RYGSettingsViewController sectionWithHeader:@"Runtime snapshots" footer:footer rows:@[importOverrides, exportSnapshot, exportOverrides, applyOverrides, clearOverrides]],
    ]];
}

- (void)presentJSONPicker:(RYGMCImportOperation)operation {
    self.pendingImportOperation = operation;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.pendingImportOperation = RYGMCImportOperationNone;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    RYGMCImportOperation operation = self.pendingImportOperation;
    self.pendingImportOperation = RYGMCImportOperationNone;
    if (!url) return;

    BOOL access = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (access) [url stopAccessingSecurityScopedResource];
    if (!data.length) {
        [RYGUtils showErrorHUDWithDescription:readError.localizedDescription ?: @"Could not read JSON"];
        return;
    }

    RYGMobileConfig *mobileConfig = RYGMobileConfig.shared;
    NSError *error = nil;
    if (operation == RYGMCImportOperationOverrides) {
        NSUInteger applied = 0;
        BOOL runtimeSnapshot = [mobileConfig ryg_isRuntimeSnapshotData:data];
        BOOL imported = runtimeSnapshot
            ? [mobileConfig ryg_importRuntimeSnapshotOverridesData:data appliedCount:&applied error:&error]
            : [mobileConfig ryg_importAndApplyOverridesData:data appliedCount:&applied error:&error];
        if (!imported) {
            [RYGUtils showErrorHUDWithDescription:error.localizedDescription ?: @"Override import failed"];
            return;
        }
        [RYGUtils showToastForDuration:1.5
                                title:runtimeSnapshot ? @"Runtime snapshot imported" : @"Canonical overrides imported"
                             subtitle:[NSString stringWithFormat:@"%lu typed override(s) applied", (unsigned long)applied]];
        [self rebuildSections];
    }
}

- (void)shareData:(NSData *)data fileName:(NSString *)fileName {
    if (!data.length) return;
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:fileName];
    NSError *error = nil;
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [RYGUtils showErrorHUDWithDescription:error.localizedDescription ?: @"Could not create export"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        activity.popoverPresentationController.sourceView = self.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), 80.0, 1.0, 1.0);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)exportOverrides {
    NSError *error = nil;
    NSData *data = [RYGMobileConfig.shared ryg_exportOverridesData:&error];
    if (!data.length) {
        [RYGUtils showErrorHUDWithDescription:error.localizedDescription ?: @"No overrides available"];
        return;
    }
    [self shareData:data fileName:@"ryukgram_mobileconfig_runtime_overrides.json"];
}

- (void)exportRuntimeSnapshot {
    [RYGUtils showToastForDuration:1.0 title:@"Reading runtime configuration" subtitle:@"Export continues in the background"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSData *data = [RYGMobileConfig.shared ryg_exportRuntimeSnapshotData:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!data.length) {
                [RYGUtils showErrorHUDWithDescription:error.localizedDescription ?: @"No runtime configuration is available"];
                return;
            }
            [self shareData:data fileName:@"ryukgram_mobileconfig_runtime_snapshot.json"];
        });
    });
}

- (void)confirmClearOverrides {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear overrides?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [RYGMobileConfig.shared resetAllOverrides];
        [weakSelf rebuildSections];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
