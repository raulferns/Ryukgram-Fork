#import "RYGRuntimeBrowserEngine.h"
#import "RYGRuntimeValueStore.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <stdlib.h>

/*
 * Final interaction/chrome policy for the WATweaks runtime port.
 *
 * - Dynamic result counts never become the navigation title (the old glass
 *   title pill wrapped "FBSharedFramework (0)" into two lines on device).
 * - BOOL remains a direct UISwitch.
 * - Numeric and NSString rows no longer embed a fixed-width UITextField in the
 *   cell. They use a typed editor on tap, so the row owns the full available
 *   width and no arbitrary accessory width leaks into the layout.
 * - Foundation objects use a fullscreen text/JSON editor preserving the native
 *   Foundation type.
 * - Overrides are persisted before the immediate hook attempt and therefore
 *   remain pending for Apply, matching WATweaks dogfood2.
 */

static NSString *RYGWATUIShortImage(NSString *path) {
    if (!path.length) return @"Runtime";
    NSString *standard = path.stringByStandardizingPath;
    if ([standard isEqualToString:NSBundle.mainBundle.executablePath.stringByStandardizingPath]) return @"Instagram Executable";
    NSString *last = path.lastPathComponent ?: @"Runtime";
    if ([last.lowercaseString containsString:@"fbsharedframework"]) return @"FBSharedFramework";
    return last.length ? last : @"Runtime";
}

static RYGRuntimeMemberRow *RYGWATUIEntry(id controller, NSIndexPath *path) {
    SEL selector = NSSelectorFromString(@"entryAtIndexPath:");
    if (!controller || !path || ![controller respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, path);
}

static id RYGWATUIRawValue(id controller, RYGRuntimeMemberRow *entry) {
    SEL selector = NSSelectorFromString(@"currentForEntry:raw:");
    if (!controller || !entry || ![controller respondsToSelector:selector]) return nil;
    id raw = nil;
    ((id (*)(id, SEL, id, id *))objc_msgSend)(controller, selector, entry, &raw);
    return raw;
}

static void RYGWATUIReload(id controller) {
    SEL selector = NSSelectorFromString(@"applyFilter");
    if ([controller respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(controller, selector);
}

static BOOL RYGWATUIInstall(RYGRuntimeMemberRow *entry, id value) {
    if (!entry) return NO;
    RYGRuntimeValueSetOverride(entry.className, entry.name, entry.classMember, entry.valueTypeCode,
                               value ?: NSNull.null);
    return RYGRuntimeValueInstallHook(entry.className, entry.name, entry.classMember, entry.valueTypeCode);
}

static NSString *RYGWATUITextForObject(id value) {
    if (!value || value == NSNull.null) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSURL.class]) return [(NSURL *)value absoluteString] ?: @"";
    if ([value isKindOfClass:NSData.class]) return [(NSData *)value base64EncodedStringWithOptions:0] ?: @"";
    if ([value isKindOfClass:NSDate.class]) return [NSString stringWithFormat:@"%.6f", [(NSDate *)value timeIntervalSince1970]];
    id json = [value isKindOfClass:NSSet.class] ? [(NSSet *)value allObjects] : value;
    if ([NSJSONSerialization isValidJSONObject:json]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text.length) return text;
    }
    return [value description] ?: @"";
}

@interface RYGWATObjectEditorViewController : UIViewController
@property(nonatomic, strong) RYGRuntimeMemberRow *entry;
@property(nonatomic, strong) id nativeValue;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, copy) dispatch_block_t completion;
@end

