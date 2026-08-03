// SCIIdNameMapGenerator.m — RyukGram-Fork
// See SCIIdNameMapGenerator.h for the verified ABI table this file relies on.

#import "SCIIdNameMapGenerator.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import "../../../modules/fishhook/fishhook.h"

#pragma mark - ABI helpers

// A libc++ shared_ptr/weak_ptr is two pointers. A 16-byte POD aggregate is
// passed in two general-purpose registers under the arm64 ObjC ABI, so a plain
// objc_msgSend cast is correct here (no objc_msgSend_stret involved).
typedef struct {
	void *ptr;
	void *ctrl;
} SCIRawSharedPtr;

static BOOL SCIEncodingIs(Method method, const char *expected) {
	if (!method || !expected) return NO;
	const char *actual = method_getTypeEncoding(method);
	return actual && strcmp(actual, expected) == 0;
}

static BOOL SCIEncodingHasPrefixAndSuffix(Method method, const char *prefix, const char *suffix) {
	if (!method) return NO;
	const char *actual = method_getTypeEncoding(method);
	if (!actual) return NO;
	size_t la = strlen(actual), lp = strlen(prefix), ls = strlen(suffix);
	if (la < lp || la < ls) return NO;
	return strncmp(actual, prefix, lp) == 0 && strcmp(actual + (la - ls), suffix) == 0;
}

static NSString *SCIEncodingOf(Method method) {
	const char *actual = method ? method_getTypeEncoding(method) : NULL;
	return actual ? @(actual) : @"missing";
}

static id SCICallObjectGetter(id target, NSString *selectorName) {
	if (!target || !selectorName.length) return nil;
	SEL selector = NSSelectorFromString(selectorName);
	Method method = class_getInstanceMethod(object_getClass(target), selector);
	if (!SCIEncodingIs(method, "@16@0:8")) return nil;
	@try {
		return ((id (*)(id, SEL))objc_msgSend)(target, selector);
	} @catch (id exception) {
		return nil;
	}
}

/// True when an ivar type encoding is a libc++ smart pointer to a MobileConfig
/// manager. IG does not use FBMobileConfigContextObjcImpl here — on device the
/// _mobileconfig ivar holds IGMobileConfigContextManager — so the ivar name is
/// never assumed; only the encoding is trusted.
static BOOL SCIEncodingIsManagerSmartPointer(const char *encoding) {
	if (!encoding) return NO;
	BOOL smart = strstr(encoding, "shared_ptr<") || strstr(encoding, "weak_ptr<");
	if (!smart) return NO;
	if (!strstr(encoding, "mobileconfig::")) return NO;
	return strstr(encoding, "FBMobileConfigManager") != NULL ||
		   strstr(encoding, "IFBMobileConfigManager") != NULL;
}

/// Reads the raw __ptr_ out of a two-pointer smart-pointer ivar.
static void *SCIReadSmartPointerIvar(id object, Ivar ivar) {
	ptrdiff_t offset = ivar_getOffset(ivar);
	if (offset <= 0) return NULL;
	SCIRawSharedPtr raw = *(SCIRawSharedPtr *)((__bridge void *)object + offset);
	return raw.ptr;
}

/// Depth-first search for a manager smart pointer, following ObjC-typed ivars.
/// `path` receives the ivar chain that produced the hit, for the report.
static void *SCIScanForManagerPointer(id object, int depth, NSMutableString *path) {
	if (!object || depth < 0) return NULL;

	Class cls = object_getClass(object);
	unsigned int count = 0;
	Ivar *ivars = class_copyIvarList(cls, &count);
	if (!ivars) return NULL;

	void *found = NULL;
	NSMutableArray<NSString *> *objectIvars = [NSMutableArray array];

	for (unsigned int i = 0; i < count && !found; i++) {
		const char *encoding = ivar_getTypeEncoding(ivars[i]);
		const char *name = ivar_getName(ivars[i]);
		if (SCIEncodingIsManagerSmartPointer(encoding)) {
			void *raw = SCIReadSmartPointerIvar(object, ivars[i]);
			if (raw) {
				found = raw;
				[path appendFormat:@"%@.%s", NSStringFromClass(cls), name ?: "?"];
			}
		} else if (encoding && encoding[0] == '@' && name) {
			[objectIvars addObject:@(name)];
		}
	}
	free(ivars);
	if (found) return found;

	for (NSString *name in objectIvars) {
		Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
		if (!ivar) continue;
		id child = object_getIvar(object, ivar);
		if (!child || child == object) continue;
		NSMutableString *childPath = [NSMutableString string];
		void *raw = SCIScanForManagerPointer(child, depth - 1, childPath);
		if (raw) {
			[path appendFormat:@"%@.%@ -> %@", NSStringFromClass(cls), name, childPath];
			return raw;
		}
	}
	return NULL;
}

