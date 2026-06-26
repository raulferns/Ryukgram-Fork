#import "SCITempFiles.h"

static NSString *const kSCITempPrefix = @"ryuk_tmp_";
static NSString *const kSCILegacyTempPrefix = @"sci_tmp_";
static const NSTimeInterval kSCIDefaultTTL = 300.0;

@implementation SCITempFiles

+ (dispatch_queue_t)queue {
	static dispatch_queue_t q;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		q = dispatch_queue_create("com.ryuk.ryukgram.tempfiles", DISPATCH_QUEUE_SERIAL);
	});
	return q;
}

// path -> dispatch_source_t (timer). Touched only on +queue.
+ (NSMutableDictionary *)timers {
	static NSMutableDictionary *d;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ d = [NSMutableDictionary new]; });
	return d;
}

+ (NSURL *)claimWithExt:(NSString *)ext {
	return [self claimWithExt:ext ttl:kSCIDefaultTTL tag:nil];
}

+ (NSURL *)claimWithExt:(NSString *)ext ttl:(NSTimeInterval)ttl {
	return [self claimWithExt:ext ttl:ttl tag:nil];
}

+ (NSURL *)claimWithExt:(NSString *)ext ttl:(NSTimeInterval)ttl tag:(NSString *)tag {
	NSString *cleanExt = ext.length ? ext : @"bin";
	NSString *cleanTag = tag.length ? [tag stringByReplacingOccurrencesOfString:@"/" withString:@"_"] : @"anon";
	NSString *name = [NSString stringWithFormat:@"%@%@_%@.%@", kSCITempPrefix, cleanTag, NSUUID.UUID.UUIDString, cleanExt];
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];

	[self scheduleDeleteForPath:url.path after:ttl];
	return url;
}

+ (NSURL *)claimNamedFile:(NSString *)filename ttl:(NSTimeInterval)ttl tag:(NSString *)tag {
	NSString *cleanTag = tag.length ? [tag stringByReplacingOccurrencesOfString:@"/" withString:@"_"] : @"anon";
	NSString *dirName = [NSString stringWithFormat:@"%@%@_%@", kSCITempPrefix, cleanTag, NSUUID.UUID.UUIDString];
	NSString *dirPath = [NSTemporaryDirectory() stringByAppendingPathComponent:dirName];
	[NSFileManager.defaultManager createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];

	// Track the wrapper dir — TTL/boot sweep remove it (and the file inside) by prefix.
	[self scheduleDeleteForPath:dirPath after:ttl];

	NSString *safeName = [(filename.length ? filename : @"RyukGram-file") lastPathComponent];
	return [NSURL fileURLWithPath:[dirPath stringByAppendingPathComponent:safeName]];
}

+ (void)releaseURL:(NSURL *)url {
	if (!url.path.length) return;
	NSString *path = url.path;
	// claimNamedFile tracks the wrapper dir, not the file — release that too.
	NSString *parent = path.stringByDeletingLastPathComponent;
	BOOL parentTracked = [parent.lastPathComponent hasPrefix:kSCITempPrefix];

	dispatch_async([self queue], ^{
		for (NSString *p in (parentTracked ? @[path, parent] : @[path])) {
			dispatch_source_t timer = (__bridge dispatch_source_t)[self timers][p];
			if (timer) {
				dispatch_source_cancel(timer);
				[[self timers] removeObjectForKey:p];
			}
			[NSFileManager.defaultManager removeItemAtPath:p error:nil];
		}
	});
}

+ (void)extendURL:(NSURL *)url ttl:(NSTimeInterval)ttl {
	if (!url.path.length) return;
	[self scheduleDeleteForPath:url.path after:ttl];
}

+ (void)scheduleDeleteForPath:(NSString *)path after:(NSTimeInterval)ttl {
	if (!path.length) return;
	if (ttl < 1.0) ttl = 1.0;

	dispatch_async([self queue], ^{
		dispatch_source_t existing = (__bridge dispatch_source_t)[self timers][path];
		if (existing) dispatch_source_cancel(existing);

		dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, [self queue]);
		dispatch_source_set_timer(timer,
			dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ttl * NSEC_PER_SEC)),
			DISPATCH_TIME_FOREVER, (uint64_t)(1 * NSEC_PER_SEC));

		dispatch_source_set_event_handler(timer, ^{
			[NSFileManager.defaultManager removeItemAtPath:path error:nil];
			[[self timers] removeObjectForKey:path];
			dispatch_source_cancel(timer);
		});

		[self timers][path] = (__bridge id)timer;
		dispatch_resume(timer);
	});
}

+ (void)sweepLeftovers {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *tmp = NSTemporaryDirectory();
		NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmp error:nil];
		for (NSString *name in names) {
			if (![name hasPrefix:kSCITempPrefix] && ![name hasPrefix:kSCILegacyTempPrefix]) continue;
			[NSFileManager.defaultManager removeItemAtPath:[tmp stringByAppendingPathComponent:name] error:nil];
		}
	});
}

@end
