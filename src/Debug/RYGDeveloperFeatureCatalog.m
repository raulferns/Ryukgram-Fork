#import "RYGDeveloperFeatureCatalog.h"
#import "RYGRuntimeBrowserEngine.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#include <stdlib.h>
#include <string.h>

NSNotificationName const RYGDeveloperFeatureCatalogDidUpdateNotification = @"RYGDeveloperFeatureCatalogDidUpdateNotification";
NSString *const RYGDeveloperFeatureCatalogSurfaceUserInfoKey = @"surface";

static atomic_uint_fast64_t gImageGeneration = 1;
static void RYGImageAdded(const struct mach_header *h, intptr_t s) { (void)h; (void)s; atomic_fetch_add(&gImageGeneration, 1); }

static const char *SkipQ(const char *t) { while (t && *t && strchr("rnNoORV", *t)) t++; return t; }
static RYGRuntimeArgumentKind ArgKind(Method m) {
    if (!m) return (RYGRuntimeArgumentKind)-1;
    char r[32]={0}; method_getReturnType(m,r,sizeof(r)); const char *rt=SkipQ(r);
    if (!rt || !strchr("BcC",*rt)) return (RYGRuntimeArgumentKind)-1;
    unsigned int n=method_getNumberOfArguments(m); if (n==2) return RYGRuntimeArgumentNone; if (n!=3) return (RYGRuntimeArgumentKind)-1;
    char a[64]={0}; method_getArgumentType(m,2,a,sizeof(a)); const char *at=SkipQ(a);
    if (at && *at=='@') return RYGRuntimeArgumentObject;
    if (at && (*at=='q'||*at=='Q')) return RYGRuntimeArgumentInteger;
    return (RYGRuntimeArgumentKind)-1;
}

