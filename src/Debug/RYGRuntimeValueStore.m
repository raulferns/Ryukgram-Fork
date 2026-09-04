#import "RYGRuntimeValueStore.h"
#import <objc/runtime.h>
#import <substrate.h>
#include <string.h>

NSString *const RYGRuntimeValueOverridesKey = @"ryg_runtime_typed_value_overrides_v1";

static NSString *const kRYGValueClassKey = @"class";
static NSString *const kRYGValueSelectorKey = @"selector";
static NSString *const kRYGValueMetaKey = @"meta";
static NSString *const kRYGValueTypeKey = @"type";
static NSString *const kRYGValuePayloadKey = @"value";
static NSString *const kRYGValueKindKey = @"kind";
static NSString *const kRYGNestedKindKey = @"__ryg_kind";
static NSString *const kRYGNestedValueKey = @"__ryg_value";

@interface RYGRuntimeValueHookDescriptor : NSObject
@property(nonatomic, copy) NSString *uid;
@property(nonatomic, assign) SEL selector;
@property(nonatomic, assign) IMP original;
@property(nonatomic, assign) char typeCode;
@end
@implementation RYGRuntimeValueHookDescriptor @end

static NSMutableDictionary<NSString *, NSDictionary *> *gRYGRuntimeValueOverrides;
static NSMutableDictionary<NSString *, RYGRuntimeValueHookDescriptor *> *gRYGRuntimeValueHooks;
static NSObject *gRYGRuntimeValueLock;
static dispatch_once_t gRYGRuntimeValueOnce;

NSString *RYGRuntimeValueNormalizedType(NSString *typeCode) {
    if (!typeCode.length) return @"";
    const char *cursor = typeCode.UTF8String;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    return *cursor ? [NSString stringWithFormat:@"%c", *cursor] : @"";
}

BOOL RYGRuntimeValueSelectorIsSafeGetter(NSString *selectorName) {
    if (!selectorName.length || [selectorName containsString:@":"]) return NO;
    static NSSet<NSString *> *unsafe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsafe = [NSSet setWithArray:@[
            @"alloc", @"init", @"new", @"dealloc", @"finalize", @"copy", @"mutableCopy",
            @"retain", @"release", @"autorelease", @"retainCount", @"zone", @"class",
            @"superclass", @"self", @"hash", @"description", @"debugDescription", @"isProxy"
        ]];
    });
    return ![unsafe containsObject:selectorName];
}

NSString *RYGRuntimeValueTypeName(NSString *typeCode) {
    NSString *type = RYGRuntimeValueNormalizedType(typeCode);
    if (!type.length) return nil;
    switch ([type characterAtIndex:0]) {
        case 'B': return @"BOOL";
        case 'c': return @"char/BOOL";
        case 'C': return @"uint8";
        case 's': return @"int16";
        case 'S': return @"uint16";
        case 'i': return @"int32";
        case 'I': return @"uint32";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"int64";
        case 'Q': return @"uint64";
        case 'f': return @"float";
        case 'd': return @"double";
        case '@': return @"object";
        default: return nil;
    }
}

BOOL RYGRuntimeValueTypeIsSupported(NSString *typeCode) { return RYGRuntimeValueTypeName(typeCode) != nil; }
BOOL RYGRuntimeValueTypeIsBoolean(NSString *typeCode) {
    NSString *type = RYGRuntimeValueNormalizedType(typeCode);
    return [type isEqualToString:@"B"] || [type isEqualToString:@"c"];
}
BOOL RYGRuntimeValueTypeIsSignedInteger(NSString *typeCode) {
    return [@[@"s", @"i", @"l", @"q"] containsObject:RYGRuntimeValueNormalizedType(typeCode)];
}
BOOL RYGRuntimeValueTypeIsUnsignedInteger(NSString *typeCode) {
    return [@[@"C", @"S", @"I", @"L", @"Q"] containsObject:RYGRuntimeValueNormalizedType(typeCode)];
}
BOOL RYGRuntimeValueTypeIsFloatingPoint(NSString *typeCode) {
    NSString *type = RYGRuntimeValueNormalizedType(typeCode);
    return [type isEqualToString:@"f"] || [type isEqualToString:@"d"];
}
BOOL RYGRuntimeValueTypeIsObject(NSString *typeCode) {
    return [RYGRuntimeValueNormalizedType(typeCode) isEqualToString:@"@"]; // Objective-C object ABI
}

