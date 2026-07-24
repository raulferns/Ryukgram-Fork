// Send an image or video from the gallery as an Instant. We wrap the camera's
// AVCaptureVideoDataOutput delegate and substitute frames; IG's native record +
// upload run unchanged on top.

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../../Utils.h"
#import "../../SCIChrome.h"
#import "SCIInstantsPath.h"
#import "../../Gallery/SCIGalleryViewController.h"
#import "../../Gallery/SCIGalleryFile.h"
#import "../../UI/SCIVideoEditor.h"

static const void *kSCIVideoInjectorKey = &kSCIVideoInjectorKey;
static const void *kSCIInstantsGalleryButtonKey = &kSCIInstantsGalleryButtonKey;

#pragma mark - Shared state

@interface SCIInstantsGalleryState : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic) BOOL active;
@property (nonatomic, strong) AVURLAsset *videoAsset;
@property (nonatomic) BOOL videoActive;
@end

@implementation SCIInstantsGalleryState
@end

static SCIInstantsGalleryState *sciGalleryState(void) {
	static SCIInstantsGalleryState *state;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ state = [SCIInstantsGalleryState new]; });
	return state;
}

static CVPixelBufferRef sCachedPB;
static __weak UIImage *sCachedImage;
static int32_t sCachedW, sCachedH;
static OSType sCachedPix;

static void sciClearFrameCache(void) {
	if (sCachedPB) CVPixelBufferRelease(sCachedPB);
	sCachedPB = NULL;
	sCachedImage = nil;
	sCachedW = sCachedH = 0;
	sCachedPix = 0;
}

// Reader ops run only on the camera sample-buffer queue; record start flips
// sVideoArmReset, consumed on the next frame there — no locking needed.
static AVAssetReader *sVideoReader;
static AVAssetReaderTrackOutput *sVideoOut;
static CVPixelBufferRef sVideoCurPB;
static CMTime sVideoCurPTS;
static CVPixelBufferRef sVideoPosterPB;
static CMTime sVideoStartPTS;
static BOOL sVideoRecording;
static BOOL sVideoStartCaptured;
static volatile BOOL sVideoArmReset;
static __weak id sQuickSnapControlView;
static volatile BOOL sVideoForcedStop;
static volatile BOOL sVideoAwaitingRelease;
static BOOL sVideoSyntheticRelease;

// Hot-path gate the per-frame wrapper checks first; YES only while armed.
static volatile BOOL sInstantsInjectActive;

static void sciTeardownReader(void) {
	if (sVideoReader) { [sVideoReader cancelReading]; sVideoReader = nil; }
	sVideoOut = nil;
	if (sVideoCurPB) { CVPixelBufferRelease(sVideoCurPB); sVideoCurPB = NULL; }
	sVideoCurPTS = kCMTimeInvalid;
	sVideoStartCaptured = NO;
}

static void sciClearPendingVideo(void) {
	SCIInstantsGalleryState *state = sciGalleryState();
	state.videoAsset = nil;
	state.videoActive = NO;
	sVideoRecording = NO;
	sVideoArmReset = NO;
	sciTeardownReader();
	if (sVideoPosterPB) { CVPixelBufferRelease(sVideoPosterPB); sVideoPosterPB = NULL; }
}

static void sciClearPendingImage(void) {
	SCIInstantsGalleryState *state = sciGalleryState();
	state.image = nil;
	state.active = NO;
	sciClearFrameCache();
	sciClearPendingVideo();
	sInstantsInjectActive = NO;
}

static BOOL sciHasPendingImage(void) {
	SCIInstantsGalleryState *state = sciGalleryState();
	return state.active && state.image.CGImage != nil;
}

static BOOL sciHasPendingVideo(void) {
	return sciGalleryState().videoActive;
}

#pragma mark - Small helpers

static UIViewController *sciTopPresenter(void) {
	UIWindow *keyWindow = nil;

	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (window.isKeyWindow) {
				keyWindow = window;
				break;
			}
		}
		if (keyWindow) break;
	}

	UIViewController *vc = keyWindow.rootViewController ?: UIApplication.sharedApplication.keyWindow.rootViewController;
	while (vc.presentedViewController) vc = vc.presentedViewController;
	return vc;
}

#pragma mark - Image → sample buffer

// Draw image centred into a malloc'd BGRA buffer at camera dims. Caller frees.
static void *sciDrawImageToBGRA(CGImageRef cg, int32_t width, int32_t height, size_t *outBPR) {
	if (!cg || width <= 0 || height <= 0) return NULL;

	size_t bpr = ((width * 4 + 63) / 64) * 64;
	void *bgra = calloc(bpr * height, 1);
	if (!bgra) return NULL;

	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) ?: CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(bgra, width, height, 8, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(cs);

	if (!ctx) {
		free(bgra);
		return NULL;
	}

	CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
	CGContextSetShouldAntialias(ctx, YES);
	CGContextSetFillColorWithColor(ctx, UIColor.blackColor.CGColor);
	CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

	CGFloat side = MIN((CGFloat)width, (CGFloat)height);
	CGRect rect = CGRectMake((width - side) * 0.5, (height - side) * 0.5, side, side);
	CGContextDrawImage(ctx, rect, cg);
	CGContextRelease(ctx);

	if (outBPR) *outBPR = bpr;
	return bgra;
}

