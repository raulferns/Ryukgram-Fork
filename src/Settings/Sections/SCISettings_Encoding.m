#import "SCISettingsSections.h"
#import "../../SCIFFmpeg.h"
#import "../../UI/SCIOptionSheet.h"
#import "../../SCIDefaults.h"

@implementation SCITweakSettings (Section_Encoding)

// MARK: - Enhanced downloads section

+ (NSDictionary *)enhancedDownloadsSection {
	BOOL ffmpegAvailable = [SCIFFmpeg isAvailable];
	BOOL disabled = !ffmpegAvailable;

	NSString *footer = ffmpegAvailable
		? SCILocalized(@"Downloads HD video via DASH streams and encodes to H.264. Requires FFmpegKit.")
		: SCILocalized(@"FFmpegKit is not available. Install the sideloaded IPA or the _ffmpeg .deb variant to enable.");

	SCISetting *toggle = [SCISetting switchCellWithTitle:SCILocalized(@"Enhanced downloads")
											   subtitle:SCILocalized(@"Download video at the highest available quality")
											defaultsKey:@"enhance_download_quality"];
	toggle.disabled = disabled;

	SCISetting *videoQuality = [SCISetting menuCellWithTitle:SCILocalized(@"Video quality")
												   subtitle:SCILocalized(@"Which quality to download")
													   menu:[self menus][@"default_video_quality"]];
	videoQuality.disabled = disabled;

	SCISetting *photoQuality = [SCISetting menuCellWithTitle:SCILocalized(@"Photo quality")
												   subtitle:SCILocalized(@"Use highest resolution available")
													   menu:[self menus][@"default_photo_quality"]];
	photoQuality.disabled = disabled;

	SCISetting *advToggle = [SCISetting switchCellWithTitle:SCILocalized(@"Advanced encoding")
												   subtitle:SCILocalized(@"Manual ffmpeg controls in place of Encoding speed.")
												defaultsKey:@"adv_encoding_enabled"];
	advToggle.disabled = disabled;

	SCISetting *swapSlot = [self encodingSpeedOrAdvancedNavCell];
	swapSlot.disabled = disabled;

	return @{
        @"sci_force_internal_settings_loggedout": @NO,
        @"sci_force_internal_settings_menu": @NO,
		@"header": SCILocalized(@"Enhanced downloads"),
		@"footer": footer,
		@"rows": @[toggle, videoQuality, photoQuality, advToggle, swapSlot]
	};
}

// Encoding-speed menu OR Advanced-encoding nav, depending on adv_encoding_enabled.
+ (SCISetting *)encodingSpeedOrAdvancedNavCell {
	if ([SCIUtils getBoolPref:@"adv_encoding_enabled"]) {
		return [SCISetting navigationCellWithTitle:SCILocalized(@"Advanced encoding settings")
										  subtitle:@""
											  icon:nil
									   navSections:[self advancedEncodingNavSections]];
	}
	return [SCISetting menuCellWithTitle:SCILocalized(@"Encoding speed")
								subtitle:SCILocalized(@"Faster = lower quality")
									menu:[self menus][@"ffmpeg_encoding_speed"]];
}

+ (NSArray *)rebuildAdvancedEncodingSlotInSections:(NSArray *)sections {
	// Rebuild the whole section — slot-only matching is fragile across l10n and row reorders.
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *sec in sections) {
		NSArray *rows = sec[@"rows"];
		BOOL containsAdvToggle = NO;
		for (SCISetting *r in rows) {
			if ([r.defaultsKey isEqualToString:@"adv_encoding_enabled"]) {
				containsAdvToggle = YES;
				break;
			}
		}
		if (containsAdvToggle) {
			[out addObject:[self enhancedDownloadsSection]];
		} else {
			[out addObject:sec];
		}
	}
	return out;
}

