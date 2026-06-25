#import "SCIIGDSLauncherConfigViewController.h"
#import <objc/runtime.h>
#import "../Utils.h"

@interface IGDSSection : NSObject
@property (copy) NSString *header, *footer;
@property (copy) NSArray<NSDictionary *> *rows;
@end
@implementation IGDSSection @end

@implementation SCIIGDSLauncherConfigViewController {
	NSArray<IGDSSection *> *_sections;
}

- (instancetype)init {
	if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
	self.title = @"IGDSLauncherConfig";
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	SCIUIKit26ConfigureViewController(self);
	SCIUIKit26ConfigureTableView(self.tableView);
	self.tableView.estimatedRowHeight = 60;
	[self buildSections];
}

- (void)buildSections {
	IGDSSection *master = [IGDSSection new];
	master.header = @"Master";
	master.footer = @"Ativa todos os grupos de uma vez. Os hooks agora instalam sempre — o toggle vale ao reabrir a tela afetada, sem precisar reabrir o app.";
	master.rows = @[
		@{@"title":@"★ Ativar tudo (IGDSLauncherConfig)", @"key":@"sci_igds_launcher_all", @"restart":@YES},
	];

	IGDSSection *lg = [IGDSSection new];
	lg.header = @"Liquid Glass";
	lg.footer = @"Liga os getters LiquidGlass do IGDS que o app realmente consulta via objc_msgSend.";
	lg.rows = @[
		@{@"title":@"Liquid Glass (IGDSLauncherConfig)", @"key":@"sci_igds_liquidglass", @"restart":@YES},
	];

	IGDSSection *prism = [IGDSSection new];
	prism.header = @"Prism UI";
	prism.footer = @"isPrism* + isIGBPrism* — novo sistema de design do Instagram.";
	prism.rows = @[
		@{@"title":@"Prism UI", @"key":@"sci_igds_prism", @"restart":@YES},
	];

	IGDSSection *lgDetail = [IGDSSection new];
	lgDetail.header = @"LiquidGlass — detalhado";
	lgDetail.footer = @"Só os getters LiquidGlass vivos. Os mortos (ToastPeek, IconBarButton, NavContentStylePinning, CGContextBlur, GlyphOpt, InternalDebugger) eram Swift direct-dispatch (sem call-site) e foram removidos.";
	lgDetail.rows = @[
		@{@"title":@"In-App Notification (LiquidGlass)", @"key":@"sci_igds_lg_inappnotif", @"restart":@NO},
		@{@"title":@"Toast (LiquidGlass)",               @"key":@"sci_igds_lg_toast",      @"restart":@NO},
		@{@"title":@"Ease-in-out Blur (LiquidGlass)",    @"key":@"sci_igds_lg_easeinout",  @"restart":@NO},
	];

	IGDSSection *nav = [IGDSSection new];
	nav.header = @"Navegação & Transições";
	nav.footer = @"NavPushRoundedCorners e TransitionZoom eram getters mortos (sem call-site) e foram removidos.";
	nav.rows = @[
		@{@"title":@"Context Menu Migration",            @"key":@"sci_igds_nav_ctxmenu",   @"restart":@NO},
		@{@"title":@"Native Bottom Sheet (iPhone)",      @"key":@"sci_igds_nav_bottomsheet", @"restart":@NO},
	];

	_sections = @[master, lg, prism, lgDetail, nav];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_sections[s].rows.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sections[s].header; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return _sections[s].footer; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"IGDS"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"IGDS"];
	SCIUIKit26ConfigureTableCell(c);
	NSDictionary *row = _sections[ip.section].rows[ip.row];
	c.textLabel.text = row[@"title"];
	c.textLabel.textColor = UIColor.labelColor;
	c.selectionStyle = UITableViewCellSelectionStyleNone;
	UISwitch *sw = [[UISwitch alloc] init];
	sw.on = [SCIUtils getBoolPref:row[@"key"]];
	sw.onTintColor = [SCIUtils SCIColor_Primary];
	[sw removeTarget:nil action:nil forControlEvents:UIControlEventAllEvents];
	objc_setAssociatedObject(sw, "igdsKey", row[@"key"], OBJC_ASSOCIATION_COPY);
	[sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
	c.accessoryView = sw;
	return c;
}

- (void)swChanged:(UISwitch *)sw {
	NSString *key = objc_getAssociatedObject(sw, "igdsKey");
	[SCIUtils setPref:@(sw.isOn) forKey:key];
}

@end