static CVPixelBufferRef sciRenderCGImageToPixelBuffer(CGImageRef cg, int32_t width, int32_t height, OSType pix) CF_RETURNS_RETAINED;

static CVPixelBufferRef sciRenderImageToPixelBuffer(UIImage *image, int32_t width, int32_t height, OSType pix) CF_RETURNS_RETAINED;

static CVPixelBufferRef sciRenderImageToPixelBuffer(UIImage *image, int32_t width, int32_t height, OSType pix) {
	return sciRenderCGImageToPixelBuffer(image.CGImage, width, height, pix);
}

static CVPixelBufferRef sciRenderCGImageToPixelBuffer(CGImageRef cg, int32_t width, int32_t height, OSType pix) {
	if (!cg || width <= 0 || height <= 0) return NULL;

	NSDictionary *attrs = @{
		(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
		(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
		(__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES
	};

	CVPixelBufferRef pb = NULL;
	if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, pix, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) return NULL;

	BOOL ok = NO;

	if (pix == kCVPixelFormatType_32BGRA) {
		CVPixelBufferLockBaseAddress(pb, 0);

		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) ?: CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), width, height, 8, CVPixelBufferGetBytesPerRow(pb), cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);

		if (ctx) {
			CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
			CGContextSetShouldAntialias(ctx, YES);
			CGContextSetFillColorWithColor(ctx, UIColor.blackColor.CGColor);
			CGContextFillRect(ctx, CGRectMake(0, 0, width, height));

			CGFloat side = MIN((CGFloat)width, (CGFloat)height);
			CGRect rect = CGRectMake((width - side) * 0.5, (height - side) * 0.5, side, side);
			CGContextDrawImage(ctx, rect, cg);
			CGContextRelease(ctx);
			ok = YES;
		}

		CGColorSpaceRelease(cs);
		CVPixelBufferUnlockBaseAddress(pb, 0);
	} else if (pix == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || pix == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
		size_t bpr = 0;
		void *bgra = sciDrawImageToBGRA(cg, width, height, &bpr);

		if (bgra) {
			if (CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
				void *yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
				void *uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1);

				if (yBase && uvBase) {
					vImage_Buffer src = { bgra, (vImagePixelCount)height, (vImagePixelCount)width, bpr };
					vImage_Buffer y = {
						yBase,
						CVPixelBufferGetHeightOfPlane(pb, 0),
						CVPixelBufferGetWidthOfPlane(pb, 0),
						CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
					};
					vImage_Buffer uv = {
						uvBase,
						CVPixelBufferGetHeightOfPlane(pb, 1),
						CVPixelBufferGetWidthOfPlane(pb, 1),
						CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
					};

					BOOL full = pix == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
					vImage_YpCbCrPixelRange range = full
						? (vImage_YpCbCrPixelRange){ 0, 128, 255, 255, 255, 1, 255, 0 }
						: (vImage_YpCbCrPixelRange){ 16, 128, 235, 240, 235, 16, 240, 16 };

					vImage_ARGBToYpCbCr info;
					const uint8_t permute[4] = { 3, 2, 1, 0 };

					if (vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info, kvImageARGB8888, kvImage420Yp8_CbCr8, kvImageNoFlags) == kvImageNoError &&
						vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &y, &uv, &info, permute, kvImageNoFlags) == kvImageNoError) {
						ok = YES;
					}
				}

				CVPixelBufferUnlockBaseAddress(pb, 0);
			}

			free(bgra);
		}
	} else {
		// Generic fallback for 10-bit / HDR / future CV formats.
		size_t bpr = 0;
		void *bgra = sciDrawImageToBGRA(cg, width, height, &bpr);

		if (bgra) {
			vImage_CGImageFormat srcFmt = {
				.bitsPerComponent = 8,
				.bitsPerPixel = 32,
				.colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB),
				.bitmapInfo = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
				.version = 0, .decode = NULL, .renderingIntent = kCGRenderingIntentDefault
			};
			if (!srcFmt.colorSpace) srcFmt.colorSpace = CGColorSpaceCreateDeviceRGB();

			vImageCVImageFormatRef dstFmt = vImageCVImageFormat_CreateWithCVPixelBuffer(pb);
			if (dstFmt) {
				if (!vImageCVImageFormat_GetColorSpace(dstFmt)) {
					CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
					vImageCVImageFormat_SetColorSpace(dstFmt, cs);
					CGColorSpaceRelease(cs);
				}

				vImage_Buffer src = { bgra, (vImagePixelCount)height, (vImagePixelCount)width, bpr };
				if (vImageBuffer_CopyToCVPixelBuffer(&src, &srcFmt, pb, dstFmt, NULL, kvImageNoFlags) == kvImageNoError) ok = YES;

				vImageCVImageFormat_Release(dstFmt);
			}

			CGColorSpaceRelease(srcFmt.colorSpace);
			free(bgra);
		}
	}

	if (!ok) {
		CVPixelBufferRelease(pb);
		return NULL;
	}

	return pb;
}

