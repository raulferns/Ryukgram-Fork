/*
 * SCITier2EmployeeGate.m
 *
 * Tier-2 employee identity for the current Instagram GraphQL model.
 *
 * Binary evidence (Instagram(16) + FBSharedFramework(14)):
 *
 *   IGBaseUser(IGUserIsEmployeeOrTestUserFragment)
 *     -asIGUserIsEmployeeOrTestUserFragmentImmutableModel
 *
 *   IGUserIsEmployeeOrTestUserFragment decision helper
 *     1. accepts either of the two known test-account ID ranges;
 *     2. asks -accountBadges whether it contains NSNumber value 0;
 *     3. only when both checks fail, reads a separate MobileConfig fallback.
 *
 * The helper has ten direct consumers, including Internal Settings. The old
 * `_ig_is_employee` / `_ig_is_employee_or_test_user` DATA descriptors and
 * their ADRP/LDR/B leaf thunks are absent from this build, so the previous
 * descriptor scanner could never install.
 *
 * Sideload-safe implementation:
 *
 *   - hooks only verified Objective-C object getters with MSHookMessageEx;
 *   - never writes Instagram or FBSharedFramework __TEXT;
 *   - never scans the Objective-C class list or every MobileConfig read;
 *   - preserves the original accountBadges collection and appends only @0;
 *   - discovers generated Pando fragment classes causally from the exact
 *     IGBaseUser fragment producers, not from names guessed at launch;
 *   - keeps installed hooks dormant and returns the untouched original value
 *     whenever the toggle is disabled.
 */

#import "SCITier2EmployeeGate.h"
#import "../../Utils.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <substrate.h>

#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

#define T2LOG(fmt, ...) \
    os_log(OS_LOG_DEFAULT, "[SCITier2] " fmt, ##__VA_ARGS__)

typedef id (*Tier2ObjectGetter)(id, SEL);

typedef struct {
    __unsafe_unretained Class cls;
    SEL selector;
    IMP original;
} Tier2GetterHook;

static atomic_bool gTier2Enabled = ATOMIC_VAR_INIT(false);
static atomic_bool gTier2Installed = ATOMIC_VAR_INIT(false);
static atomic_bool gTier2Installing = ATOMIC_VAR_INIT(false);

static NSMutableSet<NSValue *> *gTier2BadgeHookedClasses;
static NSMutableSet<NSString *> *gTier2ProducerHookKeys;

static SEL Tier2AccountBadgesSelector(void) {
    return sel_registerName("accountBadges");
}

static SEL Tier2EmployeeFragmentSelector(void) {
    return sel_registerName("asIGUserIsEmployeeOrTestUserFragment");
}

static SEL Tier2EmployeeImmutableFragmentSelector(void) {
    return sel_registerName(
        "asIGUserIsEmployeeOrTestUserFragmentImmutableModel"
    );
}

static SEL Tier2InternalSettingsFragmentSelector(void) {
    return sel_registerName(
        "asIGInternalSettingsAvailabilityFragmentImmutableModel"
    );
}

static void Tier2EnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTier2BadgeHookedClasses = [NSMutableSet set];
        gTier2ProducerHookKeys = [NSMutableSet set];
    });
}

static BOOL Tier2MethodIsObjectGetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char returnType[32] = {0};
    char selfType[32] = {0};
    char selectorType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 0, selfType, sizeof(selfType));
    method_getArgumentType(method, 1, selectorType, sizeof(selectorType));

    return returnType[0] == '@' &&
           selfType[0] == '@' &&
           selectorType[0] == ':';
}

static NSNumber *Tier2EmployeeBadge(void) {
    static NSNumber *badge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ badge = @0; });
    return badge;
}

