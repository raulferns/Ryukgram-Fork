// Notes actions — copy text, download GIF/audio from notes long-press menu.
// The Swift-backed IGDSPrismMenuView never fires ObjC init hooks, so we
// capture the note off the section controller's long-press handler and inject
// our own row from the menu view's -layoutSubviews.

#import "../../InstagramHeaders.h"
#import "../../Utils.h"
#import "../../Downloader/Download.h"
#import "../../UI/SCIDownloadMenu.h"
#import "../../Gallery/SCIGalleryFile.h"
#import "../../Gallery/SCIGallerySaveMetadata.h"
#import "../../ActionButton/SCIMediaActions.h"
#import "SCIDirectUserResolver.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

typedef id (*SCIMsgSendId)(id, SEL);
static inline id sciCall0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((SCIMsgSendId)objc_msgSend)(obj, sel);
}

static SCIGallerySaveMetadata *sciNotesMetadataForNote(id note) {
    SCIGallerySaveMetadata *md = [SCIGallerySaveMetadata new];
    md.source = (int16_t)SCIGallerySourceNotes;
    if (!note) return md;
    @try {
        id uf = [note valueForKey:@"userFields"];
        md.sourceUsername = sciDirectUserResolverUsernameFromUser(uf);
        md.sourceUserPK = sciDirectUserResolverPKFromUser(uf);
        md.sourceProfileURLString = sciDirectUserResolverProfilePicURLStringFromUser(uf);
    } @catch (__unused id e) {}
    md.sourceMediaPK = sciDirectUserResolverPKFromUser(note);
    return md;
}

static UIView *sciFindGIFView(UIView *cell) {
    if (!cell) return nil;
    NSMutableArray *q = [NSMutableArray arrayWithObject:cell];
    int s = 0;
    while (q.count && s < 100) {
        UIView *cur = q.firstObject; [q removeObjectAtIndex:0]; s++;
        if ([NSStringFromClass([cur class]) containsString:@"GIFView"]) return cur;
        for (UIView *sub in cur.subviews) [q addObject:sub];
    }
    return nil;
}

// FLAnimatedImage's -fileData has the raw GIF bytes so we save the full
// animation instead of a one-frame PNG.
static NSData *sciGIFDataFromCell(UIView *cell) {
    UIView *gifView = sciFindGIFView(cell);
    if (!gifView) return nil;
    @try {
        id renderer = [gifView valueForKey:@"renderer"];
        if (renderer && [renderer respondsToSelector:@selector(fileData)]) {
            NSData *d = ((NSData *(*)(id, SEL))objc_msgSend)(renderer, @selector(fileData));
            if ([d isKindOfClass:[NSData class]] && d.length > 0) return d;
        }
        Ivar dataIv = renderer ? class_getInstanceVariable([renderer class], "_data") : NULL;
        if (dataIv) {
            id dataObj = object_getIvar(renderer, dataIv);
            if ([dataObj isKindOfClass:[NSData class]] && [(NSData *)dataObj length] > 0) return dataObj;
            if (dataObj && [dataObj respondsToSelector:@selector(data)]) {
                NSData *d = ((NSData *(*)(id, SEL))objc_msgSend)(dataObj, @selector(data));
                if ([d isKindOfClass:[NSData class]] && d.length > 0) return d;
            }
        }
    } @catch (__unused id e) {}
    return nil;
}

