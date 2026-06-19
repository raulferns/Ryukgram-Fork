// SCISymbolBrowserEngine.m
#import "SCISymbolBrowserEngine.h"
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString *const kOverridesKey = @"sci_symbol_overrides";
static const char *kImageSuffix[2] = { "/Instagram", "/FBSharedFramework" };

static NSDictionary<NSString *, NSNumber *> *sRuntimeOverrideCache;
static NSMutableSet<NSString *> *sInstalledOverrideKeys;
static NSMutableDictionary<NSString *, NSNumber *> *sObservedOriginalValues;

static NSString *sciOverrideKeyForParts(NSString *className, NSString *selectorName, BOOL isClassMethod) {
	return [NSString stringWithFormat:@"%@%@#%@", isClassMethod ? @"+" : @"", className ?: @"", selectorName ?: @""];
}

static NSDictionary *sciOverrideDict(void) {
	NSDictionary *d = [SCIUtils getDictPref:kOverridesKey];
	return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static NSDictionary<NSString *, NSNumber *> *sciNormalizedOverrideDict(NSDictionary *dict) {
	NSMutableDictionary *out = [NSMutableDictionary dictionary];
	[dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
		if (![key isKindOfClass:NSString.class]) return;
		if ([obj isKindOfClass:NSNumber.class]) out[key] = obj;
	}];
	return out.copy;
}

static void sciRefreshRuntimeOverrideCache(void) {
	sRuntimeOverrideCache = sciNormalizedOverrideDict(sciOverrideDict());
}

static NSNumber *sciOverrideForKey(NSString *key) {
	id v = sciOverrideDict()[key];
	return [v isKindOfClass:NSNumber.class] ? v : nil;
}

static NSNumber *sciRuntimeOverrideForKey(NSString *key) {
	NSDictionary *cache = sRuntimeOverrideCache;
	NSNumber *v = cache[key];
	return [v isKindOfClass:NSNumber.class] ? v : nil;
}

static void sciRememberObservedOriginal(NSString *key, BOOL value) {
	if (!key.length) return;
	@synchronized([SCISymbolBrowserEngine class]) {
		if (!sObservedOriginalValues) sObservedOriginalValues = [NSMutableDictionary dictionary];
		sObservedOriginalValues[key] = @(value);
	}
}

static NSNumber *sciObservedOriginalForKey(NSString *key) {
	if (!key.length) return nil;
	@synchronized([SCISymbolBrowserEngine class]) {
		return sObservedOriginalValues[key];
	}
}

static BOOL sciIsBoolGetterEncoding(const char *enc) {
	if (!enc || !enc[0]) return NO;
	if (enc[0] != 'B' && enc[0] != 'c' && enc[0] != 'C') return NO;
	int at = 0, colon = 0;
	for (const char *p = enc; *p; p++) { if (*p == '@') at++; else if (*p == ':') colon++; }
	return (at == 1 && colon == 1);
}

static BOOL sciMethodIsNoArgBool(Method method) {
	if (!method || method_getNumberOfArguments(method) != 2) return NO;
	char ret[8] = {0};
	method_getReturnType(method, ret, sizeof(ret));
	return ret[0] == 'B' || ret[0] == 'c' || ret[0] == 'C';
}

static BOOL sciSelectorLooksLikeGetter(const char *name) {
	if (!name) return NO;
	if (strstr(name, ":")) return NO;
	if (strncmp(name, "set", 3) == 0) return NO;
	if (strstr(name, "init") == name) return NO;
	if (strcmp(name, "isEqual") == 0) return NO;
	return YES;
}

static BOOL sciParseOverrideKey(NSString *key, NSString **className, NSString **selectorName, BOOL *isClassMethod) {
	if (![key isKindOfClass:NSString.class] || !key.length) return NO;
	BOOL classMethod = [key hasPrefix:@"+"];
	NSString *body = classMethod ? [key substringFromIndex:1] : key;
	NSRange r = [body rangeOfString:@"#"];
	if (r.location == NSNotFound || r.location == 0 || NSMaxRange(r) >= body.length) return NO;
	if (className) *className = [body substringToIndex:r.location];
	if (selectorName) *selectorName = [body substringFromIndex:NSMaxRange(r)];
	if (isClassMethod) *isClassMethod = classMethod;
	return YES;
}

