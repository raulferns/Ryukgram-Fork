#import "SCIFBMobileConfigOverridesTableSearchViewController.h"
#import "../Utils.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>

@interface SCIFBMobileConfigOverridesTableSymbolModel : NSObject
@property (nonatomic, copy) NSString *mangledName;
@property (nonatomic, copy) NSString *demangledName;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSString *sectionName;
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *type;
@end

@implementation SCIFBMobileConfigOverridesTableSymbolModel
@end

static NSString *SCIDemangleCXX(NSString *mangled) {
    if (!mangled.length) return mangled;
    const char *name = mangled.UTF8String;
    if (name[0] == '_' && name[1] == '_') {
        name = name + 1;
    }
    
    typedef char* (*demangle_fn)(const char*, char*, size_t*, int*);
    static demangle_fn demangle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        demangle = (demangle_fn)dlsym(RTLD_DEFAULT, "__cxa_demangle");
    });
    
    if (demangle) {
        int status = 0;
        char* demangled = demangle(name, NULL, NULL, &status);
        if (status == 0 && demangled) {
            NSString *result = [NSString stringWithUTF8String:demangled];
            free(demangled);
            return result;
        }
    }
    return mangled;
}

static BOOL SCICIsImageWanted(NSString *path) {
    return [path.lastPathComponent isEqualToString:@"Instagram"] || [path containsString:@"/FBSharedFramework"];
}

