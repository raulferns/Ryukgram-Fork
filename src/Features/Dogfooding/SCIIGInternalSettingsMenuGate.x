#import <UIKit/UIKit.h>
#import "../../Utils.h"

// Natural Instagram internal-settings gate.
// Validated against the supplied Instagram executable with ObjC metadata +
// Capstone disassembly:
//   _TtC17IGBugReporterMenu29IGBugReportMenuViewController
//   -initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:
//    entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:
//    showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:
// ABI/types: @92@0:8@16@24@32@40@48@56q64q72B80B84B88
// ivars: internalSettingsAvailabilityStatus @120, showInternalSettings @128,
//        showLoggedOutInternalSettings @129, showShakeToReportPreferenceToggle @130.
//
// We force only the documented BOOL visibility flags. The enum value is left as
// Instagram computed it, because the current dump exposes the enum/type name but
// not a stable ObjC class or public constructor for IGInternalSettingsAvailabilityStatus.

%group SCIIGInternalSettingsMenuGate

%hook IGBugReportMenuViewController

- (id)initWithDeviceSession:(id)deviceSession
                userSession:(id)userSession
          reliabilityLogging:(id)reliabilityLogging
                    navChain:(id)navChain
                    endpoint:(id)endpoint
                  entryPoint:(id)entryPoint
                       style:(long long)style
internalSettingsAvailabilityStatus:(long long)availabilityStatus
        showInternalSettings:(BOOL)showInternalSettings
showLoggedOutInternalSettings:(BOOL)showLoggedOutInternalSettings
showShakeToReportPreferenceToggle:(BOOL)showShakeToReportPreferenceToggle {
    if ([SCIUtils getBoolPref:@"sci_force_internal_settings_menu"]) {
        showInternalSettings = YES;
        showShakeToReportPreferenceToggle = YES;
        if ([SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
            showLoggedOutInternalSettings = YES;
        }
    }

    return %orig(deviceSession,
                 userSession,
                 reliabilityLogging,
                 navChain,
                 endpoint,
                 entryPoint,
                 style,
                 availabilityStatus,
                 showInternalSettings,
                 showLoggedOutInternalSettings,
                 showShakeToReportPreferenceToggle);
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![SCIUtils getBoolPref:@"sci_force_internal_settings_menu"] &&
            ![SCIUtils getBoolPref:@"sci_force_internal_settings_loggedout"]) {
            return;
        }
        %init(SCIIGInternalSettingsMenuGate);
    }
}