/// Lists the ivars of an object so an unresolved manager is actionable instead
/// of just "unreadable".
static NSString *SCIDescribeIvars(id object) {
	if (!object) return @"(nil)";
	unsigned int count = 0;
	Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
	if (!ivars) return @"(no ivars)";
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	for (unsigned int i = 0; i < count && i < 24; i++) {
		const char *name = ivar_getName(ivars[i]);
		const char *encoding = ivar_getTypeEncoding(ivars[i]);
		NSString *type = encoding ? @(encoding) : @"?";
		if (type.length > 72) type = [[type substringToIndex:72] stringByAppendingString:@"…"];
		[lines addObject:[NSString stringWithFormat:@"    %s %@", name ?: "?", type]];
	}
	free(ivars);
	return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Holder resolution

static id SCIGlobalSessionManager(void) {
	Class cls = NSClassFromString(@"FBMobileConfigFBTGlobalSessionManager");
	if (!cls) return nil;
	SEL selector = NSSelectorFromString(@"sharedInstance");
	Method method = class_getClassMethod(cls, selector);
	if (!SCIEncodingIs(method, "@16@0:8")) return nil;
	@try {
		return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
	} @catch (id exception) {
		return nil;
	}
}

static NSString *SCIHolderSelectorName(SCIIdNameMapUnit unit) {
	switch (unit) {
		case SCIIdNameMapUnitAdmin:       return @"adminSessionContextManagerHolder";
		case SCIIdNameMapUnitSessionless: return @"sessionlessContextManagerHolder";
		case SCIIdNameMapUnitCurrentSession:
		default:                          return @"currentSessionContextManagerHolder";
	}
}

static id SCIHolderForUnit(SCIIdNameMapUnit unit) {
	id manager = SCIGlobalSessionManager();
	if (!manager) return nil;
	id holder = SCICallObjectGetter(manager, SCIHolderSelectorName(unit));
	if (!holder) return nil;
	if (![NSStringFromClass(object_getClass(holder)) containsString:@"ContextManagerHolder"]) return nil;
	return holder;
}

static NSString *SCIStringIvar(id object, const char *name) {
	if (!object) return nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	if (!ivar) return nil;
	id value = object_getIvar(object, ivar);
	return [value isKindOfClass:NSString.class] ? value : nil;
}

/// holder -> mcFbtManager -> (any depth) -> smart pointer to the C++ manager.
/// On device the intermediate object is IGMobileConfigContextManager, not
/// FBMobileConfigContextObjcImpl, so the walk is encoding-driven, not name-driven.
static void *SCIRawManagerPointer(id holder, NSString **detail) {
	if (!holder) {
		if (detail) *detail = @"holder=nil";
		return NULL;
	}

	NSMutableString *path = [NSMutableString string];
	void *raw = SCIScanForManagerPointer(holder, 4, path);
	if (raw) {
		if (detail) *detail = path;
		return raw;
	}

	id fbtManager = SCICallObjectGetter(holder, @"mcFbtManager");
	if (!fbtManager) {
		if (detail) *detail = @"mcFbtManager=nil and no manager ivar on the holder";
		return NULL;
	}

	id contextImpl = nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(fbtManager), "_mobileconfig");
	if (ivar) contextImpl = object_getIvar(fbtManager, ivar);

	if (detail) {
		*detail = [NSString stringWithFormat:
			@"no manager smart-pointer ivar found.\n  %@ ivars:\n%@\n  %@ ivars:\n%@",
			NSStringFromClass(object_getClass(fbtManager)), SCIDescribeIvars(fbtManager),
			contextImpl ? NSStringFromClass(object_getClass(contextImpl)) : @"(no _mobileconfig)",
			SCIDescribeIvars(contextImpl)];
	}
	return NULL;
}

#pragma mark - C++ entry point

static const char *kSCIParamListSymbol =
	"_ZN12mobileconfig21FBMobileConfigManager40updateConfigsWithParamsListSynchronouslyEiNS_37FBMobileConfigRequestForParamListModeE";

// mobileconfig::FBMobileConfigManager::setFetcher(shared_ptr<FBMobileConfigFetcher>, bool)
// Instagram imports this symbol (it appears as an undefined reference in the main
// image), so the call crosses the image boundary and fishhook can intercept it —
// no __TEXT patching, which is what gets sideloaded builds SIGKILLed on iOS 27.
static const char *kSCISetFetcherSymbol =
	"_ZN12mobileconfig21FBMobileConfigManager10setFetcherENSt3__110shared_ptrINS_21FBMobileConfigFetcherEEEb";

typedef void (*SCIParamListSyncFn)(void *self, int timeout, int mode);

// A std::shared_ptr is not trivially copyable, so AAPCS64 passes it by invisible
// reference: the ABI-level parameter is a pointer to a caller-owned temporary.
typedef void (*SCISetFetcherFn)(void *self, SCIRawSharedPtr *fetcher, bool flag);

static SCIParamListSyncFn SCIResolveParamListSync(void) {
	static SCIParamListSyncFn fn = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		fn = (SCIParamListSyncFn)dlsym(RTLD_DEFAULT, kSCIParamListSymbol);
	});
	return fn;
}

static SCISetFetcherFn SCIResolveSetFetcher(void) {
	static SCISetFetcherFn fn = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		fn = (SCISetFetcherFn)dlsym(RTLD_DEFAULT, kSCISetFetcherSymbol);
	});
	return fn;
}