static NSString *SCICImageShortName(NSString *path) {
    if ([path containsString:@"/FBSharedFramework"]) return @"FBSharedFramework";
    if ([path.lastPathComponent isEqualToString:@"Instagram"]) return @"Instagram";
    return path.lastPathComponent ?: @"Image";
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

@implementation SCIFBMobileConfigOverridesTableSearchViewController {
    NSArray<SCIFBMobileConfigOverridesTableSymbolModel *> *_allSymbols;
    NSArray<SCIFBMobileConfigOverridesTableSymbolModel *> *_filteredSymbols;
    NSString *_query;
    UIActivityIndicatorView *_spinner;
}

- (instancetype)init {
    self = [super initWithTitle:@"OverridesTable Search"];
    if (self) {
        self.reduceTopInset = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self;
    sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = @"Filter results...";
    self.navigationItem.searchController = sc;
    
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.center = self.view.center;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:_spinner];
    
    [self refreshSymbols];
}

- (void)refreshSymbols {
    [_spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<SCIFBMobileConfigOverridesTableSymbolModel *> *results = [NSMutableArray array];
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *imageName = _dyld_get_image_name(i);
            if (!imageName) continue;
            NSString *path = [NSString stringWithUTF8String:imageName];
            if (!SCICIsImageWanted(path)) continue;
            const struct mach_header *raw = _dyld_get_image_header(i);
            if (!raw || raw->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *mh = (const struct mach_header_64 *)raw;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            
            NSMutableArray<NSValue *> *sections = [NSMutableArray array];
            const struct symtab_command *symtab = NULL;
            const struct segment_command_64 *linkedit = NULL;
            scic_collect_sections(mh, sections, &symtab, &linkedit);
            if (!symtab || !linkedit) continue;
            
            uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
            const struct nlist_64 *nl = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
            const char *strtab = (const char *)(linkeditBase + symtab->stroff);
            
            NSString *imageShortName = SCICImageShortName(path);
            NSMutableSet *seen = [NSMutableSet set];
            
            for (uint32_t j = 0; j < symtab->nsyms; j++) {
                uint8_t type = nl[j].n_type;
                if (type & N_STAB) continue;
                uint8_t n_type_masked = type & N_TYPE;
                if (n_type_masked != N_SECT && n_type_masked != N_UNDF) continue;
                if (nl[j].n_un.n_strx == 0) continue;
                const char *rawName = strtab + nl[j].n_un.n_strx;
                if (!rawName) continue;
                
                if (strstr(rawName, "FBMobileConfigOverridesTable") == NULL) continue;
                
                NSString *name = [NSString stringWithUTF8String:(rawName[0] == '_') ? rawName + 1 : rawName];
                if (!name.length || [seen containsObject:name]) continue;
                [seen addObject:name];
                
                const struct section_64 *sec = NULL;
                uint8_t sectIndex = nl[j].n_sect;
                if (sectIndex > 0 && sectIndex <= sections.count) {
                    sec = [sections[sectIndex - 1] pointerValue];
                }
                NSString *section = scic_section_label(sec);
                
                SCIFBMobileConfigOverridesTableSymbolModel *model = [SCIFBMobileConfigOverridesTableSymbolModel new];
                model.mangledName = name;
                model.demangledName = SCIDemangleCXX(name);
                model.imageName = imageShortName;
                model.sectionName = section;
                model.address = [NSString stringWithFormat:@"0x%llx", (unsigned long long)(nl[j].n_value ? (nl[j].n_value + slide) : 0)];
                model.type = (n_type_masked == N_SECT) ? @"Defined" : @"Imported";
                [results addObject:model];
            }
        }
        
        [results sortUsingComparator:^NSComparisonResult(SCIFBMobileConfigOverridesTableSymbolModel *a, SCIFBMobileConfigOverridesTableSymbolModel *b) {
            return [a.demangledName compare:b.demangledName options:NSCaseInsensitiveSearch];
        }];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_allSymbols = results;
                [strongSelf->_spinner stopAnimating];
                [strongSelf rebuildSections];
            }
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _query = searchController.searchBar.text ?: @"";
    [self rebuildSections];
}

- (void)rebuildSections {
    NSArray *filtered = _allSymbols;
    if (_query.length > 0) {
        NSString *q = _query.lowercaseString;
        NSMutableArray *temp = [NSMutableArray array];
        for (SCIFBMobileConfigOverridesTableSymbolModel *m in _allSymbols) {
            if ([m.mangledName.lowercaseString containsString:q] ||
                [m.demangledName.lowercaseString containsString:q] ||
                [m.imageName.lowercaseString containsString:q] ||
                [m.type.lowercaseString containsString:q]) {
                [temp addObject:m];
            }
        }
        filtered = temp;
    }
    
    __weak typeof(self) weakSelf = self;
    NSMutableArray<SCIBaseSettingsRow *> *rows = [NSMutableArray array];
    for (SCIFBMobileConfigOverridesTableSymbolModel *m in filtered) {
        NSString *title = m.demangledName;
        NSString *subtitle = [NSString stringWithFormat:@"Mangled: %@\nAddress: %@ · Image: %@ · Section: %@ · Type: %@", 
                              m.mangledName, m.address, m.imageName, m.sectionName, m.type];
        
        SCIBaseSettingsRow *row = [SCIBaseSettingsRow rowWithTitle:title subtitle:subtitle action:^(UIViewController *vc) {
            [weakSelf showOptionsForSymbol:m];
        }];
        [rows addObject:row];
    }
    
    SCIBaseSettingsSection *section = [SCIBaseSettingsSection sectionWithHeader:[NSString stringWithFormat:@"Matches: %lu", (unsigned long)filtered.count]
                                                                        footer:@"Tap a row to copy options (symbol name or full details)."
                                                                          rows:rows];
    self.sections = @[section];
    [self reloadSettings];
}

- (void)showOptionsForSymbol:(SCIFBMobileConfigOverridesTableSymbolModel *)symbol {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Symbol Options"
                                                                   message:symbol.demangledName
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Demangled Name" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = symbol.demangledName;
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Mangled Name" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = symbol.mangledName;
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Full Details" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *details = [NSString stringWithFormat:@"Demangled: %@\nMangled: %@\nAddress: %@\nImage: %@\nSection: %@\nType: %@", 
                             symbol.demangledName, symbol.mangledName, symbol.address, symbol.imageName, symbol.sectionName, symbol.type];
        [UIPasteboard generalPasteboard].string = details;
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    UIPopoverPresentationController *pop = alert.popoverPresentationController;
    if (pop) {
        pop.sourceView = self.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 40, 1, 1);
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    UIListContentConfiguration *cfg = (UIListContentConfiguration *)cell.contentConfiguration;
    cfg.textProperties.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    cfg.textProperties.numberOfLines = 0;
    cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    cfg.secondaryTextProperties.numberOfLines = 0;
    cfg.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    cell.contentConfiguration = cfg;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

@end
