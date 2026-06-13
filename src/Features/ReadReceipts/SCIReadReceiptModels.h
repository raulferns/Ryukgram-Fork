#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One read event: a participant (readerPk) saw a message you (the owner) sent.
@interface SCIReadReceipt : NSObject

@property (nonatomic, copy)   NSString *threadId;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, copy, nullable) NSString *threadTitle;     // group name (groups only)
@property (nonatomic, copy, nullable) NSString *threadAvatarURL; // group image (groups only)

@property (nonatomic, copy)   NSString *readerPk;
@property (nonatomic, copy, nullable) NSString *readerUsername;
@property (nonatomic, copy, nullable) NSString *readerProfilePicURL;

@property (nonatomic, copy)   NSString *messageId;              // the message they read
@property (nonatomic, copy, nullable) NSString *messagePreview; // best-effort text snippet
@property (nonatomic, strong, nullable) NSDate *messageSentAt;

@property (nonatomic, strong) NSDate *readAt;                   // when we detected the read

+ (instancetype)receiptFromJSONDict:(NSDictionary *)dict;
- (NSDictionary *)toJSONDict;

@end

// One chat's receipts. 1-1: a single reader. Group: reads from multiple members.
@interface SCIReadReceiptGroup : NSObject
@property (nonatomic, copy)   NSString *threadId;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, copy, nullable) NSString *threadTitle;
@property (nonatomic, copy, nullable) NSString *threadAvatarURL;
// 1-1 convenience (the single other party); nil/ignored for groups.
@property (nonatomic, copy, nullable) NSString *readerPk;
@property (nonatomic, copy, nullable) NSString *readerUsername;
@property (nonatomic, copy, nullable) NSString *readerProfilePicURL;
@property (nonatomic, strong) NSArray<SCIReadReceipt *> *receipts; // newest-first

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly, nullable) NSDate *lastReadAt;
@property (nonatomic, readonly, nullable) SCIReadReceipt *latest;
@property (nonatomic, readonly) NSString *identifier;           // threadId
@property (nonatomic, readonly) NSString *displayTitle;         // group name or @username
@property (nonatomic, readonly, nullable) NSString *displayAvatarURL; // 1-1 reader pic; nil for groups
// One latest receipt per distinct reader (for the group member facepile / summary).
@property (nonatomic, readonly) NSArray<SCIReadReceipt *> *distinctReaders;
@end

NS_ASSUME_NONNULL_END