static id sciAudioTrackFromCell(UIView *cell) {
    if (!cell) return nil;
    SEL viewModelSel = @selector(noteViewModel);
    id vm = nil;
    if ([cell respondsToSelector:viewModelSel])
        vm = sciCall0(cell, viewModelSel);
    if (!vm) {
        Ivar vmIvar = class_getInstanceVariable([cell class], "viewModel");
        if (!vmIvar) vmIvar = class_getInstanceVariable([cell class], "_viewModel");
        if (vmIvar) vm = object_getIvar(cell, vmIvar);
    }
    if (!vm) return nil;

    SEL audioSel2 = NSSelectorFromString(@"audioTrackWithUserMap:launcherSet:");
    SEL audioSel1 = NSSelectorFromString(@"audioTrackWithUserMap:");
    @try {
        if ([vm respondsToSelector:audioSel2]) {
            id session = [SCIUtils activeUserSession];
            id launcher = nil;
            @try { launcher = session ? [session valueForKey:@"launcherSet"] : nil; } @catch (__unused id e) {}
            return ((id(*)(id,SEL,id,id))objc_msgSend)(vm, audioSel2, nil, launcher);
        }
        if ([vm respondsToSelector:audioSel1]) {
            return ((id(*)(id,SEL,id))objc_msgSend)(vm, audioSel1, nil);
        }
    } @catch (__unused id e) {}
    return nil;
}

static void sciResolveAudioURL(id track, void (^completion)(NSURL *)) {
    if (!track || !completion) { if (completion) completion(nil); return; }
    id task = nil;
    @try {
        if ([track respondsToSelector:@selector(audioFileURLTask)])
            task = ((id(*)(id,SEL))objc_msgSend)(track, @selector(audioFileURLTask));
    } @catch (__unused id e) {}
    if (!task) { completion(nil); return; }

    @try {
        id res = [task valueForKey:@"result"];
        if ([res isKindOfClass:[NSURL class]]) { completion(res); return; }
    } @catch (__unused id e) {}

    SEL onSuccess = NSSelectorFromString(@"onSuccess:");
    if (![task respondsToSelector:onSuccess]) { completion(nil); return; }
    void (^cb)(id) = ^(id resolved) {
        NSURL *u = [resolved isKindOfClass:[NSURL class]] ? resolved : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(u); });
    };
    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(task, onSuccess, cb);
    } @catch (__unused id e) { completion(nil); }
}

static id sciNoteFromViewModel(id viewModel) {
    if (!viewModel) return nil;
    if ([viewModel respondsToSelector:@selector(note)]) {
        @try { return [viewModel valueForKey:@"note"]; } @catch (__unused id e) {}
    }
    return viewModel;
}

static void sciShowNotesSubmenu(id viewModel, UIView *cell) {
    id note = sciNoteFromViewModel(viewModel);
    if (!note) return;

    NSString *text = nil;
    @try { text = [note valueForKey:@"text"]; } @catch (__unused id e) {}

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:nil message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    if (text.length) {
        [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Copy text")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [[UIPasteboard generalPasteboard] setString:text];
            SCINotifySuccess(SCI_NOTIF_COPY_NOTE, SCILocalized(@"Note text copied"), nil);
        }]];
    }

    NSString *linkString = nil;
    @try {
        id ext = [note valueForKey:@"externalContentUri"];
        if ([ext isKindOfClass:[NSString class]] && [(NSString *)ext length]) linkString = ext;
    } @catch (__unused id e) {}
    if (!linkString.length) {
        @try {
            id ext = [note valueForKey:@"externalAttributionURLString"];
            if ([ext isKindOfClass:[NSString class]] && [(NSString *)ext length]) linkString = ext;
        } @catch (__unused id e) {}
    }
    if (linkString.length) {
        NSString *capturedLink = linkString;
        [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Copy link")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [[UIPasteboard generalPasteboard] setString:capturedLink];
            SCINotifySuccess(SCI_NOTIF_COPY_URL, SCILocalized(@"Link copied"), nil);
        }]];
    }

    SCIGallerySaveMetadata *noteMD = sciNotesMetadataForNote(note);

    NSData *gifData = sciGIFDataFromCell(cell);
    if (gifData) {
        [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Save GIF")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            NSURL *fileURL = [SCITempFiles claimWithExt:@"gif" ttl:600 tag:@"note_gif"];
            [gifData writeToFile:fileURL.path atomically:YES];
            [SCIMediaActions setCurrentFilenameStem:
                [SCIMediaActions filenameStemForUsername:noteMD.sourceUsername contextLabel:@"note-gif"]];
            [SCIDownloadMenu presentForURL:fileURL
                                      mode:SCIDownloadMenuModeLocalFile
                             fileExtension:@"gif"
                                  hudLabel:SCILocalized(@"Save GIF")
                                  metadata:noteMD
                                   isAudio:NO
                                    fromVC:nil];
        }]];
    }

    id audioTrack = sciAudioTrackFromCell(cell);
    if (audioTrack) {
        [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Download audio")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            sciResolveAudioURL(audioTrack, ^(NSURL *audioURL) {
                if (!audioURL) {
                    [SCIUtils showErrorHUDWithDescription:SCILocalized(@"Audio URL not available")];
                    return;
                }
                NSString *ext = [[audioURL.path pathExtension] lowercaseString];
                if (!SCIGalleryExtensionIsAudio(ext)) ext = @"m4a";
                [SCIMediaActions setCurrentFilenameStem:
                    [SCIMediaActions filenameStemForUsername:noteMD.sourceUsername contextLabel:@"note-audio"]];
                [SCIDownloadMenu presentForURL:audioURL
                                          mode:SCIDownloadMenuModeRemoteURL
                                 fileExtension:ext
                                      hudLabel:SCILocalized(@"Download audio")
                                      metadata:noteMD
                                       isAudio:YES
                                        fromVC:nil];
            });
        }]];
    }

    if (alert.actions.count == 0) {
        [SCIUtils showErrorHUDWithDescription:SCILocalized(@"Note has no downloadable content")];
        return;
    }

    [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];

    [SCIUtils presentAlertInOwnWindow:alert];
}

