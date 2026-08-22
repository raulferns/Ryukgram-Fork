#import "RYGDeveloperHubViewController.h"
#import "RYGDeveloperTopicViewController.h"
#import "RYGWordmarkViewController.h"
#import "RYGFastRuntimeBrowserViewController.h"
#import "RYGEasyGatingViewController.h"
#import "RYGMetaLocalExperimentBrowser.h"
#import "../Features/ExpFlags/RYGMobileConfigToolsViewController.h"
#import "../UI/RYGLiquidGlass.h"

@implementation RYGDeveloperHubViewController

- (instancetype)init { return [super initWithTitle:@"Developer"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    // Opening Developer is presentation-only. Persisted state has dedicated
    // owners and never performs restore/discovery from this screen.
    [self rebuildSections];
    RYGLiquidGlassApplyToViewController(self);
}

- (void)rebuildSections {
    RYGSetting *wordmark = [RYGSetting navigationCellWithTitle:@"IGWordMark" subtitle:nil icon:[RYGSymbol symbolWithName:@"instagram"] viewController:[RYGWordmarkViewController new]];
    RYGSetting *easyGating = [RYGSetting navigationCellWithTitle:@"Easy Gating Internal" subtitle:@"Final mapped IDs observed live" icon:[RYGSymbol symbolWithName:@"key"] viewController:[RYGEasyGatingViewController new]];
    RYGSetting *mobileConfig = [RYGSetting navigationCellWithTitle:@"MobileConfig" subtitle:@"Live table + id_name_mapping + native overrides" icon:[RYGSymbol symbolWithName:@"sliders"] viewController:[RYGMobileConfigToolsViewController new]];
    RYGSetting *prism = [RYGSetting navigationCellWithTitle:@"Prism UI" subtitle:@"Exact setters + on-demand IGDS/BSLDS runtime discovery" icon:[RYGSymbol symbolWithName:@"layout"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfacePrism]];
    RYGSetting *stories = [RYGSetting navigationCellWithTitle:@"Story Tray / Story Grid" subtitle:@"Exact persistent Story Tray and Dynamic Story Grid gates" icon:[RYGSymbol symbolWithName:@"rectangle.stack"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceStories]];
    RYGSetting *glass = [RYGSetting navigationCellWithTitle:@"Liquid Glass Throwback" subtitle:@"Persistent native Swizzle, Throwback Chrome and Navigation helpers" icon:[RYGSymbol symbolWithName:@"interface"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceLiquidGlass]];
    RYGSetting *internalOnly = [RYGSetting navigationCellWithTitle:@"IG-only / Internal-only" subtitle:@"Exact internal visibility owner + on-demand runtime discovery" icon:[RYGSymbol symbolWithName:@"eye"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceInternalOnly]];
    RYGSetting *bugReport = [RYGSetting navigationCellWithTitle:@"Bug Report Menu" subtitle:@"Logged out, assistant, internal settings, shake and sandbox" icon:[RYGSymbol symbolWithName:@"bug"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceBugReport]];
    RYGSetting *settingsRows = [RYGSetting navigationCellWithTitle:@"Hidden Settings Rows" subtitle:@"On-demand visibility discovery with persisted exact hooks" icon:[RYGSymbol symbolWithName:@"list"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceSettingsRows]];
    RYGSetting *dogfood = [RYGSetting navigationCellWithTitle:@"Direct / Dogfooding Settings" subtitle:@"Native hooks; MobileConfig resolution only when explicitly applied" icon:[RYGSymbol symbolWithName:@"paw"] viewController:[[RYGDeveloperTopicViewController alloc] initWithSurface:RYGDeveloperRuntimeSurfaceDirectDogfood]];
    RYGSetting *metaLocal = [RYGSetting buttonCellWithTitle:@"MetaLocalExperiment" subtitle:nil icon:[RYGSymbol symbolWithName:@"insights"] action:^{ [RYGMetaLocalExperimentBrowser presentFromCurrentViewController]; }];
    RYGSetting *runtime = [RYGSetting navigationCellWithTitle:@"Runtime Browser · Live" subtitle:@"Images → classes → methods on demand; exact persisted overrides" icon:[RYGSymbol symbolWithName:@"search"] viewController:[RYGFastRuntimeBrowserViewController new]];

    [self applySettingSections:@[
        [RYGSettingsViewController sectionWithHeader:nil footer:nil rows:@[wordmark, easyGating, mobileConfig]],
        [RYGSettingsViewController sectionWithHeader:@"Native / live surfaces" footer:@"Startup only replays exact persisted identities. Opening Developer never performs restore; Runtime and MobileConfig discovery require an explicit action." rows:@[prism, stories, glass, internalOnly, bugReport, settingsRows, dogfood]],
        [RYGSettingsViewController sectionWithHeader:nil footer:nil rows:@[metaLocal, runtime]],
    ]];
}

@end
