#import "SCIChangelog.h"
#import "../../Utils.h"
#import "../../Tweak.h"
#import "../../UI/SCIUIKit26LiquidGlass.h"

#define kRepo SCIRepoSlug

// Stores the SCIVersionString of the last tweak build whose popup was shown.
// When the tweak updates, this mismatches and triggers a fresh check.
static NSString *const kLastSeenVersionKey = @"sci_changelog_last_seen_version";
// Debug pref: when YES, the popup fires every launch regardless of version.
static NSString *const kForceShowKey = @"sci_changelog_force_show";

// MARK: - Cache

static NSString *sciChangelogCacheDir(void) {
	static NSString *dir;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
		dir = [base stringByAppendingPathComponent:@"RyukGramChangelog"];
		[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	});
	return dir;
}

static NSString *sciCachedReleasePath(NSString *tag) {
	NSString *safe = [tag stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
	return [sciChangelogCacheDir() stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"json"]];
}

static NSDictionary *sciLoadCachedRelease(NSString *tag) {
	NSData *data = [NSData dataWithContentsOfFile:sciCachedReleasePath(tag)];
	id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static void sciSaveCachedRelease(NSDictionary *json) {
	NSString *tag = json[@"tag_name"];
	if (!tag.length) return;

	NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
	if (data) [data writeToFile:sciCachedReleasePath(tag) atomically:YES];
}

// MARK: - Liquid Glass notes surface

static UIColor *sciNotesSurfaceColor(void) {
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
		return tc.userInterfaceStyle == UIUserInterfaceStyleDark
			? UIColor.secondarySystemGroupedBackgroundColor
			: UIColor.systemGroupedBackgroundColor;
	}];
}

static void sciConfigureNotesRootView(UIViewController *vc) {
	if (!vc || !vc.isViewLoaded) return;
	SCIUIKit26ConfigureViewController(vc);
	vc.view.opaque = YES;
	vc.view.backgroundColor = sciNotesSurfaceColor();
	vc.view.layer.backgroundColor = [sciNotesSurfaceColor() resolvedColorWithTraitCollection:vc.view.traitCollection].CGColor;
}

static void sciConfigureNotesTextView(UITextView *tv) {
	if (!tv) return;
	tv.editable = NO;
	tv.selectable = YES;
	tv.scrollEnabled = YES;
	tv.alwaysBounceVertical = YES;
	tv.bounces = YES;
	tv.showsVerticalScrollIndicator = YES;
	tv.backgroundColor = UIColor.clearColor;
	tv.opaque = NO;
	tv.textContainer.lineFragmentPadding = 0.0;
	tv.adjustsFontForContentSizeCategory = YES;
	tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
	SCIUIKit26ConfigureScrollView(tv);
}

// MARK: - Network

static void sciFetchJSON(NSString *url, void (^completion)(id json)) {
	NSURL *u = [NSURL URLWithString:url];
	if (!u) { completion(nil); return; }

	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
	req.timeoutInterval = 12.0;
	[req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, __unused NSURLResponse *resp, __unused NSError *err) {
		id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		dispatch_async(dispatch_get_main_queue(), ^{ completion(json); });
	}] resume];
}

// Fetch a specific tag, falling back to /releases/latest on 404 so the popup
// works in the window between a local version bump and the release being
// published on GitHub.
static void sciFetchRelease(NSString *tag, void (^completion)(NSDictionary *json)) {
	NSString *tagURL = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/tags/%@", kRepo, tag];

	sciFetchJSON(tagURL, ^(id json) {
		if ([json isKindOfClass:NSDictionary.class] && json[@"tag_name"]) {
			sciSaveCachedRelease(json);
			completion(json);
			return;
		}

		NSString *latestURL = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepo];
		sciFetchJSON(latestURL, ^(id latest) {
			NSDictionary *rel = [latest isKindOfClass:NSDictionary.class] && latest[@"tag_name"] ? latest : nil;
			if (rel) sciSaveCachedRelease(rel);
			completion(rel);
		});
	});
}

static void sciFetchReleaseList(void (^completion)(NSArray<NSDictionary *> *releases)) {
	NSString *url = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases?per_page=50", kRepo];

	sciFetchJSON(url, ^(id json) {
		completion([json isKindOfClass:NSArray.class] ? json : nil);
	});
}