static CMSampleBufferRef sciSampleBufferFromImage(UIImage *image, CMSampleBufferRef tmpl) CF_RETURNS_RETAINED;

static CMSampleBufferRef sciSampleBufferFromImage(UIImage *image, CMSampleBufferRef tmpl) {
	if (!image.CGImage || !tmpl) return NULL;

	CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(tmpl);
	if (!fmt) return NULL;

	CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
	OSType pix = CMFormatDescriptionGetMediaSubType(fmt);

	if (!sCachedPB || sCachedImage != image || sCachedW != dims.width || sCachedH != dims.height || sCachedPix != pix) {
		sciClearFrameCache();
		sCachedPB = sciRenderImageToPixelBuffer(image, dims.width, dims.height, pix);
		if (!sCachedPB) return NULL;

		sCachedImage = image;
		sCachedW = dims.width;
		sCachedH = dims.height;
		sCachedPix = pix;
	}

	CMVideoFormatDescriptionRef newFmt = NULL;
	if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, sCachedPB, &newFmt) != noErr || !newFmt) return NULL;

	CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid };
	CMSampleBufferGetSampleTimingInfo(tmpl, 0, &timing);

	CMSampleBufferRef out = NULL;
	CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, sCachedPB, true, NULL, NULL, newFmt, &timing, &out);
	CFRelease(newFmt);

	return out;
}

#pragma mark - Video frame injection

static CGImageRef sciCGImageFromPixelBuffer(CVPixelBufferRef pb) CF_RETURNS_RETAINED;

static CGImageRef sciCGImageFromPixelBuffer(CVPixelBufferRef pb) {
	if (!pb) return NULL;
	if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NULL;

	CGImageRef cg = NULL;
	void *base = CVPixelBufferGetBaseAddress(pb);
	size_t w = CVPixelBufferGetWidth(pb);
	size_t h = CVPixelBufferGetHeight(pb);
	size_t bpr = CVPixelBufferGetBytesPerRow(pb);

	if (base && w && h) {
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) ?: CGColorSpaceCreateDeviceRGB();
		CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
		if (ctx) {
			cg = CGBitmapContextCreateImage(ctx);
			CGContextRelease(ctx);
		}
		CGColorSpaceRelease(cs);
	}

	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return cg;
}

static CMSampleBufferRef sciSampleBufferFromPixelBufferSource(CVPixelBufferRef src, CMSampleBufferRef tmpl) CF_RETURNS_RETAINED;

static CMSampleBufferRef sciSampleBufferFromPixelBufferSource(CVPixelBufferRef src, CMSampleBufferRef tmpl) {
	if (!src || !tmpl) return NULL;

	CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(tmpl);
	if (!fmt) return NULL;

	CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
	OSType pix = CMFormatDescriptionGetMediaSubType(fmt);

	CGImageRef cg = sciCGImageFromPixelBuffer(src);
	if (!cg) return NULL;

	CVPixelBufferRef pb = sciRenderCGImageToPixelBuffer(cg, dims.width, dims.height, pix);
	CGImageRelease(cg);
	if (!pb) return NULL;

	CMVideoFormatDescriptionRef newFmt = NULL;
	if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &newFmt) != noErr || !newFmt) {
		CVPixelBufferRelease(pb);
		return NULL;
	}

	CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid };
	CMSampleBufferGetSampleTimingInfo(tmpl, 0, &timing);

	CMSampleBufferRef out = NULL;
	CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true, NULL, NULL, newFmt, &timing, &out);
	CFRelease(newFmt);
	CVPixelBufferRelease(pb);

	return out;
}

// Build a fresh reader for the picked video (readers can't seek/restart).
static BOOL sciBuildVideoReader(void) {
	sciTeardownReader();

	AVURLAsset *asset = sciGalleryState().videoAsset;
	AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	if (!track) return NO;

	NSError *err = nil;
	AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if (!reader || err) return NO;

	NSDictionary *settings = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
	AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
	out.alwaysCopiesSampleData = NO;
	if (![reader canAddOutput:out]) return NO;
	[reader addOutput:out];

	if (![reader startReading]) return NO;

	sVideoReader = reader;
	sVideoOut = out;
	return YES;
}

// Decode the first frame once, for the frozen pre-record preview.
static void sciPrepareVideoPoster(void) {
	if (sVideoPosterPB) { CVPixelBufferRelease(sVideoPosterPB); sVideoPosterPB = NULL; }
	if (!sciBuildVideoReader()) return;

	CMSampleBufferRef sb = [sVideoOut copyNextSampleBuffer];
	if (sb) {
		CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
		if (pb) sVideoPosterPB = (CVPixelBufferRef)CVPixelBufferRetain(pb);
		CFRelease(sb);
	}
	sciTeardownReader();
}

