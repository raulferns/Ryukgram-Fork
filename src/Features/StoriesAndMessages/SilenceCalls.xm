// Silence incoming calls — audio + video, cold VoIP wakes too, all funnel
// through CallKit's reportNewIncomingCall.

#import "../../Utils.h"
#import <CallKit/CallKit.h>

%group SilenceCallsGroup

%hook CXProvider
- (void)reportNewIncomingCallWithUUID:(NSUUID *)uuid update:(CXCallUpdate *)update completion:(void (^)(NSError *))completion {
    if (![SCIUtils getBoolPref:@"sci_silence_calls"]) {
    	%orig;
    	return;
    }
    // Report "succeeded" so IG won't retry; call never reaches CallKit = no ring/UI.
    if (completion) completion(nil);
}
%end

%end

%ctor {
    if ([SCIUtils getBoolPref:@"sci_silence_calls"]) %init(SilenceCallsGroup);
}