@implementation RYGWATObjectEditorViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry.name.length ? self.entry.name : @"Runtime Object";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(save)];

    UILabel *meta = [UILabel new];
    meta.translatesAutoresizingMaskIntoConstraints = NO;
    meta.numberOfLines = 0;
    meta.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    meta.textColor = UIColor.secondaryLabelColor;
    meta.text = [NSString stringWithFormat:@"%@ · %@\n%@", self.entry.className ?: @"Runtime",
                 RYGRuntimeValueTypeName(self.entry.valueTypeCode) ?: @"object",
                 NSStringFromClass([self.nativeValue class]) ?: @"nil native object"];
    [self.view addSubview:meta];

    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    text.autocorrectionType = UITextAutocorrectionTypeNo;
    text.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    text.layer.cornerRadius = 14.0;
    text.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    id initial = RYGRuntimeValueHasOverride(self.entry.className, self.entry.name, self.entry.classMember)
        ? RYGRuntimeValueOverride(self.entry.className, self.entry.name, self.entry.classMember) : self.nativeValue;
    text.text = RYGWATUITextForObject(initial);
    self.textView = text;
    [self.view addSubview:text];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [meta.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [meta.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [meta.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [text.topAnchor constraintEqualToAnchor:meta.bottomAnchor constant:10],
        [text.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],
        [text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (id)parsedValue:(NSString **)error {
    NSString *text = self.textView.text ?: @"";
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    id current = self.nativeValue;
    if ([current isKindOfClass:NSString.class]) return text;
    if ([current isKindOfClass:NSURL.class]) {
        NSURL *url = [NSURL URLWithString:trim];
        if (!url && error) *error = @"Invalid URL";
        return url;
    }
    if ([current isKindOfClass:NSData.class]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:trim options:0];
        if (!data && error) *error = @"Invalid Base64";
        return data;
    }
    if ([current isKindOfClass:NSDate.class]) {
        const char *start = trim.UTF8String ?: ""; char *end = NULL; double value = strtod(start, &end);
        if (!end || end == start || *end != '\0' || !isfinite(value)) { if (error) *error = @"Invalid timestamp"; return nil; }
        return [NSDate dateWithTimeIntervalSince1970:value];
    }
    if (!current) { if (error) *error = @"Native object is nil; its Foundation class cannot be inferred safely."; return nil; }
    NSData *data = [trim dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError] : nil;
    if (!json || jsonError) { if (error) *error = jsonError.localizedDescription ?: @"Invalid JSON"; return nil; }
    if ([current isKindOfClass:NSSet.class]) {
        if (![json isKindOfClass:NSArray.class]) { if (error) *error = @"NSSet requires a JSON array"; return nil; }
        return [NSSet setWithArray:json];
    }
    if ([current isKindOfClass:NSArray.class] && ![json isKindOfClass:NSArray.class]) { if (error) *error = @"Expected JSON array"; return nil; }
    if ([current isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSDictionary.class]) { if (error) *error = @"Expected JSON object"; return nil; }
    return json;
}
- (void)save {
    NSString *error = nil;
    id value = [self parsedValue:&error];
    if (!value) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Invalid value" message:error ?: @"Could not parse value" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    (void)RYGWATUIInstall(self.entry, value);
    dispatch_block_t completion = self.completion;
    [self dismissViewControllerAnimated:YES completion:completion];
}
@end

static id RYGWATUIParseScalar(NSString *text, RYGRuntimeMemberRow *entry, BOOL *valid) {
    if (valid) *valid = NO;
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (RYGRuntimeValueTypeIsSignedInteger(entry.valueTypeCode)) {
        const char *start = trim.UTF8String ?: ""; char *end = NULL; long long value = strtoll(start, &end, 0);
        if (end && end != start && *end == '\0') { if (valid) *valid = YES; return @(value); }
    } else if (RYGRuntimeValueTypeIsUnsignedInteger(entry.valueTypeCode)) {
        if ([trim hasPrefix:@"-"]) return nil;
        const char *start = trim.UTF8String ?: ""; char *end = NULL; unsigned long long value = strtoull(start, &end, 0);
        if (end && end != start && *end == '\0') { if (valid) *valid = YES; return @(value); }
    } else if (RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode)) {
        NSString *normalized = [trim stringByReplacingOccurrencesOfString:@"," withString:@"."];
        const char *start = normalized.UTF8String ?: ""; char *end = NULL; double value = strtod(start, &end);
        if (end && end != start && *end == '\0' && isfinite(value)) { if (valid) *valid = YES; return @(value); }
    }
    return nil;
}

static void RYGWATUIPresentScalarEditor(id controller, RYGRuntimeMemberRow *entry, id raw) {
    BOOL overridden = RYGRuntimeValueHasOverride(entry.className, entry.name, entry.classMember);
    id current = overridden ? RYGRuntimeValueOverride(entry.className, entry.name, entry.classMember) : raw;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:entry.name
        message:[NSString stringWithFormat:@"%@ · %@\n%@", entry.className ?: @"Runtime",
                 RYGRuntimeValueTypeName(entry.valueTypeCode) ?: entry.valueTypeCode ?: @"?",
                 overridden ? @"Override persisted" : @"Native value"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current ? [current description] : @"";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.keyboardType = RYGRuntimeValueTypeIsFloatingPoint(entry.valueTypeCode)
            ? UIKeyboardTypeDecimalPad : UIKeyboardTypeNumbersAndPunctuation;
    }];
    __weak id weakController = controller;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        BOOL valid = NO;
        id value = RYGWATUIParseScalar(alert.textFields.firstObject.text ?: @"", entry, &valid);
        if (valid && value) (void)RYGWATUIInstall(entry, value);
        RYGWATUIReload(weakController);
    }]];
    if (overridden) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Use Native" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            RYGRuntimeValueClearOverride(entry.className, entry.name, entry.classMember);
            RYGWATUIReload(weakController);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static IMP gRYGWATImageViewDidLoad = NULL;
