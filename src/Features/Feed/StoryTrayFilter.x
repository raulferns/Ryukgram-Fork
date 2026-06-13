// Feed stories-tray filtering only — the profile highlights tray uses a
// different source. Covers suggested accounts (type-based no_suggested_users
// + friendship-based hide_suggested_stories), story ads, and the highlights
// row.

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString *sciTrayDiffID(id obj) {
    NSString *diffId = nil;
    @try { diffId = [[obj performSelector:@selector(diffIdentifier)] description]; } @catch (...) {}
    return diffId;
}

// Suggested items carry a 32-char hex UUID diffIdentifier; real users use
// numeric PKs. Default-keep when ambiguous.
static BOOL sciIsHexUUIDString(NSString *s) {
    if (s.length != 32) return NO;
    static NSCharacterSet *nonHex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    });
    return [s rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

static BOOL sciIsSuggestedTrayItem(id obj) {
    @try {
        if (![NSStringFromClass([obj class]) isEqualToString:@"IGStoryTrayViewModel"]) return NO;
        if ([[obj valueForKey:@"isCurrentUserReel"] boolValue]) return NO;
        if (!sciIsHexUUIDString(sciTrayDiffID(obj))) return NO;

        id owner = [obj valueForKey:@"reelOwner"];
        if (!owner) return NO;
        Ivar userIvar = class_getInstanceVariable([owner class], "_userReelOwner_user");
        if (!userIvar) return NO;
        id igUser = object_getIvar(owner, userIvar);
        if (!igUser) return NO;

        Ivar fcIvar = NULL;
        for (Class c = [igUser class]; c && !fcIvar; c = class_getSuperclass(c))
            fcIvar = class_getInstanceVariable(c, "_fieldCache");
        if (!fcIvar) return NO;
        id fc = object_getIvar(igUser, fcIvar);
        if (![fc isKindOfClass:[NSDictionary class]]) return NO;

        id fs = [(NSDictionary *)fc objectForKey:@"friendship_status"];
        if (!fs) return NO;
        return ![[fs valueForKey:@"following"] boolValue];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static NSArray *(*orig_objectsForListAdapter)(id, SEL, id);
static NSArray *hook_objectsForListAdapter(id self, SEL _cmd, id adapter) {
    NSArray *objects = orig_objectsForListAdapter(self, _cmd, adapter);

    if (![SCIUtils getBoolPref:@"hide_suggested_stories"]) return objects;

    BOOL anySuggested = NO;
    for (id obj in objects) {
        if (sciIsSuggestedTrayItem(obj)) { anySuggested = YES; break; }
    }
    if (!anySuggested) return objects;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:objects.count];
    for (id obj in objects) {
        if (!sciIsSuggestedTrayItem(obj)) [filtered addObject:obj];
    }
    return [filtered copy];
}

// Dropping the highlights row (type 11) here also removes the separator IG
// injects downstream only when a highlight survives — no leftover divider.
%hook IGMainStoryTrayDataSource
- (id)allItemsForTrayUsingCachedValue:(BOOL)cached {
    NSArray *items = %orig(cached);
    BOOL hideUsers = [SCIUtils getBoolPref:@"no_suggested_users"];
    BOOL hideAds = [SCIUtils getBoolPref:@"hide_ads"] && [SCIUtils getBoolPref:@"hide_ads_stories"];
    BOOL hideHighlights = [SCIUtils getBoolPref:@"hide_story_highlights"];

    if (!hideUsers && !hideAds && !hideHighlights) return items;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
    for (id obj in items) {
        BOOL hide = NO;
        if ([obj isKindOfClass:%c(IGStoryTrayViewModel)]) {
            NSNumber *type = [obj valueForKey:@"type"];
            if (hideUsers) hide = [type isEqual:@(8)] || [type isEqual:@(9)];
            if (!hide && hideAds) hide = [obj isUnseenNux] || [[obj pk] isEqualToString:@"3538572169"];
            if (!hide && hideHighlights) {
                hide = [type isEqual:@(11)] || [sciTrayDiffID(obj) hasPrefix:@"highlightRewind:"];
            }
        }
        if (!hide) [out addObject:obj];
    }
    return out.copy;
}
%end

%hook IGStoryTraySectionController
- (void)storyTrayControllerShowSUPOGEducationBump {
    if (![SCIUtils getBoolPref:@"no_suggested_users"]) %orig;
}
%end

%ctor {
    Class cls = NSClassFromString(@"IGStoryTrayListAdapterDataSource");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"objectsForListAdapter:");
    if (!class_getInstanceMethod(cls, sel)) return;
    MSHookMessageEx(cls, sel, (IMP)hook_objectsForListAdapter, (IMP *)&orig_objectsForListAdapter);
}
