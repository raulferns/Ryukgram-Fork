// SCIDogfoodingSettingsPersistenceHooks.x
//
// Notes Dogfooding opens natively, but on sideload/rootless builds the native
// dogfood UI may only mutate an in-memory IGDogfoodingSettingsOptions object.
// These hooks do NOT force random MobileConfig IDs. They capture the real
// DogfoodingSettings delegate updates, persist a FLEX-style snapshot, and when
// the item/options expose launcher+parameter+value metadata, mirror it through
// the same IGDogfoodingAssistantLauncherClient path used by native dogfood.

#import "SCIDogfoodObjectRuntime.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static void (*orig_df_toggle)(id, SEL, id, BOOL) = NULL;
static void (*orig_df_selection)(id, SEL, id, id) = NULL;

static void new_df_toggle(id self, SEL _cmd, id cell, BOOL enabled) {
    if (orig_df_toggle) orig_df_toggle(self, _cmd, cell, enabled);
    @try {
        [SCIDogfoodObjectRuntime noteObject:self role:@"IGDogfoodingSettings delegate" source:NSStringFromSelector(_cmd)];
        [SCIDogfoodObjectRuntime noteObject:cell role:@"IGDogfoodingSettingsToggleCell" source:NSStringFromSelector(_cmd)];
        id item = nil;
        if ([cell respondsToSelector:@selector(item)]) item = ((id(*)(id,SEL))objc_msgSend)(cell, @selector(item));
        if (item) [SCIDogfoodObjectRuntime noteObject:item role:@"IGDogfoodingSettingsItem" source:@"toggleCell.item"];
        [SCIDogfoodObjectRuntime noteDogfoodingSettingChangeWithItem:item options:nil toggleValue:@(enabled) source:@"dogfoodingSettingsToggleCell:didToggle:"];
    } @catch (__unused id e) {}
}

static void new_df_selection(id self, SEL _cmd, id selectionVC, id options) {
    if (orig_df_selection) orig_df_selection(self, _cmd, selectionVC, options);
    @try {
        [SCIDogfoodObjectRuntime noteObject:self role:@"IGDogfoodingSettings delegate" source:NSStringFromSelector(_cmd)];
        [SCIDogfoodObjectRuntime noteObject:selectionVC role:@"IGDogfoodingSettingsSelectionViewController" source:NSStringFromSelector(_cmd)];
        [SCIDogfoodObjectRuntime noteObject:options role:@"IGDogfoodingSettingsOptions" source:NSStringFromSelector(_cmd)];
        id item = nil;
        if ([selectionVC respondsToSelector:@selector(item)]) item = ((id(*)(id,SEL))objc_msgSend)(selectionVC, @selector(item));
        if (item) [SCIDogfoodObjectRuntime noteObject:item role:@"IGDogfoodingSettingsItem" source:@"selectionVC.item"];
        [SCIDogfoodObjectRuntime noteDogfoodingSettingChangeWithItem:item options:options toggleValue:nil source:@"dogfoodingSettingsSelectionViewController:updatedOptions:"];
    } @catch (__unused id e) {}
}

static void SCIHookDogfoodingSettingsDelegate(Class cls) {
    if (!cls) return;
    SEL toggleSel = @selector(dogfoodingSettingsToggleCell:didToggle:);
    if ([cls instancesRespondToSelector:toggleSel] && !orig_df_toggle) {
        MSHookMessageEx(cls, toggleSel, (IMP)new_df_toggle, (IMP *)&orig_df_toggle);
    }
    SEL selSel = @selector(dogfoodingSettingsSelectionViewController:updatedOptions:);
    if ([cls instancesRespondToSelector:selSel] && !orig_df_selection) {
        MSHookMessageEx(cls, selSel, (IMP)new_df_selection, (IMP *)&orig_df_selection);
    }
}

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // SCI-FIX 2026-06-11: single install; dropped redundant 2s dispatch_after retry.
            SCIHookDogfoodingSettingsDelegate(NSClassFromString(@"IGDogfoodingSettings.IGDogfoodingSettingsViewController"));
            SCIHookDogfoodingSettingsDelegate(NSClassFromString(@"_TtC20IGDogfoodingSettings34IGDogfoodingSettingsViewController"));
        });
    }
}
