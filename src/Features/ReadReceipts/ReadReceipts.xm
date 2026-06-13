// Read receipts: detect when other participants read a message you sent.
// On each thread update, fetch the live thread and diff metadata.lastSeenMessageIdsForUserIds
// per reader; when a reader advances past a message you sent, record it + fire a toast.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SCIReadReceiptModels.h"
#import "SCIReadReceiptStorage.h"
#import "../StoriesAndMessages/SCIExcludedThreads.h"
#import "../StoriesAndMessages/SCIDirectThreadInfo.h"
#import "../../Utils.h"
#import "../../UI/Notification/SCINotificationActions.h"

static NSString *rrStr(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return [v description];
}
static id rrCall(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
// BOOL returns need a BOOL-typed msgSend — id-casting a primitive return crashes.
static BOOL rrBool(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static NSString *rrUserPK(id user) {
    Ivar iv = class_getInstanceVariable([user class], "_pk");
    id pk = iv ? object_getIvar(user, iv) : nil;
    return rrStr(pk) ?: rrStr(rrCall(user, @selector(pk)));
}
static NSDictionary *rrFieldCache(id user) {
    Ivar fc = user ? class_getInstanceVariable([user class], "_fieldCache") : NULL;
    id d = fc ? object_getIvar(user, fc) : nil;
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}
static NSString *rrUsername(id user) {
    NSString *u = rrStr(rrCall(user, @selector(username)));
    if (u.length && ![u isEqualToString:@"(null)"]) return u;
    return rrStr(rrFieldCache(user)[@"username"]);
}
static NSString *rrProfilePic(id user) {
    NSDictionary *fc = rrFieldCache(user);
    return rrStr(fc[@"profile_pic_url"]) ?: rrStr(fc[@"profile_pic_url_hd"]);
}

static NSString *rrPreviewOf(id message) {
    id content = rrCall(message, @selector(content));
    for (NSString *s in @[@"text", @"string", @"bodyText", @"messageText"]) {
        NSString *t = rrStr(rrCall(content, NSSelectorFromString(s)));
        if (t.length) return t;
    }
    return nil;
}

static double rrDateTs(id dateObj) { return [dateObj isKindOfClass:NSDate.class] ? [(NSDate *)dateObj timeIntervalSince1970] : 0; }

// Indexes the loaded range into msgById and returns { serverId : sentUnixTime } for the viewer's
// own messages — reads are attributed by time, since IG item ids aren't time-ordered.
static NSDictionary *rrScanRange(id thread, NSString *viewer, NSMutableDictionary *msgById) {
    NSMutableDictionary *mine = [NSMutableDictionary dictionary];
    id set = rrCall(thread, @selector(publishedMessagesInCurrentThreadRange));
    id seq = [set respondsToSelector:@selector(objectEnumerator)] ? set
           : (rrCall(set, @selector(allMessages)) ?: rrCall(set, @selector(messages)) ?: rrCall(set, @selector(array)));
    if (![seq respondsToSelector:@selector(objectEnumerator)]) return mine;
    NSArray *snapshot = [seq respondsToSelector:@selector(allObjects)] ? [seq allObjects] : ([seq isKindOfClass:NSArray.class] ? [(NSArray *)seq copy] : nil);
    id iter = snapshot ?: seq;
    for (id m in iter) {
        id md = rrCall(m, @selector(metadata));
        NSString *sid = rrStr(rrCall(md, @selector(serverId)));
        if (!sid.length) continue;
        if (msgById) msgById[sid] = m;
        if ([rrStr(rrCall(md, @selector(senderPk))) isEqualToString:viewer])
            mine[sid] = @(rrDateTs(rrCall(md, @selector(serverTimestamp))));
    }
    return mine;
}

static void rrInspectThread(id thread, NSString *ownerUsername) {
    @try {
        if (!thread) return;
        NSString *tid = rrStr(rrCall(thread, @selector(threadId)));
        NSString *viewer = rrStr(rrCall(thread, @selector(viewerId)));
        if (!tid.length || !viewer.length) return;

        id meta = rrCall(thread, @selector(metadata));
        id seen = rrCall(meta, @selector(lastSeenMessageIdsForUserIds));
        if (![seen isKindOfClass:NSDictionary.class] || ![seen count]) return;

        BOOL isGroup = rrBool(meta, @selector(isGroup));
        if (isGroup && ![SCIUtils getBoolPref:@"read_receipts_log_groups"]) return;
        if ([SCIReadReceiptStorage isThreadExcluded:tid ownerPK:viewer]) return;

        NSString *threadTitle = isGroup ? [SCIDirectThreadInfo groupNameFromMetadata:meta viewerPK:viewer] : nil;
        NSString *threadAvatar = isGroup ? [SCIDirectThreadInfo groupImageURLFromMetadata:meta] : nil;

        // pk -> username / profile pic
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        NSMutableDictionary *pics = [NSMutableDictionary dictionary];
        id users = rrCall(meta, @selector(users));
        if ([users isKindOfClass:NSArray.class]) for (id u in users) {
            NSString *pk = rrUserPK(u);
            if (!pk) continue;
            NSString *un = rrUsername(u); if (un) names[pk] = un;
            NSString *pic = rrProfilePic(u); if (pic) pics[pk] = pic;
        }

        // one pass over the loaded range: index messages by id, record ours (id -> sent time)
        NSMutableDictionary *msgById = [NSMutableDictionary dictionary];
        NSDictionary *myIds = rrScanRange(thread, viewer, msgById);
        if (myIds.count) [SCIReadReceiptStorage recordMyMessages:myIds forThread:tid ownerPK:viewer];

        NSDictionary<NSString *, NSNumber *> *myMsgs = [SCIReadReceiptStorage myMessagesForThread:tid ownerPK:viewer];

        [(NSDictionary *)seen enumerateKeysAndObjectsUsingBlock:^(id pkKey, id info, BOOL *stop) {
            NSString *readerPk = rrStr(pkKey);
            if (!readerPk.length || [readerPk isEqualToString:viewer]) return;
            if ([SCIReadReceiptStorage isReaderExcluded:readerPk ownerPK:viewer]) return;

            NSString *lastSeen = rrStr(rrCall(info, @selector(messageId)));
            if (!lastSeen.length) return;
            NSString *prevSeen = [SCIReadReceiptStorage lastSeenMessageIdForThread:tid reader:readerPk ownerPK:viewer];
            if ([lastSeen isEqualToString:prevSeen]) return; // position unchanged
            [SCIReadReceiptStorage setLastSeenMessageId:lastSeen forThread:tid reader:readerPk ownerPK:viewer];

            // IG item ids aren't time-ordered, so compare by send time: the reader saw everything
            // sent at or before their last-seen message; the newest of ours under that cutoff is the read.
            double cutoff = rrDateTs(rrCall(info, @selector(sentTimestamp)));
            if (cutoff <= 0 && msgById[lastSeen]) cutoff = rrDateTs(rrCall(rrCall(msgById[lastSeen], @selector(metadata)), @selector(serverTimestamp)));

            NSString *candidate = nil; double candidateTs = 0;
            for (NSString *mid in myMsgs) {
                double ts = [myMsgs[mid] doubleValue];
                if (ts > 0 && ts <= cutoff + 1.0 && ts > candidateTs) { candidate = mid; candidateTs = ts; }
            }

            double prevMineTs = [SCIReadReceiptStorage lastReadMineTimeForThread:tid reader:readerPk ownerPK:viewer];
            if (prevMineTs > 1e11) prevMineTs = 0; // stale pre-timestamp (id-string) state from an earlier build

            if (!prevSeen) { // first sighting -> baseline, don't fire for already-read history
                if (candidate) [SCIReadReceiptStorage setLastReadMineTime:candidateTs forThread:tid reader:readerPk ownerPK:viewer];
                return;
            }
            if (!candidate || candidateTs <= prevMineTs) return; // nothing newly read of ours
            [SCIReadReceiptStorage setLastReadMineTime:candidateTs forThread:tid reader:readerPk ownerPK:viewer];

            id message = msgById[candidate];
            NSString *username = names[readerPk];
            NSString *preview = message ? rrPreviewOf(message) : nil;
            id ts = message ? rrCall(rrCall(message, @selector(metadata)), @selector(serverTimestamp)) : nil;
            NSDate *sentAt = [ts isKindOfClass:NSDate.class] ? ts : nil;

            if ([SCIUtils getBoolPref:@"read_receipts_save_log"]) {
                SCIReadReceipt *r = [SCIReadReceipt new];
                r.threadId = tid; r.isGroup = isGroup; r.threadTitle = threadTitle; r.threadAvatarURL = threadAvatar;
                r.readerPk = readerPk; r.readerUsername = username; r.readerProfilePicURL = pics[readerPk];
                r.messageId = candidate; r.messagePreview = preview; r.messageSentAt = sentAt;
                id seenAt = rrCall(info, @selector(seenAtTimestamp));
                r.readAt = [seenAt isKindOfClass:NSDate.class] ? seenAt : [NSDate date];
                [SCIReadReceiptStorage addReceipt:r forOwnerPK:viewer];
            }

            // UIKit / notification / session work must be on the main thread (this can run off it).
            NSString *fOwner = ownerUsername, *fViewer = viewer, *fTid = tid, *fUser = username, *fPreview = preview, *fTitle = threadTitle;
            BOOL fGroup = isGroup;
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL inThatChat = UIApplication.sharedApplication.applicationState == UIApplicationStateActive
                                  && [[SCIExcludedThreads activeThreadId] isEqualToString:fTid];
                if (inThatChat) return;
                NSString *handle = fUser.length ? [@"@" stringByAppendingString:fUser] : SCILocalized(@"Someone");
                NSString *sub = fGroup && fTitle.length
                    ? [NSString stringWithFormat:SCILocalized(@"read your message in %@"), fTitle]
                    : SCILocalized(@"read your message");
                NSString *active = [SCIUtils currentUserPK];
                if (fOwner.length && active.length && ![active isEqualToString:fViewer])
                    sub = [NSString stringWithFormat:SCILocalized(@"%@ · on @%@"), sub, fOwner];
                if (fPreview.length) sub = [NSString stringWithFormat:@"%@ · %@", sub, fPreview];
                SCINotify(SCI_NOTIF_READ_RECEIPT, handle, sub, @"eye.fill", SCINotificationToneInfo);
            });
        }];
    } @catch (__unused id e) {}
}

