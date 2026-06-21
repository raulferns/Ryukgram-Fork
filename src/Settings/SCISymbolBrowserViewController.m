// SCISymbolBrowserViewController.m
#import "SCISymbolBrowserViewController.h"
#import "../Utils.h"
#import <objc/runtime.h>
#import "../UI/SCIUIKit26LiquidGlass.h"

// Default surfacing when the search box is empty. This is intentionally a broad
// discovery list, not just persisted overrides; search always scans the full
// cached runtime index and never pins forced rows that do not match the query.
static NSArray<NSString *> *sciDefaultFilters(void) {
	return @[@"liquidglass", @"prism", @"gating", @"gate", @"config",
			 @"mobileconfig", @"mci", @"mcq", @"internal", @"debug",
			 @"employee", @"dogfood", @"aura", @"plus", @"launcher",
			 @"experiment", @"feature", @"wordmark", @"igds"];
}

static char kSCIRuntimeBrowserRowPayloadKey;
static char kSCIRuntimeBrowserInteractionPayloadKey;

@interface SCISymbolBrowserViewController () <UIContextMenuInteractionDelegate, UISearchResultsUpdating>
@end

@implementation SCISymbolBrowserViewController {
	SCISymbolImage _image;
	NSArray<SCISymbolClass *> *_allClasses;
	UISearchController *_searchController;
	NSString *_query;
	UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithImage:(SCISymbolImage)image {
	NSString *title = (image == SCISymbolImageInstagram) ? @"Instagram (exec)" : @"FBSharedFramework";
	self = [super initWithTitle:title];
	if (self) { _image = image; }
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);

	[self configureNativeSearchController];

	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	_spinner.center = self.view.center;
	_spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
	[self.view addSubview:_spinner];
	[_spinner startAnimating];

	SCISymbolImage img = _image;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<SCISymbolClass *> *classes = [SCISymbolBrowserEngine classesForImage:img];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_allClasses = classes;
			[self->_spinner stopAnimating];
			[self rebuildSections];
		});
	});
}

- (void)configureNativeSearchController {
	UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
	sc.searchResultsUpdater = self;
	sc.obscuresBackgroundDuringPresentation = NO;
	sc.searchBar.placeholder = SCILocalized(@"Search classes or BOOL getters…");
	_searchController = sc;
	self.navigationItem.searchController = sc;
	SCIUIKit26ConfigureSearchNavigationItem(self.navigationItem);
}

