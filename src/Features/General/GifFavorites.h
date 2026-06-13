#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL sciGifFavContains(NSString *giphyId);
// Returns YES if now favorited.
BOOL sciGifFavToggleId(NSString *giphyId);

#ifdef __cplusplus
}
#endif