// MARK: - Markdown renderer

static NSRegularExpression *sciRegex(NSString *pattern) {
	return [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
}

static NSAttributedString *sciRenderInline(NSString *line, NSDictionary *attrs) {
	NSMutableAttributedString *seg = [[NSMutableAttributedString alloc] initWithString:line attributes:attrs];

	for (NSTextCheckingResult *m in [sciRegex(@"\\*\\*(.+?)\\*\\*") matchesInString:seg.string options:0 range:NSMakeRange(0, seg.length)].reverseObjectEnumerator) {
		NSString *text = [seg.string substringWithRange:[m rangeAtIndex:1]];
		UIFont *base = attrs[NSFontAttributeName];
		NSMutableDictionary *a = attrs.mutableCopy;
		a[NSFontAttributeName] = [UIFont systemFontOfSize:base.pointSize weight:UIFontWeightBold];
		[seg replaceCharactersInRange:m.range withAttributedString:[[NSAttributedString alloc] initWithString:text attributes:a]];
	}

	for (NSTextCheckingResult *m in [sciRegex(@"\\[([^\\]]+)\\]\\(([^)]+)\\)") matchesInString:seg.string options:0 range:NSMakeRange(0, seg.length)].reverseObjectEnumerator) {
		NSString *text = [seg.string substringWithRange:[m rangeAtIndex:1]];
		NSString *url = [seg.string substringWithRange:[m rangeAtIndex:2]];
		NSMutableDictionary *a = attrs.mutableCopy;
		a[NSLinkAttributeName] = url;
		[seg replaceCharactersInRange:m.range withAttributedString:[[NSAttributedString alloc] initWithString:text attributes:a]];
	}

	return seg;
}

static NSAttributedString *sciRenderMarkdown(NSString *md) {
	NSMutableAttributedString *out = [NSMutableAttributedString new];
	if (!md.length) return out;

	UIFontMetrics *bodyMetrics = [UIFontMetrics metricsForTextStyle:UIFontTextStyleBody];
	UIFontMetrics *headlineMetrics = [UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline];
	UIFont *body = [bodyMetrics scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular]];
	UIFont *h2 = [headlineMetrics scaledFontForFont:[UIFont systemFontOfSize:20.0 weight:UIFontWeightBold]];
	UIFont *h3 = [headlineMetrics scaledFontForFont:[UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]];

	NSMutableParagraphStyle *bodyPS = [NSMutableParagraphStyle new];
	bodyPS.lineSpacing = 3;
	bodyPS.paragraphSpacing = 5;
	bodyPS.lineBreakMode = NSLineBreakByWordWrapping;

	NSMutableParagraphStyle *headPS = [NSMutableParagraphStyle new];
	headPS.lineSpacing = 2;
	headPS.paragraphSpacing = 7;
	headPS.paragraphSpacingBefore = 14;
	headPS.lineBreakMode = NSLineBreakByWordWrapping;

	BOOL emitted = NO;

	for (NSString *raw in [md componentsSeparatedByString:@"\n"]) {
		if (!raw.length) continue;

		NSString *line = raw;
		NSString *prefix = nil;
		NSMutableDictionary *attrs = [@{
			NSFontAttributeName: body,
			NSForegroundColorAttributeName: UIColor.labelColor,
			NSParagraphStyleAttributeName: bodyPS
		} mutableCopy];

		if ([line hasPrefix:@"## "]) {
			line = [line substringFromIndex:3];
			attrs[NSFontAttributeName] = h2;
			attrs[NSParagraphStyleAttributeName] = emitted ? headPS : bodyPS;
		} else if ([line hasPrefix:@"### "]) {
			line = [line substringFromIndex:4];
			attrs[NSFontAttributeName] = h3;
			attrs[NSParagraphStyleAttributeName] = emitted ? headPS : bodyPS;
		} else if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "]) {
			line = [line substringFromIndex:2];
			prefix = @"  •  ";
		} else if ([line hasPrefix:@"> "]) {
			line = [line substringFromIndex:2];
			attrs[NSForegroundColorAttributeName] = UIColor.secondaryLabelColor;
		}

		if (emitted) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs]];
		if (prefix) [out appendAttributedString:[[NSAttributedString alloc] initWithString:prefix attributes:attrs]];

		[out appendAttributedString:sciRenderInline(line, attrs)];
		emitted = YES;
	}

	return out;
}