static NSArray *Owners(RYGDeveloperRuntimeSurface s) {
    switch (s) {
        case RYGDeveloperRuntimeSurfacePrism: return @[@"IGBloksFollowButtonView",@"IGTableViewCell"];
        case RYGDeveloperRuntimeSurfaceLiquidGlass: return @[@"_TtC20IGLiquidGlassSwizzle26IGLiquidGlassSwizzleToggle",@"_TtC29IGLiquidGlassExperimentHelper33IGThrowbackChromeExperimentHelper",@"_TtC29IGLiquidGlassExperimentHelper39IGLiquidGlassNavigationExperimentHelper"];
        case RYGDeveloperRuntimeSurfaceStories: return @[@"_TtC27IGPersistentStoryTrayGating38IGPersistentStoryTrayGatingStaticFuncs",@"_TtC18IGNavConfiguration25IGHomecomingConfiguration",@"_TtC38IGStoryViewerRedesignExperimentHelpers38IGStoryViewerRedesignExperimentHelpers"];
        case RYGDeveloperRuntimeSurfaceBugReport: return @[@"_TtC17IGBugReporterMenu29IGBugReportMenuViewController"];
        default: return @[];
    }
}
static NSArray *ClassTokens(RYGDeveloperRuntimeSurface s) {
    switch (s) {
        case RYGDeveloperRuntimeSurfacePrism: return @[@"prism",@"igds",@"bslds",@"wordmark"];
        case RYGDeveloperRuntimeSurfaceLiquidGlass: return @[@"liquidglass",@"throwback",@"glass"];
        case RYGDeveloperRuntimeSurfaceStories: return @[@"storytray",@"storiestray",@"storygrid",@"storiesgrid",@"homecoming"];
        case RYGDeveloperRuntimeSurfaceConsumerSubs: return @[@"consumersubs",@"igplus",@"aura",@"subscription"];
        case RYGDeveloperRuntimeSurfaceInternalOnly: return @[@"internalonly",@"igonly",@"employee"];
        case RYGDeveloperRuntimeSurfaceDirectDogfood: return @[@"dogfood",@"dogfooding"];
        case RYGDeveloperRuntimeSurfaceBugReport: return @[@"bugreport",@"bugreporter",@"sandbox"];
        case RYGDeveloperRuntimeSurfaceSettingsRows: return @[@"settings",@"setting"];
    }
    return @[];
}
static NSArray *SelectorTokens(RYGDeveloperRuntimeSurface s) {
    switch (s) {
        case RYGDeveloperRuntimeSurfacePrism: return @[@"prism",@"wordmark",@"redesign",@"design"];
        case RYGDeveloperRuntimeSurfaceLiquidGlass: return @[@"glass",@"throwback",@"chrome",@"navigation"];
        case RYGDeveloperRuntimeSurfaceStories: return @[@"story",@"tray",@"grid",@"homecoming"];
        case RYGDeveloperRuntimeSurfaceConsumerSubs: return @[@"aura",@"plus",@"subscription",@"benefit"];
        case RYGDeveloperRuntimeSurfaceInternalOnly: return @[@"internal",@"employee",@"hidden",@"debug"];
        case RYGDeveloperRuntimeSurfaceDirectDogfood: return @[@"dogfood",@"assistant",@"internal"];
        case RYGDeveloperRuntimeSurfaceBugReport: return @[@"bug",@"report",@"sandbox",@"loggedout",@"internal"];
        case RYGDeveloperRuntimeSurfaceSettingsRows: return @[@"hidden",@"hide",@"show",@"visible",@"available",@"display"];
    }
    return @[];
}
static BOOL HasToken(NSString *v, NSArray *tokens) { NSString *l=v.lowercaseString?:@""; for (NSString *t in tokens) if ([l containsString:t]) return YES; return NO; }
static BOOL Noise(NSString *s) {
    if (!s.length || [RYGRuntimeBrowserEngine isStructuralNoiseSelectorName:s]) return YES;
    NSString *l=s.lowercaseString;
    static NSArray *fragments; static dispatch_once_t once;
    dispatch_once(&once,^{ fragments=@[@"canrespond",@"respondstoselector",@"isequal",@"iskindofclass",@"ismemberofclass",@"conformstoprotocol",@"methodforselector",@"debugdescription",@"description",@"retaincount",@"copywithzone",@"mutablecopywithzone",@"canperformaction"];} );
    for (NSString *f in fragments) if ([l containsString:f]) return YES;
    return NO;
}
static BOOL AppClass(Class c) {
    const char *raw=c?class_getImageName(c):NULL; if (!raw) return NO;
    NSString *p=[[NSString stringWithUTF8String:raw] stringByStandardizingPath]; NSString *b=NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    return [p isEqualToString:NSBundle.mainBundle.executablePath.stringByStandardizingPath] || [p hasPrefix:[b stringByAppendingString:@"/"]];
}
static void ScanClass(Class c, RYGDeveloperRuntimeSurface s, NSMutableDictionary *out) {
    if (!AppClass(c)) return; NSString *cn=NSStringFromClass(c)?:@""; BOOL classHit=HasToken(cn,ClassTokens(s));
    for (NSUInteger pass=0;pass<2;pass++) { Class owner=pass?object_getClass(c):c; unsigned int n=0; Method *ms=owner?class_copyMethodList(owner,&n):NULL;
        for (unsigned int i=0;ms&&i<n;i++) { RYGRuntimeArgumentKind k=ArgKind(ms[i]); if (k<0) continue; NSString *sn=NSStringFromSelector(method_getName(ms[i]))?:@"";
            if (Noise(sn)) continue; if (!HasToken(sn,SelectorTokens(s)) && !(classHit && HasToken(sn,@[@"enabled",@"available",@"visible",@"hidden",@"show",@"internal",@"debug",@"experiment"]))) continue;
            RYGRuntimeBoolMethod *r=[RYGRuntimeBoolMethod new]; r.className=cn; r.selectorName=sn; r.classMethod=pass!=0; r.argumentKind=k; const char *te=method_getTypeEncoding(ms[i]); r.typeEncoding=te?[NSString stringWithUTF8String:te]:@""; const char *im=class_getImageName(c); r.imagePath=im?[NSString stringWithUTF8String:im]:@"";
            out[[NSString stringWithFormat:@"%@|%@|%c|%@|%@",r.imagePath,r.className,r.classMethod?'+':'-',r.selectorName,r.typeEncoding]]=r;
        } if (ms) free(ms);
    }
}