#pragma mark - Safe memory probing

/// Reads `size` bytes without ever faulting: vm_read_overwrite returns a kern
/// error for unmapped pages instead of raising SIGSEGV. Every dereference of a
/// C++ pointer recovered from an ivar goes through this.
static BOOL SCISafeRead(const void *address, void *out, size_t size) {
	if (!address || !out || !size) return NO;
	vm_size_t read = 0;
	kern_return_t kr = vm_read_overwrite(mach_task_self(),
										 (vm_address_t)address,
										 (vm_size_t)size,
										 (vm_address_t)out,
										 &read);
	return kr == KERN_SUCCESS && read == size;
}

/// Itanium C++ ABI: the vptr points at the address point; typeinfo sits one slot
/// before it, and a std::type_info stores its mangled name at offset 8.
/// Returns the dynamic type name, or nil when the object cannot be identified.
static NSString *SCIDynamicTypeName(const void *object) {
	void *vptr = NULL;
	if (!SCISafeRead(object, &vptr, sizeof(vptr)) || !vptr) return nil;

	Dl_info info;
	if (!dladdr(vptr, &info)) return nil;   // dladdr compares ranges, never dereferences

	void *typeInfo = NULL;
	if (!SCISafeRead((const char *)vptr - sizeof(void *), &typeInfo, sizeof(typeInfo))) return nil;
	if (!typeInfo) return nil;

	const char *namePtr = NULL;
	if (!SCISafeRead((const char *)typeInfo + sizeof(void *), &namePtr, sizeof(namePtr))) return nil;
	if (!namePtr) return nil;

	char buffer[128] = {0};
	if (!SCISafeRead(namePtr, buffer, sizeof(buffer) - 1)) return nil;
	buffer[sizeof(buffer) - 1] = '\0';
	if (!buffer[0]) return nil;
	return @(buffer);
}

static NSString *SCIImageNameForAddress(const void *address) {
	Dl_info info;
	if (!address || !dladdr(address, &info) || !info.dli_fname) return @"unknown image";
	return @(info.dli_fname).lastPathComponent;
}

/// The param-list call is a non-virtual FBMobileConfigManager member. Invoking it
/// on anything else — an IFBMobileConfigManager base subobject, a stale weak_ptr
/// target, a different implementation — reads the wrong offsets and takes the app
/// down. Confirmed RTTI in FBSharedFramework: N12mobileconfig21FBMobileConfigManagerE.
static NSString *kSCIManagerTypeName = @"N12mobileconfig21FBMobileConfigManagerE";

static BOOL SCIManagerPointerLooksSafe(const void *manager, NSString **reason) {
	if (!manager) {
		if (reason) *reason = @"null";
		return NO;
	}
	NSString *type = SCIDynamicTypeName(manager);
	if (!type) {
		if (reason) *reason = @"object is not readable — the weak_ptr target is gone";
		return NO;
	}
	if ([type isEqualToString:kSCIManagerTypeName]) {
		if (reason) *reason = [NSString stringWithFormat:@"FBMobileConfigManager (%@)",
			SCIImageNameForAddress(manager)];
		return YES;
	}
	if (reason) {
		*reason = [NSString stringWithFormat:
			@"dynamic type is %@, not FBMobileConfigManager — calling a manager method on it "
			@"would read the wrong offsets", type];
	}
	return NO;
}

#pragma mark - Crash breadcrumb

// The param-list call runs inside Instagram's own C++ stack; if it faults there
// is no exception to catch and the app is simply gone. A marker written before
// the call and cleared after turns that silent death into a reportable fact on
// the next launch.
static NSString *const kSCICrashBreadcrumbKey = @"sci_idnamemap_inflight";

static void SCIBreadcrumbBegin(NSString *step) {
	[NSUserDefaults.standardUserDefaults setObject:step forKey:kSCICrashBreadcrumbKey];
	[NSUserDefaults.standardUserDefaults synchronize];
}

static void SCIBreadcrumbEnd(void) {
	[NSUserDefaults.standardUserDefaults removeObjectForKey:kSCICrashBreadcrumbKey];
	[NSUserDefaults.standardUserDefaults synchronize];
}

static NSString *SCIBreadcrumbPending(void) {
	return [NSUserDefaults.standardUserDefaults stringForKey:kSCICrashBreadcrumbKey];
}

#pragma mark - Fetcher capture

// The holder carries no _fetcherSetter on this build, so nothing can reinstall a
// fetcher after the manager is rebuilt. Instead of synthesising one (there is no
// exported IGMobileConfigFetcher constructor), the fetcher the app installs at
// startup is captured on its way through setFetcher and pinned, so it can be
// reinstalled on whatever manager is live later.
static SCIRawSharedPtr sSCICapturedFetcher = {NULL, NULL};
static void *sSCICapturedForManager = NULL;
static NSUInteger sSCICaptureCount = 0;

