#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const RYGRuntimeValueOverridesKey;

NSString *RYGRuntimeValueUID(NSString *className, NSString *selectorName, BOOL classMethod);
NSString *RYGRuntimeValueNormalizedType(NSString *typeCode);
NSString * _Nullable RYGRuntimeValueTypeName(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsSupported(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsBoolean(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsSignedInteger(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsUnsignedInteger(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsFloatingPoint(NSString *typeCode);
BOOL RYGRuntimeValueTypeIsObject(NSString *typeCode);
BOOL RYGRuntimeValueSelectorIsSafeGetter(NSString *selectorName);

BOOL RYGRuntimeValueHasOverride(NSString *className, NSString *selectorName, BOOL classMethod);
id _Nullable RYGRuntimeValueOverride(NSString *className, NSString *selectorName, BOOL classMethod);
void RYGRuntimeValueSetOverride(NSString *className, NSString *selectorName, BOOL classMethod,
                                NSString *typeCode, id _Nullable value);
void RYGRuntimeValueClearOverride(NSString *className, NSString *selectorName, BOOL classMethod);
NSArray<NSDictionary<NSString *, id> *> *RYGRuntimeValueAllOverrideSpecs(void);

BOOL RYGRuntimeValueInstallHook(NSString *className, NSString *selectorName, BOOL classMethod,
                                NSString *typeCode);
BOOL RYGRuntimeValueHookIsInstalled(NSString *className, NSString *selectorName, BOOL classMethod);
NSUInteger RYGRuntimeValueReinstallPersistedHooks(void);

NSString *RYGRuntimeValueRead(NSString *className, NSString *selectorName, BOOL classMethod,
                              id _Nullable instance, id _Nullable * _Nullable rawValue);

NS_ASSUME_NONNULL_END
