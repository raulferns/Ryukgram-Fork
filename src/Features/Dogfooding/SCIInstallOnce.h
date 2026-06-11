// SCIInstallOnce.h
//
// SCI-FIX 2026-06-11 (crash 433.0.283, EXC_BAD_ACCESS in a deferred GCD block).
//
// Single deterministic post-launch install point, replacing the ad-hoc
// `install(); dispatch_after(+1s); dispatch_after(+3s); dispatch_after(+6s); …`
// retry ladders that were scattered across the Dogfooding hooks.
//
// Why this is safer:
//   * No hooking during dyld static-init (%ctor runs before UIApplicationMain;
//     touching NSUserDefaults / ObjC class realization there can intercept reads
//     inside METARunPreApplicationMain and race the runtime).
//   * `UIApplicationDidBecomeActive` fires once the UI is built and the vast
//     majority of ObjC + eagerly-referenced Swift classes are realized.
//   * No timer source that can outlive a captured object → no message-to-freed.
//   * Idempotent: self-removing observer + internal guard, safe if the app
//     foreground/background-cycles.
//
// IMPORTANT: install blocks passed here MUST be pointer-safe (NSClassFromString +
// class_getInstanceMethod + MSHookMessageEx only). Do NOT message captured
// instances from inside — capture by class name and re-resolve.

#ifndef SCI_INSTALL_ONCE_H
#define SCI_INSTALL_ONCE_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static inline void SCIInstallOnceOnActive(void (^block)(void)) {
    if (!block) return;
    __block id tok = nil;
    __block BOOL ran = NO;
    tok = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        if (ran) return;
        ran = YES;
        if (tok) { [[NSNotificationCenter defaultCenter] removeObserver:tok]; tok = nil; }
        block();
    }];
}

#endif /* SCI_INSTALL_ONCE_H */
