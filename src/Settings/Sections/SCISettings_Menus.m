#import "SCISettingsSections.h"

// Wordmark thumbnails ship in the tweak bundle (BundleAssets). Template-rendered
// so they tint with the menu. Returns nil if the asset is missing → caller falls
// back to an SF Symbol.
// Canvas fixo 82x22pt -- convencao documentada (01-liquidglass-uikit-ios26.md
// secao 5, RGWordmarkCanvasImage). Todo wordmark PRECISA sair com o MESMO
// UIImage.size final (checklist secao 12). Passos: (1) alpha-trim -- cada PNG
// de origem tem padding transparente diferente, e ISSO -- nao o glyph em si --
// causava "1a grande, ultima pequena"; (2) escala por ALTURA FIXA, nao pelo
// MIN() ingenuo das duas proporcoes (que ainda teria o mesmo bug se os
// glyphs, ja trimados, tiverem proporcoes largura:altura diferentes); (3)
// desenha centralizado no canvas fixo.
static const CGFloat kSCIWordmarkCanvasW = 82.0;
static const CGFloat kSCIWordmarkCanvasH = 22.0;

static UIImage *SCIWordmarkMenuTrim(UIImage *img) {
    if (!img) return img;
    CGImageRef cg = img.CGImage;
    if (!cg) return img;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return img;
    CGColorSpaceRef csp = CGColorSpaceCreateDeviceRGB();
    uint8_t *buf = (uint8_t *)calloc(w * h * 4, 1);
    UIImage *trimmed = img;
    if (buf && csp) {
        CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, csp, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
            long minx = w, miny = h, maxx = -1, maxy = -1;
            for (size_t y = 0; y < h; y++) {
                for (size_t x = 0; x < w; x++) {
                    if (buf[(y * w + x) * 4 + 3] > 12) {
                        if ((long)x < minx) minx = x; if ((long)x > maxx) maxx = x;
                        if ((long)y < miny) miny = y; if ((long)y > maxy) maxy = y;
                    }
                }
            }
            if (maxx >= minx && maxy >= miny) {
                CGImageRef cropped = CGImageCreateWithImageInRect(cg, CGRectMake(minx, miny, maxx - minx + 1, maxy - miny + 1));
                if (cropped) { trimmed = [UIImage imageWithCGImage:cropped scale:img.scale orientation:img.imageOrientation]; CGImageRelease(cropped); }
            }
            CGContextRelease(ctx);
        }
    }
    if (buf) free(buf);
    if (csp) CGColorSpaceRelease(csp);
    return trimmed;
}

