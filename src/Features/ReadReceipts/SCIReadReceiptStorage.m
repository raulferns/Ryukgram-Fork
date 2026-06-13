#import "SCIReadReceiptStorage.h"

NSNotificationName const SCIReadReceiptsDidChangeNotification = @"SCIReadReceiptsDidChangeNotification";

static NSString *const kDir = @"RyukGram/ReadReceipts";
static NSUInteger const kMaxReceiptsPerOwner = 2000; // cull oldest beyond this

@implementation SCIReadReceiptStorage

static void *kQKey = &kQKey;
static dispatch_queue_t ioQ(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.ryukgram.readreceipts.io", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, kQKey, kQKey, NULL);
    });
    return q;
}
static void ioSync(dispatch_block_t b) { dispatch_get_specific(kQKey) ? b() : dispatch_sync(ioQ(), b); }

static NSString *cleanComp(NSString *s, NSString *fallback) {
    if (!s.length) return fallback;
    NSMutableString *m = s.mutableCopy;
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    for (NSUInteger i = 0; i < m.length; i++) {
        unichar c = [m characterAtIndex:i];
        if (c < 32 || [bad characterIsMember:c]) [m replaceCharactersInRange:NSMakeRange(i, 1) withString:@"_"];
    }
    return m.length ? m : fallback;
}
static NSString *owner(NSString *pk) { return cleanComp(pk, @"anon"); }

static NSString *storeDir(void) {
    NSString *root = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [root stringByAppendingPathComponent:kDir];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
static NSString *receiptsFile(NSString *pk) { return [storeDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", owner(pk)]]; }
static NSString *stateFile(NSString *pk)    { return [storeDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.state.json", owner(pk)]]; }

static NSMutableArray *readArray(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return [NSMutableArray array];
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [j isKindOfClass:NSArray.class] ? [j mutableCopy] : [NSMutableArray array];
}
static NSMutableDictionary *readDict(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return [NSMutableDictionary dictionary];
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? [j mutableCopy] : [NSMutableDictionary dictionary];
}
static void writeJSON(id obj, NSString *path) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    [d writeToFile:path atomically:YES];
}

// The per-owner diff state (lastSeen / mySent / mineSeen / excluded) is read several times per
// thread update; keep it in memory and write through to disk. All access is on the serial ioQ.
static NSMutableDictionary *sStateCache;
static NSMutableDictionary *stateRoot(NSString *pk) {
    if (!sStateCache) sStateCache = [NSMutableDictionary dictionary];
    NSString *k = owner(pk);
    NSMutableDictionary *r = sStateCache[k];
    if (!r) { r = readDict(stateFile(pk)); sStateCache[k] = r; }
    return r;
}
static void stateSave(NSString *pk) {
    NSMutableDictionary *r = sStateCache[owner(pk)];
    if (r) writeJSON(r, stateFile(pk));
}
static NSMutableDictionary *stateSub(NSMutableDictionary *root, NSString *key) {
    NSMutableDictionary *s = [root[key] isKindOfClass:NSDictionary.class] ? [root[key] mutableCopy] : [NSMutableDictionary dictionary];
    root[key] = s;
    return s;
}
static void post(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SCIReadReceiptsDidChangeNotification object:nil];
    });
}

+ (NSString *)storageDirectory { return storeDir(); }

#pragma mark - Records

+ (NSArray<SCIReadReceipt *> *)allReceiptsForOwnerPK:(NSString *)ownerPK {
    __block NSMutableArray *out = [NSMutableArray array];
    ioSync(^{
        for (NSDictionary *d in readArray(receiptsFile(ownerPK))) {
            SCIReadReceipt *r = [SCIReadReceipt receiptFromJSONDict:d];
            if (r.messageId) [out addObject:r];
        }
    });
    [out sortUsingComparator:^NSComparisonResult(SCIReadReceipt *a, SCIReadReceipt *b) {
        return [b.readAt compare:a.readAt]; // newest-first
    }];
    return out;
}

+ (NSArray<SCIReadReceipt *> *)receiptsForReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    NSMutableArray *out = [NSMutableArray array];
    for (SCIReadReceipt *r in [self allReceiptsForOwnerPK:ownerPK])
        if ([r.readerPk isEqualToString:readerPK]) [out addObject:r];
    return out;
}

