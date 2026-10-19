// NuvioFontManager - experimental TrollStore/TrollFools tweak.
// Separate imported fonts for MPV subtitles and UIKit-native interface elements.
// Compose/Skiko text may require a deeper Kotlin/Skia-specific hook; see README.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>

#pragma mark - Minimal fishhook-style symbol rebinding
struct NFRebinding { const char *name; void *replacement; void **replaced; };
static struct NFRebinding gRebindings[8];
static size_t gRebindingCount = 0;
static void nf_rebind_image(const struct mach_header *header, intptr_t slide);

static void nf_rebind_symbols(struct NFRebinding *rebindings, size_t count) {
    if (!rebindings || !count) return;
    for (size_t i = 0; i < count && gRebindingCount < 8; i++) gRebindings[gRebindingCount++] = rebindings[i];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) nf_rebind_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
}

static bool nf_name_matches(const char *sym, const char *wanted) {
    if (!sym || !wanted) return false;
    if (sym[0] == '_') sym++;
    return strcmp(sym, wanted) == 0;
}

static void nf_rebind_image(const struct mach_header *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct section_64 *sections[256]; unsigned sectionCount = 0;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
            const struct section_64 *sec = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects && sectionCount < 256; j++) sections[sectionCount++] = &sec[j];
        } else if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)lc;
        cursor += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab) return;
    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);
    for (unsigned s = 0; s < sectionCount; s++) {
        const struct section_64 *sec = sections[s];
        if ((sec->flags & SECTION_TYPE) != S_LAZY_SYMBOL_POINTERS && (sec->flags & SECTION_TYPE) != S_NON_LAZY_SYMBOL_POINTERS) continue;
        uint32_t *slots = (uint32_t *)(slide + sec->addr);
        uintptr_t *pointers = (uintptr_t *)slots;
        uint32_t n = (uint32_t)(sec->size / sizeof(uintptr_t));
        for (uint32_t i = 0; i < n; i++) {
            uint32_t symIndex = indirect[sec->reserved1 + i];
            if (symIndex == INDIRECT_SYMBOL_ABS || symIndex == INDIRECT_SYMBOL_LOCAL || symIndex == (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
            const char *symbolName = strings + symbols[symIndex].n_un.n_strx;
            for (size_t r = 0; r < gRebindingCount; r++) {
                if (!nf_name_matches(symbolName, gRebindings[r].name)) continue;
                uintptr_t *slot = &pointers[i];
                if (gRebindings[r].replaced && !*gRebindings[r].replaced) *gRebindings[r].replaced = (void *)*slot;
                vm_protect(mach_task_self(), (vm_address_t)((uintptr_t)slot & ~(vm_page_size - 1)), vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                *slot = (uintptr_t)gRebindings[r].replacement;
                vm_protect(mach_task_self(), (vm_address_t)((uintptr_t)slot & ~(vm_page_size - 1)), vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE);
            }
        }
    }
}

#pragma mark - Storage and MPV
static NSString *NFRoot(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *root = [[paths firstObject] stringByAppendingPathComponent:@"NuvioFontManager"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[root stringByAppendingPathComponent:@"Video"] withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:[root stringByAppendingPathComponent:@"Interface"] withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}
static NSString *NFVideoFontPath(void) { return [[NSUserDefaults standardUserDefaults] stringForKey:@"NFVideoFontPath"]; }
static NSString *NFVideoFontFamily(void) { return [[NSUserDefaults standardUserDefaults] stringForKey:@"NFVideoFontFamily"]; }
static NSString *NFInterfaceFontPath(void) { return [[NSUserDefaults standardUserDefaults] stringForKey:@"NFInterfaceFontPath"]; }
static NSString *NFInterfaceFontName(void) { return [[NSUserDefaults standardUserDefaults] stringForKey:@"NFInterfaceFontName"]; }

typedef void *(*NFMPVCreateFn)(void);
typedef int (*NFMPVSetPropertyFn)(void *, const char *, const char *);
typedef int (*NFMPVInitializeFn)(void *);
static NFMPVInitializeFn nf_orig_mpv_initialize = NULL;
static NFMPVCreateFn nf_orig_mpv_create = NULL;
static NFMPVSetPropertyFn nf_mpv_set_property_string = NULL;
static NSMutableArray<NSValue *> *nf_playerHandles;
static void nf_apply_video_font(void *handle) {
    NSString *family = NFVideoFontFamily();
    if (!handle || !family.length) return;
    if (!nf_mpv_set_property_string) nf_mpv_set_property_string = (NFMPVSetPropertyFn)dlsym(RTLD_DEFAULT, "mpv_set_property_string");
    if (nf_mpv_set_property_string) nf_mpv_set_property_string(handle, "sub-font", family.UTF8String);
}
static int nf_mpv_initialize_hook(void *handle) {
    int result = nf_orig_mpv_initialize ? nf_orig_mpv_initialize(handle) : -1;
    if (result >= 0) nf_apply_video_font(handle);
    return result;
}
static void *nf_mpv_create_hook(void) {
    void *h = nf_orig_mpv_create ? nf_orig_mpv_create() : NULL;
    if (h) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!nf_playerHandles) nf_playerHandles = [NSMutableArray array];
            [nf_playerHandles addObject:[NSValue valueWithPointer:h]];
            nf_apply_video_font(h);
        });
    }
    return h;
}

