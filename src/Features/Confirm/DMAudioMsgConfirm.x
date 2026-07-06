#import "../../Utils.h"

extern void sciMarkActiveThreadSeenOnInteract(void);

%hook IGDirectThreadViewVoiceController
- (void)voiceRecordViewController:(id)arg1 didRecordAudioClipWithURL:(id)arg2 waveform:(id)arg3 duration:(CGFloat)arg4 entryPoint:(NSInteger)arg5 aiVoiceEffectApplied:(id)arg6 aiVoiceEffectType:(id)arg7 sendButtonTypeTapped:(NSInteger)arg8 {
    if ([SCIUtils getBoolPref:@"voice_message_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
        	%orig;
        	sciMarkActiveThreadSeenOnInteract();
        } title:SCILocalized(@"Confirm voice messages")];
    } else {
        %orig;
        sciMarkActiveThreadSeenOnInteract();
    }
}
%end

// Demangled name: IGDirectAIVoiceUIKit.CompactBarContentView
%hook _TtC20IGDirectAIVoiceUIKitP33_5754F7617E0D924F9A84EFA352BBD29A21CompactBarContentView
- (void)didTapSend {
    if ([SCIUtils getBoolPref:@"voice_message_confirm"]) {
        [SCIUtils showConfirmation:^(void) {
        	%orig;
        	sciMarkActiveThreadSeenOnInteract();
        } title:SCILocalized(@"Confirm voice messages")];
    } else {
        %orig;
        sciMarkActiveThreadSeenOnInteract();
    }
}
%end
