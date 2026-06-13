// Long-press a GIF in the native picker to favorite (pinned to top of grid)
// or download it.

#import <UIKit/UIKit.h>
#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import "GifFavorites.h"
#import "../../SCIChrome.h"
#import "../../UI/SCIDownloadMenu.h"
#import "../../Gallery/SCIGalleryFile.h"
#import "../../ActionButton/SCIMediaActions.h"
#import <objc/runtime.h>
#import <objc/message.h>

static char kSCIGifFavLPKey;
static char kSCIGifFavBadgeKey;

#pragma mark - Storage

static NSArray<NSDictionary *> *sci_favList(void) {
    NSArray *list = [SCIUtils getArrayPref:@"gif_favorites_list"];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

static void sci_favSave(NSArray *list) {
    [SCIUtils setPref:list forKey:@"gif_favorites_list"];
}

static NSUInteger sci_favIndexOfPK(NSArray<NSDictionary *> *list, NSString *pk) {
    for (NSUInteger i = 0; i < list.count; i++)
        if ([list[i][@"pk"] isEqualToString:pk]) return i;
    return NSNotFound;
}

BOOL sciGifFavContains(NSString *giphyId) {
    return giphyId.length && sci_favIndexOfPK(sci_favList(), giphyId) != NSNotFound;
}

BOOL sciGifFavToggleId(NSString *giphyId) {
    if (!giphyId.length) return NO;
    NSMutableArray *list = [sci_favList() mutableCopy];
    NSUInteger existing = sci_favIndexOfPK(list, giphyId);
    BOOL nowFav;
    if (existing != NSNotFound) {
        [list removeObjectAtIndex:existing];
        nowFav = NO;
    } else {
        [list insertObject:@{ @"pk": giphyId, @"w": @(200), @"h": @(200) } atIndex:0];
        nowFav = YES;
    }
    sci_favSave(list);
    return nowFav;
}

#pragma mark - VM <-> fav dict

// Only pk + dimensions persist — picker VM URLs carry expiring giphy search
// tokens, so playback URLs are always rebuilt canonical from the pk.
static NSDictionary *sci_favFromVM(id vm) {
    @try {
        NSString *pk = [vm valueForKey:@"pk"];
        if (![pk isKindOfClass:[NSString class]] || !pk.length) return nil;
        double w = [[vm valueForKey:@"width"] doubleValue];
        double h = [[vm valueForKey:@"height"] doubleValue];
        return @{ @"pk": pk, @"w": @(w > 0 ? w : 200), @"h": @(h > 0 ? h : 200) };
    } @catch (__unused id e) { return nil; }
}

static NSString *sci_favPKFromObject(id obj) {
    if (!obj || ![obj isKindOfClass:NSClassFromString(@"IGDirectAnimatedMediaViewModel")]) return nil;
    @try {
        NSString *pk = [obj valueForKey:@"pk"];
        return [pk isKindOfClass:[NSString class]] && pk.length ? pk : nil;
    } @catch (__unused id e) { return nil; }
}

static id sci_buildFavModeConfig(Class cfgCls, NSString *urlStr) {
    if (!cfgCls || !urlStr.length) return nil;
    SEL cfgInit = @selector(initWithUrl:dataSizeInByte:);
    if (![cfgCls instancesRespondToSelector:cfgInit]) return nil;
    return ((id(*)(id, SEL, id, double))objc_msgSend)([cfgCls alloc], cfgInit, urlStr, 0.0);
}

static id sci_vmFromFav(NSDictionary *fav) {
    Class cfgCls = NSClassFromString(@"IGGiphyGIFModelModeConfig");
    Class imgCls = NSClassFromString(@"IGGiphyImageModel");
    Class vmCls  = NSClassFromString(@"IGDirectAnimatedMediaViewModel");
    if (!cfgCls || !imgCls || !vmCls) return nil;

    NSString *pk = fav[@"pk"];
    if (![pk isKindOfClass:[NSString class]] || !pk.length) return nil;
    NSString *gif  = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif",  pk];
    NSString *mp4  = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.mp4",  pk];
    NSString *webp = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.webp", pk];
    double w = [fav[@"w"] doubleValue] ?: 200;
    double h = [fav[@"h"] doubleValue] ?: 200;

    id gifCfg  = sci_buildFavModeConfig(cfgCls, gif);
    id mp4Cfg  = sci_buildFavModeConfig(cfgCls, mp4);
    id webpCfg = sci_buildFavModeConfig(cfgCls, webp);
    if (!gifCfg && !mp4Cfg) return nil;

    SEL imgInit = @selector(initWithGifConfig:mp4Config:webpConfig:width:height:);
    if (![imgCls instancesRespondToSelector:imgInit]) return nil;
    id imgModel = ((id(*)(id, SEL, id, id, id, double, double))objc_msgSend)(
        [imgCls alloc], imgInit, gifCfg, mp4Cfg, webpCfg, w, h);

    SEL vmInit = NSSelectorFromString(@"initWithPk:url:cacheIdentifier:width:height:format:backgroundColor:isSticker:imageModel:animatedImageResolver:previewImageSpecifier:creatorUsername:altText:");
    if (![vmCls instancesRespondToSelector:vmInit]) return nil;
    return ((id(*)(id, SEL, id, id, id, double, double, long long, id, BOOL, id, id, id, id, id))objc_msgSend)(
        [vmCls alloc], vmInit,
        pk, [NSURL URLWithString:mp4], mp4,
        w, h, 2 /*format*/, nil, NO,
        imgModel, nil, nil, nil, @"");
}

#pragma mark - Favorite badge

static void sci_setFavBadge(UICollectionViewCell *cell, BOOL show) {
    SCIChromeButton *badge = objc_getAssociatedObject(cell, &kSCIGifFavBadgeKey);
    if (!show) {
        if (badge) [badge removeFromSuperview];
        objc_setAssociatedObject(cell, &kSCIGifFavBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!badge) {
        badge = [[SCIChromeButton alloc] initWithSymbol:@"star.fill" pointSize:9 diameter:18];
        badge.iconTint = [UIColor systemYellowColor];
        badge.bubbleColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        badge.userInteractionEnabled = NO;
        objc_setAssociatedObject(cell, &kSCIGifFavBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    badge.frame = CGRectMake(5, 5, 18, 18);
    [cell.contentView addSubview:badge];
}

#pragma mark - Long-press

@interface SCIGifFavTarget : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gr;
@end

@implementation SCIGifFavTarget

+ (instancetype)shared {
    static SCIGifFavTarget *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [SCIGifFavTarget new]; });
    return t;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UICollectionView *cv = (UICollectionView *)gr.view;
    if (![cv isKindOfClass:[UICollectionView class]]) return;

    NSIndexPath *path = [cv indexPathForItemAtPoint:[gr locationInView:cv]];
    if (!path) return;

    UIViewController *host = nil;
    UIResponder *r = cv;
    Class vcCls = NSClassFromString(@"IGDirectGIFViewController");
    while (r) {
        if ([r isKindOfClass:vcCls]) { host = (UIViewController *)r; break; }
        r = [r nextResponder];
    }
    if (!host) return;

    id adapter = nil;
    @try { adapter = [host valueForKey:@"listAdapter"]; } @catch (__unused id e) {}
    SEL objAtSec = NSSelectorFromString(@"objectAtSection:");
    if (!adapter || ![adapter respondsToSelector:objAtSec]) return;
    id obj = ((id(*)(id, SEL, NSInteger))objc_msgSend)(adapter, objAtSec, path.section);

    NSDictionary *fav = sci_favFromVM(obj);
    if (!fav) return;

    BOOL favsOn = [SCIUtils getBoolPref:@"gif_favorites_enabled"];
    BOOL downloadOn = [SCIUtils getBoolPref:@"download_gif_comment"];
    if (!favsOn && !downloadOn) return;

    UIViewController *presenter = host;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    if (favsOn) {
        NSMutableArray *list = [sci_favList() mutableCopy];
        NSUInteger existing = sci_favIndexOfPK(list, fav[@"pk"]);
        BOOL isFav = (existing != NSNotFound);
        NSString *toggleTitle = isFav ? SCILocalized(@"Unfavorite") : SCILocalized(@"Favorite");
        [sheet addAction:[UIAlertAction actionWithTitle:toggleTitle
                                                  style:(isFav ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault)
                                                handler:^(UIAlertAction *_) {
            if (isFav) {
                [list removeObjectAtIndex:existing];
                SCINotifySuccess(SCI_NOTIF_GIF_FAVORITE, SCILocalized(@"Removed from favorites"), nil);
            } else {
                [list insertObject:fav atIndex:0];
                SCINotifySuccess(SCI_NOTIF_GIF_FAVORITE, SCILocalized(@"Added to favorites"), nil);
            }
            sci_favSave(list);
            SEL upd = NSSelectorFromString(@"performUpdatesAnimated:completion:");
            if ([adapter respondsToSelector:upd])
                ((void(*)(id, SEL, BOOL, id))objc_msgSend)(adapter, upd, YES, nil);
        }]];
    }

    if (downloadOn) {
        NSString *pk = fav[@"pk"];
        NSURL *gifURL = [NSURL URLWithString:
            [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif", pk]];
        [sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Download GIF")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            if (!gifURL) return;
            SCIGallerySaveMetadata *md = [SCIGallerySaveMetadata new];
            md.source = (int16_t)SCIGallerySourceDMs;
            md.sourceMediaPK = pk;
            md.sourceMediaURLString = gifURL.absoluteString;
            [SCIMediaActions setCurrentFilenameStem:
                [SCIMediaActions filenameStemForUsername:nil contextLabel:@"gif"]];
            if ([SCIUtils getBoolPref:@"sci_gallery_enabled"]) {
                [SCIDownloadMenu presentForURL:gifURL
                                          mode:SCIDownloadMenuModeRemoteURL
                                 fileExtension:@"gif"
                                      hudLabel:SCILocalized(@"Download GIF")
                                      metadata:md
                                       isAudio:NO
                                        fromVC:nil];
            } else {
                BOOL toPhotos = [[SCIUtils getStringPref:@"dw_save_action"] isEqualToString:@"photos"];
                [SCIDownloadMenu downloadURL:gifURL
                               fileExtension:@"gif"
                                    hudLabel:nil
                                    metadata:md
                                 forceTarget:(toPhotos ? 0 : 2)];
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = cv;
    sheet.popoverPresentationController.sourceRect = [cv cellForItemAtIndexPath:path].frame;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Hook

%hook IGDirectGIFViewController

- (NSArray *)objectsForListAdapter:(id)adapter {
    NSArray *orig = %orig;
    if (![SCIUtils getBoolPref:@"gif_favorites_enabled"]) return orig;

    NSString *query = nil;
    @try { query = [self valueForKey:@"searchQuery"]; } @catch (__unused id e) {}
    if ([query isKindOfClass:[NSString class]] && query.length) return orig;

    NSArray<NSDictionary *> *favs = sci_favList();
    if (!favs.count) return orig;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:orig.count + favs.count];
    NSMutableSet *favPKs = [NSMutableSet set];
    for (NSDictionary *f in favs) {
        id vm = sci_vmFromFav(f);
        if (!vm) continue;
        [out addObject:vm];
        [favPKs addObject:f[@"pk"]];
    }
    for (id obj in orig) {
        NSString *pk = nil;
        @try { pk = [obj valueForKey:@"pk"]; } @catch (__unused id e) {}
        if ([pk isKindOfClass:[NSString class]] && [favPKs containsObject:pk]) continue;
        [out addObject:obj];
    }
    return out;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (![SCIUtils getBoolPref:@"gif_favorites_enabled"] &&
        ![SCIUtils getBoolPref:@"download_gif_comment"]) return;
    UICollectionView *cv = nil;
    @try { cv = [self valueForKey:@"collectionView"]; } @catch (__unused id e) {}
    if (![cv isKindOfClass:[UICollectionView class]]) return;
    if (objc_getAssociatedObject(cv, &kSCIGifFavLPKey)) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[SCIGifFavTarget shared]
                action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [cv addGestureRecognizer:lp];
    objc_setAssociatedObject(cv, &kSCIGifFavLPKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

// Star badge on favorited cells. Global adapter hook, but exits unless the
// collection view carries our GIF-picker long-press marker.
%hook IGListAdapter

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = %orig;
    if (!objc_getAssociatedObject(collectionView, &kSCIGifFavLPKey)) return cell;
    if (![SCIUtils getBoolPref:@"gif_favorites_enabled"]) { sci_setFavBadge(cell, NO); return cell; }
    NSString *pk = sci_favPKFromObject([self objectAtSection:indexPath.section]);
    sci_setFavBadge(cell, pk && sci_favIndexOfPK(sci_favList(), pk) != NSNotFound);
    return cell;
}

%end