// Captured at long-press; consumed (and cleared) by the menu's layoutSubviews.
// 3s window guards against the menu never appearing.
static __weak id sciPendingNoteViewModel = nil;
static __weak UIView *sciPendingNoteCell = nil;
static NSTimeInterval sciPendingNoteAt = 0;
static BOOL sciPendingNoteFresh(void) {
    return sciPendingNoteViewModel != nil
        && (CFAbsoluteTimeGetCurrent() - sciPendingNoteAt) < 3.0;
}

typedef void (*LongTapFn)(id, SEL, id, id, id, NSInteger);
static LongTapFn orig_didLongTap = NULL;

static void new_didLongTap(id self, SEL _cmd, id sectionController, id viewModel, id pogCell, NSInteger position) {
    if ([SCIUtils getBoolPref:@"note_actions"]) {
        sciPendingNoteViewModel = viewModel;
        sciPendingNoteCell = (UIView *)pogCell;
        sciPendingNoteAt = CFAbsoluteTimeGetCurrent();
    }
    if ([SCIUtils getBoolPref:@"note_copy_on_hold"]) {
        id note = sciNoteFromViewModel(viewModel);
        if (note) {
            NSString *text = nil;
            @try { text = [note valueForKey:@"text"]; } @catch (__unused id e) {}
            if (text.length) {
                [[UIPasteboard generalPasteboard] setString:text];
                SCINotifySuccess(SCI_NOTIF_COPY_NOTE, SCILocalized(@"Note text copied"), nil);
            }
        }
    }
    orig_didLongTap(self, _cmd, sectionController, viewModel, pogCell, position);
}

static void *kSciNotesInjectedKey = &kSciNotesInjectedKey;
static void *kSciNotesItemHeightKey = &kSciNotesItemHeightKey;
static void *kSciNotesViewModelKey = &kSciNotesViewModelKey;

static void (*orig_prismMenuView_layout)(id, SEL);
static CGSize (*orig_prismMenuView_sizeThatFits)(id, SEL, CGSize);

