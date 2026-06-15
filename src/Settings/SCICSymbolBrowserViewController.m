// SCICSymbolBrowserViewController.m
#import "SCICSymbolBrowserViewController.h"
#import "../Features/Gating/SCICSymbolEngine.h"
#import "../Utils.h"

@implementation SCICSymbolBrowserViewController {
	NSTimer *_refreshTimer;
}

- (instancetype)init {
	self = [super initWithTitle:@"C Symbols (MobileConfig / EasyGating)"];
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// Live refresh so call counts / captured IDs update while you use the app in
	// another tab and come back. Cheap: just reads atomics + reloads table.
	_refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
		[self rebuild];
	}];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[_refreshTimer invalidate]; _refreshTimer = nil;
}

- (void)rebuild {
	NSMutableArray<SCIBaseSettingsSection *> *sections = [NSMutableArray array];

	// ── Master controls ────────────────────────────────────────────────────
	NSMutableArray<SCIBaseSettingsRow *> *master = [NSMutableArray array];
	[master addObject:[SCIBaseSettingsRow switchRowWithTitle:@"Enable C-symbol forcing"
		subtitle:@"Liga o fishhook nos readers C. Requer relaunch apos ligar (instala no %ctor)."
		value:^BOOL{ return [SCIUtils getBoolPref:@"sci_c_symbol_force_enabled"]; }
		action:^(BOOL on, UIViewController *vc){ [SCIUtils setPref:@(on) forKey:@"sci_c_symbol_force_enabled"]; }]];
	[master addObject:[SCIBaseSettingsRow switchRowWithTitle:@"Diagnostic capture (all readers)"
		subtitle:@"Hooka TODOS os readers listados so para observar (chama orig, nao forca). Use para descobrir o ID do internal settings. Relaunch para aplicar."
		value:^BOOL{ return [SCIUtils getBoolPref:@"sci_c_symbol_diag_all"]; }
		action:^(BOOL on, UIViewController *vc){ [SCIUtils setPref:@(on) forKey:@"sci_c_symbol_diag_all"]; }]];
	[sections addObject:[SCIBaseSettingsSection sectionWithHeader:@"Master"
		footer:@"Os readers sao importados do FBSharedFramework via GOT, entao fishhook os intercepta. Forcar TODOS quebra o app: prefira forcar um simbolo especifico, ou melhor, um ID especifico capturado abaixo."
		rows:master]];

	// ── One section per symbol ──────────────────────────────────────────────
	for (SCICSymbol *sym in [SCICSymbolEngine allSymbols]) {
		NSMutableArray<SCIBaseSettingsRow *> *rows = [NSMutableArray array];
		NSString *symName = sym.symbolName;

		// Global force switch for the whole symbol.
		SCIBaseSettingsRow *g = [SCIBaseSettingsRow switchRowWithTitle:@"Force this symbol = YES"
			subtitle:[NSString stringWithFormat:@"%@", symName]
			value:^BOOL{ NSNumber *o = [SCICSymbolEngine overrideForSymbolName:symName]; return o.boolValue; }
			action:^(BOOL on, UIViewController *vc){
				[SCICSymbolEngine setOverride:(on ? @YES : nil) forSymbolName:symName];
			}];
		[rows addObject:g];

		// Live diagnostics row (dynamic).
		SCIBaseSettingsRow *diag = [SCIBaseSettingsRow rowWithTitle:@"" subtitle:nil action:nil];
		diag.dynamicTitle = ^NSString *{
			NSUInteger hits = [SCICSymbolEngine callCountForSymbolName:symName];
			BOOL installed = sym.hookInstalled;
			return [NSString stringWithFormat:@"%@ • %@ • %lu hits",
				sym.hookInstalled ? @"hooked" : @"not hooked",
				installed ? @"live" : @"—",
				(unsigned long)hits];
		};
		diag.dynamicSubtitle = ^NSString *{
			NSArray<NSNumber *> *ids = [SCICSymbolEngine observedIDsForSymbolName:symName];
			if (ids.count == 0) return @"Nenhum ID capturado ainda. Abra telas do IG para gerar leituras.";
			NSUInteger show = MIN(ids.count, 12);
			NSMutableArray *parts = [NSMutableArray array];
			for (NSUInteger i = 0; i < show; i++) [parts addObject:[ids[i] stringValue]];
			return [NSString stringWithFormat:@"IDs: %@%@", [parts componentsJoinedByString:@", "],
				ids.count > show ? [NSString stringWithFormat:@" (+%lu)", (unsigned long)(ids.count - show)] : @""];
		};
		diag.accessoryType = UITableViewCellAccessoryNone;
		[rows addObject:diag];

		// Per-ID force rows (families that expose a gating ID).
		if (sym.abiFamily != SCICAbiFamilyOpaqueBool) {
			NSArray<NSNumber *> *ids = [SCICSymbolEngine observedIDsForSymbolName:symName];
			NSArray<NSNumber *> *sorted = [ids sortedArrayUsingSelector:@selector(compare:)];
			NSUInteger cap = MIN(sorted.count, 40); // keep the table sane
			for (NSUInteger i = 0; i < cap; i++) {
				int32_t gid = (int32_t)sorted[i].intValue;
				NSNumber *observed = [SCICSymbolEngine observedValueForSymbolName:symName gatingID:gid];
				NSString *sub = observed ? [NSString stringWithFormat:@"real=%@", observed.boolValue ? @"YES" : @"NO"] : @"real=?";
				SCIBaseSettingsRow *idRow = [SCIBaseSettingsRow switchRowWithTitle:[NSString stringWithFormat:@"Force ID %d = YES", gid]
					subtitle:sub
					value:^BOOL{ NSNumber *o = [SCICSymbolEngine overrideForSymbolName:symName gatingID:gid]; return o.boolValue; }
					action:^(BOOL on, UIViewController *vc){
						[SCICSymbolEngine setOverride:(on ? @YES : nil) forSymbolName:symName gatingID:gid];
					}];
				[rows addObject:idRow];
			}
		}

		NSString *famText = (sym.abiFamily == SCICAbiFamilyOpaqueBool) ? @"force-only (sem ID legivel)"
			: (sym.abiFamily == SCICAbiFamilyGatingId_w0) ? @"gating ID em w0" : @"gating ID em w1";
		[sections addObject:[SCIBaseSettingsSection sectionWithHeader:sym.displayName
			footer:[NSString stringWithFormat:@"ABI: %@. Origem: %@.", famText, sym.originImage]
			rows:rows]];
	}

	self.sections = sections;
	[self reloadSettings];
}

@end
