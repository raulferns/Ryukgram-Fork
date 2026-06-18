// SCISymbolsBrowserViewController.m
#import "SCISymbolsBrowserViewController.h"
#import "../Utils.h"
#import "../Features/Gating/SCICSymbolStub.h"
#import "../Features/Dogfooding/SCISymbolBrowserEngine.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

@interface SCICSymbolEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *image;
@property (nonatomic, copy) NSString *section;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *abi;
@property (nonatomic, copy) NSString *hookPlan;
@property (nonatomic, assign) BOOL function;
@property (nonatomic, assign) BOOL data;
@property (nonatomic, assign) BOOL swiftLike;
@property (nonatomic, assign) BOOL resolvable;
@property (nonatomic, assign) uintptr_t address;
@property (nonatomic, copy) NSString *objcClassName;
@property (nonatomic, copy) NSString *objcSelectorName;
@property (nonatomic, assign) BOOL objcClassMethod;
@end
@implementation SCICSymbolEntry @end

static NSString *SCICModeTitle(SCICSymbolsBrowserMode mode) {
    (void)mode;
    return @"Unified Runtime Browser";
}

static NSString *scic_section_label(const struct section_64 *sec) {
    if (!sec) return @"unknown";
    char seg[17] = {0}; char sect[17] = {0};
    memcpy(seg, sec->segname, 16); memcpy(sect, sec->sectname, 16);
    return [NSString stringWithFormat:@"%s,%s", seg, sect];
}

static void scic_collect_sections(const struct mach_header_64 *mh, NSMutableArray<NSValue *> *sections, const struct symtab_command **symtab, const struct segment_command_64 **linkedit) {
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) *linkedit = seg;
            const struct section_64 *sec = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) [sections addObject:[NSValue valueWithPointer:&sec[j]]];
        } else if (lc->cmd == LC_SYMTAB) {
            *symtab = (const struct symtab_command *)lc;
        }
        p += lc->cmdsize;
    }
}

static BOOL SCICIsImageWanted(NSString *path) {
    return [path.lastPathComponent isEqualToString:@"Instagram"] || [path containsString:@"/FBSharedFramework"];
}

static NSString *SCICImageShortName(NSString *path) {
    if ([path containsString:@"/FBSharedFramework"]) return @"FBSharedFramework";
    if ([path.lastPathComponent isEqualToString:@"Instagram"]) return @"Instagram";
    return path.lastPathComponent ?: @"Image";
}


static BOOL SCICRuntimeResolveSymbol(NSString *name, void **addrOut) {
    if (!name.length) return NO;
    void *p = dlsym(RTLD_DEFAULT, name.UTF8String);
    if (!p) p = dlsym(RTLD_DEFAULT, [[@"_" stringByAppendingString:name] UTF8String]);
    if (addrOut) *addrOut = p;
    return p != NULL;
}

static NSString *SCICImageForAddress(uintptr_t address) {
    if (!address) return @"unknown";
    Dl_info info = {0};
    if (dladdr((void *)address, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        return path.lastPathComponent ?: path;
    }
    return @"unknown";
}

static NSData *SCICBytesAtAddress(uintptr_t address, NSUInteger maxLen) {
    if (!address || !maxLen) return nil;
    @try {
        return [NSData dataWithBytes:(const void *)address length:maxLen];
    } @catch (__unused id ex) {
        return nil;
    }
}

static NSString *SCICHexDump(NSData *data, uintptr_t address) {
    if (!data.length) return @"<unavailable>";
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i += 4) {
        uint32_t word = 0;
        NSUInteger n = MIN((NSUInteger)4, data.length - i);
        memcpy(&word, b + i, n);
        [out appendFormat:@"0x%llx  %08x\n", (unsigned long long)(address + i), word];
    }
    return out.copy;
}

static int64_t SCICSignExtend(int64_t v, unsigned bits) {
    int64_t m = 1LL << (bits - 1);
    return (v ^ m) - m;
}

static NSString *SCICRegisterName(unsigned r, BOOL wide) {
    if (r == 31) return wide ? @"xzr/sp" : @"wzr/wsp";
    return [NSString stringWithFormat:@"%@%u", wide ? @"x" : @"w", r];
}