+ (NSArray<SCIReadReceipt *> *)receiptsForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    NSMutableArray *out = [NSMutableArray array];
    for (SCIReadReceipt *r in [self allReceiptsForOwnerPK:ownerPK])
        if ([r.threadId isEqualToString:threadId]) [out addObject:r];
    return out;
}

+ (void)deleteReceiptsForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    ioSync(^{
        NSString *path = receiptsFile(ownerPK);
        NSMutableArray *keep = [NSMutableArray array];
        for (NSDictionary *d in readArray(path)) if (![d[@"threadId"] isEqualToString:threadId]) [keep addObject:d];
        writeJSON(keep, path);
    });
    post();
}

+ (NSArray<SCIReadReceiptGroup *> *)groupedByThreadForOwnerPK:(NSString *)ownerPK {
    NSMutableDictionary<NSString *, NSMutableArray *> *byThread = [NSMutableDictionary dictionary];
    for (SCIReadReceipt *r in [self allReceiptsForOwnerPK:ownerPK]) {
        NSString *key = r.threadId ?: (r.readerPk ? [@"s:" stringByAppendingString:r.readerPk] : nil);
        if (!key) continue;
        NSMutableArray *a = byThread[key] ?: (byThread[key] = [NSMutableArray array]);
        [a addObject:r];
    }
    NSMutableArray *groups = [NSMutableArray array];
    [byThread enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableArray *list, BOOL *stop) {
        SCIReadReceipt *latest = list.firstObject; // newest-first
        SCIReadReceiptGroup *g = [SCIReadReceiptGroup new];
        g.threadId = latest.threadId;
        g.isGroup = latest.isGroup;
        g.threadTitle = latest.threadTitle;
        g.threadAvatarURL = latest.threadAvatarURL;
        g.receipts = list;
        if (!latest.isGroup) { // 1-1: carry the single reader for display
            g.readerPk = latest.readerPk;
            g.readerUsername = latest.readerUsername;
            g.readerProfilePicURL = latest.readerProfilePicURL;
        }
        [groups addObject:g];
    }];
    [groups sortUsingComparator:^NSComparisonResult(SCIReadReceiptGroup *a, SCIReadReceiptGroup *b) {
        return [(b.lastReadAt ?: NSDate.distantPast) compare:(a.lastReadAt ?: NSDate.distantPast)];
    }];
    return groups;
}

+ (NSUInteger)totalCountForOwnerPK:(NSString *)ownerPK {
    __block NSUInteger n = 0;
    ioSync(^{ n = readArray(receiptsFile(ownerPK)).count; });
    return n;
}

+ (void)addReceipt:(SCIReadReceipt *)receipt forOwnerPK:(NSString *)ownerPK {
    if (!receipt.messageId || !receipt.readerPk) return;
    ioSync(^{
        NSString *path = receiptsFile(ownerPK);
        NSMutableArray *arr = readArray(path);
        [arr addObject:[receipt toJSONDict]];
        if (arr.count > kMaxReceiptsPerOwner)
            [arr removeObjectsInRange:NSMakeRange(0, arr.count - kMaxReceiptsPerOwner)];
        writeJSON(arr, path);
    });
    post();
}

+ (void)deleteReceiptsForReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    ioSync(^{
        NSString *path = receiptsFile(ownerPK);
        NSMutableArray *arr = readArray(path);
        NSMutableArray *keep = [NSMutableArray array];
        for (NSDictionary *d in arr) if (![d[@"readerPk"] isEqualToString:readerPK]) [keep addObject:d];
        writeJSON(keep, path);
    });
    post();
}