/// libc++ __shared_weak_count: { vptr; long __shared_owners_; long __shared_weak_owners_; }
/// __shared_owners_ is the owner count minus one. Adding one pins the object for
/// the process lifetime — deliberate: an unpinned copy could dangle by the time
/// the Dev row runs.
static void SCIPinSharedPtr(SCIRawSharedPtr ptr) {
	if (!ptr.ptr || !ptr.ctrl) return;
	long *owners = (long *)((char *)ptr.ctrl + 8);
	__atomic_fetch_add(owners, 1, __ATOMIC_SEQ_CST);
}

static SCISetFetcherFn sSCIOriginalSetFetcher = NULL;

static void SCISetFetcherCapture(void *self, SCIRawSharedPtr *fetcher, bool flag) {
	if (fetcher && fetcher->ptr) {
		sSCICapturedFetcher = *fetcher;
		sSCICapturedForManager = self;
		sSCICaptureCount++;
		SCIPinSharedPtr(*fetcher);
	}
	if (sSCIOriginalSetFetcher) sSCIOriginalSetFetcher(self, fetcher, flag);
}

void SCIInstallMobileConfigFetcherCaptureIfNeeded(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		struct rebinding r = {
			kSCISetFetcherSymbol,
			(void *)SCISetFetcherCapture,
			(void **)&sSCIOriginalSetFetcher
		};
		rebind_symbols(&r, 1);
	});
}

/// Reinstalls the captured fetcher on `manager`. Returns a human-readable result.
static NSString *SCIReinstallCapturedFetcher(void *manager) {
	if (!manager) return @"no manager pointer";
	if (!sSCICapturedFetcher.ptr) {
		return [NSString stringWithFormat:
			@"no fetcher captured yet (setFetcher seen %lu times).\nThe capture hook only fires "
			@"when the app installs a fetcher — relaunch with the tweak loaded and try again.",
			(unsigned long)sSCICaptureCount];
	}
	SCISetFetcherFn fn = sSCIOriginalSetFetcher ?: SCIResolveSetFetcher();
	if (!fn) return @"setFetcher symbol unavailable";

	NSString *reason = nil;
	if (!SCIManagerPointerLooksSafe(manager, &reason)) {
		return [NSString stringWithFormat:@"refusing to call setFetcher: %@", reason];
	}

	SCIRawSharedPtr copy = sSCICapturedFetcher;
	SCIPinSharedPtr(copy);   // the callee's copy takes its own reference
	@try {
		fn(manager, &copy, true);
	} @catch (id exception) {
		return [NSString stringWithFormat:@"setFetcher exception: %@", exception];
	}
	return [NSString stringWithFormat:@"fetcher %p reinstalled on manager %p%@",
		copy.ptr, manager,
		(sSCICapturedForManager && sSCICapturedForManager != manager)
			? @" (manager changed since capture)" : @""];
}

#pragma mark - Mapping file discovery

static NSArray<NSURL *> *SCIMappingSearchRoots(id holder) {
	NSMutableArray<NSURL *> *roots = [NSMutableArray array];
	NSFileManager *fm = NSFileManager.defaultManager;

	NSString *containerPath = SCIStringIvar(holder, "_containerPath");
	if (containerPath.length) {
		NSURL *base = [NSURL fileURLWithPath:containerPath];
		[roots addObject:base];
		[roots addObject:[base URLByAppendingPathComponent:@"mobileconfig"]];
	}

	// The holder's containerPath moved between builds (app-local
	// Documents/AppGroup/Documents on one, the shared group container on
	// another), so every known layout is searched rather than just the current
	// containerPath — otherwise an existing file reads as "not found".
	NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.burbn.instagram"];
	if (group) {
		NSURL *groupDocs = [group URLByAppendingPathComponent:@"Documents"];
		[roots addObject:groupDocs];
		[roots addObject:[groupDocs URLByAppendingPathComponent:@"mobileconfig"]];
	}

	NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
	if (documents) {
		[roots addObject:[documents URLByAppendingPathComponent:@"mobileconfig"]];
		NSURL *mirrored = [documents URLByAppendingPathComponent:@"AppGroup/Documents"];
		[roots addObject:mirrored];
		[roots addObject:[mirrored URLByAppendingPathComponent:@"mobileconfig"]];
	}

	NSURL *library = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
	if (library) [roots addObject:[library URLByAppendingPathComponent:@"mobileconfig"]];

	return roots;
}

static NSURL *SCIFindMappingFile(id holder) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSURL *newest = nil;
	NSDate *newestDate = nil;

	for (NSURL *root in SCIMappingSearchRoots(holder)) {
		NSURL *direct = [root URLByAppendingPathComponent:@"id_name_mapping.json"];
		NSArray<NSURL *> *candidates = @[direct];

		NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:root
									  includingPropertiesForKeys:@[NSURLContentModificationDateKey]
														 options:0
														   error:nil];
		NSMutableArray<NSURL *> *all = [candidates mutableCopy];
		for (NSURL *child in children) {
			if (![child.lastPathComponent hasSuffix:@".data"]) continue;
			[all addObject:[child URLByAppendingPathComponent:@"id_name_mapping.json"]];
		}

		for (NSURL *candidate in all) {
			if (![fm fileExistsAtPath:candidate.path]) continue;
			NSDate *modified = nil;
			[candidate getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
			if (!newest || (modified && [modified compare:newestDate ?: NSDate.distantPast] == NSOrderedDescending)) {
				newest = candidate;
				newestDate = modified ?: NSDate.date;
			}
		}
	}
	return newest;
}