static SEL kSharedSelectors[6];
static void sciInitSharedSelectors(void) {
	static dispatch_once_t once; dispatch_once(&once, ^{
		kSharedSelectors[0] = @selector(sharedConfig);
		kSharedSelectors[1] = @selector(sharedInstance);
		kSharedSelectors[2] = @selector(shared);
		kSharedSelectors[3] = @selector(sharedManager);
		kSharedSelectors[4] = @selector(defaultConfig);
		kSharedSelectors[5] = @selector(defaultInstance);
	});
}

static id sciResolveInstance(Class cls) {
	sciInitSharedSelectors();
	for (int i = 0; i < 6; i++) {
		SEL s = kSharedSelectors[i];
		if ([cls respondsToSelector:s]) {
			@try {
				id (*f)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
				id inst = f(cls, s);
				if (inst) return inst;
			} @catch (__unused id e) {}
		}
	}
	return nil;
}

static NSNumber *sciCallBoolGetter(id target, SEL sel) {
	if (!target || !sel || ![target respondsToSelector:sel]) return nil;
	@try {
		BOOL (*f)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
		return @(f(target, sel));
	} @catch (__unused id e) { return nil; }
}

static void sciAppendBoolGettersForClass(NSMutableArray<SCISymbolGetter *> *getters, Class ownerClass, Class methodClass, NSString *className, BOOL isClassMethod) {
	unsigned int mc = 0;
	Method *methods = class_copyMethodList(methodClass, &mc);
	for (unsigned int j = 0; j < mc; j++) {
		SEL sel = method_getName(methods[j]);
		const char *sname = sel_getName(sel);
		const char *enc = method_getTypeEncoding(methods[j]);
		if (!sciSelectorLooksLikeGetter(sname)) continue;
		if (!sciIsBoolGetterEncoding(enc)) continue;
		SCISymbolGetter *g = [SCISymbolGetter new];
		g.selectorName = [NSString stringWithUTF8String:sname];
		g.isClassMethod = isClassMethod;
		g.ownerClassName = className;
		[getters addObject:g];
	}
	if (methods) free(methods);
	(void)ownerClass;
}

static BOOL sciInstallRuntimeOverrideForKey(NSString *key) {
	if (!key.length) return NO;
	if (!sInstalledOverrideKeys) sInstalledOverrideKeys = [NSMutableSet set];
	if ([sInstalledOverrideKeys containsObject:key]) return YES;

	NSString *className = nil;
	NSString *selectorName = nil;
	BOOL isClassMethod = NO;
	if (!sciParseOverrideKey(key, &className, &selectorName, &isClassMethod)) return NO;

	Class cls = NSClassFromString(className);
	if (!cls) return NO;
	SEL sel = NSSelectorFromString(selectorName);
	if (!sel) return NO;
	Class hookClass = isClassMethod ? object_getClass(cls) : cls;
	Method method = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
	if (!sciMethodIsNoArgBool(method)) return NO;

	NSString *capturedKey = [key copy];
	SEL capturedSel = sel;
	__block IMP originalIMP = NULL;
	IMP replacement = imp_implementationWithBlock(^BOOL(id receiver) {
		BOOL original = originalIMP ? ((BOOL (*)(id, SEL))originalIMP)(receiver, capturedSel) : NO;
		sciRememberObservedOriginal(capturedKey, original);
		NSNumber *forced = sciRuntimeOverrideForKey(capturedKey);
		return forced ? forced.boolValue : original;
	});

	MSHookMessageEx(hookClass, sel, replacement, &originalIMP);
	[sInstalledOverrideKeys addObject:key];
	return YES;
}

@implementation SCISymbolGetter
- (NSString *)overrideKey {
	return sciOverrideKeyForParts(self.ownerClassName ?: @"", self.selectorName ?: @"", self.isClassMethod);
}
- (NSNumber *)override { return sciOverrideForKey(self.overrideKey); }
- (NSNumber *)liveValue {
	return [SCISymbolBrowserEngine liveValueForClass:self.ownerClassName selector:self.selectorName isClassMethod:self.isClassMethod];
}
@end