%hook IGDirectCacheUpdatesApplicator

- (void)_applyThreadUpdates:(id)updates completion:(id)completion userAccess:(id)access {
    %orig;
    @try {
        BOOL rrOn = [SCIUtils getBoolPref:@"read_receipts_enabled"];
        // deleted-messages group images use the same shared cache; register it for them too.
        BOOL dmOn = [SCIUtils getBoolPref:@"keep_deleted_message"] || [SCIUtils getBoolPref:@"deleted_messages_log_enabled"];
        if (!rrOn && !dmOn) return; // nothing needs us

        Ivar civ = class_getInstanceVariable(object_getClass(self), "_cache");
        id cache = civ ? object_getIvar(self, civ) : nil;
        if (!cache) return;

        Ivar uiv = class_getInstanceVariable(object_getClass(self), "_user");
        id ownerUser = uiv ? object_getIvar(self, uiv) : nil;
        Ivar pkiv = ownerUser ? class_getInstanceVariable([ownerUser class], "_pk") : NULL;
        NSString *ownerPk = pkiv ? rrStr(object_getIvar(ownerUser, pkiv)) : nil;
        [SCIDirectThreadInfo registerCache:cache forOwnerPK:ownerPk];

        if (!rrOn) return; // deleted messages only needed the cache registration above

        SEL fetch = NSSelectorFromString(@"fetchThreadWithThreadId:completion:");
        if (![cache respondsToSelector:fetch]) return;
        NSString *ownerUsername = rrUsername(ownerUser);

        // defer fetch+inspect off the apply (re-entering the cache mid-apply is unsafe), on the main thread
        NSArray *arr = [updates isKindOfClass:NSArray.class] ? updates : @[updates];
        NSMutableArray *tids = [NSMutableArray array];
        for (id u in arr) {
            NSString *tid = rrStr(rrCall(u, @selector(threadId)));
            if (tid && ![tids containsObject:tid]) [tids addObject:tid];
        }
        if (!tids.count) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                for (NSString *tid in tids) {
                    void (^cb)(id) = ^(id thread) { dispatch_async(dispatch_get_main_queue(), ^{ rrInspectThread(thread, ownerUsername); }); };
                    cb = [cb copy]; // heap block — async completion would otherwise outlive a stack block
                    ((void (*)(id, SEL, id, id))objc_msgSend)(cache, fetch, tid, cb);
                }
            } @catch (__unused id e) {}
        });
    } @catch (__unused id e) {}
}

%end