+ (void)applyThreadTitle:(NSString *)title avatarURL:(NSString *)avatarURL forThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId || (!title.length && !avatarURL.length)) return;
    ioSync(^{
        NSString *path = receiptsFile(ownerPK);
        NSMutableArray *arr = readArray(path);
        BOOL changed = NO;
        for (NSUInteger i = 0; i < arr.count; i++) {
            NSDictionary *d = arr[i];
            if (![d isKindOfClass:NSDictionary.class] || ![d[@"threadId"] isEqualToString:threadId]) continue;
            NSMutableDictionary *m = [d mutableCopy];
            if (title.length && ![title isEqualToString:m[@"threadTitle"]]) { m[@"threadTitle"] = title; changed = YES; }
            if (avatarURL.length && ![avatarURL isEqualToString:m[@"threadAvatarURL"]]) { m[@"threadAvatarURL"] = avatarURL; changed = YES; }
            arr[i] = m;
        }
        if (changed) writeJSON(arr, path);
    });
    post();
}

+ (void)applyReaderUsername:(NSString *)username profilePicURL:(NSString *)picURL forReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    if (!readerPK || (!username.length && !picURL.length)) return;
    ioSync(^{
        NSString *path = receiptsFile(ownerPK);
        NSMutableArray *arr = readArray(path);
        BOOL changed = NO;
        for (NSUInteger i = 0; i < arr.count; i++) {
            NSDictionary *d = arr[i];
            if (![d isKindOfClass:NSDictionary.class] || ![d[@"readerPk"] isEqualToString:readerPK]) continue;
            NSMutableDictionary *m = [d mutableCopy];
            if (username.length && ![username isEqualToString:m[@"readerUsername"]]) { m[@"readerUsername"] = username; changed = YES; }
            if (picURL.length && ![picURL isEqualToString:m[@"readerProfilePicURL"]]) { m[@"readerProfilePicURL"] = picURL; changed = YES; }
            arr[i] = m;
        }
        if (changed) writeJSON(arr, path);
    });
    post();
}

+ (void)resetForOwnerPK:(NSString *)ownerPK {
    ioSync(^{
        [NSFileManager.defaultManager removeItemAtPath:receiptsFile(ownerPK) error:nil];
        [NSFileManager.defaultManager removeItemAtPath:stateFile(ownerPK) error:nil];
        [sStateCache removeObjectForKey:owner(ownerPK)];
    });
    post();
}

+ (void)resetAll {
    ioSync(^{ [NSFileManager.defaultManager removeItemAtPath:storeDir() error:nil]; [sStateCache removeAllObjects]; });
    post();
}

#pragma mark - Backup merge

static NSString *receiptKey(NSDictionary *d) {
    return [NSString stringWithFormat:@"%@|%@", d[@"messageId"] ?: @"", d[@"readerPk"] ?: @""];
}

// Local wins on conflict: this device's diff state is current; the import only fills gaps.
static void mergeStateInto(NSMutableDictionary *local, NSDictionary *imported) {
    for (NSString *section in @[ @"lastSeen", @"mineSeen" ]) {
        NSDictionary *imp = [imported[section] isKindOfClass:NSDictionary.class] ? imported[section] : nil;
        if (!imp.count) continue;
        NSMutableDictionary *dst = stateSub(local, section);
        for (NSString *k in imp) if (!dst[k]) dst[k] = imp[k];
    }
    NSDictionary *impMine = [imported[@"mySent"] isKindOfClass:NSDictionary.class] ? imported[@"mySent"] : nil;
    if (impMine.count) {
        NSMutableDictionary *dst = stateSub(local, @"mySent");
        for (NSString *tid in impMine) {
            NSDictionary *impMap = [impMine[tid] isKindOfClass:NSDictionary.class] ? impMine[tid] : nil;
            if (!impMap.count) continue;
            NSMutableDictionary *map = [dst[tid] isKindOfClass:NSDictionary.class] ? [dst[tid] mutableCopy] : [NSMutableDictionary dictionary];
            for (NSString *mid in impMap) if (!map[mid]) map[mid] = impMap[mid];
            dst[tid] = map;
        }
    }
    NSArray *impExcl = [imported[@"excluded"] isKindOfClass:NSArray.class] ? imported[@"excluded"] : nil;
    if (impExcl.count) {
        NSMutableSet *set = [NSMutableSet setWithArray:([local[@"excluded"] isKindOfClass:NSArray.class] ? local[@"excluded"] : @[])];
        [set addObjectsFromArray:impExcl];
        local[@"excluded"] = set.allObjects;
    }
}

