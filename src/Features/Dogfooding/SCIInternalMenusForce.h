#import <Foundation/Foundation.h>

// Applies the persisted Internal & Dogfood Menus runtime hooks for the current
// session. This must be called from an explicit settings toggle change after the
// app UI is available, never from %ctor/startup.
NSString *SCIInternalMenusForceApplyNow(void);