// At clip end, fire IG's own release handler so recording stops natively
// instead of padding frozen frames until the user lifts their finger.
static void sciForceStopRecording(void) {
	if (sVideoForcedStop || !sciHasPendingVideo()) return;
	id view = sQuickSnapControlView;
	if (!view) return;
	sVideoForcedStop = YES;

	dispatch_async(dispatch_get_main_queue(), ^{
		SEL sel = @selector(captureButtonDidReleaseAfterExpandingFinished);
		if (![view respondsToSelector:sel]) return;
		sVideoAwaitingRelease = YES;
		sVideoSyntheticRelease = YES;
		((void (*)(id, SEL))objc_msgSend)(view, sel);
		sVideoSyntheticRelease = NO;
	});
}

extern "C" BOOL SCIInstantsShouldSwallowCaptureRelease(void) {
	return sVideoAwaitingRelease;
}

// Advance sVideoCurPB to the frame at `elapsed`; freezes the last frame at EOF.
static void sciAdvanceVideoTo(CMTime elapsed) {
	if (!sVideoOut) return;

	while (1) {
		if (sVideoCurPB && CMTIME_IS_VALID(sVideoCurPTS) && CMTimeCompare(sVideoCurPTS, elapsed) > 0) return;

		CMSampleBufferRef sb = [sVideoOut copyNextSampleBuffer];
		if (!sb) {
			[sVideoReader cancelReading];
			sVideoReader = nil;
			sVideoOut = nil;
			if (sVideoRecording) sciForceStopRecording();
			return;
		}

		CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
		CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
		if (pb) {
			if (sVideoCurPB) CVPixelBufferRelease(sVideoCurPB);
			sVideoCurPB = (CVPixelBufferRef)CVPixelBufferRetain(pb);
			sVideoCurPTS = pts;
		}
		CFRelease(sb);

		if (!sVideoCurPB) return;
		if (CMTIME_IS_VALID(pts) && CMTimeCompare(pts, elapsed) >= 0) return;
	}
}

// Returns the source frame to draw this camera tick (caller does not own it).
static CVPixelBufferRef sciCurrentVideoFrame(CMSampleBufferRef tmpl) {
	if (sVideoArmReset) {
		sVideoArmReset = NO;
		sVideoRecording = YES;
		sVideoStartCaptured = NO;
		sVideoForcedStop = NO;
		sciBuildVideoReader();
	}

	if (sVideoRecording) {
		if (sVideoOut) {
			CMTime camPTS = CMSampleBufferGetPresentationTimeStamp(tmpl);
			if (!sVideoStartCaptured) {
				sVideoStartPTS = camPTS;
				sVideoStartCaptured = YES;
			}
			CMTime elapsed = CMTimeSubtract(camPTS, sVideoStartPTS);
			sciAdvanceVideoTo(elapsed);
		}
		if (sVideoCurPB) return sVideoCurPB;
	}

	return sVideoPosterPB;
}

static void sciBeginVideoFromURL(NSURL *srcURL) {
	if (!srcURL) return;

	sciClearPendingImage();

	NSString *ext = srcURL.pathExtension.length ? srcURL.pathExtension.lowercaseString : @"mp4";
	NSURL *tmp = [SCITempFiles claimWithExt:ext ttl:900 tag:@"instants-upload"];
	[NSFileManager.defaultManager removeItemAtURL:tmp error:nil];

	NSURL *assetURL = tmp;
	NSError *err = nil;
	if (![NSFileManager.defaultManager copyItemAtURL:srcURL toURL:tmp error:&err]) {
		[SCITempFiles releaseURL:tmp];
		assetURL = srcURL;
	}

	SCIInstantsGalleryState *state = sciGalleryState();
	state.videoAsset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
	sciPrepareVideoPoster();
	state.videoActive = YES;
	sInstantsInjectActive = YES;
}

static void sciArmVideoRecord(void) {
	if (!sciHasPendingVideo()) return;
	sVideoArmReset = YES;
}

static void sciEndVideoRecord(void) {
	sVideoRecording = NO;
	sVideoArmReset = NO;
	sVideoForcedStop = NO;
}

#pragma mark - AVCapture wrapper

@interface SCIVideoBufferInjector : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id realDelegate;
@end

@implementation SCIVideoBufferInjector