@implementation SCISymbolClass @end

@implementation SCISymbolBrowserEngine

+ (NSArray<SCISymbolClass *> *)classesForImage:(SCISymbolImage)image {
	const char *suffix = kImageSuffix[image];
	size_t suffixLen = strlen(suffix);

	unsigned int count = 0;
	Class *all = objc_copyClassList(&count);
	if (!all) return @[];

	NSMutableArray<SCISymbolClass *> *out = [NSMutableArray array];
	for (unsigned int i = 0; i < count; i++) {
		Class cls = all[i];
		const char *img = class_getImageName(cls);
		if (!img) continue;
		size_t il = strlen(img);
		if (il < suffixLen || strcmp(img + il - suffixLen, suffix) != 0) continue;

		const char *cname = class_getName(cls);
		if (!cname) continue;
		NSString *className = [NSString stringWithUTF8String:cname];

		NSMutableArray<SCISymbolGetter *> *getters = [NSMutableArray array];
		sciAppendBoolGettersForClass(getters, cls, cls, className, NO);
		Class meta = object_getClass(cls);
		if (meta) sciAppendBoolGettersForClass(getters, cls, meta, className, YES);

		if (getters.count) {
			[getters sortUsingComparator:^NSComparisonResult(SCISymbolGetter *a, SCISymbolGetter *b) {
				NSString *ak = [NSString stringWithFormat:@"%@%@", a.isClassMethod ? @"+" : @"-", a.selectorName ?: @""];
				NSString *bk = [NSString stringWithFormat:@"%@%@", b.isClassMethod ? @"+" : @"-", b.selectorName ?: @""];
				return [ak compare:bk];
			}];
			SCISymbolClass *sc = [SCISymbolClass new];
			sc.className = className;
			sc.getters = getters;
			[out addObject:sc];
		}
	}
	free(all);

	[out sortUsingComparator:^NSComparisonResult(SCISymbolClass *a, SCISymbolClass *b) {
		return [a.className compare:b.className];
	}];
	return out;
}

+ (NSNumber *)liveValueForClass:(NSString *)className selector:(NSString *)selectorName isClassMethod:(BOOL)isClassMethod {
	Class cls = NSClassFromString(className);
	if (!cls) return nil;
	SEL sel = NSSelectorFromString(selectorName);
	NSString *key = sciOverrideKeyForParts(className, selectorName, isClassMethod);
	NSNumber *direct = nil;
	if (isClassMethod) {
		direct = sciCallBoolGetter(cls, sel);
	} else {
		id inst = sciResolveInstance(cls);
		direct = inst ? sciCallBoolGetter(inst, sel) : nil;
	}
	return direct ?: sciObservedOriginalForKey(key);
}

+ (NSNumber *)overrideForKey:(NSString *)overrideKey { return sciOverrideForKey(overrideKey); }
+ (BOOL)hookInstalledForKey:(NSString *)overrideKey { return overrideKey.length && [sInstalledOverrideKeys containsObject:overrideKey]; }
+ (BOOL)installOverrideForKey:(NSString *)overrideKey { return sciInstallRuntimeOverrideForKey(overrideKey); }

+ (void)setOverride:(NSNumber *)value forClass:(NSString *)className selector:(NSString *)selectorName isClassMethod:(BOOL)isClassMethod {
	NSString *key = sciOverrideKeyForParts(className, selectorName, isClassMethod);
	NSMutableDictionary *d = [sciOverrideDict() mutableCopy];
	if (value) d[key] = value; else [d removeObjectForKey:key];
	[SCIUtils setPref:d forKey:kOverridesKey];
	sciRefreshRuntimeOverrideCache();
	if (value) sciInstallRuntimeOverrideForKey(key);
}

+ (void)reinstallPersistedHooks {
	sciRefreshRuntimeOverrideCache();
	NSDictionary *overrides = sRuntimeOverrideCache;
	if (!overrides.count) return;
	for (NSString *key in overrides) {
		sciInstallRuntimeOverrideForKey(key);
	}
}

@end