+ (NSArray *)advancedEncodingNavSections {
	// Inner panel uses SCIOptionSheet pickers; no per-row subtitles.
	SCISetting *codec = [self optionCellTitle:SCILocalized(@"Video codec") key:@"adv_video_codec" options:@[
		@{ @"title": SCILocalized(@"Hardware (VideoToolbox)"), @"value": @"h264_videotoolbox",
		   @"description": SCILocalized(@"Fast, fixed-bitrate, GPU-accelerated.") },
		@{ @"title": SCILocalized(@"Software (libx264)"), @"value": @"libx264",
		   @"description": SCILocalized(@"Slower, better compression per bit.") },
	]];
	SCISetting *preset = [self optionCellTitle:SCILocalized(@"Preset") key:@"adv_preset" options:@[
		@{ @"title": @"ultrafast", @"value": @"ultrafast", @"description": SCILocalized(@"Fastest, worst compression.") },
		@{ @"title": @"superfast", @"value": @"superfast" },
		@{ @"title": @"veryfast",  @"value": @"veryfast" },
		@{ @"title": @"faster",    @"value": @"faster" },
		@{ @"title": @"fast",      @"value": @"fast" },
		@{ @"title": @"medium",    @"value": @"medium",    @"description": SCILocalized(@"Balanced. libx264 default.") },
		@{ @"title": @"slow",      @"value": @"slow" },
		@{ @"title": @"slower",    @"value": @"slower" },
		@{ @"title": @"veryslow",  @"value": @"veryslow", @"description": SCILocalized(@"Best practical quality per bit.") },
		@{ @"title": @"placebo",   @"value": @"placebo",  @"description": SCILocalized(@"Marginal gain, huge time cost.") },
	]];
	SCISetting *tune = [self optionCellTitle:SCILocalized(@"Tune") key:@"adv_tune" options:@[
		@{ @"title": SCILocalized(@"None"), @"value": @"none", @"description": SCILocalized(@"No tuning. Default.") },
		@{ @"title": @"film",        @"value": @"film",        @"description": SCILocalized(@"Live-action video.") },
		@{ @"title": @"animation",   @"value": @"animation",   @"description": SCILocalized(@"Cartoons / anime.") },
		@{ @"title": @"grain",       @"value": @"grain",       @"description": SCILocalized(@"Preserve film grain.") },
		@{ @"title": @"stillimage",  @"value": @"stillimage",  @"description": SCILocalized(@"Slideshow-like content.") },
		@{ @"title": @"fastdecode",  @"value": @"fastdecode",  @"description": SCILocalized(@"Easier to play back on weak devices.") },
		@{ @"title": @"zerolatency", @"value": @"zerolatency", @"description": SCILocalized(@"Low-latency streaming.") },
	]];
	SCISetting *profile = [self optionCellTitle:SCILocalized(@"H.264 profile") key:@"adv_h264_profile" options:@[
		@{ @"title": @"baseline", @"value": @"baseline", @"description": SCILocalized(@"Widest compatibility, no B-frames.") },
		@{ @"title": @"main",     @"value": @"main",     @"description": SCILocalized(@"Standard 8-bit.") },
		@{ @"title": @"high",     @"value": @"high",     @"description": SCILocalized(@"8-bit. Best for modern devices.") },
		@{ @"title": @"high10",   @"value": @"high10",   @"description": SCILocalized(@"10-bit colour. Slower, smoother gradients. Software only.") },
		@{ @"title": @"high422",  @"value": @"high422",  @"description": SCILocalized(@"8-bit 4:2:2 chroma. Niche playback.") },
		@{ @"title": @"high444",  @"value": @"high444",  @"description": SCILocalized(@"8-bit 4:4:4 full chroma. Niche playback.") },
	]];
	SCISetting *level = [self optionCellTitle:SCILocalized(@"H.264 level") key:@"adv_h264_level" options:@[
		@{ @"title": SCILocalized(@"Auto"), @"value": @"auto", @"description": SCILocalized(@"Let the encoder pick.") },
		@{ @"title": @"3.0", @"value": @"3.0" },
		@{ @"title": @"3.1", @"value": @"3.1" },
		@{ @"title": @"3.2", @"value": @"3.2" },
		@{ @"title": @"4.0", @"value": @"4.0", @"description": SCILocalized(@"1080p30 baseline.") },
		@{ @"title": @"4.1", @"value": @"4.1" },
		@{ @"title": @"4.2", @"value": @"4.2" },
		@{ @"title": @"5.0", @"value": @"5.0" },
		@{ @"title": @"5.1", @"value": @"5.1", @"description": SCILocalized(@"4K30 baseline.") },
		@{ @"title": @"5.2", @"value": @"5.2" },
	]];
	SCISetting *pixFmt = [self optionCellTitle:SCILocalized(@"Pixel format") key:@"adv_pixel_format" options:@[
		@{ @"title": @"yuv420p",     @"value": @"yuv420p",     @"description": SCILocalized(@"8-bit 4:2:0. Universal default.") },
		@{ @"title": @"yuv422p",     @"value": @"yuv422p",     @"description": SCILocalized(@"8-bit 4:2:2 chroma. Software only.") },
		@{ @"title": @"yuv444p",     @"value": @"yuv444p",     @"description": SCILocalized(@"8-bit 4:4:4 chroma. Software only.") },
		@{ @"title": @"yuv420p10le", @"value": @"yuv420p10le", @"description": SCILocalized(@"10-bit 4:2:0. ~2x slower, smoother gradients.") },
	]];

	SCISetting *crf = [self optionCellTitle:SCILocalized(@"CRF quality") key:@"adv_crf" options:@[
		@{ @"title": @"0",  @"value": @"0",  @"description": SCILocalized(@"Lossless. Huge files.") },
		@{ @"title": @"12", @"value": @"12", @"description": SCILocalized(@"Archival quality.") },
		@{ @"title": @"15", @"value": @"15", @"description": SCILocalized(@"Very high quality.") },
		@{ @"title": @"17", @"value": @"17" },
		@{ @"title": @"18", @"value": @"18", @"description": SCILocalized(@"Visually lossless. RyukGram default.") },
		@{ @"title": @"20", @"value": @"20" },
		@{ @"title": @"22", @"value": @"22" },
		@{ @"title": @"23", @"value": @"23", @"description": SCILocalized(@"Balanced. libx264 default.") },
		@{ @"title": @"26", @"value": @"26" },
		@{ @"title": @"28", @"value": @"28", @"description": SCILocalized(@"Smaller, visible artefacts.") },
		@{ @"title": @"32", @"value": @"32" },
		@{ @"title": @"35", @"value": @"35" },
		@{ @"title": @"40", @"value": @"40" },
		@{ @"title": @"51", @"value": @"51", @"description": SCILocalized(@"Worst quality.") },
	]];

	SCISetting *bitrate = [SCISetting buttonCellWithTitle:SCILocalized(@"Video bitrate")
												 subtitle:@""
													 icon:nil
												   action:^{ [self promptAdvVideoBitrate]; }];
	bitrate.dynamicValueText = ^NSString *{ return [SCITweakSettings advBitrateValueText]; };
	bitrate.defaultsKey = @"adv_video_bitrate"; // button cells ignore defaultsKey; set for the what's-new dot

	SCISetting *maxRes = [self optionCellTitle:SCILocalized(@"Max resolution") key:@"adv_max_resolution" options:@[
		@{ @"title": SCILocalized(@"Original"), @"value": @"original" },
		@{ @"title": @"2160p (4K)", @"value": @"2160" },
		@{ @"title": @"1440p",      @"value": @"1440" },
		@{ @"title": @"1080p",      @"value": @"1080" },
		@{ @"title": @"720p",       @"value": @"720" },
		@{ @"title": @"480p",       @"value": @"480" },
	]];
	SCISetting *fps = [self optionCellTitle:SCILocalized(@"Frame rate") key:@"adv_fps" options:@[
		@{ @"title": SCILocalized(@"Original"), @"value": @"original", @"description": SCILocalized(@"Keep the source frame rate.") },
		@{ @"title": @"60", @"value": @"60" },
		@{ @"title": @"30", @"value": @"30" },
		@{ @"title": @"24", @"value": @"24", @"description": SCILocalized(@"Cinematic. Smaller files.") },
	]];

	SCISetting *audioCodec = [self optionCellTitle:SCILocalized(@"Audio codec") key:@"adv_audio_codec" options:@[
		@{ @"title": SCILocalized(@"Copy (passthrough)"), @"value": @"copy",
		   @"description": SCILocalized(@"Keep original audio. Fast.") },
		@{ @"title": @"AAC", @"value": @"aac",
		   @"description": SCILocalized(@"Re-encode. Use when source is opus or unsupported.") },
	]];
	SCISetting *audioBitrate = [self optionCellTitle:SCILocalized(@"Audio bitrate") key:@"adv_audio_bitrate" options:@[
		@{ @"title": @"64k",  @"value": @"64k" },
		@{ @"title": @"96k",  @"value": @"96k" },
		@{ @"title": @"128k", @"value": @"128k", @"description": SCILocalized(@"Streaming default.") },
		@{ @"title": @"192k", @"value": @"192k" },
		@{ @"title": @"256k", @"value": @"256k" },
		@{ @"title": @"320k", @"value": @"320k", @"description": SCILocalized(@"Top of AAC.") },
	]];
	SCISetting *audioChannels = [self optionCellTitle:SCILocalized(@"Audio channels") key:@"adv_audio_channels" options:@[
		@{ @"title": SCILocalized(@"Original"), @"value": @"original" },
		@{ @"title": SCILocalized(@"Stereo"),   @"value": @"stereo" },
		@{ @"title": SCILocalized(@"Mono"),     @"value": @"mono" },
	]];
	SCISetting *audioSampleRate = [self optionCellTitle:SCILocalized(@"Audio sample rate") key:@"adv_audio_samplerate" options:@[
		@{ @"title": SCILocalized(@"Original"), @"value": @"original" },
		@{ @"title": @"44.1 kHz", @"value": @"44100" },
		@{ @"title": @"48 kHz",   @"value": @"48000" },
	]];

	SCISetting *faststart = [SCISetting switchCellWithTitle:SCILocalized(@"Faststart")
												   subtitle:@""
												defaultsKey:@"adv_faststart"];

	SCISetting *stripMetadata = [SCISetting switchCellWithTitle:SCILocalized(@"Strip metadata")
													   subtitle:@""
													defaultsKey:@"adv_strip_metadata"];

	SCISetting *reset = [SCISetting buttonCellWithTitle:SCILocalized(@"Reset to defaults")
											   subtitle:@""
												   icon:[SCISymbol symbolWithName:@"arrow.counterclockwise"]
												 action:^{ [self resetAdvancedEncoding]; }];
	reset.titleColor = [UIColor systemBlueColor];

	SCISetting *docs = [SCISetting linkCellWithTitle:SCILocalized(@"FFmpeg documentation")
											subtitle:@""
												icon:[SCISymbol symbolWithName:@"info.circle"]
												 url:@"https://ffmpeg.org/ffmpeg-codecs.html#libx264_002c-libx264rgb"];

	return @[
		@{ @"header": SCILocalized(@"Codec"),
		   @"footer": SCILocalized(@"Preset and Tune apply to Software (libx264) only. Pair profile with pixel format: high↔yuv420p, high10↔yuv420p10le, high422↔yuv422p, high444↔yuv444p. Mismatches downconvert silently. Hardware always uses yuv420p."),
		   @"rows": @[codec, preset, tune, profile, level, pixFmt] },
		@{ @"header": SCILocalized(@"Quality"),
		   @"footer": SCILocalized(@"Setting a video bitrate switches Software to fixed-bitrate and ignores CRF. Leave empty for CRF. Hardware uses bitrate."),
		   @"rows": @[crf, bitrate, maxRes, fps] },
		@{ @"header": SCILocalized(@"Audio"),
		   @"footer": SCILocalized(@"Bitrate, channels, and sample rate apply only when the codec is AAC (re-encoding)."),
		   @"rows": @[audioCodec, audioBitrate, audioChannels, audioSampleRate] },
		@{ @"header": SCILocalized(@"Container"),
		   @"footer": SCILocalized(@"Faststart moves the MP4 index to the start so playback begins before the file fully buffers. Strip metadata removes source tags (creation date, handler, encoder) from the file."),
		   @"rows": @[faststart, stripMetadata] },
		@{ @"header": @"",
		   @"rows": @[reset, docs] },
	];
}

