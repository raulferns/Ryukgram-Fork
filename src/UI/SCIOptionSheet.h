// Bottom-sheet single-select picker. Each row: title, optional description,
// check on the active value.
//
// Options: dicts with @"title", @"value", optional @"description". Pick
// writes to defaultsKey (if set) and fires onChange.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIOptionSheet : NSObject

+ (void)presentFrom:(UIViewController *)presenter
              title:(nullable NSString *)title
        defaultsKey:(nullable NSString *)defaultsKey
            options:(NSArray<NSDictionary<NSString *, NSString *> *> *)options
           onChange:(nullable void (^)(NSString *value))onChange;

+ (void)presentFrom:(UIViewController *)presenter
              title:(nullable NSString *)title
               menu:(UIMenu *)menu
             onPick:(nullable void (^)(UICommand *command))onPick;

+ (void)presentFrom:(UIViewController *)presenter
              title:(nullable NSString *)title
               menu:(UIMenu *)menu
         sourceView:(nullable UIView *)sourceView
             onPick:(nullable void (^)(UICommand *command))onPick;

@end

NS_ASSUME_NONNULL_END