static BOOL Tier2CollectionContainsBadge(id collection, id badge) {
    if (!collection || !badge ||
        ![collection respondsToSelector:@selector(containsObject:)]) {
        return NO;
    }

    @try {
        return [collection containsObject:badge];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id Tier2CollectionByAddingEmployeeBadge(id original) {
    NSNumber *badge = Tier2EmployeeBadge();
    if (!original) return @[badge];
    if (Tier2CollectionContainsBadge(original, badge)) return original;

    @try {
        if ([original isKindOfClass:NSArray.class]) {
            return [(NSArray *)original arrayByAddingObject:badge];
        }

        if ([original isKindOfClass:NSSet.class]) {
            return [(NSSet *)original setByAddingObject:badge];
        }

        if ([original isKindOfClass:NSOrderedSet.class]) {
            NSMutableOrderedSet *copy =
                [(NSOrderedSet *)original mutableCopy];
            [copy addObject:badge];
            return copy.copy;
        }

        if ([original respondsToSelector:@selector(mutableCopy)]) {
            id copy = [original mutableCopy];
            if ([copy respondsToSelector:@selector(addObject:)]) {
                [copy addObject:badge];
                return [copy respondsToSelector:@selector(copy)]
                    ? [copy copy]
                    : copy;
            }
        }
    } @catch (NSException *exception) {
        T2LOG("accountBadges copy failed class=%{public}@ reason=%{public}@",
              NSStringFromClass([original class]),
              exception.reason ?: @"unknown");
    }

    // An unknown collection type is left untouched. Returning an arbitrary
    // NSArray here could violate a generated Pando model's concrete contract.
    return original;
}

static BOOL Tier2InstallBadgeHookForClass(Class cls, NSString *source);
static BOOL Tier2InstallProducerHook(Class cls, SEL selector, NSString *source);

static void Tier2ObserveFragmentCandidate(id candidate, NSString *source) {
    if (!candidate ||
        !atomic_load_explicit(&gTier2Enabled, memory_order_acquire)) {
        return;
    }

    Class cls = object_getClass(candidate);
    if (!cls) return;

    // A direct employee fragment exposes accountBadges. A parent fragment,
    // such as IGInternalSettingsAvailabilityFragmentImpl, exposes the nested
    // asIGUserIsEmployeeOrTestUserFragment producer instead. Trying both is
    // bounded to this one causally returned class and performs no class scan.
    Tier2InstallBadgeHookForClass(cls, source);
    Tier2InstallProducerHook(
        cls,
        Tier2EmployeeFragmentSelector(),
        @"nested employee/test-user fragment"
    );
    Tier2InstallProducerHook(
        cls,
        Tier2EmployeeImmutableFragmentSelector(),
        @"nested immutable employee/test-user fragment"
    );
}

static BOOL Tier2InstallBadgeHookForClass(Class cls, NSString *source) {
    if (!cls) return NO;
    Tier2EnsureState();

    SEL selector = Tier2AccountBadgesSelector();
    Method method = class_getInstanceMethod(cls, selector);
    if (!Tier2MethodIsObjectGetter(method)) return NO;

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
    @synchronized (gTier2BadgeHookedClasses) {
        if ([gTier2BadgeHookedClasses containsObject:key]) return YES;
        [gTier2BadgeHookedClasses addObject:key];
    }

    Tier2GetterHook *descriptor = calloc(1, sizeof(*descriptor));
    if (!descriptor) {
        @synchronized (gTier2BadgeHookedClasses) {
            [gTier2BadgeHookedClasses removeObject:key];
        }
        return NO;
    }

    descriptor->cls = cls;
    descriptor->selector = selector;

    IMP replacement = imp_implementationWithBlock(^id(id receiver) {
        Tier2ObjectGetter original =
            (Tier2ObjectGetter)descriptor->original;
        id badges = original
            ? original(receiver, descriptor->selector)
            : nil;

        if (!atomic_load_explicit(
                &gTier2Enabled,
                memory_order_acquire)) {
            return badges;
        }
        return Tier2CollectionByAddingEmployeeBadge(badges);
    });

    MSHookMessageEx(
        cls,
        selector,
        replacement,
        &descriptor->original
    );
    if (!descriptor->original) {
        @synchronized (gTier2BadgeHookedClasses) {
            [gTier2BadgeHookedClasses removeObject:key];
        }
        imp_removeBlock(replacement);
        free(descriptor);
        return NO;
    }

    T2LOG("accountBadges hooked class=%{public}@ source=%{public}@",
          NSStringFromClass(cls),
          source ?: @"unknown");
    return YES;
}

static BOOL Tier2InstallProducerHook(
    Class cls,
    SEL selector,
    NSString *source
) {
    if (!cls || !selector) return NO;
    Tier2EnsureState();

    Method method = class_getInstanceMethod(cls, selector);
    if (!Tier2MethodIsObjectGetter(method)) return NO;

    NSString *key = [NSString stringWithFormat:
        @"%p:%s", (void *)cls, sel_getName(selector)];
    @synchronized (gTier2ProducerHookKeys) {
        if ([gTier2ProducerHookKeys containsObject:key]) return YES;
        [gTier2ProducerHookKeys addObject:key];
    }

    Tier2GetterHook *descriptor = calloc(1, sizeof(*descriptor));
    if (!descriptor) {
        @synchronized (gTier2ProducerHookKeys) {
            [gTier2ProducerHookKeys removeObject:key];
        }
        return NO;
    }

    descriptor->cls = cls;
    descriptor->selector = selector;

    IMP replacement = imp_implementationWithBlock(^id(id receiver) {
        Tier2ObjectGetter original =
            (Tier2ObjectGetter)descriptor->original;
        id fragment = original
            ? original(receiver, descriptor->selector)
            : nil;

        if (atomic_load_explicit(
                &gTier2Enabled,
                memory_order_acquire)) {
            Tier2ObserveFragmentCandidate(
                fragment,
                [NSString stringWithUTF8String:
                    sel_getName(descriptor->selector)] ?: source
            );
        }
        return fragment;
    });

    MSHookMessageEx(
        cls,
        selector,
        replacement,
        &descriptor->original
    );
    if (!descriptor->original) {
        @synchronized (gTier2ProducerHookKeys) {
            [gTier2ProducerHookKeys removeObject:key];
        }
        imp_removeBlock(replacement);
        free(descriptor);
        return NO;
    }

    T2LOG("fragment producer hooked class=%{public}@ selector=%{public}s source=%{public}@",
          NSStringFromClass(cls),
          sel_getName(selector),
          source ?: @"unknown");
    return YES;
}

static void Tier2ClearLegacyEmployeeMasters(void) {
    NSArray<NSString *> *keys = @[
        @"sci_employee_internal",
        @"sci_force_mc_session_employee_gate",
        @"sci_force_ig_internal_employee",
        @"sci_force_ig_is_employee",
        @"sci_force_employee_defaults_persist",
    ];

    for (NSString *key in keys) {
        [SCIUtils setPref:@NO forKey:key];
    }
}

static void Tier2InstallNow(void) {
    NSCAssert(
        NSThread.isMainThread,
        @"Tier-2 initial installation must run on the main thread"
    );

    if (!atomic_load_explicit(&gTier2Enabled, memory_order_acquire) ||
        atomic_load_explicit(&gTier2Installed, memory_order_acquire)) {
        return;
    }

    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &gTier2Installing,
            &expected,
            true,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return;
    }

    @autoreleasepool {
        Class baseUser = objc_getClass("IGBaseUser");
        if (!baseUser) {
            T2LOG("IGBaseUser is not loaded; retrying on next foreground");
            atomic_store_explicit(
                &gTier2Installing,
                false,
                memory_order_release
            );
            return;
        }

        const BOOL baseBadges = Tier2InstallBadgeHookForClass(
            baseUser,
            @"IGBaseUser canonical accountBadges"
        );
        const BOOL directFragment = Tier2InstallProducerHook(
            baseUser,
            Tier2EmployeeImmutableFragmentSelector(),
            @"IGBaseUser employee/test-user fragment"
        );
        const BOOL internalSettingsParent = Tier2InstallProducerHook(
            baseUser,
            Tier2InternalSettingsFragmentSelector(),
            @"IGBaseUser internal-settings availability fragment"
        );

        // Some model implementations expose the non-immutable producer on
        // IGBaseUser itself. Its absence is valid; generated parent fragments
        // are hooked causally by the two verified producers above.
        const BOOL directRuntimeFragment = Tier2InstallProducerHook(
            baseUser,
            Tier2EmployeeFragmentSelector(),
            @"IGBaseUser runtime employee/test-user fragment"
        );

        const BOOL installed =
            baseBadges && directFragment && internalSettingsParent;
        atomic_store_explicit(
            &gTier2Installed,
            installed,
            memory_order_release
        );

        T2LOG("install baseBadges=%d directFragment=%d internalParent=%d runtimeFragment=%d active=%d",
              baseBadges,
              directFragment,
              internalSettingsParent,
              directRuntimeFragment,
              installed);
    }

    atomic_store_explicit(
        &gTier2Installing,
        false,
        memory_order_release
    );
}

static void Tier2ScheduleInstallOnMainThread(void) {
    if (!atomic_load_explicit(&gTier2Enabled, memory_order_acquire)) {
        return;
    }

    if (NSThread.isMainThread) {
        Tier2InstallNow();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            Tier2InstallNow();
        });
    }
}

void SCITier2EmployeeGateSetEnabled(BOOL enabled) {
    if (enabled) Tier2ClearLegacyEmployeeMasters();
    atomic_store_explicit(
        &gTier2Enabled,
        enabled,
        memory_order_release
    );

    if (enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState ==
                UIApplicationStateActive) {
                Tier2InstallNow();
            }
        });
    }
}

BOOL SCITier2EmployeeGateEnabled(void) {
    return atomic_load_explicit(&gTier2Enabled, memory_order_acquire);
}

BOOL SCITier2EmployeeGateInstalled(void) {
    return atomic_load_explicit(&gTier2Installed, memory_order_acquire);
}

__attribute__((constructor))
static void Tier2Bootstrap(void) {
    @autoreleasepool {
        const BOOL enabled =
            [SCIUtils getBoolPref:@"sci_tier2_employee_internal"];
        if (enabled) Tier2ClearLegacyEmployeeMasters();
        atomic_store_explicit(
            &gTier2Enabled,
            enabled,
            memory_order_release
        );

        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(
                        __unused NSNotification *notification
                    ) {
            Tier2ScheduleInstallOnMainThread();
        }];
    }
}
