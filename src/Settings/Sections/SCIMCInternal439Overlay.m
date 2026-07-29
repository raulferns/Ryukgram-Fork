// SCIMCInternal439Overlay.m
// Merges build-verified Instagram(16) MobileConfig aliases into the embedded
// mapping without replacing the large generated catalogue. The overlay is
// stored in __DATA,__idmap439 and applied after every SCIMCOverrideStore reload.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <os/log.h>
#import <string.h>

#define SCI439MAPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] IG439Map " fmt, ##__VA_ARGS__)

static NSData *SCI439EmbeddedMappingData(void) {
    Dl_info info;
    if (!dladdr((const void *)&SCI439EmbeddedMappingData, &info) || !info.dli_fbase) {
        return nil;
    }

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)info.dli_fbase;
    unsigned long size = 0;
    uint8_t *bytes = getsectiondata(header, "__DATA", "__idmap439", &size);
    return bytes && size ? [NSData dataWithBytes:bytes length:size] : nil;
}

static id SCI439ObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static void SCI439SetObjectIvar(id object, const char *name, id value) {
    if (!object || !name) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (ivar) object_setIvar(object, ivar, value);
}

static void SCI439ApplyMappingOverlay(id store) {
    NSData *data = SCI439EmbeddedMappingData();
    if (!data.length || !store) return;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return;

    NSMutableDictionary<NSNumber *, NSString *> *names =
        SCI439ObjectIvar(store, "_names");
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, NSString *> *> *params =
        SCI439ObjectIvar(store, "_params");
    NSMutableDictionary<NSNumber *, NSString *> *normalized =
        SCI439ObjectIvar(store, "_norm");
    if (![names isKindOfClass:NSMutableDictionary.class] ||
        ![params isKindOfClass:NSMutableDictionary.class]) return;

    NSUInteger inserted = 0;
    for (NSString *entry in (NSArray *)json) {
        if (![entry isKindOfClass:NSString.class]) continue;
        NSArray<NSString *> *parts = [entry componentsSeparatedByString:@":"];
        if (parts.count < 2) continue;

        NSNumber *configID = @([parts[0] longLongValue]);
        NSString *configName = parts[1];
        if (configName.length) names[configID] = configName;

        NSMutableDictionary<NSNumber *, NSString *> *configParams = params[configID];
        if (![configParams isKindOfClass:NSMutableDictionary.class]) {
            configParams = NSMutableDictionary.dictionary;
            params[configID] = configParams;
        }

        for (NSUInteger index = 2; index + 1 < parts.count; index += 2) {
            NSNumber *paramID = @([parts[index] longLongValue]);
            NSString *paramName = parts[index + 1];
            if (!paramName.length) continue;
            configParams[paramID] = paramName;
            inserted++;
        }
        [normalized removeObjectForKey:configID];
    }

    NSArray<NSNumber *> *ids =
        [names.allKeys sortedArrayUsingSelector:@selector(compare:)];
    SCI439SetObjectIvar(store, "_ids", ids);
    SCI439MAPLOG("merged %lu verified parameter aliases",
                 (unsigned long)inserted);
}

static void (*orig_SCI439StoreReload)(id, SEL) = NULL;
static void (*orig_SCI439ApplyInternalPreset)(id, SEL) = NULL;

static void SCI439StoreReload(id self, SEL _cmd) {
    if (orig_SCI439StoreReload) orig_SCI439StoreReload(self, _cmd);
    SCI439ApplyMappingOverlay(self);
}

static void SCI439ApplyInternalPreset(id self, SEL _cmd) {
    if (orig_SCI439ApplyInternalPreset) {
        orig_SCI439ApplyInternalPreset(self, _cmd);
    }

    SEL setState = sel_registerName("setState:forConfig:param:");
    if (![self respondsToSelector:setState]) return;

    // SCIMCOverrideON = 2. Only the two verified BOOL parameters are added to
    // the preset. MAISA is int64 and remains system-controlled until a concrete
    // functional variant is validated.
    ((void (*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
        self, setState, 2, 167, 308);
    ((void (*)(id, SEL, NSInteger, NSInteger, NSInteger))objc_msgSend)(
        self, setState, 2, 2698, 80342);
}

__attribute__((constructor))
static void SCI439MappingOverlayInit(void) {
    @autoreleasepool {
        Class cls = objc_getClass("SCIMCOverrideStore");
        if (!cls) {
            SCI439MAPLOG("SCIMCOverrideStore unavailable");
            return;
        }

        Method reload = class_getInstanceMethod(cls, sel_registerName("reload"));
        if (reload && strcmp(method_getTypeEncoding(reload), "v16@0:8") == 0) {
            MSHookMessageEx(cls, method_getName(reload), (IMP)SCI439StoreReload,
                            (IMP *)&orig_SCI439StoreReload);
        } else if (reload) {
            SCI439MAPLOG("skip reload ABI=%{public}s",
                         method_getTypeEncoding(reload) ?: "<nil>");
        }

        Method preset = class_getInstanceMethod(
            cls, sel_registerName("applyInternalPreset"));
        if (preset && strcmp(method_getTypeEncoding(preset), "v16@0:8") == 0) {
            MSHookMessageEx(cls, method_getName(preset),
                            (IMP)SCI439ApplyInternalPreset,
                            (IMP *)&orig_SCI439ApplyInternalPreset);
        } else if (preset) {
            SCI439MAPLOG("skip preset ABI=%{public}s",
                         method_getTypeEncoding(preset) ?: "<nil>");
        }
    }
}
