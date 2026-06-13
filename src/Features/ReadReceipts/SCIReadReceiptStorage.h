#import <Foundation/Foundation.h>
#import "SCIReadReceiptModels.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const SCIReadReceiptsDidChangeNotification;

@interface SCIReadReceiptStorage : NSObject

+ (NSString *)storageDirectory;

// Records
+ (NSArray<SCIReadReceipt *> *)allReceiptsForOwnerPK:(NSString *)ownerPK;
+ (NSArray<SCIReadReceiptGroup *> *)groupedByThreadForOwnerPK:(NSString *)ownerPK;
+ (NSArray<SCIReadReceipt *> *)receiptsForReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK;
+ (NSArray<SCIReadReceipt *> *)receiptsForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK;
+ (void)deleteReceiptsForThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK;
+ (void)addReceipt:(SCIReadReceipt *)receipt forOwnerPK:(NSString *)ownerPK;
+ (NSUInteger)totalCountForOwnerPK:(NSString *)ownerPK;

+ (void)deleteReceiptsForReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK;
+ (void)resetForOwnerPK:(NSString *)ownerPK;
+ (void)resetAll;

// Merge another store's files into this one (backup import). Receipts dedup by
// (messageId, readerPk); diff state keeps local values and fills gaps; exclude lists union.
+ (void)mergeImportedStoreAtPath:(NSString *)importedDir;

// Refresh: stamp updated thread/reader display info onto existing records.
+ (void)applyThreadTitle:(nullable NSString *)title avatarURL:(nullable NSString *)avatarURL forThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK;
+ (void)applyReaderUsername:(nullable NSString *)username profilePicURL:(nullable NSString *)picURL forReaderPK:(NSString *)readerPK ownerPK:(NSString *)ownerPK;

// Per-(thread,reader) last-seen message id — diff state for the detection engine.
+ (nullable NSString *)lastSeenMessageIdForThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK;
+ (void)setLastSeenMessageId:(NSString *)messageId forThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK;

// Messages YOU sent, captured as they pass through the loaded range (id -> sent unix time), so a
// read can be attributed even after the message scrolls out of the window. Capped per thread.
+ (void)recordMyMessages:(NSDictionary<NSString *, NSNumber *> *)idToTimestamp forThread:(NSString *)threadId ownerPK:(NSString *)ownerPK;
+ (NSDictionary<NSString *, NSNumber *> *)myMessagesForThread:(NSString *)threadId ownerPK:(NSString *)ownerPK;

// Latest sent-time of a message OF YOURS that a reader has been seen to pass — notify only on a new advance.
+ (double)lastReadMineTimeForThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK;
+ (void)setLastReadMineTime:(double)timestamp forThread:(NSString *)threadId reader:(NSString *)readerPK ownerPK:(NSString *)ownerPK;

// Exclude list — identifiers are threadId (whole chat) or "u:<readerPk>" (a person everywhere).
+ (BOOL)isThreadExcluded:(NSString *)threadId ownerPK:(NSString *)ownerPK;
+ (BOOL)isReaderExcluded:(NSString *)readerPK ownerPK:(NSString *)ownerPK;
+ (void)setThread:(NSString *)threadId excluded:(BOOL)excluded ownerPK:(NSString *)ownerPK;
+ (void)setReader:(NSString *)readerPK excluded:(BOOL)excluded ownerPK:(NSString *)ownerPK;
+ (NSArray<NSString *> *)excludedIdentifiersForOwnerPK:(NSString *)ownerPK;

@end

NS_ASSUME_NONNULL_END
