#import <UIKit/UIKit.h>
#import "../../Utils.h"

// Native Instagram internal-settings gate, validated on the supplied Instagram
// executable with LIEF + llvm-objdump/otool-equivalent + Capstone.
//
// _TtC17IGBugReporterMenu29IGBugReportMenuViewController
// -initWithDeviceSession:userSession:reliabilityLogging:navChain:endpoint:
//  entryPoint:style:internalSettingsAvailabilityStatus:showInternalSettings:
//  showLoggedOutInternalSettings:showShakeToReportPreferenceToggle:
// ABI/types: @92@0:8@16@24@32@40@48@56q64q72B80B84B88
//
// Metadata/disasm facts:
// - IGInternalSettingsAvailabilityStatus is a Swift enum descriptor, not ObjC class.
// - The ObjC bridge passes it as q/long long and stores it in ivar @120.
// - Capstone shows downstream code compares the ivar against #2 before building
//   the internal-settings row/action.
// - showInternalSettings/showLoggedOutInternalSettings/showShakeToReportPreferenceToggle
//   are BOOL ivars @128/@129/@130.

static const long long SCIIGInternalSettingsAvailabilityEnabled = 2;

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
        availabilityStatus = SCIIGInternalSettingsAvailabilityEnabled;
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