static NSString *SCICDecodeARM64(uint32_t insn, uintptr_t pc) {
    if (insn == 0xd503245f) return @"bti c";
    if (insn == 0xd503201f) return @"nop";
    if (insn == 0xd65f03c0) return @"ret";
    if ((insn & 0x7f800000) == 0x52800000) {
        unsigned rd = insn & 31;
        unsigned imm = (insn >> 5) & 0xffff;
        unsigned hw = (insn >> 21) & 3;
        return [NSString stringWithFormat:@"movz %@, #0x%x, lsl #%u", SCICRegisterName(rd, NO), imm, hw * 16];
    }
    if ((insn & 0xfc000000) == 0x94000000) {
        int64_t imm = SCICSignExtend((int64_t)(insn & 0x03ffffff), 26) << 2;
        return [NSString stringWithFormat:@"bl 0x%llx", (unsigned long long)(pc + imm)];
    }
    if ((insn & 0xfc000000) == 0x14000000) {
        int64_t imm = SCICSignExtend((int64_t)(insn & 0x03ffffff), 26) << 2;
        return [NSString stringWithFormat:@"b 0x%llx", (unsigned long long)(pc + imm)];
    }
    if ((insn & 0x9f000000) == 0x90000000) {
        unsigned rd = insn & 31;
        return [NSString stringWithFormat:@"adrp %@, <page>", SCICRegisterName(rd, YES)];
    }
    if ((insn & 0xffc00000) == 0x91000000) {
        unsigned rd = insn & 31, rn = (insn >> 5) & 31, imm = (insn >> 10) & 0xfff;
        return [NSString stringWithFormat:@"add %@, %@, #0x%x", SCICRegisterName(rd, YES), SCICRegisterName(rn, YES), imm];
    }
    if ((insn & 0xffc00000) == 0xb9400000) {
        unsigned rt = insn & 31, rn = (insn >> 5) & 31, imm = ((insn >> 10) & 0xfff) << 2;
        return [NSString stringWithFormat:@"ldr %@, [%@,#0x%x]", SCICRegisterName(rt, NO), SCICRegisterName(rn, YES), imm];
    }
    if ((insn & 0xffc00000) == 0xf9400000) {
        unsigned rt = insn & 31, rn = (insn >> 5) & 31, imm = ((insn >> 10) & 0xfff) << 3;
        return [NSString stringWithFormat:@"ldr %@, [%@,#0x%x]", SCICRegisterName(rt, YES), SCICRegisterName(rn, YES), imm];
    }
    if ((insn & 0xffe0ffe0) == 0xaa0003e0) {
        unsigned rd = insn & 31, rn = (insn >> 16) & 31;
        return [NSString stringWithFormat:@"mov %@, %@", SCICRegisterName(rd, YES), SCICRegisterName(rn, YES)];
    }
    return @"<decode pending>";
}

static NSString *SCICDisassembleCommonARM64(uintptr_t address, NSUInteger instructionCount) {
    NSData *data = SCICBytesAtAddress(address, instructionCount * 4);
    if (!data.length) return @"<bytes unavailable>";
    const uint8_t *b = data.bytes;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i + 4 <= data.length; i += 4) {
        uint32_t word = 0;
        memcpy(&word, b + i, 4);
        uintptr_t pc = address + i;
        [out appendFormat:@"0x%llx  %08x  %@\n", (unsigned long long)pc, word, SCICDecodeARM64(word, pc)];
    }
    return out.copy;
}

@interface SCICRealtimeDetailViewController : UIViewController
@property (nonatomic, strong) SCICSymbolEntry *entry;
@end