static id RYGRuntimeValueEncodeNested(id value);
static id RYGRuntimeValueDecodeNested(id value);

static id RYGRuntimeValueEncodeNested(id value) {
    if (!value || value == NSNull.null) return @{kRYGNestedKindKey:@"nil"};
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSURL.class])
        return @{kRYGNestedKindKey:@"url", kRYGNestedValueKey:[(NSURL *)value absoluteString] ?: @""};
    if ([value isKindOfClass:NSData.class])
        return @{kRYGNestedKindKey:@"data", kRYGNestedValueKey:[(NSData *)value base64EncodedStringWithOptions:0] ?: @""};
    if ([value isKindOfClass:NSDate.class])
        return @{kRYGNestedKindKey:@"date", kRYGNestedValueKey:@([(NSDate *)value timeIntervalSince1970])};
    if ([value isKindOfClass:NSSet.class]) {
        NSMutableArray *encoded = [NSMutableArray array];
        for (id item in [(NSSet *)value allObjects])
            [encoded addObject:RYGRuntimeValueEncodeNested(item) ?: @{kRYGNestedKindKey:@"nil"}];
        return @{kRYGNestedKindKey:@"set", kRYGNestedValueKey:encoded};
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *encoded = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value)
            [encoded addObject:RYGRuntimeValueEncodeNested(item) ?: @{kRYGNestedKindKey:@"nil"}];
        return encoded;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *encoded = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            (void)stop;
            NSString *stringKey = [key isKindOfClass:NSString.class] ? key : [key description];
            if (stringKey.length)
                encoded[stringKey] = RYGRuntimeValueEncodeNested(object) ?: @{kRYGNestedKindKey:@"nil"};
        }];
        return encoded;
    }
    return nil;
}

static id RYGRuntimeValueDecodeNested(id value) {
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *decoded = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id item in (NSArray *)value) [decoded addObject:RYGRuntimeValueDecodeNested(item) ?: NSNull.null];
        return decoded;
    }
    if (![value isKindOfClass:NSDictionary.class]) return value;
    NSString *kind = value[kRYGNestedKindKey];
    id payload = value[kRYGNestedValueKey];
    if ([kind isEqualToString:@"nil"]) return nil;
    if ([kind isEqualToString:@"url"]) return [NSURL URLWithString:[payload description] ?: @""];
    if ([kind isEqualToString:@"data"])
        return [[NSData alloc] initWithBase64EncodedString:[payload description] ?: @"" options:0];
    if ([kind isEqualToString:@"date"]) return [NSDate dateWithTimeIntervalSince1970:[payload doubleValue]];
    if ([kind isEqualToString:@"set"]) {
        id decoded = RYGRuntimeValueDecodeNested(payload);
        return [decoded isKindOfClass:NSArray.class] ? [NSSet setWithArray:decoded] : [NSSet set];
    }
    NSMutableDictionary *decoded = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
        (void)stop;
        decoded[key] = RYGRuntimeValueDecodeNested(object) ?: NSNull.null;
    }];
    return decoded;
}

static NSDictionary *RYGRuntimeValueEncodedObjectSpec(id value) {
    if (!value || value == NSNull.null) return @{kRYGValueKindKey:@"nil", kRYGValuePayloadKey:@""};
    id encoded = RYGRuntimeValueEncodeNested(value);
    if (!encoded) return nil;
    NSString *kind = @"foundation";
    if ([value isKindOfClass:NSString.class]) kind = @"string";
    else if ([value isKindOfClass:NSNumber.class]) kind = @"number";
    else if ([value isKindOfClass:NSArray.class]) kind = @"array";
    else if ([value isKindOfClass:NSDictionary.class]) kind = @"dictionary";
    else if ([value isKindOfClass:NSSet.class]) kind = @"set";
    else if ([value isKindOfClass:NSURL.class]) kind = @"url";
    else if ([value isKindOfClass:NSData.class]) kind = @"data";
    else if ([value isKindOfClass:NSDate.class]) kind = @"date";
    return @{kRYGValueKindKey:kind, kRYGValuePayloadKey:encoded};
}

