#import "SCIInternalSettingsApplier.h"
#import "SCIDogfoodObjectRuntime.h"
#import "SCIInternalGatePrefs.h"
#import "SCIEmployeeDefaults.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

#define APLOG(fmt,...) os_log(OS_LOG_DEFAULT,"[SCIGate] Applier " fmt,##__VA_ARGS__)
static inline BOOL ON(NSString *k){ return [SCIInternalGatePrefs individualGateEnabledForKey:k]; }

@implementation SCIInternalSettingsApplier

// [session autofillInternalSettings] can return a cached instance whose
// sessionUserDefaults is nil. A fresh validated initWithUserSession: instance
// is preferred; the session property remains the final fallback.
+ (id)autofillInternalSettingsForSession:(id)session {
    if (!session) return nil;
    Class C = NSClassFromString(@"IGAutofillInternalSettings");
    if (!C) {
        C = NSClassFromString(
            @"_TtC33AutofillInternalSettingsInstagram26IGAutofillInternalSettings");
    }
    if (C) {
        SEL iwus = NSSelectorFromString(@"initWithUserSession:");
        id obj = [C alloc];
        if (obj && [obj respondsToSelector:iwus]) {
            id ais = nil;
            @try {
                ais = ((id(*)(id,SEL,id))objc_msgSend)(
                    obj, iwus, session);
            } @catch (id e) {
                APLOG("initWithUserSession: threw: %{public}@", e);
            }
            if (ais) {
                id sud = nil;
                @try {
                    sud = [ais valueForKey:@"sessionUserDefaults"];
                } @catch (__unused id e) {}
                APLOG("ais=ok sessionUserDefaults=%{public}s",
                      sud ? "populated" : "nil");
                if (!sud) {
                    SEL sp =
                        NSSelectorFromString(@"autofillInternalSettings");
                    if ([session respondsToSelector:sp]) {
                        @try {
                            ais = ((id(*)(id,SEL))objc_msgSend)(
                                session, sp);
                        } @catch (__unused id e) {}
                    }
                }
                return ais;
            }
        }
    }

    SEL selector = NSSelectorFromString(@"autofillInternalSettings");
    if ([session respondsToSelector:selector]) {
        @try {
            return ((id(*)(id,SEL))objc_msgSend)(
                session, selector);
        } @catch (__unused id e) {}
    }
    return nil;
}

+ (void)callVoid:(id)obj sel:(NSString *)selName {
    if (!obj) return;
    SEL selector = NSSelectorFromString(selName);
    if ([obj respondsToSelector:selector]) {
        @try {
            ((void(*)(id,SEL))objc_msgSend)(obj, selector);
        } @catch (__unused id e) {}
    }
}

+ (void)callBool:(id)obj sel:(NSString *)selName value:(BOOL)value {
    if (!obj) return;
    SEL selector = NSSelectorFromString(selName);
    if ([obj respondsToSelector:selector]) {
        @try {
            ((void(*)(id,SEL,BOOL))objc_msgSend)(
                obj, selector, value);
        } @catch (__unused id e) {}
    }
}

+ (NSString *)applyNow {
    NSMutableString *out = [NSMutableString string];
    id session = [SCIDogfoodObjectRuntime activeUserSession];

    [SCIEmployeeDefaults installHooksIfNeeded];
    BOOL employeeDefaultsEnabled = [SCIEmployeeDefaults enabled];
    if (employeeDefaultsEnabled) {
        [SCIEmployeeDefaults applyToStandardDefaults];
        if (session) {
            [SCIEmployeeDefaults applyToUserSession:session
                source:@"SCIInternalSettingsApplier.applyNow"];
            [out appendString:@"employeeDefaults=legacy explicit; "];
        } else {
            [out appendString:@"employeeDefaults=legacy standard only; "];
        }
    } else {
        [out appendString:@"employeeDefaults=disabled; "];
    }

    if (!session) {
        [out appendString:@"no session — open after login"];
        goto done;
    }

    {
        id ais = [self autofillInternalSettingsForSession:session];
        if (ais) {
            [self callBool:ais
                sel:@"setDebugFooterEnabledWithEnabled:"
                value:YES];
            [out appendString:@"debugFooter=ON; "];

            if (ON(@"sci_apply_force_bloks")) {
                [self callVoid:ais sel:@"setForceBloksExperienceOn"];
                [out appendString:@"bloks=ON; "];
            }
            if (ON(@"sci_apply_bloks_prefetch")) {
                [self callBool:ais
                    sel:@"setBloksPrefetchEnabledWithEnabled:"
                    value:YES];
                [out appendString:@"prefetch=ON; "];
            }
        } else {
            [out appendString:
                @"autofillInternalSettings unavailable; "];
        }
    }

    if (ON(@"sci_apply_liquidglass")) {
        // Liquid Glass has one owner: Tweak.x + Interface preferences. Do not
        // mutate the native singleton again from the internal settings applier.
        [out appendString:
            @"LiquidGlass=use Interface preferences (duplicate override skipped); "];
    }

done:
    [SCIDogfoodObjectRuntime noteAction:@"applyInternalSettingsNative"
        status:(session ? @"ok" : @"no-session")
        detail:out];
    APLOG("applyNow: %{public}@", out);
    return out.length ? out : @"nothing applied";
}

+ (void)scheduleAutoApplyIfEnabled {
    if (!ON(@"sci_apply_internal_native")) return;

    // One deterministic main-queue turn, not a timer/retry ladder.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([SCIDogfoodObjectRuntime activeUserSession]) {
            [SCIInternalSettingsApplier applyNow];
        }
    });
}

@end