@implementation SCICRealtimeDetailViewController
- (instancetype)initWithEntry:(SCICSymbolEntry *)entry { if ((self=[super initWithNibName:nil bundle:nil])) { _entry=entry; self.title=@"Realtime"; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    SCIUIKit26ConfigureViewController(self);
    SCIConfigureNavigationChromeForGlass(self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshNow)];
    [self refreshNow];
}
- (void)refreshNow {
    for (UIView *v in self.view.subviews) [v removeFromSuperview];
    void *runtime = NULL;
    BOOL dlsymOK = SCICRuntimeResolveSymbol(self.entry.name, &runtime);
    uintptr_t addr = runtime ? (uintptr_t)runtime : self.entry.address;
    NSString *resolvedImage = SCICImageForAddress(addr);
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@\n\n", self.entry.name ?: @""];
    [text appendFormat:@"Mode: %@\nImage(enum): %@\nImage(runtime): %@\nSection: %@\nKind: %@\n", self.entry.swiftLike?@"Swift/C++":(self.entry.function?@"C function":@"DATA"), self.entry.image?:@"", resolvedImage, self.entry.section?:@"", self.entry.kind?:@""];
    [text appendFormat:@"Symbol table addr: 0x%llx\ndlsym: %@%@\n\n", (unsigned long long)self.entry.address, dlsymOK?@"YES":@"NO", dlsymOK?[NSString stringWithFormat:@" (0x%llx)", (unsigned long long)addr]:@""];
    [text appendFormat:@"ABI\n%@\n\nHook plan\n%@\n\n", self.entry.abi?:@"", self.entry.hookPlan?:@""];
    if (self.entry.function && addr) {
        [text appendString:@"Realtime ARM64 decode (common patterns)\n"];
        [text appendString:SCICDisassembleCommonARM64(addr, 12)];
        [text appendString:@"\nRaw bytes\n"];
        [text appendString:SCICHexDump(SCICBytesAtAddress(addr, 48), addr)];
    } else if (addr) {
        [text appendString:@"DATA bytes\n"];
        [text appendString:SCICHexDump(SCICBytesAtAddress(addr, 32), addr)];
    }
    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.editable = NO;
    tv.selectable = YES;
    tv.alwaysBounceVertical = YES;
    tv.backgroundColor = UIColor.clearColor;
    tv.textColor = UIColor.labelColor;
    tv.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    tv.textContainerInset = UIEdgeInsetsMake(14, 14, 24, 14);
    tv.text = text;
    [self.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
@end

static BOOL SCICNameLooksSwiftOrCXX(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    return [name hasPrefix:@"$s"] || [name hasPrefix:@"$S"] || [name hasPrefix:@"_T"] || [name hasPrefix:@"_Z"] || [name hasPrefix:@"__Z"] || [name containsString:@"Swift"];
}

static NSString *SCICABIForName(NSString *name, BOOL function, NSString *section) {
    if (!function) {
        if ([name hasPrefix:@"ig_"] || [name hasPrefix:@"xav_"] || [name hasPrefix:@"mc_team_"]) return @"DATA param descriptor; force via typed MobileConfig reader after xref/capture";
        if ([name containsString:@"MapSchema"] || [name containsString:@"MapFields"] || [name hasPrefix:@"IGAPI"]) return @"DATA schema/field map; no function ABI";
        if ([name hasPrefix:@"k"] || [name containsString:@"Key"] || [name containsString:@"Name"]) return @"DATA NSString/constant key; hook consumer, not symbol";
        return @"DATA/constant; not callable";
    }
    if ([name isEqualToString:@"IGMobileConfigBooleanValueForInternalUse"]) return @"BOOL reader: (id/param, BOOL default, void *ctx) -> BOOL w0";
    if ([name isEqualToString:@"IGMobileConfigIntegerValueForInternalUse"]) return @"integer reader: returns x0/w0; typed int64/int override only";
    if ([name isEqualToString:@"IGMobileConfigStringValueForInternalUse"]) return @"string reader: returns object/pointer in x0; ABI-specific, no BOOL stub";
    if ([name containsString:@"EasyGatingGetBoolean"]) return @"BOOL reader: gate id/context -> BOOL w0";
    if ([name containsString:@"EasyGatingGetInt32"]) return @"int32 reader: returns w0";
    if ([name containsString:@"EasyGatingGetInt64"]) return @"int64 reader: returns x0";
    if ([name containsString:@"EasyGatingGetDouble"]) return @"double reader: returns d0/v0";
    if ([name containsString:@"EasyGatingCopyString"]) return @"string/copy reader: returns pointer/object in x0; ownership-sensitive";
    if ([name isEqualToString:@"TALEventsGetIdToNameMappingForEventId"]) return @"event id -> name mapping; string/pointer return, observe/typed only";
    if ([name isEqualToString:@"MCIDatabaseTableToProcedureNameMapRegisterMappings"]) return @"registration/action; observe/log only, no return stub";
    if ([name hasPrefix:@"IGMobileConfigSetConfigOverrides"] || [name hasPrefix:@"IGMobileConfigForceUpdateConfigs"] || [name hasPrefix:@"IGMobileConfigTryUpdateConfigs"]) return @"MobileConfig action; call only with valid args/table, no return-YES";
    if (SCICNameLooksSwiftOrCXX(name)) return @"Swift/C++ direct symbol; disassemble/xref first, sideload hook not assumed";
    return @"unknown function ABI; classify before hook";
}

static NSString *SCICHookPlanForName(NSString *name, BOOL function, NSString *section) {
    if (!function) {
        if ([name hasPrefix:@"ig_"] || [name hasPrefix:@"xav_"] || [name hasPrefix:@"mc_team_"]) return @"Param hook: xref/capture descriptor, then force via IGMobileConfigBoolean/Integer/String reader";
        return @"No direct hook. Copy symbol and find consumer/xrefs.";
    }
    if ([SCICSymbolStub isForceableSymbol:name]) return @"Hardstub BOOL allowed: mov w0,#1; ret via fishhook";
    if ([name containsString:@"GetInt32"] || [name containsString:@"IntegerValue"] || [name containsString:@"GetInt64"]) return @"Typed numeric hook: return w0/x0; use value-specific replacement, not BOOL stub";
    if ([name containsString:@"GetDouble"]) return @"Typed double hook: return d0; use fmov/typed replacement";
    if ([name containsString:@"String"] || [name containsString:@"CopyString"] || [name isEqualToString:@"TALEventsGetIdToNameMappingForEventId"]) return @"Typed string hook: resolve ownership/CF/ObjC before forcing; observe safe";
    if ([name containsString:@"SetConfigOverrides"] || [name containsString:@"ForceUpdate"] || [name containsString:@"TryUpdate"] || [name containsString:@"RegisterMappings"]) return @"Action hook/button only with real args; never return-YES";
    return @"List/diagnose until ABI/callers are known";
}

static NSArray<NSString *> *SCICDefaultFiltersForMode(SCICSymbolsBrowserMode mode) {
    if (mode == SCICSymbolsBrowserModeObjCMethods) return @[@"MobileConfig", @"Gating", @"Employee", @"Dogfood", @"Internal", @"Debug", @"Plus", @"IGDS", @"Launcher"];
    if (mode == SCICSymbolsBrowserModeDataParams) return @[@"ig_is_employee", @"ig_user_session", @"xav_switcher", @"mc_team", @"MapFields", @"MapSchema", @"OpenSettings", @"DeveloperAccount", @"FeatureFlags"];
    if (mode == SCICSymbolsBrowserModeSwiftDisassembly) return @[@"$s", @"_Tt", @"ConsumerSubs", @"MobileConfig", @"Dogfood", @"Eligibility", @"FeatureFlags"];
    return @[@"MobileConfig", @"EasyGating", @"MSGC", @"MCI", @"TALEvents", @"RegisterMappings", @"UpdateConfigs", @"SetConfigOverrides", @"InternalApps", @"Minos"];
}

static void SCICEnumerateImageSymbolsAtIndex(uint32_t imageIndex, NSMutableArray<SCICSymbolEntry *> *out) {
    const char *imageName = _dyld_get_image_name(imageIndex);
    if (!imageName) return;
    NSString *path = [NSString stringWithUTF8String:imageName];
    if (!SCICIsImageWanted(path)) return;
    const struct mach_header *raw = _dyld_get_image_header(imageIndex);
    if (!raw || raw->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    NSMutableArray<NSValue *> *sections = [NSMutableArray array];
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    scic_collect_sections(mh, sections, &symtab, &linkedit);
    if (!symtab || !linkedit) return;
    uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *nl = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strtab = (const char *)(linkeditBase + symtab->stroff);
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        uint8_t type = nl[i].n_type;
        if (type & N_STAB) continue;
        if ((type & N_TYPE) != N_SECT) continue;
        if (nl[i].n_un.n_strx == 0) continue;
        const char *rawName = strtab + nl[i].n_un.n_strx;
        if (!rawName || rawName[0] != '_') continue;
        NSString *name = [NSString stringWithUTF8String:rawName + 1];
        if (!name.length || [seen containsObject:name]) continue;
        if ([name hasPrefix:@"OBJC_"] || [name hasPrefix:@"\001"]) continue;
        [seen addObject:name];
        const struct section_64 *sec = NULL;
        uint8_t sectIndex = nl[i].n_sect;
        if (sectIndex > 0 && sectIndex <= sections.count) sec = [sections[sectIndex - 1] pointerValue];
        NSString *section = scic_section_label(sec);
        BOOL isText = sec && strncmp(sec->segname, "__TEXT", 16) == 0 && strncmp(sec->sectname, "__text", 16) == 0;
        SCICSymbolEntry *e = [SCICSymbolEntry new];
        e.name = name;
        e.image = SCICImageShortName(path);
        e.section = section;
        e.function = isText;
        e.data = !isText;
        e.swiftLike = SCICNameLooksSwiftOrCXX(name);
        e.address = (uintptr_t)nl[i].n_value + (uintptr_t)slide;
        e.kind = isText ? (e.swiftLike ? @"Swift/C++ function" : @"C/function") : @"DATA/const";
        e.abi = SCICABIForName(name, isText, section);
        e.hookPlan = SCICHookPlanForName(name, isText, section);
        e.resolvable = (dlsym(RTLD_DEFAULT, name.UTF8String) != NULL || dlsym(RTLD_DEFAULT, [[@"_" stringByAppendingString:name] UTF8String]) != NULL);
        [out addObject:e];
    }
}


static NSArray<SCICSymbolEntry *> *SCICEnumerateObjCEntriesForImage(SCISymbolImage image) {
    NSMutableArray<SCICSymbolEntry *> *out = [NSMutableArray array];
    NSString *imgName = image == SCISymbolImageInstagram ? @"Instagram" : @"FBSharedFramework";
    NSArray<SCISymbolClass *> *classes = [SCISymbolBrowserEngine classesForImage:image] ?: @[];
    for (SCISymbolClass *cls in classes) {
        for (SCISymbolGetter *g in cls.getters ?: @[]) {
            SCICSymbolEntry *e = [SCICSymbolEntry new];
            e.name = [NSString stringWithFormat:@"%@%@#%@", g.isClassMethod ? @"+" : @"", cls.className ?: @"", g.selectorName ?: @""];
            e.image = imgName;
            e.section = @"ObjC runtime";
            e.kind = @"ObjC BOOL getter";
            e.function = YES;
            e.data = NO;
            e.swiftLike = NO;
            e.resolvable = YES;
            e.abi = @"ObjC dispatch BOOL getter: id self, SEL _cmd -> BOOL w0; hook via SCISymbolBrowserEngine/MSHookMessageEx.";
            e.hookPlan = @"Force ON/OFF through ObjC runtime browser override. No C stub.";
            e.objcClassName = cls.className ?: @"";
            e.objcSelectorName = g.selectorName ?: @"";
            e.objcClassMethod = g.isClassMethod;
            [out addObject:e];
        }
    }
    return out.copy;
}

static NSArray<SCICSymbolEntry *> *SCICEnumerateInstagramAndFBSharedSymbols(void) {
    NSMutableArray *out = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) SCICEnumerateImageSymbolsAtIndex(i, out);
    [out sortUsingComparator:^NSComparisonResult(SCICSymbolEntry *a, SCICSymbolEntry *b) {
        NSComparisonResult r = [a.image compare:b.image options:NSCaseInsensitiveSearch];
        return r == NSOrderedSame ? [a.name compare:b.name options:NSCaseInsensitiveSearch] : r;
    }];
    return out.copy;
}

static char kSCICSymbolRowPayloadKey;

@interface SCISymbolsBrowserViewController () <UISearchResultsUpdating>
@end

@implementation SCISymbolsBrowserViewController {
    SCICSymbolsBrowserMode _mode;
    NSArray<SCICSymbolEntry *> *_allSymbols;
    NSString *_query;
    UIActivityIndicatorView *_spinner;
    UISegmentedControl *_imageSegment;
    UISegmentedControl *_kindSegment;
}

- (instancetype)init { return [self initWithMode:SCICSymbolsBrowserModeObjCMethods]; }
- (instancetype)initWithMode:(SCICSymbolsBrowserMode)mode {
    self = [super initWithTitle:SCICModeTitle(mode)];
    if (self) { _mode = mode; self.reduceTopInset = NO; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = @"Search symbols, ABI, section…";
    SCIUIKit26ConfigureSearchBar(sc.searchBar);
    self.navigationItem.searchController = sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshRuntimeSymbols)];
    [self configureUnifiedTabs];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.center = self.view.center;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spinner];
    [_spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *symbols = [SCICEnumerateInstagramAndFBSharedSymbols() mutableCopy];
        [symbols addObjectsFromArray:SCICEnumerateObjCEntriesForImage(SCISymbolImageInstagram)];
        [symbols addObjectsFromArray:SCICEnumerateObjCEntriesForImage(SCISymbolImageFBShared)];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_allSymbols = symbols;
            [self->_spinner stopAnimating];
            [self rebuildSections];
        });
    });
}