+ (void)mergeImportedStoreAtPath:(NSString *)importedDir {
    BOOL isDir = NO;
    if (!importedDir.length || ![NSFileManager.defaultManager fileExistsAtPath:importedDir isDirectory:&isDir] || !isDir) return;
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:importedDir error:nil];
    ioSync(^{
        for (NSString *name in names) {
            NSString *src = [importedDir stringByAppendingPathComponent:name];
            if ([name hasSuffix:@".state.json"]) {
                NSString *pk = [name substringToIndex:name.length - @".state.json".length];
                NSMutableDictionary *local = stateRoot(pk);
                mergeStateInto(local, readDict(src));
                stateSave(pk);
            } else if ([name hasSuffix:@".json"]) {
                NSString *pk = [name substringToIndex:name.length - @".json".length];
                NSString *dst = receiptsFile(pk);
                NSMutableArray *arr = readArray(dst);
                NSMutableSet *seen = [NSMutableSet set];
                for (NSDictionary *d in arr) if ([d isKindOfClass:NSDictionary.class]) [seen addObject:receiptKey(d)];
                BOOL changed = NO;
                for (NSDictionary *d in readArray(src)) {
                    if (![d isKindOfClass:NSDictionary.class] || [seen containsObject:receiptKey(d)]) continue;
                    [seen addObject:receiptKey(d)];
                    [arr addObject:d];
                    changed = YES;
                }
                if (!changed) continue;
                // disk order is oldest-first append order; the cap drops from the front
                [arr sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    double ta = [a[@"readAt"] doubleValue], tb = [b[@"readAt"] doubleValue];
                    return ta < tb ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
                }];
                if (arr.count > kMaxReceiptsPerOwner)
                    [arr removeObjectsInRange:NSMakeRange(0, arr.count - kMaxReceiptsPerOwner)];
                writeJSON(arr, dst);
            }
        }
    });
    post();
}

#pragma mark - Diff state

+ (NSString *)lastSeenMessageIdForThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    __block NSString *v = nil;
    ioSync(^{
        NSDictionary *state = stateRoot(ownerPK)[@"lastSeen"];
        v = [state isKindOfClass:NSDictionary.class] ? state[[NSString stringWithFormat:@"%@|%@", threadId, readerPK]] : nil;
    });
    return v;
}

+ (void)setLastSeenMessageId:(NSString *)messageId forThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    if (!messageId) return;
    ioSync(^{
        NSMutableDictionary *root = stateRoot(ownerPK);
        stateSub(root, @"lastSeen")[[NSString stringWithFormat:@"%@|%@", threadId, readerPK]] = messageId;
        stateSave(ownerPK);
    });
}

static NSUInteger const kMaxMyIdsPerThread = 1500;

+ (void)recordMyMessages:(NSDictionary<NSString *, NSNumber *> *)idToTimestamp forThread:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!idToTimestamp.count || !threadId) return;
    ioSync(^{
        NSMutableDictionary *root = stateRoot(ownerPK);
        NSMutableDictionary *mine = stateSub(root, @"mySent");
        NSMutableDictionary *map = [mine[threadId] isKindOfClass:NSDictionary.class] ? [mine[threadId] mutableCopy] : [NSMutableDictionary dictionary];
        BOOL changed = NO;
        for (NSString *mid in idToTimestamp) if (mid.length && !map[mid]) { map[mid] = idToTimestamp[mid]; changed = YES; }
        if (!changed) return;
        if (map.count > kMaxMyIdsPerThread) { // drop oldest by timestamp
            NSArray *byOldest = [map keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b){ return [a compare:b]; }];
            for (NSUInteger i = 0; i < map.count - kMaxMyIdsPerThread; i++) [map removeObjectForKey:byOldest[i]];
        }
        mine[threadId] = map;
        stateSave(ownerPK);
    });
}