static NSString *SCIDescribeMappingFile(NSURL *url) {
	if (!url) return @"id_name_mapping.json not found yet";

	NSError *error = nil;
	NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
	if (!data) return [NSString stringWithFormat:@"%@\nunreadable: %@", url.path, error.localizedDescription];

	id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
	if (![parsed isKindOfClass:NSArray.class]) {
		return [NSString stringWithFormat:@"%@\n%.1f KB — not a JSON array (%@)",
			url.path, data.length / 1024.0, error.localizedDescription ?: @"unexpected root"];
	}

	NSArray *entries = parsed;
	NSUInteger params = 0;
	NSUInteger named = 0;
	for (id entry in entries) {
		if (![entry isKindOfClass:NSString.class]) continue;
		NSArray<NSString *> *parts = [entry componentsSeparatedByString:@":"];
		if (parts.count >= 2 && parts[1].length) named++;
		if (parts.count > 2) params += (parts.count - 2) / 2;
	}

	NSDate *modified = nil;
	[url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];

	return [NSString stringWithFormat:
		@"%@\n%.1f KB — %lu configs (%lu named), %lu params\nmodified: %@",
		url.path, data.length / 1024.0,
		(unsigned long)entries.count, (unsigned long)named, (unsigned long)params,
		modified ?: @"unknown"];
}

static SCIIdNameMapUnit SCIIdNameMapSelectedUnitForSummary(void) {
	NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:@"sci_idnamemap_unit"];
	if ([raw isEqualToString:@"admin"]) return SCIIdNameMapUnitAdmin;
	if ([raw isEqualToString:@"sessionless"]) return SCIIdNameMapUnitSessionless;
	return SCIIdNameMapUnitCurrentSession;
}

#pragma mark - Implementation

@implementation SCIIdNameMapGenerator

+ (NSString *)nameForUnit:(SCIIdNameMapUnit)unit {
	switch (unit) {
		case SCIIdNameMapUnitAdmin:       return @"admin (kMobileConfigAdminId)";
		case SCIIdNameMapUnitSessionless: return @"sessionless";
		case SCIIdNameMapUnitCurrentSession:
		default:                          return @"current session";
	}
}

+ (void)load {
	// Must be rebound before Instagram installs its fetcher at startup.
	SCIInstallMobileConfigFetcherCaptureIfNeeded();
}

+ (NSString *)wiringState {
	SCIInstallMobileConfigFetcherCaptureIfNeeded();
	NSMutableString *report = [NSMutableString string];

	Class globalCls = NSClassFromString(@"FBMobileConfigFBTGlobalSessionManager");
	if (!globalCls) return @"FBMobileConfigFBTGlobalSessionManager: class not loaded";

	id global = SCIGlobalSessionManager();
	[report appendFormat:@"sharedInstance: %@\n", global ? @"ok" : @"nil / ABI mismatch"];
	if (!global) return report;

	SCIParamListSyncFn fn = SCIResolveParamListSync();
	[report appendFormat:@"updateConfigsWithParamsListSynchronously: %@\n",
		fn ? @"exported (dlsym ok)" : @"not exported (local symbol) — holder path only"];
	[report appendFormat:@"setFetcher: %@\n",
		(sSCIOriginalSetFetcher || SCIResolveSetFetcher()) ? @"resolved" : @"unavailable"];
	NSString *pending = SCIBreadcrumbPending();
	if (pending) {
		[report appendFormat:@"⚠︎ last attempt did not finish: %@\n"
			@"   the app went down inside that call — see \"Request mode\" below\n", pending];
	}
	[report appendFormat:@"fetcher captured: %@ (setFetcher seen %lu×)\n\n",
		sSCICapturedFetcher.ptr ? [NSString stringWithFormat:@"%p", sSCICapturedFetcher.ptr] : @"none",
		(unsigned long)sSCICaptureCount];

	SCIIdNameMapUnit units[] = {
		SCIIdNameMapUnitCurrentSession,
		SCIIdNameMapUnitAdmin,
		SCIIdNameMapUnitSessionless,
	};

	for (int i = 0; i < 3; i++) {
		SCIIdNameMapUnit unit = units[i];
		[report appendFormat:@"— %@ —\n", [self nameForUnit:unit]];

		id holder = SCIHolderForUnit(unit);
		if (!holder) {
			[report appendString:@"holder: nil\n\n"];
			continue;
		}

		Class holderClass = object_getClass(holder);
		Method reload = class_getInstanceMethod(holderClass, NSSelectorFromString(@"reload:"));
		Method sync = class_getInstanceMethod(holderClass,
			NSSelectorFromString(@"syncConfigsAndMayUpdateManager:syncFetchTimeout:"));

		BOOL reloadOK = SCIEncodingIs(reload, "q24@0:8d16");
		BOOL syncOK = SCIEncodingHasPrefixAndSuffix(sync,
			"q40@0:8{shared_ptr<mobileconfig::FBMobileConfigManager>", "d32");

		id fetcherSetter = SCICallObjectGetter(holder, @"fetcherSetter");
		id creator = SCICallObjectGetter(holder, @"contextManagerCreator");
		id fbtManager = SCICallObjectGetter(holder, @"mcFbtManager");

		NSString *detail = nil;
		void *rawManager = SCIRawManagerPointer(holder, &detail);

		[report appendFormat:@"holder: %@\n", NSStringFromClass(holderClass)];
		[report appendFormat:@"containerPath: %@\n", SCIStringIvar(holder, "_containerPath") ?: @"nil"];
		[report appendFormat:@"fbLocale: %@\n", SCIStringIvar(holder, "_fbLocale") ?: @"nil"];
		[report appendFormat:@"reload: %@\n", reloadOK ? @"q24@0:8d16" : SCIEncodingOf(reload)];
		[report appendFormat:@"sync: %@\n", syncOK ? @"verified" : SCIEncodingOf(sync)];
		[report appendFormat:@"contextManagerCreator: %@\n", creator ? @"set" : @"NIL"];
		[report appendFormat:@"fetcherSetter: %@\n", fetcherSetter ? @"set" : @"NIL (this is the wiring gap)"];
		[report appendFormat:@"mcFbtManager: %@\n", fbtManager ? NSStringFromClass(object_getClass(fbtManager)) : @"nil"];
		if (rawManager) {
			NSString *safety = nil;
			BOOL safe = SCIManagerPointerLooksSafe(rawManager, &safety);
			[report appendFormat:@"manager ptr: %p via %@\n", rawManager, detail ?: @"?"];
			[report appendFormat:@"object check: %@ %@\n\n", safe ? @"PASS" : @"FAIL", safety ?: @""];
		} else {
			[report appendFormat:@"manager ptr: %@\n\n", detail ?: @"unresolved"];
		}
	}

	[report appendFormat:@"mapping file:\n%@", SCIDescribeMappingFile(SCIFindMappingFile(SCIHolderForUnit(SCIIdNameMapUnitCurrentSession)))];
	return report;
}