static id RYGRuntimeValueDecodeSpec(NSDictionary *spec) {
    if (![spec isKindOfClass:NSDictionary.class]) return nil;
    if (![spec[kRYGValueTypeKey] isEqualToString:@"@"]) return spec[kRYGValuePayloadKey];
    if ([spec[kRYGValueKindKey] isEqualToString:@"nil"]) return nil;
    return RYGRuntimeValueDecodeNested(spec[kRYGValuePayloadKey]);
}

static void RYGRuntimeValueEnsureStorage(void) {
    dispatch_once(&gRYGRuntimeValueOnce, ^{
        gRYGRuntimeValueLock = [NSObject new];
        gRYGRuntimeValueHooks = [NSMutableDictionary dictionary];
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:RYGRuntimeValueOverridesKey];
        gRYGRuntimeValueOverrides = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    });
}

static void RYGRuntimeValuePersistLocked(void) {
    if (gRYGRuntimeValueOverrides.count)
        [NSUserDefaults.standardUserDefaults setObject:gRYGRuntimeValueOverrides.copy forKey:RYGRuntimeValueOverridesKey];
    else
        [NSUserDefaults.standardUserDefaults removeObjectForKey:RYGRuntimeValueOverridesKey];
}

NSString *RYGRuntimeValueUID(NSString *className, NSString *selectorName, BOOL classMethod) {
    if (!className.length || !selectorName.length) return @"";
    return [NSString stringWithFormat:@"%@|%@|%@", className, classMethod ? @"class" : @"instance", selectorName];
}

static NSDictionary *RYGRuntimeValueSpec(NSString *className, NSString *selectorName, BOOL classMethod) {
    RYGRuntimeValueEnsureStorage();
    NSString *uid = RYGRuntimeValueUID(className, selectorName, classMethod);
    @synchronized (gRYGRuntimeValueLock) { return gRYGRuntimeValueOverrides[uid]; }
}

BOOL RYGRuntimeValueHasOverride(NSString *className, NSString *selectorName, BOOL classMethod) {
    return RYGRuntimeValueSpec(className, selectorName, classMethod) != nil;
}

id RYGRuntimeValueOverride(NSString *className, NSString *selectorName, BOOL classMethod) {
    return RYGRuntimeValueDecodeSpec(RYGRuntimeValueSpec(className, selectorName, classMethod));
}

void RYGRuntimeValueSetOverride(NSString *className, NSString *selectorName, BOOL classMethod,
                                NSString *typeCode, id value) {
    NSString *uid = RYGRuntimeValueUID(className, selectorName, classMethod);
    NSString *type = RYGRuntimeValueNormalizedType(typeCode);
    if (!uid.length || !RYGRuntimeValueTypeIsSupported(type)) return;
    NSMutableDictionary *spec = [@{kRYGValueClassKey:className, kRYGValueSelectorKey:selectorName,
                                   kRYGValueMetaKey:@(classMethod), kRYGValueTypeKey:type} mutableCopy];
    if ([type isEqualToString:@"@"]) {
        NSDictionary *objectSpec = RYGRuntimeValueEncodedObjectSpec(value);
        if (!objectSpec) return;
        [spec addEntriesFromDictionary:objectSpec];
    } else {
        if (![value isKindOfClass:NSNumber.class]) return;
        spec[kRYGValuePayloadKey] = value;
    }
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) {
        gRYGRuntimeValueOverrides[uid] = spec.copy;
        RYGRuntimeValuePersistLocked();
    }
}

void RYGRuntimeValueClearOverride(NSString *className, NSString *selectorName, BOOL classMethod) {
    NSString *uid = RYGRuntimeValueUID(className, selectorName, classMethod);
    if (!uid.length) return;
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) {
        [gRYGRuntimeValueOverrides removeObjectForKey:uid];
        RYGRuntimeValuePersistLocked();
    }
}