- (BOOL)respondsToSelector:(SEL)sel {
	return [super respondsToSelector:sel] || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
	return self.realDelegate;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	id real = self.realDelegate;
	if (!real) return;

	if (!sInstantsInjectActive) {
		[(id<AVCaptureVideoDataOutputSampleBufferDelegate>)real captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
		return;
	}

	if (sciHasPendingVideo()) {
		CVPixelBufferRef src = sciCurrentVideoFrame(sampleBuffer);
		CMSampleBufferRef fake = src ? sciSampleBufferFromPixelBufferSource(src, sampleBuffer) : NULL;
		if (fake) {
			[(id<AVCaptureVideoDataOutputSampleBufferDelegate>)real captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
			CFRelease(fake);
			return;
		}
	} else {
		UIImage *image = sciGalleryState().image;
		if (sciHasPendingImage()) {
			CMSampleBufferRef fake = sciSampleBufferFromImage(image, sampleBuffer);
			if (fake) {
				[(id<AVCaptureVideoDataOutputSampleBufferDelegate>)real captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
				CFRelease(fake);
				return;
			}
		}
	}

	[(id<AVCaptureVideoDataOutputSampleBufferDelegate>)real captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}

@end

#pragma mark - Crop controller

@interface SCIInstantsCropController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, copy) void (^onConfirm)(UIImage *image);
@end

@implementation SCIInstantsCropController {
	UIScrollView *_scroll;
	UIImageView *_imageView;
	UIView *_overlay;
	CAShapeLayer *_dimLayer;
	CAShapeLayer *_borderLayer;
	UIButton *_cancelButton;
	UIButton *_useButton;
	CGFloat _cropSide;
	BOOL _configured;
}

- (void)viewDidLoad {
	[super viewDidLoad];

	self.view.backgroundColor = UIColor.blackColor;
	self.modalPresentationStyle = UIModalPresentationFullScreen;

	_scroll = [UIScrollView new];
	_scroll.delegate = self;
	_scroll.bouncesZoom = YES;
	_scroll.clipsToBounds = YES;
	_scroll.backgroundColor = UIColor.blackColor;
	_scroll.showsHorizontalScrollIndicator = NO;
	_scroll.showsVerticalScrollIndicator = NO;
	[self.view addSubview:_scroll];

	_imageView = [[UIImageView alloc] initWithImage:self.sourceImage];
	_imageView.contentMode = UIViewContentModeScaleToFill;
	[_scroll addSubview:_imageView];

	_overlay = [UIView new];
	_overlay.userInteractionEnabled = NO;
	[self.view addSubview:_overlay];

	_dimLayer = [CAShapeLayer layer];
	_dimLayer.fillColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
	_dimLayer.fillRule = kCAFillRuleEvenOdd;
	[_overlay.layer addSublayer:_dimLayer];

	_borderLayer = [CAShapeLayer layer];
	_borderLayer.fillColor = UIColor.clearColor.CGColor;
	_borderLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
	_borderLayer.lineWidth = 1.0;
	[_overlay.layer addSublayer:_borderLayer];

	_cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_cancelButton setTitle:SCILocalized(@"Cancel") forState:UIControlStateNormal];
	_cancelButton.tintColor = UIColor.whiteColor;
	_cancelButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
	[_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:_cancelButton];

	_useButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[_useButton setTitle:SCILocalized(@"Use") forState:UIControlStateNormal];
	_useButton.tintColor = UIColor.whiteColor;
	_useButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	[_useButton addTarget:self action:@selector(useTapped) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:_useButton];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];

	CGSize size = self.view.bounds.size;
	if (size.width <= 0 || size.height <= 0 || !self.sourceImage.CGImage) return;

	UIEdgeInsets safe = self.view.safeAreaInsets;
	CGFloat buttonsH = MAX(_cancelButton.intrinsicContentSize.height, _useButton.intrinsicContentSize.height) + 32.0;
	CGFloat imageH = size.height - safe.top - safe.bottom - buttonsH;

	_scroll.frame = CGRectMake(0, safe.top, size.width, imageH);
	_overlay.frame = _scroll.frame;

	_cropSide = MIN(size.width, imageH) - 56.0;
	CGRect crop = CGRectMake((size.width - _cropSide) * 0.5, (imageH - _cropSide) * 0.5, _cropSide, _cropSide);

	UIBezierPath *hole = SCIInstantsSquirclePathInRect(crop);
	UIBezierPath *dim = [UIBezierPath bezierPathWithRect:_overlay.bounds];
	[dim appendPath:hole];
	dim.usesEvenOddFillRule = YES;

	_dimLayer.frame = _overlay.bounds;
	_dimLayer.path = dim.CGPath;
	_borderLayer.frame = _overlay.bounds;
	_borderLayer.path = hole.CGPath;

	CGSize cancelSize = _cancelButton.intrinsicContentSize;
	CGSize useSize = _useButton.intrinsicContentSize;
	CGFloat y = size.height - safe.bottom - 16.0;

	_cancelButton.frame = CGRectMake(safe.left + 24.0, y - cancelSize.height, cancelSize.width, cancelSize.height);
	_useButton.frame = CGRectMake(size.width - safe.right - 24.0 - useSize.width, y - useSize.height, useSize.width, useSize.height);

	if (_configured) return;
	_configured = YES;

	CGSize imageSize = self.sourceImage.size;
	_imageView.frame = (CGRect){ CGPointZero, imageSize };
	_scroll.contentSize = imageSize;

	CGFloat minZoom = MAX(_cropSide / imageSize.width, _cropSide / imageSize.height);
	_scroll.minimumZoomScale = minZoom;
	_scroll.maximumZoomScale = MAX(minZoom * 4.0, 1.0);
	_scroll.zoomScale = minZoom;
	_scroll.contentInset = UIEdgeInsetsMake(crop.origin.y, crop.origin.x, crop.origin.y, crop.origin.x);
	_scroll.contentOffset = CGPointMake((imageSize.width * minZoom - size.width) * 0.5, (imageSize.height * minZoom - imageH) * 0.5);
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
	return _imageView;
}

- (void)cancelTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)useTapped {
	UIImage *image = [self croppedImage];
	void (^callback)(UIImage *) = self.onConfirm;

	[self dismissViewControllerAnimated:YES completion:^{
		if (callback && image) callback(image);
	}];
}