+ (NSString *)rebindFetcherForUnit:(SCIIdNameMapUnit)unit {
	id holder = SCIHolderForUnit(unit);
	if (!holder) return [NSString stringWithFormat:@"%@: holder nil", [self nameForUnit:unit]];

	id fetcherSetter = SCICallObjectGetter(holder, @"fetcherSetter");
	if (!fetcherSetter) {
		NSString *detail = nil;
		void *rawManager = SCIRawManagerPointer(holder, &detail);
		return [NSString stringWithFormat:
			@"%@: _fetcherSetter is nil.\nThis holder was built without a fetcher setter AND without a "
			@"contextManagerCreator, so no reload can ever rebind one — the FBT init-params path that "
			@"carries those blocks is not the one this app uses.\n\nThat is fine: the param-list entry "
			@"point is exported, so Generate calls it directly on the live manager instead.\n\nmanager: %@",
			[self nameForUnit:unit],
			rawManager ? [NSString stringWithFormat:@"%p via %@", rawManager, detail] : (detail ?: @"unresolved")];
	}

	NSString *detail = nil;
	void *rawManager = SCIRawManagerPointer(holder, &detail);
	if (!rawManager) {
		return [NSString stringWithFormat:@"%@: fetcherSetter set, but no live manager (%@)",
			[self nameForUnit:unit], detail ?: @"unresolved"];
	}

	// The setter block owns the manager->fetcher install. Its signature is
	// opaque to us, so it is invoked through the OEM sync path below rather
	// than being called blind with a guessed argument list.
	return [NSString stringWithFormat:
		@"%@: fetcherSetter set, manager %p live.\nUse \"Reload + rebind\" so the OEM holder "
		@"re-runs contextManagerCreator + fetcherSetter itself.",
		[self nameForUnit:unit], rawManager];
}

+ (NSString *)reinstallFetcherForUnit:(SCIIdNameMapUnit)unit {
	SCIInstallMobileConfigFetcherCaptureIfNeeded();
	id holder = SCIHolderForUnit(unit);
	if (!holder) return [NSString stringWithFormat:@"%@: holder nil", [self nameForUnit:unit]];
	NSString *detail = nil;
	void *rawManager = SCIRawManagerPointer(holder, &detail);
	if (!rawManager) return [NSString stringWithFormat:@"%@: %@", [self nameForUnit:unit], detail ?: @"no manager"];
	return SCIReinstallCapturedFetcher(rawManager);
}