NSArray<NSDictionary<NSString *, id> *> *RYGRuntimeValueAllOverrideSpecs(void) {
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) {
        return [gRYGRuntimeValueOverrides.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSString *a = [NSString stringWithFormat:@"%@ %@", left[kRYGValueClassKey] ?: @"", left[kRYGValueSelectorKey] ?: @""];
            NSString *b = [NSString stringWithFormat:@"%@ %@", right[kRYGValueClassKey] ?: @"", right[kRYGValueSelectorKey] ?: @""];
            return [a localizedCaseInsensitiveCompare:b];
        }];
    }
}

static id RYGRuntimeValueForcedValue(RYGRuntimeValueHookDescriptor *descriptor, BOOL *hasOverride) {
    if (hasOverride) *hasOverride = NO;
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) {
        NSDictionary *spec = gRYGRuntimeValueOverrides[descriptor.uid];
        if (!spec) return nil;
        if (hasOverride) *hasOverride = YES;
        return RYGRuntimeValueDecodeSpec(spec);
    }
}

static IMP RYGRuntimeValueReplacement(RYGRuntimeValueHookDescriptor *descriptor) {
    switch (descriptor.typeCode) {
        case 'B': return imp_implementationWithBlock(^BOOL(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v boolValue] : (descriptor.original ? ((BOOL(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : NO); });
        case 'c': return imp_implementationWithBlock(^signed char(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v charValue] : (descriptor.original ? ((signed char(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'C': return imp_implementationWithBlock(^unsigned char(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v unsignedCharValue] : (descriptor.original ? ((unsigned char(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 's': return imp_implementationWithBlock(^short(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v shortValue] : (descriptor.original ? ((short(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'S': return imp_implementationWithBlock(^unsigned short(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v unsignedShortValue] : (descriptor.original ? ((unsigned short(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'i': return imp_implementationWithBlock(^int(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v intValue] : (descriptor.original ? ((int(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'I': return imp_implementationWithBlock(^unsigned int(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v unsignedIntValue] : (descriptor.original ? ((unsigned int(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'l': return imp_implementationWithBlock(^long(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v longValue] : (descriptor.original ? ((long(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'L': return imp_implementationWithBlock(^unsigned long(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v unsignedLongValue] : (descriptor.original ? ((unsigned long(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'q': return imp_implementationWithBlock(^long long(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v longLongValue] : (descriptor.original ? ((long long(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'Q': return imp_implementationWithBlock(^unsigned long long(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v unsignedLongLongValue] : (descriptor.original ? ((unsigned long long(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0); });
        case 'f': return imp_implementationWithBlock(^float(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v floatValue] : (descriptor.original ? ((float(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0.0f); });
        case 'd': return imp_implementationWithBlock(^double(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? [v doubleValue] : (descriptor.original ? ((double(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : 0.0); });
        case '@': return imp_implementationWithBlock(^id(id receiver) { BOOL has=NO; id v=RYGRuntimeValueForcedValue(descriptor,&has); return has ? v : (descriptor.original ? ((id(*)(id,SEL))descriptor.original)(receiver,descriptor.selector) : nil); });
        default: return NULL;
    }
}

BOOL RYGRuntimeValueInstallHook(NSString *className, NSString *selectorName, BOOL classMethod,
                                NSString *typeCode) {
    NSString *uid = RYGRuntimeValueUID(className, selectorName, classMethod);
    NSString *type = RYGRuntimeValueNormalizedType(typeCode);
    if (!uid.length || !RYGRuntimeValueTypeIsSupported(type) ||
        !RYGRuntimeValueSelectorIsSafeGetter(selectorName)) return NO;
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) { if (gRYGRuntimeValueHooks[uid]) return YES; }

    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return NO;
    char rawType[64] = {0};
    method_getReturnType(method, rawType, sizeof(rawType));
    if (![RYGRuntimeValueNormalizedType([NSString stringWithUTF8String:rawType]) isEqualToString:type]) return NO;

    RYGRuntimeValueHookDescriptor *descriptor = [RYGRuntimeValueHookDescriptor new];
    descriptor.uid = uid;
    descriptor.selector = selector;
    descriptor.typeCode = (char)[type characterAtIndex:0];
    IMP replacement = RYGRuntimeValueReplacement(descriptor);
    if (!replacement) return NO;
    Class target = classMethod ? object_getClass(cls) : cls;
    IMP original = NULL;
    MSHookMessageEx(target, selector, replacement, &original);
    if (!original || original == replacement) return NO;
    descriptor.original = original;
    @synchronized (gRYGRuntimeValueLock) { gRYGRuntimeValueHooks[uid] = descriptor; }
    return YES;
}

BOOL RYGRuntimeValueHookIsInstalled(NSString *className, NSString *selectorName, BOOL classMethod) {
    NSString *uid = RYGRuntimeValueUID(className, selectorName, classMethod);
    RYGRuntimeValueEnsureStorage();
    @synchronized (gRYGRuntimeValueLock) { return gRYGRuntimeValueHooks[uid] != nil; }
}

NSUInteger RYGRuntimeValueReinstallPersistedHooks(void) {
    NSUInteger installed = 0;
    for (NSDictionary *spec in RYGRuntimeValueAllOverrideSpecs()) {
        NSString *className = spec[kRYGValueClassKey];
        NSString *selector = spec[kRYGValueSelectorKey];
        NSString *type = spec[kRYGValueTypeKey];
        BOOL meta = [spec[kRYGValueMetaKey] boolValue];
        if (RYGRuntimeValueInstallHook(className, selector, meta, type)) installed++;
    }
    return installed;
}

NSString *RYGRuntimeValueRead(NSString *className, NSString *selectorName, BOOL classMethod,
                              id instance, id *rawValue) {
    if (rawValue) *rawValue = nil;
    if (!RYGRuntimeValueSelectorIsSafeGetter(selectorName)) return @"blocked lifecycle selector";
    Class cls = NSClassFromString(className) ?: objc_getClass(className.UTF8String);
    SEL selector = NSSelectorFromString(selectorName);
    id receiver = classMethod ? ([cls respondsToSelector:selector] ? cls : nil)
                              : (instance && [instance isKindOfClass:cls] && [instance respondsToSelector:selector] ? instance : nil);
    if (!receiver) return classMethod ? @"exact receiver unavailable" : @"instance required";
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) return @"method unavailable";
    char rawType[64] = {0};
    method_getReturnType(method, rawType, sizeof(rawType));
    NSString *type = RYGRuntimeValueNormalizedType([NSString stringWithUTF8String:rawType]);
    IMP imp = [receiver methodForSelector:selector];
    if (!imp || !RYGRuntimeValueTypeIsSupported(type)) return @"unsupported ABI";
    @try {
        switch ([type characterAtIndex:0]) {
            case 'B': { BOOL v=((BOOL(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return v?@"YES":@"NO"; }
            case 'c': { signed char v=((signed char(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%d",(int)v]; }
            case 'C': { unsigned char v=((unsigned char(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%u",(unsigned)v]; }
            case 's': { short v=((short(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%d",(int)v]; }
            case 'S': { unsigned short v=((unsigned short(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%u",(unsigned)v]; }
            case 'i': { int v=((int(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%d",v]; }
            case 'I': { unsigned int v=((unsigned int(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%u",v]; }
            case 'l': { long v=((long(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%ld",v]; }
            case 'L': { unsigned long v=((unsigned long(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%lu",v]; }
            case 'q': { long long v=((long long(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%lld",v]; }
            case 'Q': { unsigned long long v=((unsigned long long(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%llu",v]; }
            case 'f': { float v=((float(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%.9g",v]; }
            case 'd': { double v=((double(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=@(v); return [NSString stringWithFormat:@"%.17g",v]; }
            case '@': { id v=((id(*)(id,SEL))imp)(receiver,selector); if(rawValue)*rawValue=v; if(!v)return @"nil"; NSString *d=[v description]?:@""; if(d.length>500)d=[[d substringToIndex:500]stringByAppendingString:@"…"]; return [NSString stringWithFormat:@"%@ · %@",NSStringFromClass([v class]),d]; }
            default: return @"unsupported ABI";
        }
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"exception %@: %@", exception.name ?: @"?", exception.reason ?: @"?"];
    }
}