@interface SCINotesInjectedTapTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) id viewModel;
@property (nonatomic, weak) UIView *cell;
@property (nonatomic, weak) UIView *menuView;
@property (nonatomic, weak) UIView *wrapper;
@end
// IG's prism menu sits in its own key window — hide it to hand input back.
static void sciDismissPrismMenuPresentation(UIView *menuView) {
    if (!menuView) return;
    UIWindow *menuWindow = menuView.window;
    [menuView removeFromSuperview];
    menuWindow.hidden = YES;
}

@implementation SCINotesInjectedTapTarget
- (void)tap {
    id vm = self.viewModel;
    UIView *cell = self.cell;
    [self.wrapper removeFromSuperview];
    sciDismissPrismMenuPresentation(self.menuView);
    dispatch_async(dispatch_get_main_queue(), ^{
        sciShowNotesSubmenu(vm, cell);
    });
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return [touch.view isDescendantOfView:self.wrapper];
}
@end

static void new_prismMenuView_layout(id self, SEL _cmd) {
    orig_prismMenuView_layout(self, _cmd);

    if (objc_getAssociatedObject(self, kSciNotesInjectedKey)) return;
    if (![SCIUtils getBoolPref:@"note_actions"]) return;
    if (!sciPendingNoteFresh()) return;

    Ivar elIvar = class_getInstanceVariable([self class], "menuElementViews");
    NSArray *elements = elIvar ? object_getIvar(self, elIvar) : nil;
    if (![elements isKindOfClass:[NSArray class]] || elements.count == 0) return;

    UIView *template = elements.lastObject;
    if (!template || !template.superview) return;

    Class builderClass = NSClassFromString(@"IGDSPrismMenuItemBuilder");
    Class itemViewClass = NSClassFromString(@"IGDSPrismMenu.IGDSPrismMenuItemView");
    if (!itemViewClass) itemViewClass = NSClassFromString(@"_TtC13IGDSPrismMenu21IGDSPrismMenuItemView");
    if (!builderClass) return;

    typedef id (*InitFn)(id, SEL, id);
    typedef id (*WithFn)(id, SEL, id);
    typedef id (*BuildFn)(id, SEL);
    id builder = ((InitFn)objc_msgSend)([builderClass alloc], @selector(initWithTitle:), SCILocalized(@"Note actions"));
    builder = ((WithFn)objc_msgSend)(builder, @selector(withHandler:), ^{});
    id menuItem = ((BuildFn)objc_msgSend)(builder, @selector(build));
    if (!menuItem) return;

    // Match the existing rows' style — read edrEnabled off the template ivar.
    BOOL edrEnabled = NO;
    Ivar edrIv = class_getInstanceVariable([template class], "edrEnabled");
    if (edrIv) {
        ptrdiff_t off = ivar_getOffset(edrIv);
        edrEnabled = *(BOOL *)((uint8_t *)(__bridge void *)template + off);
    }
    UIView *itemView = nil;
    if (itemViewClass) {
        itemView = ((id(*)(id,SEL,id,BOOL,BOOL,BOOL))objc_msgSend)([itemViewClass alloc],
            @selector(initWithMenuItem:edrEnabled:isHeader:isSubmenu:), menuItem, edrEnabled, NO, NO);
    }
    if (!itemView) {
        UIView *fallback = [[UIView alloc] initWithFrame:CGRectZero];
        fallback.backgroundColor = UIColor.clearColor;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = SCILocalized(@"Note actions");
        label.textColor = UIColor.labelColor;
        label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [fallback addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:fallback.leadingAnchor constant:18.0],
            [label.centerYAnchor constraintEqualToAnchor:fallback.centerYAnchor],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:fallback.trailingAnchor constant:-18.0],
        ]];
        itemView = fallback;
    }

    CGFloat itemHeight = template.frame.size.height;
    CGFloat itemX = template.frame.origin.x;
    CGFloat itemWidth = template.frame.size.width;

    // Sibling-of-items placement keeps our row inside the menu's dismisser
    // hit zone — siblings of the menu itself end up outside it.
    SCINotesInjectedTapTarget *target = [SCINotesInjectedTapTarget new];
    target.viewModel = sciPendingNoteViewModel;
    target.cell = sciPendingNoteCell;
    target.menuView = (UIView *)self;

    CGFloat injY = CGRectGetMaxY(template.frame);
    UIControl *wrapper = [[UIControl alloc] initWithFrame:CGRectMake(itemX, injY, itemWidth, itemHeight)];
    target.wrapper = wrapper;
    itemView.frame = wrapper.bounds;
    itemView.userInteractionEnabled = NO;
    [wrapper addSubview:itemView];
    [wrapper addTarget:target action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [template.superview addSubview:wrapper];

    // IG's central tap recognizer eats UIControl touches; layer our own
    // recognizer alongside it.
    UITapGestureRecognizer *ownTap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tap)];
    ownTap.delegate = target;
    objc_setAssociatedObject(wrapper, "_sciTap", ownTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [wrapper addGestureRecognizer:ownTap];

    // Grow menu + ancestors so the bottom row stays visible.
    UIView *menuView = (UIView *)self;
    CGRect mF = menuView.frame;
    mF.size.height += itemHeight;
    menuView.frame = mF;
    UIView *node = template.superview;
    while (node && node != menuView) {
        CGRect nf = node.frame;
        nf.size.height += itemHeight;
        node.frame = nf;
        node.clipsToBounds = NO;
        node = node.superview;
    }
    menuView.clipsToBounds = NO;

    objc_setAssociatedObject(self, kSciNotesInjectedKey, wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kSciNotesItemHeightKey, @(itemHeight), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kSciNotesViewModelKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    sciPendingNoteViewModel = nil;
    sciPendingNoteCell = nil;
}

static void (*orig_prismMenuView_willMove)(id, SEL, id);
static void new_prismMenuView_willMove(id self, SEL _cmd, UIWindow *newWindow) {
    if (!newWindow) {
        UIView *wrapper = objc_getAssociatedObject(self, kSciNotesInjectedKey);
        [wrapper removeFromSuperview];
        objc_setAssociatedObject(self, kSciNotesInjectedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kSciNotesViewModelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    orig_prismMenuView_willMove(self, _cmd, newWindow);
}

static CGSize new_prismMenuView_sizeThatFits(id self, SEL _cmd, CGSize size) {
    CGSize s = orig_prismMenuView_sizeThatFits(self, _cmd, size);
    NSNumber *extra = objc_getAssociatedObject(self, kSciNotesItemHeightKey);
    if (extra) s.height += extra.doubleValue;
    return s;
}

%ctor {
    Class prismMenuView = objc_getClass("IGDSPrismMenu.IGDSPrismMenuView");
    if (!prismMenuView) prismMenuView = NSClassFromString(@"_TtC13IGDSPrismMenu17IGDSPrismMenuView");
    if (prismMenuView) {
        MSHookMessageEx(prismMenuView, @selector(layoutSubviews),
                        (IMP)new_prismMenuView_layout, (IMP *)&orig_prismMenuView_layout);
        MSHookMessageEx(prismMenuView, @selector(sizeThatFits:),
                        (IMP)new_prismMenuView_sizeThatFits, (IMP *)&orig_prismMenuView_sizeThatFits);
        MSHookMessageEx(prismMenuView, @selector(willMoveToWindow:),
                        (IMP)new_prismMenuView_willMove, (IMP *)&orig_prismMenuView_willMove);
    }

    Class helper = NSClassFromString(@"IGDirectNotesTrayUISwift.IGDirectNotesTrayCellInteractionHelper");
    if (!helper) helper = NSClassFromString(@"_TtC24IGDirectNotesTrayUISwift38IGDirectNotesTrayCellInteractionHelper");
    if (helper) {
        SEL sel = @selector(traySectionController:didLongTapViewModel:pogCell:itemPosition:);
        if ([helper instancesRespondToSelector:sel])
            MSHookMessageEx(helper, sel, (IMP)new_didLongTap, (IMP *)&orig_didLongTap);
    }
}