+ (NSString *)reloadUnit:(SCIIdNameMapUnit)unit timeout:(double)timeout {
	id holder = SCIHolderForUnit(unit);
	if (!holder) return [NSString stringWithFormat:@"%@: holder nil", [self nameForUnit:unit]];

	Class holderClass = object_getClass(holder);
	SEL reloadSel = NSSelectorFromString(@"reload:");
	Method reload = class_getInstanceMethod(holderClass, reloadSel);
	if (!SCIEncodingIs(reload, "q24@0:8d16")) {
		return [NSString stringWithFormat:@"%@: reload: ABI=%@ (expected q24@0:8d16)",
			[self nameForUnit:unit], SCIEncodingOf(reload)];
	}

	long long result = 0;
	@try {
		result = ((long long (*)(id, SEL, double))objc_msgSend)(holder, reloadSel, timeout);
	} @catch (id exception) {
		return [NSString stringWithFormat:@"%@: reload: exception %@", [self nameForUnit:unit], exception];
	}
	return [NSString stringWithFormat:@"%@: reload:(%.1f) -> %lld", [self nameForUnit:unit], timeout, result];
}

+ (void)generateForUnit:(SCIIdNameMapUnit)unit
				timeout:(double)timeout
				   mode:(int)mode
			 completion:(void (^)(NSString *))completion {

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableString *report = [NSMutableString string];
		[report appendFormat:@"unit: %@\ntimeout: %.1fs   mode: %d\n\n",
			[self nameForUnit:unit], timeout, mode];

		id holder = SCIHolderForUnit(unit);
		if (!holder) {
			[report appendFormat:
				@"holder: nil.\nFBMobileConfigFBTGlobalSessionManager only sets up the holders the "
				@"app actually initialises. On this build just the current-session holder exists, so "
				@"%@ has nothing behind it. Pick \"Current session\" — the admin table needs an admin "
				@"unit manager that this app never creates.",
				[self nameForUnit:unit]];
			dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
			return;
		}

		Class holderClass = object_getClass(holder);
		SEL syncSel = NSSelectorFromString(@"syncConfigsAndMayUpdateManager:syncFetchTimeout:");
		Method sync = class_getInstanceMethod(holderClass, syncSel);
		if (!SCIEncodingHasPrefixAndSuffix(sync,
				"q40@0:8{shared_ptr<mobileconfig::FBMobileConfigManager>", "d32")) {
			[report appendFormat:@"syncConfigsAndMayUpdateManager: ABI=%@\nRefusing to call.",
				SCIEncodingOf(sync)];
			dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
			return;
		}

		// A hand-placed mapping (e.g. the Android table copied into the App
		// Group) makes "the file exists" meaningless. Move it aside first: if
		// nothing reappears, the framework definitively did not write, and the
		// backup is restored so nothing is lost.
		NSFileManager *fm = NSFileManager.defaultManager;
		NSURL *before = SCIFindMappingFile(holder);
		NSURL *backup = nil;
		if (before) {
			backup = [before.URLByDeletingLastPathComponent URLByAppendingPathComponent:
				[NSString stringWithFormat:@"id_name_mapping.pre-%.0f.json", NSDate.date.timeIntervalSince1970]];
			NSError *moveError = nil;
			if ([fm moveItemAtURL:before toURL:backup error:&moveError]) {
				[report appendFormat:@"existing mapping moved aside:\n  %@\n\n", backup.lastPathComponent];
			} else {
				backup = nil;
				[report appendFormat:@"could not move existing mapping aside (%@) — a stale file may "
					@"be reported below\n\n", moveError.localizedDescription];
			}
		}

		// This build's holder reports contextManagerCreator = nil and
		// fetcherSetter = nil, so the OEM cannot rebind a fetcher for us. The
		// param-list entry point is exported though, so the direct call on the
		// live manager is the primary path and the holder sync is secondary.
		id creator = SCICallObjectGetter(holder, @"contextManagerCreator");
		id fetcherSetter = SCICallObjectGetter(holder, @"fetcherSetter");
		[report appendFormat:@"contextManagerCreator: %@   fetcherSetter: %@\n\n",
			creator ? @"set" : @"nil", fetcherSetter ? @"set" : @"nil"];

		// Step 1 — resolve the live C++ manager before anything is torn down.
		NSString *detail = nil;
		void *rawManager = SCIRawManagerPointer(holder, &detail);
		[report appendFormat:@"1. manager: %@\n",
			rawManager ? [NSString stringWithFormat:@"%p via %@", rawManager, detail] : (detail ?: @"unresolved")];

		// Step 2 — reinstall the captured fetcher. Without a fetcher the manager
		// has nothing to send the request with and the call below returns
		// instantly having done nothing.
		[report appendFormat:@"2. %@\n", SCIReinstallCapturedFetcher(rawManager)];

		// Step 3 — param-list request in the requested mode. This is the call
		// that makes FBMobileConfigStorageManager::persistExtraData write names.
		// The elapsed time is the tell: a few milliseconds means it no-opped,
		// a real request blocks for a network round trip.
		SCIParamListSyncFn fn = SCIResolveParamListSync();
		BOOL paramListRan = NO;
		NSString *safety = nil;
		BOOL safe = SCIManagerPointerLooksSafe(rawManager, &safety);
		[report appendFormat:@"3. object check: %@\n", safety ?: @"unknown"];

		if (fn && safe) {
			NSDate *started = NSDate.date;
			SCIBreadcrumbBegin([NSString stringWithFormat:@"param-list mode %d, timeout %d", mode, (int)timeout]);
			@try {
				fn(rawManager, (int)timeout, mode);
				paramListRan = YES;
				[report appendFormat:@"4. updateConfigsWithParamsListSynchronously(%d, %d) — returned after %.0f ms\n",
					(int)timeout, mode, [NSDate.date timeIntervalSinceDate:started] * 1000.0];
			} @catch (id exception) {
				[report appendFormat:@"4. param-list exception: %@\n", exception];
			}
			SCIBreadcrumbEnd();
		} else if (!fn) {
			[report appendString:@"4. param-list symbol not exported — skipped\n"];
		} else {
			[report appendString:@"4. skipped — the object check above did not pass\n"];
		}

		// Step 3 — only rebuild through the holder when the OEM actually has the
		// blocks to rebind with; otherwise a reload would drop the manager we
		// just used and gain nothing.
		if (creator || fetcherSetter) {
			[report appendFormat:@"5. %@\n", [self reloadUnit:unit timeout:timeout]];
			@try {
				SCIRawSharedPtr null = {NULL, NULL};
				long long syncResult = ((long long (*)(id, SEL, SCIRawSharedPtr, double))objc_msgSend)(
					holder, syncSel, null, timeout);
				[report appendFormat:@"   syncConfigsAndMayUpdateManager(null, %.1f) -> %lld\n", timeout, syncResult];
			} @catch (id exception) {
				[report appendFormat:@"   sync exception: %@\n", exception];
			}
		} else if (!paramListRan) {
			[report appendString:@"5. holder has neither block and the direct call did not run — "
				@"nothing left to drive.\n"];
		} else {
			[report appendString:@"5. holder rebuild skipped (no creator/setter to rebind with)\n"];
		}

		// Step 5 — the framework persists asynchronously; poll for a brand new file.
		NSURL *after = nil;
		for (int i = 0; i < 20; i++) {
			[NSThread sleepForTimeInterval:0.5];
			after = SCIFindMappingFile(holder);
			if (after && (!backup || ![after.path isEqualToString:backup.path])) break;
			after = nil;
		}

		if (after) {
			[report appendFormat:@"\n6. FRAMEWORK WROTE A NEW FILE\n%@", SCIDescribeMappingFile(after)];
			if (backup) [report appendFormat:@"\n\nprevious file kept as %@", backup.lastPathComponent];
		} else {
			if (backup) {
				NSError *restoreError = nil;
				NSURL *original = [backup.URLByDeletingLastPathComponent
					URLByAppendingPathComponent:@"id_name_mapping.json"];
				if ([fm moveItemAtURL:backup toURL:original error:&restoreError]) {
					[report appendString:@"\n6. nothing was written — previous file restored.\n"];
				} else {
					[report appendFormat:@"\n6. nothing was written and the restore failed (%@).\n"
						@"Your file is still at %@\n", restoreError.localizedDescription, backup.lastPathComponent];
				}
			} else {
				[report appendString:@"\n6. nothing was written.\n"];
			}
			[report appendString:
				@"\nRead step 2 and the elapsed time in step 3: no captured fetcher, or a param-list "
				@"call that returned in a few milliseconds, both mean no request left the device."];
		}

		dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
	});
}

