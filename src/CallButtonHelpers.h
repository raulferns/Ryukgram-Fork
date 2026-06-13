// Runtime helpers shared by CallConfirm.x and HideCallButtons.x for DM-header
// call buttons (old dual-button layout + newer joint-button/menu A/B).

#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static inline id sciCBIvarObj(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

static inline long long sciCBIvarLL(id obj, const char *name, BOOL *ok) {
    if (ok) *ok = NO;
    if (!obj) return 0;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return 0;
    if (ok) *ok = YES;
    return *(long long *)((char *)(__bridge void *)obj + ivar_getOffset(iv));
}

// Call-type of a consolidated-menu entry. Menu order (video first) is the
// language-independent signal; the English title is only an override.
static inline BOOL sciCallMenuTypeIsVideo(id item, NSUInteger idx, NSUInteger count) {
    NSString *t = [item respondsToSelector:@selector(title)] ? [item title] : nil;
    if (t) {
        if ([t rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([t rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    }
    if (count >= 2) return (idx == 0);
    return NO;
}

// YES = video, NO = audio, matching `type` against the coordinator's joint-button
// _callType ivars. *resolved is NO when neither matches.
static inline BOOL sciCallTypeIsVideo(id coordinator, long long type, BOOL *resolved) {
    if (resolved) *resolved = NO;
    BOOL vok = NO, aok = NO;
    long long vt = sciCBIvarLL(sciCBIvarObj(coordinator, "_videoJointCallButton"), "_callType", &vok);
    long long at = sciCBIvarLL(sciCBIvarObj(coordinator, "_audioJointCallButton"), "_callType", &aok);
    if (vok && type == vt) { if (resolved) *resolved = YES; return YES; }
    if (aok && type == at) { if (resolved) *resolved = YES; return NO; }
    return NO;
}