#pragma mark - UIKit font fallback hook (does not guarantee Compose/Skiko coverage)
static UIFont *(*nf_orig_systemFont)(id, SEL, CGFloat) = NULL;
static UIFont *(*nf_orig_boldSystemFont)(id, SEL, CGFloat) = NULL;
static BOOL nf_ui_hooks_installed = NO;
static UIFont *nf_custom_ui_font(CGFloat size, BOOL bold) {
    NSString *name = NFInterfaceFontName();
    if (name.length) {
        UIFont *font = [UIFont fontWithName:name size:size];
        if (font) return font;
    }
    return nil;
}
static UIFont *nf_system_font_hook(id self, SEL cmd, CGFloat size) {
    UIFont *f = nf_custom_ui_font(size, NO);
    return f ?: (nf_orig_systemFont ? nf_orig_systemFont(self, cmd, size) : [UIFont systemFontOfSize:size]);
}
static UIFont *nf_bold_font_hook(id self, SEL cmd, CGFloat size) {
    UIFont *f = nf_custom_ui_font(size, YES);
    return f ?: (nf_orig_boldSystemFont ? nf_orig_boldSystemFont(self, cmd, size) : [UIFont boldSystemFontOfSize:size]);
}
static void nf_hook_ui_fonts(void) {
    if (nf_ui_hooks_installed) return;
    nf_ui_hooks_installed = YES;
    Class meta = object_getClass([UIFont class]);
    Method m1 = class_getClassMethod([UIFont class], @selector(systemFontOfSize:));
    Method m2 = class_getClassMethod([UIFont class], @selector(boldSystemFontOfSize:));
    if (m1) nf_orig_systemFont = (void *)method_setImplementation(m1, (IMP)nf_system_font_hook);
    if (m2) nf_orig_boldSystemFont = (void *)method_setImplementation(m2, (IMP)nf_bold_font_hook);
    (void)meta;
}

#pragma mark - Import and settings UI
@interface NFSettingsController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic) UISegmentedControl *segment;
@property(nonatomic) UILabel *status;
@property(nonatomic) UIButton *importButton;
@property(nonatomic) UIButton *resetButton;
@property(nonatomic) NSString *target;
@end
@implementation NFSettingsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.title = @"Nuvio Font Manager";
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; [close setTitle:@"Đóng" forState:UIControlStateNormal];
    close.frame = CGRectMake(0, 0, 60, 36); [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:close];
    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"Video", @"Giao diện"]]; self.segment.selectedSegmentIndex = 0;
    self.segment.translatesAutoresizingMaskIntoConstraints = NO; [self.segment addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged]; [self.view addSubview:self.segment];
    self.status = [UILabel new]; self.status.numberOfLines = 0; self.status.font = [UIFont systemFontOfSize:15]; self.status.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.status];
    self.importButton = [UIButton buttonWithType:UIButtonTypeSystem]; self.importButton.backgroundColor = [UIColor systemBlueColor]; [self.importButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; [self.importButton setTitle:@"Nhập font (.ttf / .otf)" forState:UIControlStateNormal]; self.importButton.layer.cornerRadius = 10; self.importButton.translatesAutoresizingMaskIntoConstraints = NO; [self.importButton addTarget:self action:@selector(importTapped) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:self.importButton];
    self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem]; [self.resetButton setTitle:@"Khôi phục mặc định" forState:UIControlStateNormal]; self.resetButton.translatesAutoresizingMaskIntoConstraints = NO; [self.resetButton addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:self.resetButton];
    [NSLayoutConstraint activateConstraints:@[
      [self.segment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:28], [self.segment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22], [self.segment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
      [self.status.topAnchor constraintEqualToAnchor:self.segment.bottomAnchor constant:26], [self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24], [self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
      [self.importButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:28], [self.importButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22], [self.importButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22], [self.importButton.heightAnchor constraintEqualToConstant:50],
      [self.resetButton.topAnchor constraintEqualToAnchor:self.importButton.bottomAnchor constant:18], [self.resetButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]
    ]];
    [self refreshStatus];
}
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refreshStatus {
    if (self.segment.selectedSegmentIndex == 0) { self.target = @"Video"; NSString *f = NFVideoFontFamily(); self.status.text = [NSString stringWithFormat:@"VIDEO FONT\nĐang chọn: %@\n\nFont sẽ được lưu riêng cho phụ đề MPV. Khả năng áp dụng tùy cách Nuvio khởi tạo MPV trong phiên bản hiện tại.", f.length ? f : @"Mặc định"]; }
    else { self.target = @"Interface"; NSString *f = NFInterfaceFontName(); self.status.text = [NSString stringWithFormat:@"INTERFACE FONT\nĐang chọn: %@\n\nHook UIFont áp dụng cho thành phần UIKit. Chữ Compose/Skiko của Nuvio có thể không đổi; cần hook riêng nếu bản này kết xuất trực tiếp bằng Skia.", f.length ? f : @"Mặc định"]; }
}
- (void)importTapped {
    UIDocumentPickerViewController *picker;
    if (@available(iOS 14.0, *)) picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFont, UTTypeData] asCopy:YES];
    else picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.truetype-ttf-font", @"public.opentype-font", @"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *ext = url.pathExtension.lowercaseString;
    if (![@[@"ttf", @"otf", @"ttc"] containsObject:ext]) { if (scoped) [url stopAccessingSecurityScopedResource]; return; }
    NSString *folder = [NFRoot() stringByAppendingPathComponent:self.target];
    NSString *dest = [folder stringByAppendingPathComponent:url.lastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil]; NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!ok) { self.status.text = [NSString stringWithFormat:@"Không thể nhập font: %@", err.localizedDescription ?: @"unknown error"]; return; }
    CFErrorRef cfErr = NULL; CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:dest], kCTFontManagerScopeProcess, &cfErr);
    NSString *family = nil;
    CGDataProviderRef provider = CGDataProviderCreateWithFilename(dest.fileSystemRepresentation);
    CGFontRef cg = provider ? CGFontCreateWithDataProvider(provider) : NULL;
    if (cg) { family = CFBridgingRelease(CGFontCopyPostScriptName(cg)); CGFontRelease(cg); }
    if (provider) CGDataProviderRelease(provider);
    if (!family.length) family = url.lastPathComponent.stringByDeletingPathExtension;
    if (self.segment.selectedSegmentIndex == 0) {
        [[NSUserDefaults standardUserDefaults] setObject:dest forKey:@"NFVideoFontPath"];
        [[NSUserDefaults standardUserDefaults] setObject:family forKey:@"NFVideoFontFamily"];
        for (NSValue *v in nf_playerHandles) nf_apply_video_font(v.pointerValue);
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:dest forKey:@"NFInterfaceFontPath"];
        [[NSUserDefaults standardUserDefaults] setObject:family forKey:@"NFInterfaceFontName"];
        nf_hook_ui_fonts();
    }
    if (cfErr) CFRelease(cfErr); [self refreshStatus];
}
- (void)resetTapped {
    if (self.segment.selectedSegmentIndex == 0) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NFVideoFontPath"]; [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NFVideoFontFamily"]; }
    else { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NFInterfaceFontPath"]; [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NFInterfaceFontName"]; }
    [self refreshStatus];
}
@end