+ (NSURL *)mappingFileURL {
	NSURL *url = SCIFindMappingFile(SCIHolderForUnit(SCIIdNameMapUnitCurrentSession));
	if (!url) url = SCIFindMappingFile(SCIHolderForUnit(SCIIdNameMapUnitAdmin));
	if (!url) url = SCIFindMappingFile(nil);
	return url;
}

+ (NSString *)wiringSummary {
	SCIInstallMobileConfigFetcherCaptureIfNeeded();
	if (!SCIGlobalSessionManager()) return SCILocalized(@"unavailable");
	id holder = SCIHolderForUnit(SCIIdNameMapSelectedUnitForSummary());
	if (!holder) return SCILocalized(@"no session");
	NSString *detail = nil;
	if (!SCIRawManagerPointer(holder, &detail)) return SCILocalized(@"no manager");
	if (!SCIResolveParamListSync()) return SCILocalized(@"blocked");
	NSString *safety = nil;
	if (!SCIManagerPointerLooksSafe(SCIRawManagerPointer(holder, NULL), &safety)) {
		return SCILocalized(@"unsafe");
	}
	if (!sSCICapturedFetcher.ptr) return SCILocalized(@"no fetcher");
	if (SCIBreadcrumbPending()) return SCILocalized(@"last run crashed");
	return SCILocalized(@"ready");
}

+ (NSString *)shortStatus {
	NSURL *url = [self mappingFileURL];
	if (!url) return SCILocalized(@"none");
	NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
	if (!data) return SCILocalized(@"unreadable");
	id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if (![parsed isKindOfClass:NSArray.class]) return SCILocalized(@"invalid");
	NSNumberFormatter *f = [NSNumberFormatter new];
	f.numberStyle = NSNumberFormatterDecimalStyle;
	return [NSString stringWithFormat:SCILocalized(@"%@ configs"),
		[f stringFromNumber:@([(NSArray *)parsed count])]];
}

+ (NSString *)mappingFileState {
	return SCIDescribeMappingFile([self mappingFileURL]);
}

@end