// MARK: - Detail view controller (renders one release)

@interface _SCIChangelogDetailVC : UIViewController
@property (nonatomic, copy) NSDictionary *releaseJSON;
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation _SCIChangelogDetailVC

- (void)viewDidLoad {
	[super viewDidLoad];
	sciConfigureNotesRootView(self);

	self.title = SCILocalized(@"What's new in RyukGram");
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

	NSString *name = self.releaseJSON[@"name"] ?: self.releaseJSON[@"tag_name"] ?: @"?";
	NSString *body = self.releaseJSON[@"body"] ?: @"";
	NSString *url = self.releaseJSON[@"html_url"] ?: @"";
	NSString *header = url.length ? [NSString stringWithFormat:@"## [%@](%@)\n", name, url] : [NSString stringWithFormat:@"## %@\n", name];

	SCIUIKit26GlassPanelView *panel = [[SCIUIKit26GlassPanelView alloc] initWithRadius:24.0];
	panel.sciGlassClearStyle = NO;
	panel.sciGlassInteractive = NO;
	panel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:panel];

	UITextView *tv = [UITextView new];
	sciConfigureNotesTextView(tv);
	tv.textContainerInset = UIEdgeInsetsMake(18, 18, 22, 18);
	tv.translatesAutoresizingMaskIntoConstraints = NO;
	tv.attributedText = sciRenderMarkdown([header stringByAppendingString:body]);
	[panel.contentView addSubview:tv];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	UILayoutGuide *readable = self.view.readableContentGuide;
	NSLayoutConstraint *maxWidth = [panel.widthAnchor constraintLessThanOrEqualToConstant:760.0];
	NSLayoutConstraint *readableLeading = [panel.leadingAnchor constraintEqualToAnchor:readable.leadingAnchor constant:-8.0];
	NSLayoutConstraint *readableTrailing = [panel.trailingAnchor constraintEqualToAnchor:readable.trailingAnchor constant:8.0];
	maxWidth.priority = UILayoutPriorityRequired;
	readableLeading.priority = UILayoutPriorityDefaultHigh;
	readableTrailing.priority = UILayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		[panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
		[panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12.0],
		[panel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12.0],
		readableLeading,
		readableTrailing,
		[panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12.0],
		maxWidth,
		[panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[tv.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
		[tv.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
		[tv.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
		[tv.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
	]];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
	[super traitCollectionDidChange:previousTraitCollection];
	self.view.backgroundColor = sciNotesSurfaceColor();
	self.view.layer.backgroundColor = [sciNotesSurfaceColor() resolvedColorWithTraitCollection:self.view.traitCollection].CGColor;
}

- (void)done {
	void (^cb)(void) = self.onDismiss;
	self.onDismiss = nil;
	[self dismissViewControllerAnimated:YES completion:cb];
}

@end

// MARK: - Releases list view controller

@interface _SCIReleaseListVC : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *releases;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation _SCIReleaseListVC

- (void)viewDidLoad {
	[super viewDidLoad];
	sciConfigureNotesRootView(self);
	SCIUIKit26ConfigureTableView(self.tableView);

	self.title = SCILocalized(@"Release notes");
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 68.0;
	self.tableView.contentInset = UIEdgeInsetsMake(10, 0, 16, 0);
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

	self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	self.spinner.hidesWhenStopped = YES;
	self.tableView.backgroundView = self.spinner;
	[self.spinner startAnimating];

	[self loadReleases];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
	[super traitCollectionDidChange:previousTraitCollection];
	self.view.backgroundColor = sciNotesSurfaceColor();
	self.view.layer.backgroundColor = [sciNotesSurfaceColor() resolvedColorWithTraitCollection:self.view.traitCollection].CGColor;
}

- (void)loadReleases {
	sciFetchReleaseList(^(NSArray<NSDictionary *> *arr) {
		self.releases = arr ?: @[];
		[self.spinner stopAnimating];
		self.tableView.backgroundView = nil;

		if (!self.releases.count) {
			UILabel *empty = [UILabel new];
			empty.text = SCILocalized(@"No releases");
			empty.textAlignment = NSTextAlignmentCenter;
			empty.textColor = UIColor.secondaryLabelColor;
			empty.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular]];
			empty.adjustsFontForContentSizeCategory = YES;
			self.tableView.backgroundView = empty;
		}

		[self.tableView reloadData];
	});
}

- (void)done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(__unused UITableView *)tv numberOfRowsInSection:(__unused NSInteger)section {
	return self.releases.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"r"];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
	SCIUIKit26ConfigureTableCell(cell);

	NSDictionary *rel = self.releases[ip.row];
	NSString *tag = rel[@"tag_name"] ?: @"";
	NSString *title = rel[@"name"] ?: tag;

	NSMutableArray *badges = [NSMutableArray new];
	if (ip.row == 0) [badges addObject:SCILocalized(@"latest")];
	if ([tag isEqualToString:SCIVersionString]) [badges addObject:SCILocalized(@"installed")];
	if (badges.count) title = [NSString stringWithFormat:@"%@  (%@)", title, [badges componentsJoinedByString:@", "]];

	NSString *published = rel[@"published_at"];
	cell.textLabel.text = title;
	cell.detailTextLabel.text = published.length ? [published substringToIndex:MIN((NSUInteger)10, published.length)] : @"";
	cell.textLabel.numberOfLines = 2;
	cell.detailTextLabel.numberOfLines = 1;
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.textLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]];
	cell.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular]];
	cell.textLabel.adjustsFontForContentSizeCategory = YES;
	cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];

	_SCIChangelogDetailVC *vc = [_SCIChangelogDetailVC new];
	vc.releaseJSON = self.releases[ip.row];
	[self.navigationController pushViewController:vc animated:YES];
}