- (UIImage *)croppedImage {
	UIImage *src = self.sourceImage;
	if (!src.CGImage || _cropSide <= 0) return src;

	CGFloat zoom = _scroll.zoomScale;
	CGFloat x = ((_scroll.bounds.size.width - _cropSide) * 0.5 + _scroll.contentOffset.x) / zoom;
	CGFloat y = ((_scroll.bounds.size.height - _cropSide) * 0.5 + _scroll.contentOffset.y) / zoom;
	CGRect rect = CGRectMake(x, y, _cropSide / zoom, _cropSide / zoom);

	UIGraphicsBeginImageContextWithOptions(src.size, NO, src.scale);
	[src drawInRect:(CGRect){ CGPointZero, src.size }];
	UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext() ?: src;
	UIGraphicsEndImageContext();

	CGFloat scale = normalized.scale;
	CGRect pixelRect = CGRectMake(rect.origin.x * scale, rect.origin.y * scale, rect.size.width * scale, rect.size.height * scale);
	CGImageRef cg = CGImageCreateWithImageInRect(normalized.CGImage, pixelRect);
	if (!cg) return normalized;

	UIImage *out = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
	CGImageRelease(cg);
	return out;
}

@end

#pragma mark - Picker proxy

@interface SCIInstantsGalleryPickerProxy : NSObject <PHPickerViewControllerDelegate>
- (void)presentCropForImage:(UIImage *)image;
- (void)presentTrimmerForURL:(NSURL *)url;
@end

@implementation SCIInstantsGalleryPickerProxy

+ (instancetype)shared {
	static SCIInstantsGalleryPickerProxy *proxy;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ proxy = [SCIInstantsGalleryPickerProxy new]; });
	return proxy;
}

// Decode via ImageIO for a guaranteed CGImage-backed UIImage — PHPicker's
// loadObjectOfClass: can return a CIImage-backed one (nil .CGImage) for HEIC/HDR.
static UIImage *sciDecodeImageURL(NSURL *url) {
	if (!url) return nil;
	CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
	if (!src) return nil;

	NSDictionary *opts = @{
		(__bridge NSString *)kCGImageSourceShouldCache: @YES,
		(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
		(__bridge NSString *)kCGImageSourceShouldAllowFloat: @NO
	};
	CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, (__bridge CFDictionaryRef)opts);

	UIImageOrientation orient = UIImageOrientationUp;
	CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
	if (props) {
		CFNumberRef o = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyOrientation);
		int v = 1;
		if (o) CFNumberGetValue(o, kCFNumberIntType, &v);
		switch (v) {
			case 1: orient = UIImageOrientationUp; break;
			case 2: orient = UIImageOrientationUpMirrored; break;
			case 3: orient = UIImageOrientationDown; break;
			case 4: orient = UIImageOrientationDownMirrored; break;
			case 5: orient = UIImageOrientationLeftMirrored; break;
			case 6: orient = UIImageOrientationRight; break;
			case 7: orient = UIImageOrientationRightMirrored; break;
			case 8: orient = UIImageOrientationLeft; break;
		}
		CFRelease(props);
	}

	CFRelease(src);
	if (!cg) return nil;

	UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:orient];
	CGImageRelease(cg);
	return img;
}

