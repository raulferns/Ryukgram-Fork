#import "../../Utils.h"
#import "../../InstagramHeaders.h"

// Channels dms tab (header)
%hook IGDirectInboxHeaderSectionController
- (id)viewModel {
    id sciVM = %orig;
    if ([[sciVM title] isEqualToString:@"Suggested"]) {

        if ([SCIUtils getBoolPref:@"no_suggested_chats"]) {
            return nil;
        }

    }

    return sciVM;
}
%end

%ctor {
    %init(IGDirectInboxHeaderSectionController = NSClassFromString(@"_TtC32IGDirectInboxViewControllerSwift36IGDirectInboxHeaderSectionController") ?: NSClassFromString(@"IGDirectInboxHeaderSectionController"));
}