static UIViewController *nf_top_controller(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:[UIWindowScene class]]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) key = w;
    if (!key) key = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = key.rootViewController; while (vc.presentedViewController) vc = vc.presentedViewController; return vc;
}
static void nf_open_settings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = nf_top_controller(); if (!top || top.presentedViewController) return;
        NFSettingsController *root = [NFSettingsController new]; UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
        nav.modalPresentationStyle = UIModalPresentationPageSheet; [top presentViewController:nav animated:YES completion:nil];
    });
}
static UIButton *nf_button;
@interface NFActionTarget : NSObject
+ (instancetype)shared;
- (void)open;
@end
static void nf_install_button(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        if (@available(iOS 13.0, *)) for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:[UIWindowScene class]]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) key = w;
        if (!key) key = UIApplication.sharedApplication.keyWindow;
        if (!key) return;
        if (nf_button && nf_button.superview) return;
        nf_button = [UIButton buttonWithType:UIButtonTypeSystem]; nf_button.frame = CGRectMake(key.bounds.size.width - 58, key.safeAreaInsets.top + 12, 44, 44); nf_button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        [nf_button setTitle:@"Aa" forState:UIControlStateNormal]; nf_button.titleLabel.font = [UIFont boldSystemFontOfSize:17]; nf_button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.92]; [nf_button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; nf_button.layer.cornerRadius = 22; nf_button.layer.shadowOpacity = 0.25; nf_button.layer.shadowRadius = 4; [nf_button addTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [nf_button addTarget:[NFActionTarget shared] action:@selector(open) forControlEvents:UIControlEventTouchUpInside]; [key addSubview:nf_button]; [key bringSubviewToFront:nf_button];
    });
}
@implementation NFActionTarget
+ (instancetype)shared { static NFActionTarget *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[NFActionTarget new]; }); return x; }
- (void)open { nf_open_settings(); }
@end

__attribute__((constructor)) static void NuvioFontManagerInit(void) {
    nf_playerHandles = [NSMutableArray array];
    struct NFRebinding rb[] = {
      {"mpv_create", (void *)nf_mpv_create_hook, (void **)&nf_orig_mpv_create},
      {"mpv_initialize", (void *)nf_mpv_initialize_hook, (void **)&nf_orig_mpv_initialize}
    };
    nf_rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
    if (NFInterfaceFontName().length) nf_hook_ui_fonts();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ nf_install_button(); }); }];
    dispatch_async(dispatch_get_main_queue(), ^{ dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ nf_install_button(); }); });
}