static UIImage *SCIWordmarkMenuCanvasImage(UIImage *source) {
    if (!source) return nil;
    UIImage *trimmed = SCIWordmarkMenuTrim(source);
    CGSize canvas = CGSizeMake(kSCIWordmarkCanvasW, kSCIWordmarkCanvasH);
    CGSize sz = trimmed.size;
    if (sz.width <= 0 || sz.height <= 0) return [trimmed imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    CGFloat r = canvas.height / sz.height;
    CGFloat rw = canvas.width / sz.width;
    if (rw < r) r = rw;
    if (r <= 0) r = 1.0;
    CGSize target = CGSizeMake(floor(sz.width * r), floor(sz.height * r));
    CGRect rect = CGRectMake((canvas.width - target.width) / 2.0,
                             (canvas.height - target.height) / 2.0,
                             target.width, target.height);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [trimmed drawInRect:rect];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *SCIWordmarkMenuImage(NSString *name) {
    NSBundle *bundle = SCILocalizationBundle();
    UIImage *img = bundle ? [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil] : nil;
    return img ? SCIWordmarkMenuCanvasImage(img) : nil;
}

@implementation SCITweakSettings (Section_Menus)

// MARK: - Menus

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

// Builds the default-tap-action picker menu for a given action button context.
// Adding a new tap action = one entry here. Order: actions first, downloads last.
+ (UIMenu *)defaultTapMenuForKey:(NSString *)key context:(NSString *)ctx {
	// { value, title, contexts (csv of feed,reels,stories,dm_visual,all) }
	NSArray *entries = @[
		@[@"menu",		   SCILocalized(@"Open menu"),		  @"all"],
		@[@"expand",		 SCILocalized(@"Expand"),			 @"all"],
		@[@"repost",		 SCILocalized(@"Repost"),			 @"feed,reels,stories"],
		@[@"view_mentions",  SCILocalized(@"View mentions"),	  @"stories"],
		@[@"copy_link",	  SCILocalized(@"Copy download URL"),  @"feed,reels,stories"],
		@[@"download_share", SCILocalized(@"Download and share"), @"all"],
		@[@"download_photos",SCILocalized(@"Download to Photos"), @"all"],
	];
	NSMutableArray *children = [NSMutableArray array];
	for (NSArray *e in entries) {
		NSString *contexts = e[2];
		if (![contexts isEqualToString:@"all"] && ![contexts containsString:ctx]) continue;
		[children addObject:[UICommand commandWithTitle:e[1] image:nil
												 action:@selector(menuChanged:)
										   propertyList:@{@"defaultsKey": key, @"value": e[0]}]];
	}
	return [UIMenu menuWithChildren:children];
}

+ (NSDictionary *)menus {
	return @{
		@"gallery_save_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Photos only")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"gallery_save_mode", @"value": @"off" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Photos + Gallery")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"gallery_save_mode", @"value": @"mirror" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Gallery only")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"gallery_save_mode", @"value": @"gallery_only" }
			]
		]],

		@"instants_auto_save": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Off")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"instants_auto_save", @"value": @"off" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Save to Photos")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"instants_auto_save", @"value": @"photos" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Save to Gallery")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"instants_auto_save", @"value": @"gallery" }
			]
		]],

		@"theme_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Off")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_mode", @"value": @"off" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Light")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_mode", @"value": @"light" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Dark")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_mode", @"value": @"dark" }
			],
			[UICommand commandWithTitle:SCILocalized(@"OLED")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_mode", @"value": @"oled" }
			]
		]],

		@"theme_keyboard": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Off")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_keyboard", @"value": @"off" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Dark")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_keyboard", @"value": @"dark" }
			],
			[UICommand commandWithTitle:SCILocalized(@"OLED")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"theme_keyboard", @"value": @"oled" }
			]
		]],

		@"chat_blocking_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Block all")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"chat_blocking_mode", @"value": @"block_all" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Block selected")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"chat_blocking_mode", @"value": @"block_selected" }
			]
		]],

		@"follow_indicator": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Off")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"follow_indicator", @"value": @"off" }],
			[UICommand commandWithTitle:SCILocalized(@"On")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"follow_indicator", @"value": @"on" }],
			[UICommand commandWithTitle:SCILocalized(@"Colored")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"follow_indicator", @"value": @"colored" }]
		]],

		@"story_blocking_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Block all")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"story_blocking_mode", @"value": @"block_all" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Block selected")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{ @"defaultsKey": @"story_blocking_mode", @"value": @"block_selected" }
			]
		]],

		@"sticker_interact_stories_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Disabled")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_stories_mode", @"value": @"off" }],
			[UICommand commandWithTitle:SCILocalized(@"All")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_stories_mode", @"value": @"all" }],
			[UICommand commandWithTitle:SCILocalized(@"Reaction stickers only")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_stories_mode", @"value": @"reactions" }]
		]],

		@"sticker_interact_highlights_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Disabled")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_highlights_mode", @"value": @"off" }],
			[UICommand commandWithTitle:SCILocalized(@"All")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_highlights_mode", @"value": @"all" }],
			[UICommand commandWithTitle:SCILocalized(@"Reaction stickers only")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"sticker_interact_highlights_mode", @"value": @"reactions" }]
		]],

		@"story_seen_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Button")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"story_seen_mode",
								@"value": @"button"
							}
			],
			[UICommand commandWithTitle:SCILocalized(@"Toggle")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"story_seen_mode",
								@"value": @"toggle"
							}
			]
		]],

		@"seen_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Button")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"seen_mode",
								@"value": @"button"
							}
			],
			[UICommand commandWithTitle:SCILocalized(@"Toggle")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"seen_mode",
								@"value": @"toggle"
							}
			]
		]],

		@"dw_save_action": ({
			NSMutableArray *_dwItems = [NSMutableArray array];
			[_dwItems addObject:[UICommand commandWithTitle:SCILocalized(@"Share sheet")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"dw_save_action",
								@"value": @"share"
							}
			]];
			[_dwItems addObject:[UICommand commandWithTitle:SCILocalized(@"Save to Photos")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"dw_save_action",
								@"value": @"photos"
							}
			]];
			if ([SCIUtils getBoolPref:@"sci_gallery_enabled"]) {
				[_dwItems addObject:[UICommand commandWithTitle:SCILocalized(@"Save to Gallery")
										image:nil
										action:@selector(menuChanged:)
								propertyList:@{
									@"defaultsKey": @"dw_save_action",
									@"value": @"gallery"
								}
				]];
			}
			[UIMenu menuWithChildren:_dwItems];
		}),

		@"feed_action_default":	[self defaultTapMenuForKey:@"feed_action_default"	context:@"feed"],
		@"reels_action_default":   [self defaultTapMenuForKey:@"reels_action_default"   context:@"reels"],
		@"stories_action_default": [self defaultTapMenuForKey:@"stories_action_default" context:@"stories"],
		@"dm_visual_action_default": [self defaultTapMenuForKey:@"dm_visual_action_default" context:@"dm_visual"],
		@"dm_log_date_format": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Relative (1m / 3h / 3d ago)") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"dm_log_date_format", @"value": @"relative"}],
			[UICommand commandWithTitle:SCILocalized(@"Absolute date + time") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"dm_log_date_format", @"value": @"absolute"}],
		]],
		@"main_feed_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"main_feed_mode", @"value": @"default", @"requiresRestart": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Following") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"main_feed_mode", @"value": @"following", @"requiresRestart": @YES}],
		]],
		@"ig_wordmark_variant": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default")
								  image:(SCIWordmarkMenuImage(@"instagram-wordmark-default") ?: [UIImage systemImageNamed:@"textformat"])
								 action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"sci_ig_wordmark_variant", @"value": @"off", @"wordmarkImageName": @"instagram-wordmark-default", @"noTitle": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Wordmark 1")
								  image:(SCIWordmarkMenuImage(@"instagram-wordmark-1a-alt") ?: [UIImage systemImageNamed:@"1.circle"])
								 action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"sci_ig_wordmark_variant", @"value": @"1a_alt", @"wordmarkImageName": @"instagram-wordmark-1a-alt", @"noTitle": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Wordmark 2")
								  image:(SCIWordmarkMenuImage(@"instagram-wordmark-1a") ?: [UIImage systemImageNamed:@"2.circle"])
								 action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"sci_ig_wordmark_variant", @"value": @"1a", @"wordmarkImageName": @"instagram-wordmark-1a", @"noTitle": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Wordmark 3")
								  image:(SCIWordmarkMenuImage(@"instagram-wordmark-1b-alt") ?: [UIImage systemImageNamed:@"3.circle"])
								 action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"sci_ig_wordmark_variant", @"value": @"1b_alt", @"wordmarkImageName": @"instagram-wordmark-1b-alt", @"noTitle": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Wordmark 4")
								  image:(SCIWordmarkMenuImage(@"instagram-wordmark-1b") ?: [UIImage systemImageNamed:@"4.circle"])
								 action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"sci_ig_wordmark_variant", @"value": @"1b", @"wordmarkImageName": @"instagram-wordmark-1b", @"noTitle": @YES}],
		]],

		@"liquid_glass_tabbar_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"liquid_glass_tabbar_mode", @"value": @"default", @"requiresRestart": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Fixed") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"liquid_glass_tabbar_mode", @"value": @"fixed", @"requiresRestart": @YES}],
			[UICommand commandWithTitle:SCILocalized(@"Hide on scroll") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"liquid_glass_tabbar_mode", @"value": @"hide", @"requiresRestart": @YES}],
		]],

		@"default_video_quality": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Always ask") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_video_quality", @"value": @"always_ask"}],
			[UICommand commandWithTitle:SCILocalized(@"High") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_video_quality", @"value": @"high"}],
			[UICommand commandWithTitle:SCILocalized(@"Medium") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_video_quality", @"value": @"medium"}],
			[UICommand commandWithTitle:SCILocalized(@"Low") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_video_quality", @"value": @"low"}],
		]],
		@"default_photo_quality": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"High") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_photo_quality", @"value": @"high"}],
			[UICommand commandWithTitle:SCILocalized(@"Standard") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"default_photo_quality", @"value": @"standard"}],
		]],
		@"ffmpeg_encoding_speed": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Fast") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"ffmpeg_encoding_speed", @"value": @"ultrafast"}],
			[UICommand commandWithTitle:SCILocalized(@"Balanced") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"ffmpeg_encoding_speed", @"value": @"veryfast"}],
			[UICommand commandWithTitle:SCILocalized(@"Quality") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"ffmpeg_encoding_speed", @"value": @"fast"}],
			[UICommand commandWithTitle:SCILocalized(@"Max") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"ffmpeg_encoding_speed", @"value": @"max"}],
		]],

		@"adv_video_codec": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Hardware (VideoToolbox)") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"adv_video_codec", @"value": @"h264_videotoolbox"}],
			[UICommand commandWithTitle:SCILocalized(@"Software (libx264)") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"adv_video_codec", @"value": @"libx264"}],
		]],
		@"adv_preset": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:@"ultrafast" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"ultrafast"}],
			[UICommand commandWithTitle:@"superfast" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"superfast"}],
			[UICommand commandWithTitle:@"veryfast"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"veryfast"}],
			[UICommand commandWithTitle:@"faster"    image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"faster"}],
			[UICommand commandWithTitle:@"fast"      image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"fast"}],
			[UICommand commandWithTitle:@"medium"    image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"medium"}],
			[UICommand commandWithTitle:@"slow"      image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"slow"}],
			[UICommand commandWithTitle:@"slower"    image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"slower"}],
			[UICommand commandWithTitle:@"veryslow"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"veryslow"}],
			[UICommand commandWithTitle:@"placebo"   image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_preset", @"value": @"placebo"}],
		]],
		@"adv_h264_profile": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:@"baseline" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"baseline"}],
			[UICommand commandWithTitle:@"main"     image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"main"}],
			[UICommand commandWithTitle:@"high"     image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"high"}],
			[UICommand commandWithTitle:@"high10"   image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"high10"}],
			[UICommand commandWithTitle:@"high422"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"high422"}],
			[UICommand commandWithTitle:@"high444"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_profile", @"value": @"high444"}],
		]],
		@"adv_h264_level": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Auto") image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"auto"}],
			[UICommand commandWithTitle:@"3.0" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"3.0"}],
			[UICommand commandWithTitle:@"3.1" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"3.1"}],
			[UICommand commandWithTitle:@"3.2" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"3.2"}],
			[UICommand commandWithTitle:@"4.0" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"4.0"}],
			[UICommand commandWithTitle:@"4.1" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"4.1"}],
			[UICommand commandWithTitle:@"4.2" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"4.2"}],
			[UICommand commandWithTitle:@"5.0" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"5.0"}],
			[UICommand commandWithTitle:@"5.1" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"5.1"}],
			[UICommand commandWithTitle:@"5.2" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_h264_level", @"value": @"5.2"}],
		]],
		@"adv_max_resolution": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Original") image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"original"}],
			[UICommand commandWithTitle:@"2160p (4K)" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"2160"}],
			[UICommand commandWithTitle:@"1440p"      image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"1440"}],
			[UICommand commandWithTitle:@"1080p"      image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"1080"}],
			[UICommand commandWithTitle:@"720p"       image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"720"}],
			[UICommand commandWithTitle:@"480p"       image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_max_resolution", @"value": @"480"}],
		]],
		@"adv_audio_codec": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Copy (passthrough)") image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_codec", @"value": @"copy"}],
			[UICommand commandWithTitle:@"AAC" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_codec", @"value": @"aac"}],
		]],
		@"adv_audio_bitrate": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:@"64k"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"64k"}],
			[UICommand commandWithTitle:@"96k"  image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"96k"}],
			[UICommand commandWithTitle:@"128k" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"128k"}],
			[UICommand commandWithTitle:@"192k" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"192k"}],
			[UICommand commandWithTitle:@"256k" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"256k"}],
			[UICommand commandWithTitle:@"320k" image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_bitrate", @"value": @"320k"}],
		]],
		@"adv_audio_channels": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Original") image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_channels", @"value": @"original"}],
			[UICommand commandWithTitle:SCILocalized(@"Stereo")   image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_channels", @"value": @"stereo"}],
			[UICommand commandWithTitle:SCILocalized(@"Mono")     image:nil action:@selector(menuChanged:) propertyList:@{@"defaultsKey": @"adv_audio_channels", @"value": @"mono"}],
		]],

		@"reels_tap_control": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"reels_tap_control",
								@"value": @"default",
								@"requiresRestart": @YES
							}
			],
			[UIMenu menuWithTitle:@""
							image:nil
						identifier:nil
							options:UIMenuOptionsDisplayInline
							children:@[
								[UICommand commandWithTitle:SCILocalized(@"Pause/Play")
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"reels_tap_control",
													@"value": @"pause",
													@"requiresRestart": @YES
												}
								],
								[UICommand commandWithTitle:SCILocalized(@"Mute/Unmute")
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"reels_tap_control",
													@"value": @"mute",
													@"requiresRestart": @YES
												}
								]
							]
			]
		]],

		@"launch_tab": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"default"}],
			[UICommand commandWithTitle:SCILocalized(@"Feed") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"feed"}],
			[UICommand commandWithTitle:SCILocalized(@"Explore") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"explore"}],
			[UICommand commandWithTitle:SCILocalized(@"Reels") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"reels"}],
			[UICommand commandWithTitle:SCILocalized(@"Inbox") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"inbox"}],
			[UICommand commandWithTitle:SCILocalized(@"Profile") image:nil action:@selector(menuChanged:)
						   propertyList:@{@"defaultsKey": @"launch_tab", @"value": @"profile"}],
		]],
		@"swipe_nav_tabs": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Default")
									image:nil
									action:@selector(menuChanged:)
							propertyList:@{
								@"defaultsKey": @"swipe_nav_tabs",
								@"value": @"default",
								@"requiresRestart": @YES
							}
			],
			[UIMenu menuWithTitle:@""
							image:nil
						identifier:nil
							options:UIMenuOptionsDisplayInline
							children:@[
								[UICommand commandWithTitle:SCILocalized(@"Enabled")
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"swipe_nav_tabs",
													@"value": @"enabled",
													@"requiresRestart": @YES
												}
								],
								[UICommand commandWithTitle:SCILocalized(@"Disabled")
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"swipe_nav_tabs",
													@"value": @"disabled",
													@"requiresRestart": @YES
												}
								]
							]
			]
		]],

		@"test": [UIMenu menuWithChildren:@[
			[UIMenu menuWithTitle:@""
							image:nil
						identifier:nil
							options:UIMenuOptionsDisplayInline
							children:@[
								[UICommand commandWithTitle:@"ABC"
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"test_menu_cell",
													@"value": @"abc"
												}
								],
								[UICommand commandWithTitle:@"123"
														image:nil
														action:@selector(menuChanged:)
												propertyList:@{
													@"defaultsKey": @"test_menu_cell",
													@"value": @"123"
												}
								]
							]
			],
			[UICommand commandWithTitle:SCILocalized(@"Requires restart")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{
							   @"defaultsKey": @"test_menu_cell",
							   @"value": @"requires_restart",
							   @"requiresRestart": @YES
						   }
			],
		]],

		@"cache_auto_clear_mode": [UIMenu menuWithChildren:@[
			[UICommand commandWithTitle:SCILocalized(@"Off")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"cache_auto_clear_mode", @"value": @"off" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Daily")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"cache_auto_clear_mode", @"value": @"daily" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Weekly")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"cache_auto_clear_mode", @"value": @"weekly" }
			],
			[UICommand commandWithTitle:SCILocalized(@"Monthly")
								  image:nil
								 action:@selector(menuChanged:)
						   propertyList:@{ @"defaultsKey": @"cache_auto_clear_mode", @"value": @"monthly" }
			],
		]]
	};
}

#pragma clang diagnostic pop

@end