static IMP gRYGWATImageApplyFilter = NULL;
static IMP gRYGWATImageCell = NULL;
static IMP gRYGWATImageDidSelect = NULL;
static IMP gRYGWATRootViewDidLoad = NULL;

static void RYGWATFixImageTitle(id self) {
    NSString *path = nil;
    @try { path = [self valueForKey:@"imagePath"]; } @catch (__unused NSException *exception) {}
    NSString *title = RYGWATUIShortImage(path);
    UIViewController *controller = (UIViewController *)self;
    controller.title = title;
    controller.navigationItem.titleView = nil;
    controller.navigationItem.title = title;
}

static void RYGWATImageViewDidLoad(id self, SEL _cmd) {
    ((void (*)(id, SEL))gRYGWATImageViewDidLoad)(self, _cmd);
    RYGWATFixImageTitle(self);
}
static void RYGWATImageApplyFilter(id self, SEL _cmd) {
    ((void (*)(id, SEL))gRYGWATImageApplyFilter)(self, _cmd);
    RYGWATFixImageTitle(self);
}
static id RYGWATImageCell(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    UITableViewCell *cell = ((id (*)(id, SEL, id, id))gRYGWATImageCell)(self, _cmd, table, path);
    RYGRuntimeMemberRow *entry = RYGWATUIEntry(self, path);
    if (entry && !RYGRuntimeValueTypeIsBoolean(entry.valueTypeCode) && [cell.accessoryView isKindOfClass:UITextField.class]) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
static void RYGWATImageDidSelect(id self, SEL _cmd, UITableView *table, NSIndexPath *path) {
    RYGRuntimeMemberRow *entry = RYGWATUIEntry(self, path);
    if (!entry) { ((void (*)(id, SEL, id, id))gRYGWATImageDidSelect)(self, _cmd, table, path); return; }
    [table deselectRowAtIndexPath:path animated:YES];
    id raw = RYGWATUIRawValue(self, entry);
    if (RYGRuntimeValueTypeIsBoolean(entry.valueTypeCode)) {
        ((void (*)(id, SEL, id, id))gRYGWATImageDidSelect)(self, _cmd, table, path);
        return;
    }
    if (RYGRuntimeValueTypeIsObject(entry.valueTypeCode)) {
        RYGWATObjectEditorViewController *editor = [RYGWATObjectEditorViewController new];
        editor.entry = entry;
        editor.nativeValue = raw;
        __weak id weakSelf = self;
        editor.completion = ^{ RYGWATUIReload(weakSelf); };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    RYGWATUIPresentScalarEditor(self, entry, raw);
}
static void RYGWATRootViewDidLoad(id self, SEL _cmd) {
    ((void (*)(id, SEL))gRYGWATRootViewDidLoad)(self, _cmd);
    UIViewController *controller = (UIViewController *)self;
    NSString *title = nil;
    @try { title = [self valueForKey:@"browserTitle"]; } @catch (__unused NSException *exception) {}
    if (!title.length) title = @"Runtime Browser";
    controller.title = title;
    controller.navigationItem.titleView = nil;
    controller.navigationItem.title = title;
}

static void RYGWATSwizzleInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return;
    IMP original = method_getImplementation(method);
    if (!original || original == replacement) return;
    if (originalOut) *originalOut = original;
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void RYGInstallWATRuntimeUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class image = NSClassFromString(@"RYGPortedRuntimeImageViewController");
        RYGWATSwizzleInstanceMethod(image, @selector(viewDidLoad), (IMP)RYGWATImageViewDidLoad, &gRYGWATImageViewDidLoad);
        RYGWATSwizzleInstanceMethod(image, NSSelectorFromString(@"applyFilter"), (IMP)RYGWATImageApplyFilter, &gRYGWATImageApplyFilter);
        RYGWATSwizzleInstanceMethod(image, @selector(tableView:cellForRowAtIndexPath:), (IMP)RYGWATImageCell, &gRYGWATImageCell);
        RYGWATSwizzleInstanceMethod(image, @selector(tableView:didSelectRowAtIndexPath:), (IMP)RYGWATImageDidSelect, &gRYGWATImageDidSelect);

        Class root = NSClassFromString(@"RYGPortedRuntimeBrowserViewController");
        RYGWATSwizzleInstanceMethod(root, @selector(viewDidLoad), (IMP)RYGWATRootViewDidLoad, &gRYGWATRootViewDidLoad);
    });
}