@end

// MARK: - Public API

@implementation SCIChangelog

+ (UIViewController *)topVCInWindow:(UIWindow *)window {
	UIViewController *vc = window.rootViewController;
	while (vc.presentedViewController) vc = vc.presentedViewController;
	return vc;
}

+ (UINavigationController *)navWithRoot:(UIViewController *)root largeOnly:(BOOL)largeOnly {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
	nav.modalPresentationStyle = UIModalPresentationPageSheet;

	if (@available(iOS 15.0, *)) {
		UISheetPresentationController *sheet = nav.sheetPresentationController;
		sheet.detents = largeOnly
			? @[UISheetPresentationControllerDetent.largeDetent]
			: @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];

		sheet.selectedDetentIdentifier = largeOnly
			? UISheetPresentationControllerDetentIdentifierLarge
			: UISheetPresentationControllerDetentIdentifierMedium;

		sheet.prefersGrabberVisible = YES;
		sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
	}

	return nav;
}

+ (void)presentReleaseJSON:(NSDictionary *)json onDismiss:(void(^)(void))onDismiss fromWindow:(UIWindow *)window {
	if (!json || !window) return;

	_SCIChangelogDetailVC *vc = [_SCIChangelogDetailVC new];
	vc.releaseJSON = json;
	vc.onDismiss = onDismiss;

	[[self topVCInWindow:window] presentViewController:[self navWithRoot:vc largeOnly:NO] animated:YES completion:nil];
}

+ (void)presentIfNewFromWindow:(UIWindow *)window {
	if (!window) return;

	NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
	BOOL force = [ud boolForKey:kForceShowKey];

	// Fast-path: already shown for this tweak version — skip all I/O.
	if (!force && [[ud stringForKey:kLastSeenVersionKey] isEqualToString:SCIVersionString]) return;

	void (^show)(NSDictionary *) = ^(NSDictionary *json) {
		if (!json) return;

		// Mark seen on show so any dismissal path (Done, swipe) is covered.
		[ud setObject:SCIVersionString forKey:kLastSeenVersionKey];
		[self presentReleaseJSON:json onDismiss:nil fromWindow:window];
	};

	NSDictionary *cached = sciLoadCachedRelease(SCIVersionString);
	if (cached) show(cached);
	else sciFetchRelease(SCIVersionString, show);
}

+ (void)presentAllFromViewController:(UIViewController *)host {
	if (!host) return;

	_SCIReleaseListVC *list = [_SCIReleaseListVC new];
	[host presentViewController:[self navWithRoot:list largeOnly:YES] animated:YES completion:nil];
}

@end
