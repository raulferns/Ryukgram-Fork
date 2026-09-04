#import "RYGDeveloperHubViewController.h"
#import "RYGDeveloperTopicViewController.h"
#import "RYGDeveloperTypedFeatureViewController.h"
#import "RYGWordmarkViewController.h"
#import "RYGPortedRuntimeBrowserViewController.h"
#import "RYGEasyGatingViewController.h"
#import "RYGMetaLocalExperimentBrowser.h"
#import "../Features/ExpFlags/RYGMobileConfigToolsViewController.h"
#import "../UI/RYGLiquidGlass.h"

@implementation RYGDeveloperHubViewController

- (instancetype)init { return [super initWithTitle:@"Developer"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    [self rebuildSections];
    RYGLiquidGlassApplyToViewController(self);
}

- (void)rebuildSections {
    RYGSetting *wordmark = [RYGSetting navigationCellWithTitle:@"IGWordMark"
                                                     subtitle:@"Validated IGDS/BSLDS native WordMark variants"
                                                         icon:[RYGSymbol symbolWithName:@"instagram"]
                                               viewController:[RYGWordmarkViewController new]];
    RYGSetting *wordmarkFlags = [RYGSetting navigationCellWithTitle:@"IGWordMark / Branding Flags"
                                                          subtitle:@"Resolved typed launcher, wordmark and branding parameters"
                                                              icon:[RYGSymbol symbolWithName:@"textformat"]
                                                    viewController:[[RYGDeveloperTypedFeatureViewController alloc]
                                                        initWithTitle:@"IGWordMark / Branding Flags"
                                                                query:@"wordmark|ig wordmark|branding|launcher wordmark"]];
    RYGSetting *easyGating = [RYGSetting navigationCellWithTitle:@"Easy Gating Runtime"
                                                       subtitle:@"Current wrapper mapper discovered structurally · final IDs observed live"
                                                           icon:[RYGSymbol symbolWithName:@"key"]
                                                 viewController:[RYGEasyGatingViewController new]];
    RYGSetting *mobileConfig = [RYGSetting navigationCellWithTitle:@"MobileConfig Runtime"
                                                         subtitle:@"Typed live parameter table · StartupConfigs · portable snapshots"
                                                             icon:[RYGSymbol symbolWithName:@"sliders"]
                                                   viewController:[RYGMobileConfigToolsViewController new]];

    RYGSetting *prism = [RYGSetting navigationCellWithTitle:@"Prism / IGDS / BSLDS"
                                                   subtitle:@"Exact native setters + resolved typed feature parameters"
                                                       icon:[RYGSymbol symbolWithName:@"layout"]
                                             viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfacePrism]];
    RYGSetting *stories = [RYGSetting navigationCellWithTitle:@"Story Tray / Story Grid"
                                                     subtitle:@"Exact Story gates + typed Story Tray, Grid and Homecoming parameters"
                                                         icon:[RYGSymbol symbolWithName:@"rectangle.stack"]
                                               viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceStories]];
    RYGSetting *glass = [RYGSetting navigationCellWithTitle:@"Liquid Glass / Throwback"
                                                   subtitle:@"Native Swizzle/Throwback/Navigation helpers + typed Glass parameters"
                                                       icon:[RYGSymbol symbolWithName:@"interface"]
                                             viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceLiquidGlass]];
    RYGSetting *maps = [RYGSetting navigationCellWithTitle:@"Maps / Location"
                                                  subtitle:@"Friend Map, location, event-map and related resolved typed parameters"
                                                      icon:[RYGSymbol symbolWithName:@"map"]
                                            viewController:[[RYGDeveloperTypedFeatureViewController alloc]
                                                initWithTitle:@"Maps / Location"
                                                        query:@"friend map|friendmap|event map|eventmap|location map|map location|friends map"]];
    RYGSetting *subscriptions = [RYGSetting navigationCellWithTitle:@"Aura / IG Plus / Subscriptions"
                                                           subtitle:@"Consumer subscriptions and Aura feature parameters"
                                                               icon:[RYGSymbol symbolWithName:@"star"]
                                                     viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceConsumerSubs]];
    RYGSetting *internalOnly = [RYGSetting navigationCellWithTitle:@"IG-only / Internal-only"
                                                          subtitle:@"Exact internal visibility owner + typed employee/internal parameters"
                                                              icon:[RYGSymbol symbolWithName:@"eye"]
                                                    viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceInternalOnly]];
    RYGSetting *bugReport = [RYGSetting navigationCellWithTitle:@"Bug Report Menu"
                                                       subtitle:@"Logged out, assistant, internal, shake and sandbox typed gates"
                                                           icon:[RYGSymbol symbolWithName:@"bug"]
                                                 viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceBugReport]];
    RYGSetting *settingsRows = [RYGSetting navigationCellWithTitle:@"Hidden Settings Rows"
                                                          subtitle:@"Visibility selectors remain in the raw Runtime Browser by design"
                                                              icon:[RYGSymbol symbolWithName:@"list"]
                                                    viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceSettingsRows]];
    RYGSetting *dogfood = [RYGSetting navigationCellWithTitle:@"Direct / Dogfooding Settings"
                                                     subtitle:@"Native flows + typed dogfood/employee/internal parameters"
                                                         icon:[RYGSymbol symbolWithName:@"paw"]
                                               viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceDirectDogfood]];

    RYGSetting *metaLocal = [RYGSetting buttonCellWithTitle:@"Meta / Family Local Experiments"
                                                   subtitle:@"Native list + FDID generator + current Odin family device ID"
                                                       icon:[RYGSymbol symbolWithName:@"insights"]
                                                     action:^{ [RYGMetaLocalExperimentBrowser presentFromCurrentViewController]; }];
    RYGSetting *runtime = [RYGSetting navigationCellWithTitle:@"Runtime Browser · WAT Port"
                                                     subtitle:@"dogfood2 model · image → flat typed getters · live receiver · persist/retry/apply"
                                                         icon:[RYGSymbol symbolWithName:@"search"]
                                               viewController:[RYGPortedRuntimeBrowserViewController new]];

    [self applySettingSections:@[
        [RYGSettingsViewController sectionWithHeader:nil footer:nil rows:@[wordmark, wordmarkFlags, easyGating, mobileConfig]],
        [RYGSettingsViewController sectionWithHeader:@"Feature domains"
                                               footer:@"Feature menus resolve typed MobileConfig/runtime parameters only. Raw class/selector exploration is isolated in Runtime Browser. Native Bug Report and Dogfooding flows still use Instagram's real sessions, providers and uploader."
                                                 rows:@[prism, stories, glass, maps, subscriptions, internalOnly, bugReport, settingsRows, dogfood]],
        [RYGSettingsViewController sectionWithHeader:nil footer:@"Runtime Browser is the WATweaks dogfood2 interaction model adapted to Instagram: flat typed getters, direct BOOL switches, typed scalar/Foundation editors, persist-first hooks and pending retry."
                                                 rows:@[metaLocal, runtime]],
    ]];
}

@end
