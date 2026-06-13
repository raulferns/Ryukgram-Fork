#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Shared access to live IG thread data (IGDirectPublishedThread / IGDirectThreadMetadata).
// The cache applicator registers its IGDirectCache per owner pk; any feature can then fetch a
// thread by id and pull a group's display name + image off the live metadata — no API call.
@interface SCIDirectThreadInfo : NSObject

+ (void)registerCache:(id)cache forOwnerPK:(nullable NSString *)ownerPK;

// Fetch the live published thread by id (completion on main; thread may be nil).
+ (void)fetchThreadId:(NSString *)threadId ownerPK:(NSString *)ownerPK completion:(void (^)(id _Nullable thread))completion;

// Group display name from a thread's metadata: thread title → custom name → joined member usernames.
+ (nullable NSString *)groupNameFromMetadata:(id)meta viewerPK:(nullable NSString *)viewerPK;
// Group image URL string from a thread's metadata (groupPhotoIdentifier → specifier → remoteImageURL).
+ (nullable NSString *)groupImageURLFromMetadata:(id)meta;

// Convenience over a fetched IGDirectPublishedThread: @{ "is_group": @(bool), "name": NSString?, "image": NSString? }.
+ (nullable NSDictionary *)groupInfoForThread:(id)thread viewerPK:(nullable NSString *)viewerPK;

// pk -> @{ "username": NSString, "profile_pic_url": NSString } for a fetched thread's participants.
+ (NSDictionary<NSString *, NSDictionary *> *)participantsForThread:(id)thread;

@end

NS_ASSUME_NONNULL_END
