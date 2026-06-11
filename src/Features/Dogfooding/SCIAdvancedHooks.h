#import <Foundation/Foundation.h>

// Applies exactly the Advanced hook whose toggle changed.
// No constructor, no post-launch replay, no persisted-state sweep.
void SCIAdvancedHooksApplyForChangedKey(NSString *key, BOOL isOn);