@interface RYGDeveloperFeatureCatalog () { dispatch_queue_t _q; BOOL _started; NSMutableDictionary *_snap; NSMutableDictionary *_gen; NSMutableDictionary *_full; NSMutableSet *_busy; }
@end
@implementation RYGDeveloperFeatureCatalog
+ (instancetype)sharedCatalog { static id x; static dispatch_once_t once; dispatch_once(&once,^{x=[self new];}); return x; }
- (instancetype)init { if ((self=[super init])) { _q=dispatch_queue_create("com.ryukgram.devcatalog",DISPATCH_QUEUE_SERIAL); _snap=[NSMutableDictionary dictionary]; _gen=[NSMutableDictionary dictionary]; _full=[NSMutableDictionary dictionary]; _busy=[NSMutableSet set]; } return self; }
- (void)startIfNeeded { @synchronized(self){ if (_started) return; _started=YES; } _dyld_register_func_for_add_image(RYGImageAdded); for (NSInteger i=RYGDeveloperRuntimeSurfacePrism;i<=RYGDeveloperRuntimeSurfaceSettingsRows;i++) [self requestRefreshForSurface:(RYGDeveloperRuntimeSurface)i discoverAdditionalClasses:NO]; }
- (NSArray *)snapshotForSurface:(RYGDeveloperRuntimeSurface)s { @synchronized(self){ return _snap[@(s)]?:@[]; } }
- (BOOL)isRefreshingSurface:(RYGDeveloperRuntimeSurface)s { @synchronized(self){ return [_busy containsObject:@(s)]; } }
- (void)requestRefreshForSurface:(RYGDeveloperRuntimeSurface)s discoverAdditionalClasses:(BOOL)discover {
    [self startIfNeeded]; NSNumber *key=@(s); uint64_t g=atomic_load(&gImageGeneration);
    @synchronized(self){ BOOL fresh=[_gen[key] unsignedLongLongValue]==g; BOOL fullFresh=[_full[key] unsignedLongLongValue]==g; if ((discover?fullFresh:fresh)||[_busy containsObject:key]) return; [_busy addObject:key]; }
    dispatch_async(_q,^{ NSMutableDictionary *rows=[NSMutableDictionary dictionary]; for (NSString *name in Owners(s)) { Class c=objc_lookUpClass(name.UTF8String); if(c) ScanClass(c,s,rows); }
        if (discover) { int total=objc_getClassList(NULL,0); Class __unsafe_unretained *classes=total>0?(__unsafe_unretained Class *)calloc((size_t)total,sizeof(Class)):NULL; if(classes){ int actual=objc_getClassList(classes,total); NSArray *tokens=ClassTokens(s); for(int i=0;i<actual;i++){ Class c=classes[i]; if(c&&AppClass(c)&&HasToken(NSStringFromClass(c)?:@"",tokens)) ScanClass(c,s,rows); } free(classes); } }
        NSArray *sorted=[rows.allValues sortedArrayUsingComparator:^NSComparisonResult(RYGRuntimeBoolMethod *a,RYGRuntimeBoolMethod *b){ NSComparisonResult r=[a.className localizedCaseInsensitiveCompare:b.className]; return r==NSOrderedSame?[a.selectorName localizedCaseInsensitiveCompare:b.selectorName]:r; }];
        @synchronized(self){ _snap[key]=sorted?:@[]; _gen[key]=@(g); if(discover)_full[key]=@(g); [_busy removeObject:key]; }
        dispatch_async(dispatch_get_main_queue(),^{ [NSNotificationCenter.defaultCenter postNotificationName:RYGDeveloperFeatureCatalogDidUpdateNotification object:self userInfo:@{RYGDeveloperFeatureCatalogSurfaceUserInfoKey:key}]; });
    });
}
@end
