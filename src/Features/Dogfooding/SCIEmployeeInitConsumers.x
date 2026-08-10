// SCIEmployeeInitConsumers.x
//
// Employee/test-user identity that is consumed as an *initializer argument*
// (and cached inside the callee) rather than read back through an isEmployee
// getter. SCIEmployeeInternal.x already forces every identity GETTER; this
// file closes the remaining gap: loggers/stores that snapshot the flag at
// construction time and never re-read a hookable getter afterwards.
//
// This mirrors the Facebook tweak's RCDMobileConfigParams.init / FBLoom
// argument rewriting. Those FB classes do not exist on IG; the flag is
// carried into these IG consumers instead. All four classes are plain
// Objective-C in the Instagram image (not Swift-mangled), so a Logos %hook
// on the initializer is the correct, single-owner mechanism — no other file
// hooks these selectors, so there is no MSHookMessageEx chain to compete with.
//
// Every class / selector / ABI below was dumped from the shipped Instagram
// executable and matched exactly before being written here:
//
//   IGSeenStateStore
//     -initWithDependencies:isEmployee:                         @28@0:8@16B24
//   IGSeenStateLogger
//     -initWithIsEmployee:analyticsLogger:                      @28@0:8B16@20
//   IGLeadGenAnalyticsLogger
//     -initWithAnalyticsLogger:userFbidV2:isEmployee:           @36@0:8@16q24B32
//   IGFeedRequestQPLogger
//     -initWithShouldIncludeRequestId:instancesManager:
//        persistentFailureTracker:isDeferredNppTapEnabled:
//        isCacheLoadEnabled:isEmployee:isTestUser:              @52@0:8B16@20@28B36B40B44B48
//
// Scope: these rewrite a client-side identity argument only; nothing here
// mints or replaces a server-side internal token.

#import "../../Utils.h"
#import "SCIInternalGatePrefs.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

#define ICLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SCIGate] EmployeeInitConsumers " fmt, ##__VA_ARGS__)

// Same master switch as SCIEmployeeInternal.x's identity getters, so the
// argument rewriting turns on and off together with the getter forcing.
static inline BOOL ICEmployeeOn(void) {
    return [SCIInternalGatePrefs employeeInternalMasterEnabled] ||
           [SCIUtils getBoolPref:@"sci_internal_menus"];
}

// isTestUser is a superset of employee: force it whenever employee is forced,
// or when the dedicated test-user pref is set.
static inline BOOL ICTestUserOn(void) {
    return ICEmployeeOn() ||
           [SCIUtils getBoolPref:@"sci_force_ig_is_test_user"];
}

%group SCIEmployeeInitConsumers

%hook IGSeenStateStore
- (id)initWithDependencies:(id)dependencies isEmployee:(BOOL)isEmployee {
    return %orig(dependencies, ICEmployeeOn() ? YES : isEmployee);
}
%end

%hook IGSeenStateLogger
- (id)initWithIsEmployee:(BOOL)isEmployee analyticsLogger:(id)analyticsLogger {
    return %orig(ICEmployeeOn() ? YES : isEmployee, analyticsLogger);
}
%end

%hook IGLeadGenAnalyticsLogger
- (id)initWithAnalyticsLogger:(id)analyticsLogger
                   userFbidV2:(long long)userFbidV2
                   isEmployee:(BOOL)isEmployee {
    return %orig(analyticsLogger, userFbidV2, ICEmployeeOn() ? YES : isEmployee);
}
%end

%hook IGFeedRequestQPLogger
- (id)initWithShouldIncludeRequestId:(BOOL)shouldIncludeRequestId
                    instancesManager:(id)instancesManager
            persistentFailureTracker:(id)persistentFailureTracker
             isDeferredNppTapEnabled:(BOOL)isDeferredNppTapEnabled
                  isCacheLoadEnabled:(BOOL)isCacheLoadEnabled
                          isEmployee:(BOOL)isEmployee
                          isTestUser:(BOOL)isTestUser {
    return %orig(shouldIncludeRequestId,
                 instancesManager,
                 persistentFailureTracker,
                 isDeferredNppTapEnabled,
                 isCacheLoadEnabled,
                 ICEmployeeOn() ? YES : isEmployee,
                 ICTestUserOn() ? YES : isTestUser);
}
%end

%end // group SCIEmployeeInitConsumers

// These are plain ObjC classes realized through normal dispatch; a gated
// %init at construction time is safe (no MSHookMessageEx, no late-image sweep
// needed). Only initialise when the feature is enabled so stock builds pay
// nothing.
%ctor {
    @autoreleasepool {
        if (ICEmployeeOn()) {
            %init(SCIEmployeeInitConsumers);
            ICLOG("init-arg consumer hooks installed (master=%d testUser=%d)",
                  ICEmployeeOn(), ICTestUserOn());
        }
    }
}