// Tappable cell opening SCIOptionSheet for a single-select pref. After pick,
// posts SCISettingsShouldReload — observer path beats hand-chasing the
// visible VC across modal stacks.
+ (SCISetting *)optionCellTitle:(NSString *)title key:(NSString *)key options:(NSArray<NSDictionary *> *)options {
	SCISetting *cell = [SCISetting buttonCellWithTitle:title subtitle:@"" icon:nil action:^{
		[SCIOptionSheet presentFrom:sciTopVC() title:title defaultsKey:key options:options onChange:^(__unused NSString *v) {
			[[NSNotificationCenter defaultCenter] postNotificationName:@"SCISettingsShouldReload" object:nil];
		}];
	}];
	cell.dynamicValueText = ^NSString *{ return [SCITweakSettings optionCellValueTextForKey:key options:options]; };
	cell.defaultsKey = key; // button cells ignore defaultsKey; set for the what's-new dot
	return cell;
}

+ (NSString *)optionCellValueTextForKey:(NSString *)key options:(NSArray<NSDictionary *> *)options {
	NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"";
	for (NSDictionary *opt in options) {
		if ([opt[@"value"] isEqualToString:cur]) return opt[@"title"] ?: cur;
	}
	return cur.length ? cur : @"—";
}

+ (NSString *)advBitrateValueText {
	NSString *cur = [[SCIUtils getStringPref:@"adv_video_bitrate"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	return cur.length ? cur : SCILocalized(@"Auto");
}

+ (void)promptAdvVideoBitrate {
	NSString *current = [SCIUtils getStringPref:@"adv_video_bitrate"];
	UIViewController *presenter = sciTopVC();
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:SCILocalized(@"Video bitrate")
																   message:SCILocalized(@"Examples: 8M, 12M, 25M, 4500k. Leave empty for auto.")
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"8M";
		tf.text = current ?: @"";
		tf.autocorrectionType = UITextAutocorrectionTypeNo;
		tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
		NSString *v = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		[[NSUserDefaults standardUserDefaults] setObject:(v ?: @"") forKey:@"adv_video_bitrate"];
		// No row handle here — post the reload signal and let observers re-derive valueText.
		[[NSNotificationCenter defaultCenter] postNotificationName:@"SCISettingsAdvBitrateChanged" object:nil];
		[[NSNotificationCenter defaultCenter] postNotificationName:@"SCISettingsShouldReload" object:nil];
	}]];
	[presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)resetAdvancedEncoding {
	[SCIUtils showConfirmation:^{
		NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
		NSArray *keys = @[
			@"adv_encoding_enabled", @"adv_video_codec", @"adv_preset", @"adv_tune",
			@"adv_h264_profile", @"adv_h264_level", @"adv_crf",
			@"adv_video_bitrate", @"adv_max_resolution", @"adv_fps", @"adv_audio_codec",
			@"adv_audio_bitrate", @"adv_audio_channels", @"adv_audio_samplerate", @"adv_pixel_format",
			@"adv_faststart", @"adv_strip_metadata",
		];
		NSDictionary *defaults = SCIDefaultsDictionary();
		for (NSString *k in keys) {
			id v = defaults[k];
			if (v) [d setObject:v forKey:k];
			else [d removeObjectForKey:k];
		}
		UIViewController *presenter = sciTopVC();
		if ([presenter respondsToSelector:@selector(tableView)]) {
			id tv = [presenter performSelector:@selector(tableView)];
			if ([tv respondsToSelector:@selector(reloadData)]) [tv performSelector:@selector(reloadData)];
		}
	} title:SCILocalized(@"Reset advanced encoding")];
}

@end