- (void)configureUnifiedTabs {
    _imageSegment = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Exec", @"FBShared"]];
    _imageSegment.selectedSegmentIndex = 0;
    [_imageSegment addTarget:self action:@selector(unifiedTabChanged:) forControlEvents:UIControlEventValueChanged];
    SCIUIKit26ConfigureSegmentedControl(_imageSegment);

    _kindSegment = [[UISegmentedControl alloc] initWithItems:@[@"ObjC", @"C", @"DATA", @"Swift"]];
    _kindSegment.selectedSegmentIndex = MAX(0, MIN(3, (NSInteger)_mode));
    [_kindSegment addTarget:self action:@selector(unifiedTabChanged:) forControlEvents:UIControlEventValueChanged];
    SCIUIKit26ConfigureSegmentedControl(_kindSegment);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_imageSegment, _kindSegment]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    stack.layoutMargins = UIEdgeInsetsMake(8, 16, 8, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 92)];
    wrap.backgroundColor = UIColor.clearColor;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
    ]];
    self.tableView.tableHeaderView = wrap;
}

- (void)unifiedTabChanged:(__unused id)sender {
    _mode = (SCICSymbolsBrowserMode)_kindSegment.selectedSegmentIndex;
    [self rebuildSections];
}

- (void)refreshRuntimeSymbols {
    [_spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *symbols = [SCICEnumerateInstagramAndFBSharedSymbols() mutableCopy];
        [symbols addObjectsFromArray:SCICEnumerateObjCEntriesForImage(SCISymbolImageInstagram)];
        [symbols addObjectsFromArray:SCICEnumerateObjCEntriesForImage(SCISymbolImageFBShared)];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_allSymbols = symbols;
            [self->_spinner stopAnimating];
            [self rebuildSections];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _query = searchController.searchBar.text ?: @"";
    [self rebuildSections];
}

- (NSArray<NSString *> *)queryTokens {
    NSString *q = [[_query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!q.length) return @[];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *t in [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) if (t.length) [tokens addObject:t];
    return tokens.copy;
}

- (BOOL)entryMatchesMode:(SCICSymbolEntry *)e {
    if (_imageSegment.selectedSegmentIndex == 1 && ![e.image isEqualToString:@"Instagram"]) return NO;
    if (_imageSegment.selectedSegmentIndex == 2 && ![e.image isEqualToString:@"FBSharedFramework"]) return NO;
    if (_mode == SCICSymbolsBrowserModeObjCMethods) return e.objcSelectorName.length > 0;
    if (_mode == SCICSymbolsBrowserModeCFunctions) return e.function && !e.swiftLike && e.objcSelectorName.length == 0;
    if (_mode == SCICSymbolsBrowserModeDataParams) return e.data;
    return e.function && e.swiftLike && e.objcSelectorName.length == 0;
}

- (BOOL)entry:(SCICSymbolEntry *)e matchesTokens:(NSArray<NSString *> *)tokens {
    NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@", e.name?:@"", e.image?:@"", e.section?:@"", e.kind?:@"", e.abi?:@"", e.hookPlan?:@""].lowercaseString;
    for (NSString *t in tokens) if (![hay containsString:t]) return NO;
    return YES;
}

- (BOOL)entryMatchesDefaultFilters:(SCICSymbolEntry *)e {
    if (e.objcSelectorName.length) { NSString *k=[NSString stringWithFormat:@"%@%@", e.objcClassMethod?@"+":@"", [NSString stringWithFormat:@"%@#%@", e.objcClassName?:@"", e.objcSelectorName?:@""]]; if ([SCISymbolBrowserEngine overrideForKey:k] != nil) return YES; }
    if ([SCICSymbolStub forceForSymbol:e.name] != nil || [SCICSymbolStub typedForceForSymbol:e.name] != nil || [SCICSymbolStub forceForParamDescriptorSymbol:e.name] != nil || [SCICSymbolStub hookInstalledForSymbol:e.name]) return YES;
    for (NSString *f in SCICDefaultFiltersForMode(_mode)) if ([e.name.lowercaseString containsString:f.lowercaseString] || [e.abi.lowercaseString containsString:f.lowercaseString]) return YES;
    return NO;
}

- (NSString *)subtitleForEntry:(SCICSymbolEntry *)e {
    NSMutableArray *bits = [NSMutableArray array];
    [bits addObject:e.image ?: @"Image"];
    [bits addObject:e.section ?: @"section?"];
    [bits addObject:e.kind ?: @"kind?"];
    if (e.objcSelectorName.length) {
        NSNumber *forced = [SCISymbolBrowserEngine overrideForKey:[NSString stringWithFormat:@"%@%@#%@", e.objcClassMethod?@"+":@"", e.objcClassName?:@"", e.objcSelectorName?:@""]];
        [bits addObject:forced ? (forced.boolValue ? @"ObjC forced ON" : @"ObjC forced OFF") : @"ObjC live/passthrough"];
    } else if (e.resolvable) [bits addObject:@"dlsym OK"];
    NSNumber *pf = [SCICSymbolStub forceForParamDescriptorSymbol:e.name];
    NSDictionary *typed = [SCICSymbolStub typedForceForSymbol:e.name];
    if (pf) [bits addObject:[NSString stringWithFormat:@"param forced %@", pf.boolValue?@"YES":@"NO"]];
    else if ([SCICSymbolStub forceForSymbol:e.name] != nil) [bits addObject:@"BOOL forced"];
    else if (typed) [bits addObject:[NSString stringWithFormat:@"%@ forced %@", typed[@"kind"] ?: @"typed", typed[@"value"] ?: @""]];
    else if ([SCICSymbolStub isParamDescriptorSymbol:e.name]) [bits addObject:@"param force via MC bool reader"];
    else if (e.function && [SCICSymbolStub isForceableSymbol:e.name]) [bits addObject:@"BOOL hardstub allowed"];
    else if (e.function && [SCICSymbolStub isTypedForceableSymbol:e.name]) [bits addObject:[NSString stringWithFormat:@"%@ force allowed", [SCICSymbolStub returnKindForSymbol:e.name] ?: @"typed"]];
    else [bits addObject:e.abi ?: @"ABI unknown"];
    return [bits componentsJoinedByString:@" · "];
}

- (NSString *)detailForEntry:(SCICSymbolEntry *)e {
    if (e.objcSelectorName.length) return [NSString stringWithFormat:@"%@\n\nImage: %@\nKind: %@\nClass: %@\nSelector: %@\nClass method: %@\n\nABI: %@\n\nHook plan: %@", e.name?:@"", e.image?:@"", e.kind?:@"", e.objcClassName?:@"", e.objcSelectorName?:@"", e.objcClassMethod?@"YES":@"NO", e.abi?:@"", e.hookPlan?:@""];
    return [NSString stringWithFormat:@"%@\n\nImage: %@\nSection: %@\nAddress: 0x%llx\nKind: %@\nResolvable: %@\n\nABI: %@\n\nHook plan: %@", e.name?:@"", e.image?:@"", e.section?:@"", (unsigned long long)e.address, e.kind?:@"", e.resolvable?@"YES":@"NO", e.abi?:@"", e.hookPlan?:@""];
}

- (void)pushRealtimeDetailForEntry:(SCICSymbolEntry *)entry {
    if (!entry) return;
    [self.navigationController pushViewController:[[SCICRealtimeDetailViewController alloc] initWithEntry:entry] animated:YES];
}



- (NSString *)objcOverrideKeyForEntry:(SCICSymbolEntry *)entry {
    if (!entry.objcSelectorName.length) return nil;
    return [NSString stringWithFormat:@"%@%@#%@", entry.objcClassMethod ? @"+" : @"", entry.objcClassName ?: @"", entry.objcSelectorName ?: @""];
}

- (void)setObjCEntry:(SCICSymbolEntry *)entry force:(NSNumber *)value {
    if (!entry.objcSelectorName.length) return;
    [SCISymbolBrowserEngine setOverride:value forClass:entry.objcClassName ?: @"" selector:entry.objcSelectorName ?: @"" isClassMethod:entry.objcClassMethod];
    [self rebuildSections];
}

- (void)setParamEntry:(SCICSymbolEntry *)entry force:(NSNumber *)value {
    if (![SCICSymbolStub isParamDescriptorSymbol:entry.name]) return;
    [SCICSymbolStub setParamDescriptorForce:value forSymbol:entry.name];
    [self rebuildSections];
}

- (void)promptTypedForceForEntry:(SCICSymbolEntry *)entry {
    NSString *kind = [SCICSymbolStub returnKindForSymbol:entry.name] ?: @"unknown";
    if (![SCICSymbolStub isTypedForceableSymbol:entry.name]) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Force %@", kind]
                                                                 message:entry.name
                                                          preferredStyle:UIAlertControllerStyleAlert];
    NSString *placeholder = [kind isEqualToString:@"double"] ? @"1.0" : ([kind isEqualToString:@"string"] ? @"forced" : @"1");
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = placeholder;
        NSDictionary *cur = [SCICSymbolStub typedForceForSymbol:entry.name];
        id v = cur[@"value"];
        tf.text = v ? [v description] : placeholder;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        if ([kind isEqualToString:@"int64"] || [kind isEqualToString:@"double"]) tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        id value = text;
        if ([kind isEqualToString:@"int64"]) value = @([text longLongValue]);
        else if ([kind isEqualToString:@"double"]) value = @([text doubleValue]);
        [SCICSymbolStub setTypedForceValue:value returnKind:kind forSymbol:entry.name];
        [weakSelf rebuildSections];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)presentActionsForEntry:(SCICSymbolEntry *)entry {
    if (!entry) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:entry.name message:[self detailForEntry:entry] preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Realtime resolve/disassemble" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf pushRealtimeDetailForEntry:entry]; }]];
    if (entry.objcSelectorName.length) {
        [a addAction:[UIAlertAction actionWithTitle:@"Force ObjC BOOL ON" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf setObjCEntry:entry force:@YES]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Force ObjC BOOL OFF" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf setObjCEntry:entry force:@NO]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear ObjC override" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act){ [weakSelf setObjCEntry:entry force:nil]; }]];
    } else if ([SCICSymbolStub isParamDescriptorSymbol:entry.name]) {
        [a addAction:[UIAlertAction actionWithTitle:@"Force param YES via MobileConfig BOOL reader" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf setParamEntry:entry force:@YES]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Force param NO via MobileConfig BOOL reader" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf setParamEntry:entry force:@NO]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear param force" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act){ [weakSelf setParamEntry:entry force:nil]; }]];
    } else if (entry.function && [SCICSymbolStub isForceableSymbol:entry.name]) {
        [a addAction:[UIAlertAction actionWithTitle:@"Force BOOL YES (hardstub)" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setForce:@YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Force BOOL NO (hardstub)" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setForce:@NO forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Observe only" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setObserve:YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear BOOL force" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setForce:nil forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
    } else if (entry.function && [SCICSymbolStub isTypedForceableSymbol:entry.name]) {
        NSString *kind = [SCICSymbolStub returnKindForSymbol:entry.name] ?: @"typed";
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Force %@ value…", kind] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [weakSelf promptTypedForceForEntry:entry]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Observe only" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setObserve:YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Clear typed force" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setTypedForceValue:nil returnKind:kind forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
    } else if (entry.function && [SCICSymbolStub isHookableSymbol:entry.name]) {
        [a addAction:[UIAlertAction actionWithTitle:@"Observe action/function" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [SCICSymbolStub setObserve:YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
    } else {
        UIAlertAction *blocked = [UIAlertAction actionWithTitle:@"No safe runtime hook: see ABI/Hook plan" style:UIAlertActionStyleDefault handler:nil];
        blocked.enabled = NO;
        [a addAction:blocked];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Copy symbol" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ UIPasteboard.generalPasteboard.string = entry.name ?: @""; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy ABI report" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ UIPasteboard.generalPasteboard.string = [weakSelf detailForEntry:entry]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = a.popoverPresentationController;
    pop.sourceView = self.view;
    pop.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds)-40, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)rebuildSections {
    if (!_allSymbols) return;
    NSArray *tokens = [self queryTokens];
    NSMutableArray *igRows = [NSMutableArray array];
    NSMutableArray *fbRows = [NSMutableArray array];
    NSUInteger limit = tokens.count ? 700 : 300;
    NSUInteger shown = 0;
    for (SCICSymbolEntry *e in _allSymbols) {
        if (![self entryMatchesMode:e]) continue;
        if (tokens.count) { if (![self entry:e matchesTokens:tokens]) continue; }
        else if (![self entryMatchesDefaultFilters:e]) continue;
        if (shown++ >= limit) break;
        SCIBaseSettingsRow *row = [SCIBaseSettingsRow rowWithTitle:e.name subtitle:nil action:^(__unused UIViewController *vc){ [self pushRealtimeDetailForEntry:e]; }];
        row.dynamicSubtitle = ^NSString *{ return [self subtitleForEntry:e]; };
        objc_setAssociatedObject(row, &kSCICSymbolRowPayloadKey, e, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([e.image isEqualToString:@"Instagram"]) [igRows addObject:row]; else [fbRows addObject:row];
    }
    NSString *footer = @"Modes are separated: C functions, DATA/param descriptors, and Swift/direct-dispatch symbols. ObjC method browsing remains in the Instagram/FBShared ObjC browsers. Validated BOOL functions get hardstub toggles; validated int64/double/string readers get typed runtime force; actions get observe-only unless arguments are mounted by a dedicated button.";
    if (!igRows.count) [igRows addObject:[SCIBaseSettingsRow rowWithTitle:@"No Instagram symbols" subtitle:@"Search another term or switch browser mode." action:nil]];
    if (!fbRows.count) [fbRows addObject:[SCIBaseSettingsRow rowWithTitle:@"No FBShared symbols" subtitle:@"Search another term or switch browser mode." action:nil]];
    self.sections = @[
        [SCIBaseSettingsSection sectionWithHeader:@"Instagram executable" footer:nil rows:igRows],
        [SCIBaseSettingsSection sectionWithHeader:@"FBSharedFramework" footer:footer rows:fbRows],
    ];
    [self reloadSettings];
}


- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(__unused CGPoint)point {
    SCIBaseSettingsRow *row = self.sections[indexPath.section].rows[indexPath.row];
    SCICSymbolEntry *entry = objc_getAssociatedObject(row, &kSCICSymbolRowPayloadKey);
    if (!entry) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        [items addObject:[UIAction actionWithTitle:@"Realtime resolve/disassemble" image:[UIImage systemImageNamed:@"waveform.path.ecg"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf pushRealtimeDetailForEntry:entry]; }]];
        if (entry.objcSelectorName.length) {
            [items addObject:[UIAction actionWithTitle:@"Force ObjC BOOL ON" image:[UIImage systemImageNamed:@"switch.2"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf setObjCEntry:entry force:@YES]; }]];
            [items addObject:[UIAction actionWithTitle:@"Clear ObjC override" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf setObjCEntry:entry force:nil]; }]];
        } else if ([SCICSymbolStub isParamDescriptorSymbol:entry.name]) {
            [items addObject:[UIAction actionWithTitle:@"Force param YES via reader" image:[UIImage systemImageNamed:@"bolt.fill"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf setParamEntry:entry force:@YES]; }]];
            [items addObject:[UIAction actionWithTitle:@"Clear param force" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf setParamEntry:entry force:nil]; }]];
        } else if (entry.function && [SCICSymbolStub isForceableSymbol:entry.name]) {
            [items addObject:[UIAction actionWithTitle:@"Force BOOL YES (hardstub)" image:[UIImage systemImageNamed:@"bolt.fill"] identifier:nil handler:^(__unused UIAction *action) { [SCICSymbolStub setForce:@YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
            [items addObject:[UIAction actionWithTitle:@"Clear BOOL force" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [SCICSymbolStub setForce:nil forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        } else if (entry.function && [SCICSymbolStub isTypedForceableSymbol:entry.name]) {
            NSString *kind = [SCICSymbolStub returnKindForSymbol:entry.name] ?: @"typed";
            [items addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Force %@ value…", kind] image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(__unused UIAction *action) { [weakSelf promptTypedForceForEntry:entry]; }]];
            [items addObject:[UIAction actionWithTitle:@"Clear typed force" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(__unused UIAction *action) { [SCICSymbolStub setTypedForceValue:nil returnKind:kind forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        } else if (entry.function && [SCICSymbolStub isHookableSymbol:entry.name]) {
            [items addObject:[UIAction actionWithTitle:@"Observe action/function" image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(__unused UIAction *action) { [SCICSymbolStub setObserve:YES forSymbol:entry.name]; [weakSelf rebuildSections]; }]];
        }
        [items addObject:[UIAction actionWithTitle:@"Copy symbol" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action) { UIPasteboard.generalPasteboard.string = entry.name ?: @""; }]];
        [items addObject:[UIAction actionWithTitle:@"Copy ABI report" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(__unused UIAction *action) { UIPasteboard.generalPasteboard.string = [weakSelf detailForEntry:entry]; }]];
        return [UIMenu menuWithTitle:entry.name ?: @"Symbol" children:items];
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    UIListContentConfiguration *cfg = (UIListContentConfiguration *)cell.contentConfiguration;
    cfg.textProperties.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    cfg.textProperties.numberOfLines = 2;
    cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
    cfg.secondaryTextProperties.numberOfLines = 3;
    cell.contentConfiguration = cfg;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

@end