+ (NSDictionary<NSString *, NSNumber *> *)myMessagesForThread:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId) return @{};
    __block NSDictionary *out = @{};
    ioSync(^{
        NSDictionary *mine = stateRoot(ownerPK)[@"mySent"];
        NSDictionary *map = [mine isKindOfClass:NSDictionary.class] ? mine[threadId] : nil;
        if ([map isKindOfClass:NSDictionary.class]) out = map;
    });
    return out;
}

+ (double)lastReadMineTimeForThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    __block double v = 0;
    ioSync(^{
        NSDictionary *s = stateRoot(ownerPK)[@"mineSeen"];
        if ([s isKindOfClass:NSDictionary.class]) v = [s[[NSString stringWithFormat:@"%@|%@", threadId, readerPK]] doubleValue];
    });
    return v;
}

+ (void)setLastReadMineTime:(double)timestamp forThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    ioSync(^{
        NSMutableDictionary *root = stateRoot(ownerPK);
        stateSub(root, @"mineSeen")[[NSString stringWithFormat:@"%@|%@", threadId, readerPK]] = @(timestamp);
        stateSave(ownerPK);
    });
}

#pragma mark - Exclude list

+ (NSMutableSet *)excludeSet:(NSString *)ownerPK {
    NSArray *a = stateRoot(ownerPK)[@"excluded"];
    return [a isKindOfClass:NSArray.class] ? [NSMutableSet setWithArray:a] : [NSMutableSet set];
}
+ (void)writeExcludeSet:(NSSet *)set ownerPK:(NSString *)ownerPK {
    stateRoot(ownerPK)[@"excluded"] = set.allObjects;
    stateSave(ownerPK);
}

+ (BOOL)isThreadExcluded:(NSString *)threadId ownerPK:(NSString *)ownerPK {
    if (!threadId) return NO;
    __block BOOL r = NO;
    ioSync(^{ r = [[self excludeSet:ownerPK] containsObject:threadId]; });
    return r;
}
+ (BOOL)isReaderExcluded:(NSString *)readerPK ownerPK:(NSString *)ownerPK {
    if (!readerPK) return NO;
    __block BOOL r = NO;
    ioSync(^{ r = [[self excludeSet:ownerPK] containsObject:[@"u:" stringByAppendingString:readerPK]]; });
    return r;
}
+ (void)setThread:(NSString *)threadId excluded:(BOOL)excluded ownerPK:(NSString *)ownerPK {
    if (!threadId) return;
    ioSync(^{
        NSMutableSet *s = [self excludeSet:ownerPK];
        excluded ? [s addObject:threadId] : [s removeObject:threadId];
        [self writeExcludeSet:s ownerPK:ownerPK];
    });
    post();
}
+ (void)setReader:(NSString *)readerPK excluded:(BOOL)excluded ownerPK:(NSString *)ownerPK {
    if (!readerPK) return;
    ioSync(^{
        NSMutableSet *s = [self excludeSet:ownerPK];
        NSString *id_ = [@"u:" stringByAppendingString:readerPK];
        excluded ? [s addObject:id_] : [s removeObject:id_];
        [self writeExcludeSet:s ownerPK:ownerPK];
    });
    post();
}
+ (NSArray<NSString *> *)excludedIdentifiersForOwnerPK:(NSString *)ownerPK {
    __block NSArray *a = @[];
    ioSync(^{ a = [self excludeSet:ownerPK].allObjects; });
    return a;
}

@end
