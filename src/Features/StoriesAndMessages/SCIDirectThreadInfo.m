#import "SCIDirectThreadInfo.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *tiStr(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSURL.class]) return [(NSURL *)v absoluteString];
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}
static id tiCall(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static BOOL tiBool(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static NSString *tiUserPK(id user) {
    Ivar iv = class_getInstanceVariable([user class], "_pk");
    id pk = iv ? object_getIvar(user, iv) : nil;
    return tiStr(pk) ?: tiStr(tiCall(user, @selector(pk)));
}
static NSDictionary *tiFieldCache(id user) {
    Ivar fc = user ? class_getInstanceVariable([user class], "_fieldCache") : NULL;
    id d = fc ? object_getIvar(user, fc) : nil;
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}
static NSString *tiUsername(id user) {
    NSString *u = tiStr(tiCall(user, @selector(username)));
    if (u.length) return u;
    return tiStr(tiFieldCache(user)[@"username"]);
}
static NSString *tiProfilePic(id user) {
    NSDictionary *fc = tiFieldCache(user);
    return tiStr(fc[@"profile_pic_url"]) ?: tiStr(fc[@"profile_pic_url_hd"]);
}

@implementation SCIDirectThreadInfo

// ownerPK -> IGDirectCache (weak values; caches are long-lived per session)
static NSMapTable *tiCaches(void) {
    static NSMapTable *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMapTable strongToWeakObjectsMapTable]; });
    return m;
}

+ (void)registerCache:(id)cache forOwnerPK:(NSString *)ownerPK {
    if (!cache) return;
    @synchronized (tiCaches()) {
        [tiCaches() setObject:cache forKey:ownerPK ?: @"_"];
        if (ownerPK) [tiCaches() setObject:cache forKey:@"_"]; // last-seen fallback
    }
}

+ (void)fetchThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK completion:(void (^)(id))completion {
    if (!threadId.length || !completion) { if (completion) completion(nil); return; }
    id cache;
    @synchronized (tiCaches()) { cache = [tiCaches() objectForKey:ownerPK ?: @"_"] ?: [tiCaches() objectForKey:@"_"]; }
    SEL fetch = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
    if (!cache || ![cache respondsToSelector:fetch]) { completion(nil); return; }
    void (^cb)(id) = ^(id thread) { dispatch_async(dispatch_get_main_queue(), ^{ completion(thread); }); };
    cb = [cb copy];
    ((void (*)(id, SEL, id, id))objc_msgSend)(cache, fetch, threadId, cb);
}

+ (NSString *)groupNameFromMetadata:(id)meta viewerPK:(NSString *)viewerPK {
    NSString *t = tiStr(tiCall(meta, @selector(threadTitle)));
    if (t.length) return t;
    id gm = tiCall(meta, @selector(groupMetadata));
    NSString *cn = tiStr(tiCall(gm, @selector(customName)));
    if (cn.length) return cn;
    // fall back to joined member usernames (excluding the owner), like IG's default group label
    NSMutableArray *names = [NSMutableArray array];
    id users = tiCall(meta, @selector(users));
    if ([users isKindOfClass:NSArray.class]) for (id u in users) {
        NSString *pk = tiUserPK(u);
        if (viewerPK.length && [pk isEqualToString:viewerPK]) continue;
        NSString *un = tiUsername(u);
        if (un.length) [names addObject:un];
    }
    return names.count ? [names componentsJoinedByString:@", "] : nil;
}

+ (NSString *)groupImageURLFromMetadata:(id)meta {
    id gm = tiCall(meta, @selector(groupMetadata));
    id photoId = tiCall(gm, @selector(groupPhotoIdentifier));
    id spec = tiCall(photoId, @selector(groupImageSpecifier));
    id imgURL = tiCall(spec, @selector(remoteImageURL)); // IGImageURL
    if (!imgURL) return nil;
    if ([imgURL isKindOfClass:NSString.class]) return imgURL;
    if ([imgURL isKindOfClass:NSURL.class]) return [(NSURL *)imgURL absoluteString];
    id u = tiCall(imgURL, @selector(url));
    if (!u) { Ivar iv = class_getInstanceVariable([imgURL class], "_url"); u = iv ? object_getIvar(imgURL, iv) : nil; }
    return tiStr(u);
}

+ (NSDictionary *)groupInfoForThread:(id)thread viewerPK:(NSString *)viewerPK {
    id meta = tiCall(thread, @selector(metadata));
    if (!meta) return nil;
    BOOL isGroup = tiBool(meta, @selector(isGroup));
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@(isGroup) forKey:@"is_group"];
    if (isGroup) {
        NSString *name = [self groupNameFromMetadata:meta viewerPK:viewerPK];
        NSString *image = [self groupImageURLFromMetadata:meta];
        if (name.length) d[@"name"] = name;
        if (image.length) d[@"image"] = image;
    }
    return d;
}

+ (NSDictionary<NSString *, NSDictionary *> *)participantsForThread:(id)thread {
    id meta = tiCall(thread, @selector(metadata));
    id users = tiCall(meta, @selector(users));
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if ([users isKindOfClass:NSArray.class]) for (id u in users) {
        NSString *pk = tiUserPK(u);
        if (!pk.length) continue;
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        NSString *un = tiUsername(u); if (un.length) e[@"username"] = un;
        NSString *pic = tiProfilePic(u); if (pic.length) e[@"profile_pic_url"] = pic;
        if (e.count) out[pk] = e;
    }
    return out;
}

@end