- (NSArray<NSString *> *)queryTokens {
	NSString *q = [[_query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
	if (!q.length) return @[];
	NSArray *raw = [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSMutableArray *tokens = [NSMutableArray array];
	for (NSString *t in raw) if (t.length) [tokens addObject:t];
	return tokens.copy;
}

- (BOOL)haystack:(NSString *)haystack matchesTokens:(NSArray<NSString *> *)tokens {
	if (!tokens.count) return YES;
	NSString *lower = [haystack.lowercaseString copy] ?: @"";
	for (NSString *t in tokens) if (![lower containsString:t]) return NO;
	return YES;
}

- (BOOL)getter:(SCISymbolGetter *)getter matchesTokens:(NSArray<NSString *> *)tokens className:(NSString *)className {
	if (!tokens.count) return YES;
	NSString *haystack = [NSString stringWithFormat:@"%@ %@", className ?: @"", getter.selectorName ?: @""];
	return [self haystack:haystack matchesTokens:tokens];
}

- (BOOL)stringMatchesDefaultFilters:(NSString *)s {
	NSString *lower = [s.lowercaseString copy] ?: @"";
	for (NSString *f in sciDefaultFilters()) if ([lower containsString:f]) return YES;
	return NO;
}

- (BOOL)classHasOverride:(SCISymbolClass *)symbolClass {
	for (SCISymbolGetter *g in symbolClass.getters ?: @[]) if (g.override != nil) return YES;
	return NO;
}

- (NSArray<SCISymbolGetter *> *)visibleGettersForClass:(SCISymbolClass *)symbolClass tokens:(NSArray<NSString *> *)tokens {
	BOOL searching = tokens.count > 0;
	BOOL classMatched = [self haystack:symbolClass.className ?: @"" matchesTokens:tokens];
	NSMutableArray<SCISymbolGetter *> *out = [NSMutableArray array];

	if (searching) {
		for (SCISymbolGetter *g in symbolClass.getters ?: @[]) {
			if (classMatched || [self getter:g matchesTokens:tokens className:symbolClass.className]) [out addObject:g];
		}
		return out.copy;
	}

	BOOL hasOverride = [self classHasOverride:symbolClass];
	BOOL classDefault = [self stringMatchesDefaultFilters:symbolClass.className ?: @""];
	if (hasOverride || classDefault) return symbolClass.getters ?: @[];

	for (SCISymbolGetter *g in symbolClass.getters ?: @[]) {
		if ([self stringMatchesDefaultFilters:g.selectorName ?: @""]) [out addObject:g];
	}
	return out.copy;
}

- (NSString *)subtitleForClass:(NSString *)className selector:(NSString *)selector isClass:(BOOL)isClass overrideKey:(NSString *)overrideKey {
	NSNumber *live = [SCISymbolBrowserEngine liveValueForClass:className selector:selector isClassMethod:isClass];
	NSNumber *forced = [SCISymbolBrowserEngine overrideForKey:overrideKey];
	NSString *liveText = live ? (live.boolValue ? SCILocalized(@"Live: ON") : SCILocalized(@"Live: OFF")) : SCILocalized(@"Live: unknown");
	NSString *forceText = SCILocalized(@"IG default");
	if (forced) {
		forceText = forced.boolValue ? SCILocalized(@"Forced: ON") : SCILocalized(@"Forced: OFF");
		if (![SCISymbolBrowserEngine hookInstalledForKey:overrideKey]) {
			forceText = [forceText stringByAppendingFormat:@" • %@", SCILocalized(@"restart")];
		}
	}
	return [NSString stringWithFormat:@"%@ • %@", liveText, forceText];
}

- (void)applyOverridePayload:(NSDictionary *)payload value:(NSNumber *)value {
	NSString *className = payload[@"class"] ?: @"";
	NSString *selector = payload[@"selector"] ?: @"";
	BOOL isClass = [payload[@"isClass"] boolValue];
	[SCISymbolBrowserEngine setOverride:value forClass:className selector:selector isClassMethod:isClass];
	[self rebuildSections];
}

- (void)rebuildSections {
	if (!_allClasses) return;

	NSArray<NSString *> *tokens = [self queryTokens];
	NSMutableArray<SCIBaseSettingsSection *> *sections = [NSMutableArray array];

	for (SCISymbolClass *c in _allClasses) {
		NSArray<SCISymbolGetter *> *visibleGetters = [self visibleGettersForClass:c tokens:tokens];
		if (!visibleGetters.count) continue;

		NSMutableArray<SCIBaseSettingsRow *> *rows = [NSMutableArray array];
		for (SCISymbolGetter *g in visibleGetters) {
			NSString *cn = c.className ?: @"";
			NSString *sn = g.selectorName ?: @"";
			BOOL isClass = g.isClassMethod;
			NSString *overrideKey = g.overrideKey;
			NSString *rowTitle = [NSString stringWithFormat:@"%@%@", isClass ? @"+ " : @"", sn];
			__weak typeof(self) weakSelf = self;

			SCIBaseSettingsRow *row = [SCIBaseSettingsRow
				switchRowWithTitle:rowTitle
						  subtitle:nil
							 value:^BOOL{
								 NSNumber *forced = [SCISymbolBrowserEngine overrideForKey:overrideKey];
								 if (forced) return forced.boolValue;
								 NSNumber *lv = [SCISymbolBrowserEngine liveValueForClass:cn selector:sn isClassMethod:isClass];
								 return lv ? lv.boolValue : NO;
							 }
							action:^(BOOL enabled, __unused UIViewController *vc) {
								 // Tapping ON creates a Force ON override. Tapping OFF does
								 // not mean Force OFF; it removes the override and returns
								 // the getter to IG default. Force OFF is available by
								 // long-pressing the row.
								 [SCISymbolBrowserEngine setOverride:(enabled ? @YES : nil) forClass:cn selector:sn isClassMethod:isClass];
								 [weakSelf rebuildSections];
							 }];
			row.dynamicSubtitle = ^NSString *{
				return [weakSelf subtitleForClass:cn selector:sn isClass:isClass overrideKey:overrideKey];
			};
			NSDictionary *payload = @{ @"class": cn, @"selector": sn, @"isClass": @(isClass), @"overrideKey": overrideKey ?: @"" };
			objc_setAssociatedObject(row, &kSCIRuntimeBrowserRowPayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[rows addObject:row];
		}
		[sections addObject:[SCIBaseSettingsSection sectionWithHeader:c.className footer:nil rows:rows]];
	}

	NSString *mode = tokens.count ? SCILocalized(@"Search is scanning the full cached class/getter index; forced rows are only shown when they match the query.") : SCILocalized(@"Showing default discovery filters plus any forced overrides. Search scans every class and BOOL getter in the loaded image; no 80-row cap.");
	NSString *footer = [NSString stringWithFormat:SCILocalized(@"Indexed %lu classes in this image. %@"), (unsigned long)_allClasses.count, mode];
	if (sections.count == 0) {
		SCIBaseSettingsRow *hint = [SCIBaseSettingsRow
			rowWithTitle:tokens.count ? SCILocalized(@"No matching classes/getters") : SCILocalized(@"No default matches")
			subtitle:SCILocalized(@"Search any class or getter name to browse the full loaded image index.")
			  action:nil];
		[sections addObject:[SCIBaseSettingsSection sectionWithHeader:nil footer:footer rows:@[hint]]];
	} else {
		[sections addObject:[SCIBaseSettingsSection sectionWithHeader:nil footer:footer rows:@[]]];
	}

	self.sections = sections;
	[self reloadSettings];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	if (indexPath.section < (NSInteger)self.sections.count) {
		SCIBaseSettingsSection *section = self.sections[indexPath.section];
		if (indexPath.row < (NSInteger)section.rows.count) {
			SCIBaseSettingsRow *row = section.rows[indexPath.row];
			NSDictionary *payload = objc_getAssociatedObject(row, &kSCIRuntimeBrowserRowPayloadKey);
			for (id<UIInteraction> interaction in cell.interactions.copy) {
				if ([interaction isKindOfClass:UIContextMenuInteraction.class]) [cell removeInteraction:interaction];
			}
			if ([payload isKindOfClass:NSDictionary.class]) {
				UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
				objc_setAssociatedObject(interaction, &kSCIRuntimeBrowserInteractionPayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				[cell addInteraction:interaction];
			}
		}
	}
	return cell;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(__unused CGPoint)location {
	NSDictionary *payload = objc_getAssociatedObject(interaction, &kSCIRuntimeBrowserInteractionPayloadKey);
	if (![payload isKindOfClass:NSDictionary.class]) return nil;
	NSString *overrideKey = payload[@"overrideKey"] ?: @"";
	BOOL hasOverride = [SCISymbolBrowserEngine overrideForKey:overrideKey] != nil;
	__weak typeof(self) weakSelf = self;
	return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
		UIAction *undo = [UIAction actionWithTitle:SCILocalized(@"Desfazer override") image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(__unused UIAction *action) {
			[weakSelf applyOverridePayload:payload value:nil];
		}];
		if (!hasOverride) undo.attributes = UIMenuElementAttributesDisabled;
		UIAction *forceOff = [UIAction actionWithTitle:SCILocalized(@"Force OFF") image:[UIImage systemImageNamed:@"poweroff"] identifier:nil handler:^(__unused UIAction *action) {
			[weakSelf applyOverridePayload:payload value:@NO];
		}];
		return [UIMenu menuWithTitle:@"" children:@[undo, forceOff]];
	}];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
	_query = searchController.searchBar.text ?: @"";
	[self rebuildSections];
}

@end
