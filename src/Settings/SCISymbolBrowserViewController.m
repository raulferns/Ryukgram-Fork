// SCISymbolBrowserViewController.m
#import "SCISymbolBrowserViewController.h"
#import "../Utils.h"
#import <objc/runtime.h>

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

@interface SCISymbolBrowserViewController () <UIContextMenuInteractionDelegate>
@end

@implementation SCISymbolBrowserViewController {
	SCISymbolImage _image;
	BOOL _unified;
	NSArray<SCISymbolClass *> *_allClasses;
	NSArray<SCISymbolClass *> *_fbClasses;
	UISearchBar *_searchBar;
	SCIUIKit26SearchBarContainerView *_searchContainer;
	NSLayoutConstraint *_searchBottomConstraint;
	NSString *_query;
	UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithImage:(SCISymbolImage)image {
	NSString *title = (image == SCISymbolImageInstagram) ? @"Instagram (exec)" : @"FBSharedFramework";
	self = [super initWithTitle:title];
	if (self) { _image = image; }
	return self;
}

- (instancetype)initUnified {
	self = [super initWithTitle:SCILocalized(@"Unified Runtime Browser")];
	if (self) { _image = SCISymbolImageInstagram; _unified = YES; }
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);

	[self configureBottomSearchBar];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	_spinner.center = self.view.center;
	_spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
	[self.view addSubview:_spinner];
	[_spinner startAnimating];

	SCISymbolImage img = _image;
	BOOL unified = _unified;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<SCISymbolClass *> *ig = [SCISymbolBrowserEngine classesForImage:img];
		NSArray<SCISymbolClass *> *fb = unified ? [SCISymbolBrowserEngine classesForImage:SCISymbolImageFBShared] : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_allClasses = ig;
			self->_fbClasses = fb;
			[self->_spinner stopAnimating];
			[self rebuildSections];
		});
	});
}

- (void)configureBottomSearchBar {
	self.tableView.tableHeaderView = nil;
	[self applyBottomSearchInsetForKeyboardOverlap:0.0];

	_searchContainer = [[SCIUIKit26SearchBarContainerView alloc] initWithRadius:22.0];
	_searchContainer.translatesAutoresizingMaskIntoConstraints = NO;
	_searchContainer.sciGlassInteractive = YES;
	_searchContainer.sciGlassClearStyle = YES;
	_searchContainer.sciGlassTintColor = [UIColor colorWithWhite:1.0 alpha:0.04];
	[_searchContainer applyLiquidGlassStyle];
	[self.view addSubview:_searchContainer];

	_searchBar = _searchContainer.searchBar;
	_searchBar.placeholder = SCILocalized(@"Search classes or BOOL getters…");
	_searchBar.delegate = self;
	SCIUIKit26ConfigureSearchBar(_searchBar);

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	_searchBottomConstraint = [_searchContainer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10.0];
	[NSLayoutConstraint activateConstraints:@[
		[_searchContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14.0],
		[_searchContainer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14.0],
		_searchBottomConstraint,
		[_searchContainer.heightAnchor constraintEqualToConstant:52.0],
	]];
}

- (void)applyBottomSearchInsetForKeyboardOverlap:(CGFloat)overlap {
	UIEdgeInsets inset = self.tableView.contentInset;
	inset.bottom = 84.0 + MAX(0.0, overlap);
	self.tableView.contentInset = inset;
	self.tableView.scrollIndicatorInsets = inset;
}

- (void)keyboardWillHide:(NSNotification *)note {
	[self updateSearchBarForKeyboardNotification:note hidden:YES];
}

- (void)keyboardWillChangeFrame:(NSNotification *)note {
	[self updateSearchBarForKeyboardNotification:note hidden:NO];
}

- (void)updateSearchBarForKeyboardNotification:(NSNotification *)note hidden:(BOOL)hidden {
	CGFloat overlap = 0.0;
	if (!hidden) {
		CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
		CGRect frameInView = [self.view convertRect:endFrame fromView:nil];
		CGFloat rawOverlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(frameInView);
		overlap = MAX(0.0, rawOverlap - self.view.safeAreaInsets.bottom);
	}

	NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
	UIViewAnimationOptions options = ([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16);
	void (^changes)(void) = ^{
		self->_searchBottomConstraint.constant = -10.0 - overlap;
		[self applyBottomSearchInsetForKeyboardOverlap:overlap];
		[self.view layoutIfNeeded];
	};
	if (duration > 0.0) {
		[UIView animateWithDuration:duration delay:0.0 options:options animations:changes completion:nil];
	} else {
		changes();
	}
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

// Builds the section for one class (or nil if no getter is visible for the query).
// imageTag is prefixed to the header so the unified scope can show both images.
- (SCIBaseSettingsSection *)sectionForClass:(SCISymbolClass *)c tokens:(NSArray<NSString *> *)tokens imageTag:(NSString *)imageTag {
	NSArray<SCISymbolGetter *> *visibleGetters = [self visibleGettersForClass:c tokens:tokens];
	if (!visibleGetters.count) return nil;

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
	NSString *header = imageTag.length ? [NSString stringWithFormat:@"%@ · %@", imageTag, c.className ?: @""] : (c.className ?: @"");
	return [SCIBaseSettingsSection sectionWithHeader:header footer:nil rows:rows];
}

- (void)rebuildSections {
	if (!_allClasses && !_fbClasses) return;

	NSArray<NSString *> *tokens = [self queryTokens];
	NSMutableArray<SCIBaseSettingsSection *> *sections = [NSMutableArray array];

	// Instagram scope (or the single selected image when not unified).
	NSString *igTag = _unified ? @"IG" : nil;
	for (SCISymbolClass *c in _allClasses) {
		SCIBaseSettingsSection *s = [self sectionForClass:c tokens:tokens imageTag:igTag];
		if (s) [sections addObject:s];
	}
	// FBShared scope (unified only).
	if (_unified) {
		for (SCISymbolClass *c in _fbClasses) {
			SCIBaseSettingsSection *s = [self sectionForClass:c tokens:tokens imageTag:@"FB"];
			if (s) [sections addObject:s];
		}
	}

	NSUInteger indexed = _allClasses.count + _fbClasses.count;
	NSString *mode = tokens.count ? SCILocalized(@"Search is scanning the full cached class/getter index; forced rows are only shown when they match the query.") : SCILocalized(@"Showing default discovery filters plus any forced overrides. Search scans every class and BOOL getter in the loaded image(s); no 80-row cap.");
	NSString *footer = [NSString stringWithFormat:SCILocalized(@"Indexed %lu classes. %@"), (unsigned long)indexed, mode];
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

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
	_query = searchText ?: @"";
	[self rebuildSections];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

@end