- (void)loadVideoFromProvider:(NSItemProvider *)prov {
	NSString *videoType = nil;
	for (NSString *t in prov.registeredTypeIdentifiers) {
		if ([t isEqualToString:@"public.mpeg-4"] || [t isEqualToString:@"com.apple.quicktime-movie"] || [t isEqualToString:@"public.movie"] || [t isEqualToString:@"public.video"]) {
			videoType = t;
			break;
		}
	}
	if (!videoType) videoType = prov.registeredTypeIdentifiers.firstObject;

	[prov loadFileRepresentationForTypeIdentifier:videoType completionHandler:^(NSURL *fileURL, __unused NSError *err) {
		if (!fileURL) return;
		NSString *ext = fileURL.pathExtension.length ? fileURL.pathExtension.lowercaseString : @"mp4";
		NSURL *tmp = [SCITempFiles claimWithExt:ext ttl:900 tag:@"instants-upload-src"];
		[NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
		NSURL *use = fileURL;
		if ([NSFileManager.defaultManager copyItemAtURL:fileURL toURL:tmp error:nil]) use = tmp;
		dispatch_async(dispatch_get_main_queue(), ^{ [SCIInstantsGalleryPickerProxy.shared presentTrimmerForURL:use]; });
	}];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	[picker dismissViewControllerAnimated:YES completion:^{
		NSItemProvider *prov = results.firstObject.itemProvider;
		if (!prov) return;

		if ([prov hasItemConformingToTypeIdentifier:@"public.movie"] && ![prov hasItemConformingToTypeIdentifier:@"public.image"]) {
			[self loadVideoFromProvider:prov];
			return;
		}

		NSString *type = nil;
		for (NSString *t in prov.registeredTypeIdentifiers) {
			if ([t isEqualToString:@"public.heic"] || [t isEqualToString:@"public.jpeg"] || [t isEqualToString:@"public.png"] || [t isEqualToString:@"public.image"]) {
				type = t;
				break;
			}
		}
		if (!type) type = prov.registeredTypeIdentifiers.firstObject;

		void (^fallback)(void) = ^{
			if (![prov canLoadObjectOfClass:UIImage.class]) return;
			[prov loadObjectOfClass:UIImage.class completionHandler:^(__kindof id<NSItemProviderReading> obj, NSError *err) {
				UIImage *raw = [obj isKindOfClass:UIImage.class] ? (UIImage *)obj : nil;
				if (!raw || err) return;

				UIImage *image = raw;
				if (!image.CGImage) {
					UIGraphicsBeginImageContextWithOptions(raw.size, NO, raw.scale);
					[raw drawInRect:(CGRect){ CGPointZero, raw.size }];
					image = UIGraphicsGetImageFromCurrentImageContext() ?: raw;
					UIGraphicsEndImageContext();
				}
				dispatch_async(dispatch_get_main_queue(), ^{ [self presentCropForImage:image]; });
			}];
		};

		if (!type) { fallback(); return; }

		// Temp URL is valid only inside this completion; decode before it's reaped.
		[prov loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *fileURL, NSError *err) {
			if (err || !fileURL) {
				dispatch_async(dispatch_get_main_queue(), fallback);
				return;
			}
			UIImage *image = sciDecodeImageURL(fileURL);
			if (!image || !image.CGImage) {
				dispatch_async(dispatch_get_main_queue(), fallback);
				return;
			}
			dispatch_async(dispatch_get_main_queue(), ^{ [self presentCropForImage:image]; });
		}];
	}];
}

- (void)presentTrimmerForURL:(NSURL *)url {
	[SCIVideoEditor presentForVideoURL:url from:sciTopPresenter() maxDuration:7.0 onDone:^(NSURL *edited) {
		sciBeginVideoFromURL(edited);
	}];
}

- (void)presentCropForImage:(UIImage *)image {
	if (!image.CGImage) return;

	SCIInstantsCropController *crop = [SCIInstantsCropController new];
	crop.sourceImage = image;
	crop.onConfirm = ^(UIImage *cropped) {
		SCIInstantsGalleryState *state = sciGalleryState();
		state.image = cropped;
		state.active = YES;
		sInstantsInjectActive = YES;
		sciClearFrameCache();

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (sciGalleryState().image == cropped) sciClearPendingImage();
		});
	};

	[sciTopPresenter() presentViewController:crop animated:YES completion:nil];
}

@end

static void sciPresentSystemPicker(void) {
	PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
	config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
	config.selectionLimit = 1;
	config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

	PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
	picker.delegate = SCIInstantsGalleryPickerProxy.shared;
	picker.modalPresentationStyle = UIModalPresentationFullScreen;

	[sciTopPresenter() presentViewController:picker animated:YES completion:nil];
}

static void sciPresentGallerySourceSheet(UIView *sender) {
	if (![SCIUtils getBoolPref:@"sci_gallery_enabled"]) {
		sciPresentSystemPicker();
		return;
	}

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SCILocalized(@"Pick from") message:nil preferredStyle:UIAlertControllerStyleActionSheet];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"In-app Gallery") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
		[SCIGalleryViewController presentPickerWithMediaTypes:@[@(SCIGalleryMediaTypeImage), @(SCIGalleryMediaTypeVideo)] title:SCILocalized(@"Send from gallery") fromVC:sciTopPresenter() completion:^(NSURL *pickedURL, SCIGalleryFile *pickedFile) {
			if (!pickedURL.path.length) return;
			if (pickedFile.mediaType == SCIGalleryMediaTypeVideo) {
				[SCIInstantsGalleryPickerProxy.shared presentTrimmerForURL:pickedURL];
				return;
			}
			UIImage *image = [UIImage imageWithContentsOfFile:pickedURL.path];
			if (image) [SCIInstantsGalleryPickerProxy.shared presentCropForImage:image];
		}];
	}]];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Photos library") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
		sciPresentSystemPicker();
	}]];

	[sheet addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

	sheet.popoverPresentationController.sourceView = sender;
	sheet.popoverPresentationController.sourceRect = sender.bounds;

	[sciTopPresenter() presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Hooks

// Clone a native bar button and pin it under the leftmost one via Auto Layout.
static void sciInjectInstantsGalleryButton(UIView *view, NSInteger attempt) {
	if (!view.window || objc_getAssociatedObject(view, kSCIInstantsGalleryButtonKey)) return;

	UIView *bar = nil;
	for (UIView *sub in view.subviews) {
		if ([NSStringFromClass(sub.class) containsString:@"CameraControlView"]) { bar = sub; break; }
	}

	UIButton *tmplBtn = nil;
	for (UIView *sub in bar.subviews) {
		if ([sub isKindOfClass:UIButton.class] && fabs(sub.bounds.size.width - sub.bounds.size.height) < 1.0 &&
			sub.bounds.size.width > 40.0 && sub.bounds.size.width < 72.0) {
			if (!tmplBtn || sub.frame.origin.x < tmplBtn.frame.origin.x) tmplBtn = (UIButton *)sub;
		}
	}

	if (!bar || !tmplBtn) {
		if (attempt < 25) {
			__weak UIView *weakView = view;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				if (weakView) sciInjectInstantsGalleryButton(weakView, attempt + 1);
			});
		}
		return;
	}

	CGFloat side = tmplBtn.bounds.size.width;
	CGRect tf = tmplBtn.frame;

	SCIChromeButton *button = [[SCIChromeButton alloc] initWithSymbol:@"photo.on.rectangle.angled" pointSize:side * 0.34 diameter:side];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	button.iconTint = tmplBtn.tintColor ?: UIColor.whiteColor;
	button.bubbleColor = tmplBtn.backgroundColor ?: UIColor.clearColor;

	[button addTarget:view action:@selector(sci_instantsGalleryTapped:) forControlEvents:UIControlEventTouchUpInside];
	[view addSubview:button];
	objc_setAssociatedObject(view, kSCIInstantsGalleryButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	[NSLayoutConstraint activateConstraints:@[
		[button.widthAnchor    constraintEqualToConstant:side],
		[button.heightAnchor   constraintEqualToConstant:side],
		[button.centerXAnchor  constraintEqualToAnchor:bar.leadingAnchor constant:CGRectGetMidX(tf)],
		[button.topAnchor      constraintEqualToAnchor:bar.topAnchor constant:CGRectGetMaxY(tf) + 8.0],
	]];
}

%group SCIInstantsGalleryGroup

%hook _TtC29IGQuickSnapCreationController23IGQuickSnapCreationView

- (void)didMoveToWindow {
	%orig;
	if (((UIView *)self).window) sciInjectInstantsGalleryButton((UIView *)self, 0);
}

%new
- (void)sci_instantsGalleryTapped:(UIButton *)sender {
	sciPresentGallerySourceSheet(sender);
}

- (void)willMoveToWindow:(UIWindow *)window {
	if (!window) sciClearPendingImage();
	%orig;
}

- (void)dealloc {
	sciClearPendingImage();
	%orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
	if (delegate && ![delegate isKindOfClass:SCIVideoBufferInjector.class]) {
		SCIVideoBufferInjector *wrap = [SCIVideoBufferInjector new];
		wrap.realDelegate = delegate;
		objc_setAssociatedObject(self, kSCIVideoInjectorKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		%orig(wrap, queue);
		return;
	}

	%orig;
}

%end

// Hold onto the active capture-control view so we can fire its release handler
// at clip end (see sciForceStopRecording).
%hook _TtC34IGQuickSnapCameraControlController28IGQuickSnapCameraControlView

- (void)captureButtonDidTouchDown {
	sVideoAwaitingRelease = NO;
	if (sciHasPendingVideo()) sQuickSnapControlView = self;
	%orig;
}

- (void)captureButtonDidBeginExpanding {
	if (sciHasPendingVideo()) sQuickSnapControlView = self;
	%orig;
}

- (void)captureButtonDidReleaseAfterExpandingFinished {
	if (!sVideoSyntheticRelease && sVideoAwaitingRelease) return;
	%orig;
}

- (void)captureButtonDidConfirm {
	if (sVideoAwaitingRelease) return;
	%orig;
}

%end

%hook AVAssetWriter

- (void)startSessionAtSourceTime:(CMTime)time {
	sciArmVideoRecord();
	%orig;
}

- (void)finishWritingWithCompletionHandler:(void (^)(void))handler {
	sciEndVideoRecord();
	%orig;
}

%end

%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)url recordingDelegate:(id)delegate {
	sciArmVideoRecord();
	%orig;
}

- (void)stopRecording {
	sciEndVideoRecord();
	%orig;
}

%end

%end

%ctor {
	if ([SCIUtils getBoolPref:@"instants_send_from_gallery"]) {
		%init(SCIInstantsGalleryGroup);
	}
}