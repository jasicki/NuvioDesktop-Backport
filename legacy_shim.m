#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <malloc/malloc.h>
#include <sys/mman.h>
#include <locale.h>
#include <glob.h>
#include <unistd.h>

static WKWebView *gActivePlayerWebView = nil;

// --- Konwerter Relative Method Lists (macOS 12+ -> macOS 10.13) ---
struct method_64_t {
    const char *name;
    const char *types;
    IMP imp;
};

struct method_list_64_t {
    uint32_t entsizeAndFlags;
    uint32_t count;
    struct method_64_t first;
};

struct relative_method_t {
    int32_t nameOffset;
    int32_t typesOffset;
    int32_t impOffset;
};

static void* convert_method_list(void *mlist_ptr) {
    if (!mlist_ptr) return NULL;
    uint32_t *header = (uint32_t *)mlist_ptr;
    uint32_t entsizeAndFlags = header[0];
    uint32_t count = header[1];

    if ((entsizeAndFlags & 0x80000000) == 0) {
        return mlist_ptr;
    }

    struct method_list_64_t *new_list = calloc(1, sizeof(uint32_t) * 2 + sizeof(struct method_64_t) * count);
    new_list->entsizeAndFlags = sizeof(struct method_64_t);
    new_list->count = count;

    struct relative_method_t *rel = (struct relative_method_t *)(header + 2);
    struct method_64_t *dst = &new_list->first;

    for (uint32_t i = 0; i < count; i++) {
        const char **sel_ref = (const char **)((uintptr_t)&rel[i].nameOffset + (intptr_t)rel[i].nameOffset);
        const char *types_ptr = (const char *)((uintptr_t)&rel[i].typesOffset + (intptr_t)rel[i].typesOffset);
        IMP imp_ptr = (IMP)((uintptr_t)&rel[i].impOffset + (intptr_t)rel[i].impOffset);

        dst[i].name = sel_ref ? *sel_ref : NULL;
        dst[i].types = types_ptr;
        dst[i].imp = imp_ptr;
    }
    return new_list;
}

static void fix_class_ro(void *cls_ptr) {
    if (!cls_ptr) return;
    uintptr_t *cls = (uintptr_t *)cls_ptr;
    uintptr_t bits = cls[4] & 0x00007ffffffffff8ULL;
    if (!bits) return;

    uint32_t *ro_or_rw = (uint32_t *)bits;
    if (ro_or_rw[0] & (1U << 31)) {
        return;
    }

    void **baseMethodsPtr = (void **)(bits + 32);
    if (*baseMethodsPtr) {
        vm_protect(mach_task_self(), (vm_address_t)baseMethodsPtr & ~0xfffULL, 0x2000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        *baseMethodsPtr = convert_method_list(*baseMethodsPtr);
    }
}

struct category_64_t {
    const char *name;
    void *cls;
    void *instanceMethods;
    void *classMethods;
    void *protocols;
    void *instanceProperties;
};

static void register_category_methods(void *cls, void *mlist_ptr) {
    if (!cls || !mlist_ptr) return;
    struct method_list_64_t *mlist = (struct method_list_64_t *)convert_method_list(mlist_ptr);
    struct method_64_t *m = &mlist->first;
    for (uint32_t i = 0; i < mlist->count; i++) {
        if (m[i].name) {
            SEL sel = sel_registerName(m[i].name);
            class_replaceMethod((Class)cls, sel, m[i].imp, m[i].types);
        }
    }
}

static NSInteger fast_getTopmostWindowUnderMouseID(id self, SEL _cmd) {
    NSWindow *win = [[NSApplication sharedApplication] keyWindow];
    if (!win) win = [[NSApplication sharedApplication] mainWindow];
    return win ? [win windowNumber] : 0;
}

static NSInteger fast_getTopmostWindowUnderMouseIDImpl(id self, SEL _cmd, id arg) {
    NSWindow *win = [[NSApplication sharedApplication] keyWindow];
    if (!win) win = [[NSApplication sharedApplication] mainWindow];
    return win ? [win windowNumber] : 0;
}

static void on_image_loaded(const struct mach_header *mh, intptr_t slide) {
    if (mh->magic != MH_MAGIC_64) return;

    Dl_info info;
    if (dladdr(mh, &info) == 0 || !info.dli_fname) return;

    if (strstr(info.dli_fname, "libawt_lwawt")) {
        Class awtWinCls = objc_getClass("AWTWindow");
        if (awtWinCls) {
            Method m1 = class_getClassMethod(awtWinCls, sel_registerName("getTopmostWindowUnderMouseID"));
            if (m1) method_setImplementation(m1, (IMP)fast_getTopmostWindowUnderMouseID);
            Method m2 = class_getClassMethod(awtWinCls, sel_registerName("getTopmostWindowUnderMouseIDImpl:"));
            if (m2) method_setImplementation(m2, (IMP)fast_getTopmostWindowUnderMouseIDImpl);
        }
        return;
    }

    if (!strstr(info.dli_fname, "libskiko") && !strstr(info.dli_fname, "libplayer_bridge") && !strstr(info.dli_fname, "libmpv")) {
        return;
    }

    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;

    unsigned long size = 0;
    const char * segs[] = {"__DATA", "__DATA_CONST", "__OBJC_CONST"};

    for (int s = 0; s < 3; s++) {
        uint8_t *cls_sec = getsectiondata(mh64, segs[s], "__objc_classlist", &size);
        if (cls_sec && size > 0) {
            void **classes = (void **)cls_sec;
            for (unsigned long i = 0; i < size / sizeof(void*); i++) {
                void *cls = classes[i];
                if (cls) {
                    fix_class_ro(cls);
                    void *metacls = *(void **)cls;
                    fix_class_ro(metacls);
                }
            }
        }
    }

    for (int s = 0; s < 3; s++) {
        uint8_t *cat_sec = getsectiondata(mh64, segs[s], "__objc_catlisX", &size);
        if (cat_sec && size > 0) {
            struct category_64_t **cats = (struct category_64_t **)cat_sec;
            for (unsigned long i = 0; i < size / sizeof(void*); i++) {
                struct category_64_t *cat = cats[i];
                if (cat && cat->cls) {
                    register_category_methods(cat->cls, cat->instanceMethods);
                    void *metacls = object_getClass((id)cat->cls);
                    register_category_methods(metacls, cat->classMethods);
                }
            }
        }
    }
}

static long safe_zero_imp(id self, SEL _cmd, ...) {
    return 0;
}

static IMP orig_forwardingTargetForSelector = NULL;
static id shim_forwardingTargetForSelector(id self, SEL _cmd, SEL aSelector) {
    if (orig_forwardingTargetForSelector) {
        id res = ((id (*)(id, SEL, SEL))orig_forwardingTargetForSelector)(self, _cmd, aSelector);
        if (res) return res;
    }
    class_addMethod(object_getClass(self), aSelector, (IMP)safe_zero_imp, "@@:@@@@@@@@");
    return self;
}

__attribute__((constructor))
static void init_legacy_shim() {
    _dyld_register_func_for_add_image(on_image_loaded);
    Method m = class_getInstanceMethod([NSObject class], @selector(forwardingTargetForSelector:));
    if (m) {
        orig_forwardingTargetForSelector = method_setImplementation(m, (IMP)shim_forwardingTargetForSelector);
    }
}

@implementation NSObject (LegacyMetalAndAppKitShim)
- (BOOL)supportsFamily:(NSInteger)family {
    return (family <= 2001 || family == 3001 || family == 3002) ? YES : NO;
}
- (id)commandBufferWithDescriptor:(id)desc {
    SEL sel = sel_registerName("commandBuffer");
    if ([self respondsToSelector:sel]) {
        return ((id (*)(id, SEL))objc_msgSend)(self, sel);
    }
    return nil;
}
- (BOOL)hasUnifiedMemory {
    return YES;
}
- (NSUInteger)maxBufferLength {
    return 256 * 1024 * 1024;
}
- (id)effectiveAppearance {
    return nil;
}
@end

@interface NSWorkspaceOpenConfiguration : NSObject
+ (instancetype)configuration;
@end
@implementation NSWorkspaceOpenConfiguration
+ (instancetype)configuration { return [[self alloc] init]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { return [NSMethodSignature signatureWithObjCTypes:"v@:"]; }
- (void)forwardInvocation:(NSInvocation *)anInvocation {}
@end

@interface NSConstantIntegerNumber : NSNumber
@end
@implementation NSConstantIntegerNumber
@end

@interface MTLCommandBufferDescriptor : NSObject
@end
@implementation MTLCommandBufferDescriptor
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { return [NSMethodSignature signatureWithObjCTypes:"v@:"]; }
- (void)forwardInvocation:(NSInvocation *)anInvocation {}
@end

@interface AVCaptureDeviceDiscoverySession : NSObject
@end
@implementation AVCaptureDeviceDiscoverySession
+ (instancetype)discoverySessionWithDeviceTypes:(id)t mediaType:(id)m position:(NSInteger)p { return nil; }
@end

// --- Stale i klasy MediaPlayer / AVFoundation / AppKit / CoreGraphics ---
@interface MPRemoteCommandCenter : NSObject
+ (instancetype)sharedCommandCenter;
@end
@implementation MPRemoteCommandCenter
+ (instancetype)sharedCommandCenter { return [[self alloc] init]; }
@end

@interface MPNowPlayingInfoCenter : NSObject
+ (instancetype)defaultCenter;
@end
@implementation MPNowPlayingInfoCenter
+ (instancetype)defaultCenter { return [[self alloc] init]; }
@end

@interface MPMediaItemArtwork : NSObject
@end
@implementation MPMediaItemArtwork
@end

NSString * const MPMediaItemPropertyArtist = @"artist";
NSString * const MPMediaItemPropertyArtwork = @"artwork";
NSString * const MPMediaItemPropertyPlaybackDuration = @"playbackDuration";
NSString * const MPMediaItemPropertyTitle = @"title";
NSString * const MPNowPlayingInfoPropertyElapsedPlaybackTime = @"elapsedPlaybackTime";
NSString * const MPNowPlayingInfoPropertyMediaType = @"mediaType";
NSString * const MPNowPlayingInfoPropertyPlaybackRate = @"playbackRate";

NSString * const AVCaptureDeviceTypeBuiltInMicrophone = @"AVCaptureDeviceTypeBuiltInMicrophone";
NSString * const AVCaptureDeviceTypeBuiltInWideAngleCamera = @"AVCaptureDeviceTypeBuiltInWideAngleCamera";
NSString * const AVCaptureDeviceTypeExternalUnknown = @"AVCaptureDeviceTypeExternalUnknown";
NSString * const AVMediaTypeAudio = @"soun";
NSString * const AVMediaTypeMuxed = @"muxx";
NSString * const AVMediaTypeVideo = @"vide";
NSString * const AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification = @"AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification";

NSString * const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";
NSString * const NSAppearanceNameAccessibilityHighContrastAqua = @"NSAppearanceNameAccessibilityHighContrastAqua";
NSString * const NSAppearanceNameAccessibilityHighContrastDarkAqua = @"NSAppearanceNameAccessibilityHighContrastDarkAqua";
NSString * const NSAppearanceNameAccessibilityHighContrastVibrantLight = @"NSAppearanceNameAccessibilityHighContrastVibrantLight";
NSString * const NSAppearanceNameAccessibilityHighContrastVibrantDark = @"NSAppearanceNameAccessibilityHighContrastVibrantDark";

CFStringRef const kCGColorSpaceDisplayP3_PQ = CFSTR("kCGColorSpaceDisplayP3_PQ");
CFStringRef const kCGColorSpaceITUR_2100_PQ = CFSTR("kCGColorSpaceITUR_2100_PQ");

// --- Funkcje C / libffi / Darwin / Swift / C++17 Filesystem ---
__attribute__((naked)) void ___chkstk_darwin(void) {
    __asm__ volatile ("ret");
}

void* archive_read_new(void) {
    return NULL;
}

int __darwin_check_fd_set_overflow(int a, const void *b, int c) { return 1; }
void __os_signpost_pack_fill(void) {}
void __os_signpost_pack_send(void) {}

void *ffi_closure_alloc(size_t size, void **code) {
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (code) *code = ptr;
    return ptr;
}
void ffi_closure_free(void *ptr) {}
int ffi_prep_closure_loc(void *closure, void *cif, void *fun, void *user_data, void *codeloc) { return 0; }

void *pl_log_create_349(int api_ver, const void *params) { return NULL; }

void objc_setHook_getClass(void *new_hook, void **old_out) {}
void objc_setHook_getImageName(void *new_hook, void **old_out) {}
Class _objc_realizeClassFromSwift(Class cls, void *previously) { return cls; }

long $s6AppKit01_abB23NumericRawRepresentablePAAE1poiyxx_0D5ValueQztFZ(long a, long b) { return a + b; }
uint64_t $sSo13NSWindowLevela6AppKit01_cdD23NumericRawRepresentableACMc = 0;

void _ZNSt3__120__libcpp_atomic_waitEPVKvx(const volatile void *p, long long v) {}
void _ZNSt3__123__cxx_atomic_notify_allEPVKv(const volatile void *p) {}
long long _ZNSt3__123__libcpp_atomic_monitorEPVKv(const volatile void *p) { return 0; }
char* _ZNSt3__16__itoa8__u32toaEjPc(uint32_t v, char *buf) { return buf + sprintf(buf, "%u", v); }
char* _ZNSt3__16__itoa8__u64toaEyPc(uint64_t v, char *buf) { return buf + sprintf(buf, "%llu", v); }

void* _ZNKSt3__14__fs10filesystem18directory_iterator13__dereferenceEv(void *a) { return a; }
void* _ZNKSt3__14__fs10filesystem28recursive_directory_iterator13__dereferenceEv(void *a) { return a; }
void* _ZNKSt3__14__fs10filesystem4path10__filenameEv(void *a) { return a; }
void* _ZNKSt3__14__fs10filesystem4path13__parent_pathEv(void *a) { return a; }
void* _ZNKSt3__14__fs10filesystem4path16__root_directoryEv(void *a) { return a; }
void _ZNSt3__14__fs10filesystem10__absoluteERKNS1_4pathEPNS_10error_codeE(void) {}
uint64_t _ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
uint64_t _ZNSt3__14__fs10filesystem12__remove_allERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
int64_t _ZNSt3__14__fs10filesystem16_FilesystemClock3nowEv(void) { return 0; }
uint32_t _ZNSt3__14__fs10filesystem16__symlink_statusERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
void _ZNSt3__14__fs10filesystem16filesystem_error13__create_whatEi(void) {}
void _ZNSt3__14__fs10filesystem16filesystem_errorD1Ev(void) {}
void _ZNSt3__14__fs10filesystem17__last_write_timeERKNS1_4pathENS_6chrono10time_pointINS1_16_FilesystemClockENS5_8durationInNS_5ratioILl1ELl1000000000EEEEEEEPNS_10error_codeE(void) {}
int64_t _ZNSt3__14__fs10filesystem17__last_write_timeERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
int _ZNSt3__14__fs10filesystem18__create_directoryERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
void _ZNSt3__14__fs10filesystem18directory_iterator11__incrementEPNS_10error_codeE(void) {}
void _ZNSt3__14__fs10filesystem18directory_iteratorC1ERKNS1_4pathEPNS_10error_codeENS1_17directory_optionsE(void) {}
int _ZNSt3__14__fs10filesystem20__create_directoriesERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
void _ZNSt3__14__fs10filesystem28recursive_directory_iterator11__incrementEPNS_10error_codeE(void) {}
void _ZNSt3__14__fs10filesystem28recursive_directory_iteratorC1ERKNS1_4pathENS1_17directory_optionsEPNS_10error_codeE(void) {}
int _ZNSt3__14__fs10filesystem8__removeERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
uint32_t _ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE(void) { return 0; }
void *_ZTINSt3__14__fs10filesystem16filesystem_errorE = NULL;
void *_ZTVNSt3__14__fs10filesystem16filesystem_errorE = NULL;

id objc_alloc(Class cls) {
    if (!cls) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
}

id objc_alloc_init(Class cls) {
    if (!cls) return nil;
    id obj = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
    if (!obj) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("init"));
}

id objc_opt_self(id self) {
    return self;
}

Class objc_opt_class(id obj) {
    if (!obj) return nil;
    return ((Class (*)(id, SEL))objc_msgSend)(obj, sel_registerName("class"));
}

id objc_opt_new(Class cls) {
    if (!cls) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("new"));
}

BOOL objc_opt_isKindOfClass(id obj, Class otherClass) {
    if (!obj) return NO;
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(obj, sel_registerName("isKindOfClass:"), otherClass);
}

BOOL objc_opt_respondsToSelector(id obj, SEL sel) {
    if (!obj) return NO;
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(obj, sel_registerName("respondsToSelector:"), sel);
}

// --- Pelna obsluga komend MPRemoteCommandCenter i MPNowPlayingInfoCenter ---
@interface MPRemoteCommand : NSObject
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
- (id)addTargetWithHandler:(id)handler;
- (void)removeTarget:(id)target;
- (void)removeTarget:(id)target action:(SEL)action;
@end

@implementation MPRemoteCommand
- (id)addTargetWithHandler:(id)handler { return [NSObject new]; }
- (void)removeTarget:(id)target {}
- (void)removeTarget:(id)target action:(SEL)action {}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSMethodSignature signatureWithObjCTypes:"v@:@"];
}
- (void)forwardInvocation:(NSInvocation *)anInvocation {}
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {}
- (id)valueForUndefinedKey:(NSString *)key { return nil; }
@end

@implementation MPRemoteCommandCenter (Compat)
- (id)playCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)pauseCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)stopCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)togglePlayPauseCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)nextTrackCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)previousTrackCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)changePlaybackPositionCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)changePlaybackRateCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)skipForwardCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)skipBackwardCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)seekForwardCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (id)seekBackwardCommand { static id c; if (!c) c = [MPRemoteCommand new]; return c; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)anInvocation {
    static MPRemoteCommand *dummyCmd = nil;
    if (!dummyCmd) dummyCmd = [MPRemoteCommand new];
    [anInvocation setReturnValue:&dummyCmd];
}
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {}
- (id)valueForUndefinedKey:(NSString *)key { return [MPRemoteCommand new]; }
@end

@implementation MPNowPlayingInfoCenter (Compat)
- (void)setNowPlayingInfo:(NSDictionary *)info {}
- (NSDictionary *)nowPlayingInfo { return @{}; }
- (void)setPlaybackState:(NSUInteger)state {}
- (NSUInteger)playbackState { return 0; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [NSMethodSignature signatureWithObjCTypes:"v@:@"];
}
- (void)forwardInvocation:(NSInvocation *)anInvocation {}
@end

@implementation MPMediaItemArtwork (Compat)
- (instancetype)initWithBoundsSize:(CGSize)boundsSize requestHandler:(id)requestHandler { return [super init]; }
- (instancetype)initWithImage:(id)image { return [super init]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector { return [NSMethodSignature signatureWithObjCTypes:"@@:"]; }
- (void)forwardInvocation:(NSInvocation *)anInvocation { id selfObj = self; [anInvocation setReturnValue:&selfObj]; }
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {}
- (id)valueForUndefinedKey:(NSString *)key { return nil; }
@end

// --- MPV & WKWEBVIEW HIGH SIERRA PERFORMANCE & UI FIX ---

@implementation WKWebView (HighSierraOpaqueFix)
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {
    if ([key isEqualToString:@"drawsBackground"]) {
        [self setValue:value forKey:@"_drawsBackground"];
        return;
    }
    [super setValue:value forUndefinedKey:key];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (!newWindow && gActivePlayerWebView == self) {
        gActivePlayerWebView = nil;
    }
    [super viewWillMoveToWindow:newWindow];
}
@end

static void cleanOldTempSubtitles(void) {
    glob_t g;
    if (glob("/tmp/nuvio_sub_*.srt", 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            unlink(g.gl_pathv[i]);
        }
        globfree(&g);
    }
}

void* mpv_creatX(void) {
    setlocale(LC_NUMERIC, "C");
    cleanOldTempSubtitles();
    static void* (*real_mpv_create)(void) = NULL;
    if (!real_mpv_create) {
        void *h = dlopen("/Applications/Nuvio.app/Contents/app/resources/native/macos/libmpv.2.dylib", RTLD_LAZY | RTLD_GLOBAL);
        if (h) real_mpv_create = dlsym(h, "mpv_create");
        if (!real_mpv_create) real_mpv_create = dlsym(RTLD_DEFAULT, "mpv_create");
    }
    void *ctx = real_mpv_create ? real_mpv_create() : NULL;
    if (ctx) {
        static int (*set_opt)(void*, const char*, const char*) = NULL;
        if (!set_opt) set_opt = dlsym(RTLD_DEFAULT, "mpv_set_option_string");
        if (set_opt) {
            set_opt(ctx, "msg-level", "all=no");
            set_opt(ctx, "terminal", "no");
            set_opt(ctx, "ytdl", "no");
            set_opt(ctx, "load-scripts", "no");
            set_opt(ctx, "load-stats-overlay", "no");
            set_opt(ctx, "load-console", "no");
            set_opt(ctx, "load-commands", "no");
            set_opt(ctx, "load-select", "no");
            set_opt(ctx, "load-positioning", "no");
            set_opt(ctx, "load-auto-profiles", "no");
            set_opt(ctx, "osc", "no");
            set_opt(ctx, "tls-verify", "no");
            set_opt(ctx, "tls-ca-file", "");
            set_opt(ctx, "ao", "coreaudio");
            set_opt(ctx, "sub-auto", "no");
            set_opt(ctx, "vd-lavc-threads", "4");
            set_opt(ctx, "scale", "bilinear");
            set_opt(ctx, "cscale", "bilinear");
            set_opt(ctx, "dscale", "bilinear");
            set_opt(ctx, "correct-downscaling", "no");
            set_opt(ctx, "linear-downscaling", "no");
            set_opt(ctx, "sigmoid-upscaling", "no");
            set_opt(ctx, "hdr-compute-peak", "no");
        }
    }
    return ctx;
}

int mpv_set_option_strinX(void *ctx, const char *name, const char *data) {
    setlocale(LC_NUMERIC, "C");
    static int (*real_fn)(void*, const char*, const char*) = NULL;
    if (!real_fn) real_fn = dlsym(RTLD_DEFAULT, "mpv_set_option_string");
    if (!name) return -1;

    if (strcmp(name, "terminal") == 0) return 0;
    if (strcmp(name, "msg-level") == 0) return real_fn(ctx, "msg-level", "all=no");
    if (strcmp(name, "hdr-compute-peak") == 0) return real_fn(ctx, "hdr-compute-peak", "no");
    if (strcmp(name, "ao") == 0) return real_fn(ctx, "ao", "coreaudio");
    if (strcmp(name, "hwdec") == 0) return real_fn(ctx, "hwdec", "videotoolbox");

    if (strcmp(name, "stream-lavf-o") == 0 && data) {
        NSString *newLavf = [NSString stringWithFormat:@"%s,tls_verify=0", data];
        return real_fn(ctx, name, [newLavf UTF8String]);
    }
    return real_fn ? real_fn(ctx, name, data) : -1;
}

int mpv_commanX(void *ctx, const char **args) {
    setlocale(LC_NUMERIC, "C");
    static int (*real_async_fn)(void*, uint64_t, const char**) = NULL;
    static int (*real_sync_fn)(void*, const char**) = NULL;
    if (!real_async_fn) real_async_fn = dlsym(RTLD_DEFAULT, "mpv_command_async");
    if (!real_sync_fn) real_sync_fn = dlsym(RTLD_DEFAULT, "mpv_command");

    if (args && args[0]) {
        if (strcmp(args[0], "stop") == 0) {
            gActivePlayerWebView = nil;
            static const char *stop_args[] = { "stop", NULL };
            if (real_async_fn) return real_async_fn(ctx, 0, stop_args);
        }
        if (strcmp(args[0], "quit") == 0) {
            gActivePlayerWebView = nil;
            static const char *quit_args[] = { "quit", NULL };
            if (real_async_fn) return real_async_fn(ctx, 0, quit_args);
        }
        if (strcmp(args[0], "sub-add") == 0 && args[1] && strncmp(args[1], "http", 4) == 0) {
            static int sub_idx = 0;
            NSString *tmpSub = [NSString stringWithFormat:@"/tmp/nuvio_sub_%d.srt", ++sub_idx];
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/curl"];
            [task setArguments:@[@"-ksL", @"--compressed", @"--max-time", @"10", [NSString stringWithUTF8String:args[1]], @"-o", tmpSub]];
            [task launch];
            [task waitUntilExit];
            const char *newArgs[3] = { "sub-add", [tmpSub UTF8String], NULL };
            return real_sync_fn ? real_sync_fn(ctx, newArgs) : -1;
        }
    }
    return real_sync_fn ? real_sync_fn(ctx, args) : -1;
}

void mpv_render_context_freX(void *render_ctx) {
    gActivePlayerWebView = nil;
    if (!render_ctx) return;
    static void (*set_cb)(void*, void*, void*) = NULL;
    static void (*real_free)(void*) = NULL;
    if (!set_cb) set_cb = dlsym(RTLD_DEFAULT, "mpv_render_context_set_update_callback");
    if (!real_free) real_free = dlsym(RTLD_DEFAULT, "mpv_render_context_free");
    if (set_cb) set_cb(render_ctx, NULL, NULL);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (real_free) real_free(render_ctx);
    });
}

void mpv_terminate_destroX(void *ctx) {
    gActivePlayerWebView = nil;
    if (!ctx) return;
    static void (*set_wakeup)(void*, void*, void*) = NULL;
    static int (*real_async_fn)(void*, uint64_t, const char**) = NULL;
    static void (*real_destroy)(void*) = NULL;
    if (!set_wakeup) set_wakeup = dlsym(RTLD_DEFAULT, "mpv_set_wakeup_callback");
    if (!real_async_fn) real_async_fn = dlsym(RTLD_DEFAULT, "mpv_command_async");
    if (!real_destroy) real_destroy = dlsym(RTLD_DEFAULT, "mpv_terminate_destroy");

    if (set_wakeup) set_wakeup(ctx, NULL, NULL);
    static const char *stop_args[] = { "stop", NULL };
    if (real_async_fn) real_async_fn(ctx, 0, stop_args);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (real_destroy) real_destroy(ctx);
    });
}

static NSString* transpileCSSForSafari11(NSString *css) {
    if (!css) return css;
    NSMutableString *m = [css mutableCopy];
    NSError *err = nil;

    // 1. env(...) -> 0px
    NSRegularExpression *reEnv = [NSRegularExpression regularExpressionWithPattern:@"env\\([^\\)]+\\)" options:0 error:&err];
    if (reEnv) [reEnv replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"0px"];

    // 2. Wszystkie warianty inset: ... -> top/right/bottom/left
    [m replaceOccurrencesOfString:@"inset: 0 auto 0 0;" withString:@"top: 0; right: auto; bottom: 0; left: 0;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"inset: 0 0 0 auto;" withString:@"top: 0; right: 0; bottom: 0; left: auto;" options:0 range:NSMakeRange(0, m.length)];
    NSRegularExpression *reInset0 = [NSRegularExpression regularExpressionWithPattern:@"\\binset\\s*:\\s*0(px)?\\s*;" options:0 error:&err];
    if (reInset0) [reInset0 replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"top: 0; right: 0; bottom: 0; left: 0;"];

    // 3. :is(.blur-thumb) oraz aspect-ratio: 16 / 9 -> kompatybilne z Safari 11
    [m replaceOccurrencesOfString:@":is(.blur-thumb)" withString:@".blur-thumb" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"height: auto;\n    aspect-ratio: 16 / 9;" withString:@"height: 68px;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"aspect-ratio: 16 / 9;" withString:@"min-height: 68px;" options:0 range:NSMakeRange(0, m.length)];

    // 4. Elastyczne kolumny w menu Napisy
    [m replaceOccurrencesOfString:@"grid-template-columns: 200px 300px 280px;" withString:@"grid-template-columns: minmax(140px, 0.75fr) minmax(190px, 1.25fr) minmax(210px, 1fr);" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"grid-template-columns: 180px 260px 260px;" withString:@"grid-template-columns: minmax(130px, 0.75fr) minmax(170px, 1.25fr) minmax(200px, 1fr);" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"grid-template-columns: minmax(250px, .78fr) minmax(400px, 1.25fr) minmax(340px, 1fr);" withString:@"grid-template-columns: minmax(150px, 0.78fr) minmax(220px, 1.25fr) minmax(230px, 1fr);" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"grid-template-columns: 200px 300px;" withString:@"grid-template-columns: minmax(140px, 0.85fr) minmax(200px, 1.15fr);" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"grid-template-columns: 180px 260px;" withString:@"grid-template-columns: minmax(130px, 0.85fr) minmax(180px, 1.15fr);" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"grid-template-columns: minmax(250px, .8fr) minmax(400px, 1.2fr);" withString:@"grid-template-columns: minmax(150px, 0.8fr) minmax(220px, 1.2fr);" options:0 range:NSMakeRange(0, m.length)];

    // 5. Niezachlanny regex dla clamp(min, val, max)
    NSRegularExpression *reClamp = [NSRegularExpression regularExpressionWithPattern:@"clamp\\(\\s*([^,()]+),\\s*([^,()]+),\\s*([^()]+)\\)" options:0 error:&err];
    if (reClamp) [reClamp replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"$1"];

    // 6. min(...) i max(...) -> zamieniamy na wartosc kompatybilna z Safari 11
    [m replaceOccurrencesOfString:@"max(calc(var(--title) * 1.8), 32px)" withString:@"32px" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"max(calc(var(--title) * 1.35), 32px)" withString:@"28px" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"width: min(1280px, calc(100vw - 112px)) !important;" withString:@"width: calc(100vw - 96px) !important; max-width: 1140px !important;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"width: min(560px, calc(100vw - 112px)) !important;" withString:@"width: 440px !important; max-width: calc(100vw - 80px) !important;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"width: min(444px, calc(100vw - 56px)) !important;" withString:@"width: 400px !important; max-width: calc(100vw - 64px) !important;" options:0 range:NSMakeRange(0, m.length)];

    NSRegularExpression *reMinVW = [NSRegularExpression regularExpressionWithPattern:@"\\bmin\\(\\s*[0-9.]+(?:vw|vh|%)\\s*,\\s*([^\\)]+)\\)" options:0 error:&err];
    if (reMinVW) [reMinVW replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"$1"];
    NSRegularExpression *reMinPx = [NSRegularExpression regularExpressionWithPattern:@"\\bmin\\(\\s*([^,()]+),\\s*(?:calc\\([^\\)]+\\)|[^\\)]+)\\)" options:0 error:&err];
    if (reMinPx) [reMinPx replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"$1"];

    // 7. padding-inline / margin-inline
    NSRegularExpression *rePadIn = [NSRegularExpression regularExpressionWithPattern:@"padding-inline\\s*:\\s*([^;]+);" options:0 error:&err];
    if (rePadIn) [rePadIn replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"padding-left: $1; padding-right: $1;"];
    NSRegularExpression *reMarIn = [NSRegularExpression regularExpressionWithPattern:@"margin-inline\\s*:\\s*([^;]+);" options:0 error:&err];
    if (reMarIn) [reMarIn replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"margin-left: $1; margin-right: $1;"];

    // 8. gap: X -> grid-gap: X; gap: X;
    NSRegularExpression *reGap = [NSRegularExpression regularExpressionWithPattern:@"(?<![-\\w])gap\\s*:\\s*([^;]+);" options:0 error:&err];
    if (reGap) [reGap replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"grid-gap: $1; gap: $1;"];

    // 9. Wszystkie place-items: center -> align-items + justify-content
    [m replaceOccurrencesOfString:@"display: grid;\n  place-items: center;" withString:@"display: flex;\n  align-items: center;\n  justify-content: center;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"place-items: center;" withString:@"align-items: center; justify-content: center;" options:0 range:NSMakeRange(0, m.length)];

    NSString *extraFix = @"\n/* SAFARI 11 FIX16 - ODSTEP OBRAZKA OD TEKSTU W ODCINKACH I KOMPLETNY UI */\n"
        "[hidden] { display: none !important; }\n"
        ".parental-guide:not(.visible), .player-toast:not(.visible), .opening-overlay:not(.visible), #pipLockButton:not(.visible), .pip-lock-button, .pip-lock-badge:not(.visible) { display: none !important; opacity: 0 !important; background: transparent !important; border: none !important; }\n"
        "html, body, #playerRoot, .player-root, .player, #app { width: 100vw !important; height: 100vh !important; background: transparent !important; pointer-events: auto !important; }\n"
        "* { -webkit-backdrop-filter: none !important; backdrop-filter: none !important; will-change: auto !important; filter: none !important; animation: none !important; }\n"
        "svg { fill: currentColor !important; color: inherit !important; pointer-events: none; }\n"
        "symbol path:not([fill]) { fill: currentColor !important; }\n"
        ".header-button:not([hidden]), .opening-button:not([hidden]), .side-control:not([hidden]), .play-control:not([hidden]), .action:not([hidden]), .round-step:not([hidden]), .panel-button:not([hidden]), .capture-button:not([hidden]) { display: inline-flex !important; align-items: center !important; justify-content: center !important; color: #fff !important; transform: none !important; transition: background-color 120ms ease, opacity 120ms ease !important; }\n"
        ".header-button svg { width: 24px !important; height: 24px !important; }\n"
        ".side-control svg { width: 32px !important; height: 32px !important; }\n"
        ".play-control svg { width: 42px !important; height: 42px !important; }\n"
        ".action svg { width: 20px !important; height: 20px !important; margin-right: 6px; }\n"
        ".center-controls:not([hidden]) { display: flex !important; align-items: center !important; justify-content: center !important; position: absolute !important; top: 50% !important; left: 50% !important; transform: translate(-50%, -50%) !important; z-index: 10 !important; }\n"
        ".side-control:not([hidden]), .play-control:not([hidden]) { margin: 0 24px !important; border-radius: 999px !important; background: rgba(0,0,0,0.55) !important; padding: 14px !important; }\n"
        ".header:not([hidden]) { position: absolute !important; top: 20px !important; left: 24px !important; right: 24px !important; display: flex !important; align-items: center !important; justify-content: space-between !important; z-index: 10 !important; }\n"
        ".header-actions:not([hidden]) { display: flex !important; align-items: center !important; margin-left: auto !important; }\n"
        ".header-actions > *:not([hidden]) { margin-left: 10px !important; }\n"
        ".progress:not([hidden]) { position: absolute !important; left: 24px !important; right: 24px !important; bottom: 20px !important; z-index: 10 !important; display: flex !important; flex-direction: column !important; }\n"
        ".action-row:not([hidden]), .controls-row:not([hidden]), .bottom-row:not([hidden]), .bottom-actions:not([hidden]) { display: flex !important; align-items: center !important; justify-content: space-between !important; margin-top: 8px !important; }\n"
        ".action:not([hidden]) { display: inline-flex !important; align-items: center !important; padding: 8px 12px !important; margin-right: 8px !important; border-radius: 999px !important; background: rgba(0,0,0,0.55) !important; color: #fff !important; }\n"
        ".modal-layer:not([hidden]) { display: flex !important; align-items: center !important; justify-content: center !important; padding: 28px 36px 84px 36px !important; background: transparent !important; }\n"
        ".modal, .track-panel, .episodes-panel, .sources-panel { background: rgba(20, 21, 27, 0.96) !important; border: 1px solid rgba(255, 255, 255, 0.14) !important; border-radius: 24px !important; padding: 28px 34px !important; margin: auto !important; max-height: calc(100vh - 120px) !important; box-shadow: 0 16px 40px rgba(0, 0, 0, 0.65) !important; box-sizing: border-box !important; overflow: hidden !important; }\n"
        ".modal-header, .panel-header { margin-bottom: 18px !important; padding-bottom: 4px !important; }\n"
        ".modal *, .track-panel * { min-width: 0; }\n"
        ".track-row, .segment-button, .subtitle-tab, .filter-chip { margin-bottom: 6px !important; line-height: 1.35 !important; overflow-wrap: break-word !important; word-break: normal !important; }\n"
        ".modal label, .modal span, .modal p, .track-panel label, .track-panel span { overflow-wrap: break-word !important; word-break: normal !important; line-height: 1.35 !important; }\n"
        ".modal button, .track-panel button { white-space: nowrap !important; flex-shrink: 0 !important; }\n"
        ".track-row button, .subtitle-list button, .track-list button { white-space: normal !important; text-align: left !important; }\n"
        "button + button, span + button, label + button { margin-left: 10px !important; }\n"
        "/* Odstep miedzy obrazkiem odcinka a tekstem obok oraz odstepy w liscie Odcinki / Zrodla */\n"
        "[class*='thumb'] + *, [class*='poster'] + *, [class*='image'] + *, [class*='media'] + *, .episode-card > *:first-child + *, .episode-item > *:first-child + *, .episode-row > *:first-child + * { margin-left: 16px !important; }\n"
        "[class*='episode-thumb'], [class*='next-episode-thumb'] { margin-right: 16px !important; flex-shrink: 0 !important; }\n"
        "[class*='episode-card'], [class*='episode-item'], [class*='episode-row'], [class*='stream-item'], [class*='source-card'] { margin-bottom: 10px !important; padding: 10px !important; }\n"
        "[class*='season'], [class*='filter-row'], [class*='chips'] { margin-bottom: 12px !important; }\n"
        ".swatch { margin: 4px !important; flex: 0 0 auto !important; }\n"
        ".round-step { min-width: 34px !important; min-height: 34px !important; margin: 0 4px !important; flex: 0 0 auto !important; }\n";
    if (![m containsString:@"SAFARI 11 FIX16"]) {
        [m appendString:extraFix];
    }
    return m;
}

static NSString* transpileHTMLForSafari11(NSString *html) {
    if (!html) return html;
    NSMutableString *m = [html mutableCopy];
    if (![m containsString:@"xmlns:xlink"]) {
        [m replaceOccurrencesOfString:@"<svg " withString:@"<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" " options:0 range:NSMakeRange(0, m.length)];
        [m replaceOccurrencesOfString:@"<svg>" withString:@"<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">" options:0 range:NSMakeRange(0, m.length)];
    }
    NSError *err = nil;
    NSRegularExpression *reUse = [NSRegularExpression regularExpressionWithPattern:@"<use([^>]*?)\\bhref=\"([^\"]+)\"" options:0 error:&err];
    if (reUse) {
        [reUse replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"<use$1href=\"$2\" xlink:href=\"$2\""];
    }
    return m;
}

static NSString* transpileJSForSafari11(NSString *js) {
    if (!js) return js;
    if (![js containsString:@"?."] && ![js containsString:@" ?? "] && ![js containsString:@"setAttribute(\"href\""] && ![js containsString:@"setAttribute('href'"] && ![js containsString:@"pointermove"] && ![js containsString:@"pointerdown"] && ![js containsString:@"const noteCursorActivity = () => {"] && ![js containsString:@"setPointerCapture"]) {
        return js;
    }
    NSMutableString *m = [js mutableCopy];

    NSString *polyfills = @"/* SAFARI 11 POLYFILLS */\n"
        "(function(){\n"
        "  if (!Element.prototype.setPointerCapture) Element.prototype.setPointerCapture = function(){};\n"
        "  if (!Element.prototype.releasePointerCapture) Element.prototype.releasePointerCapture = function(){};\n"
        "  if (!Element.prototype.hasPointerCapture) Element.prototype.hasPointerCapture = function(){ return false; };\n"
        "  var origScroll = Element.prototype.scrollIntoView;\n"
        "  if (origScroll) {\n"
        "    Element.prototype.scrollIntoView = function(arg) {\n"
        "      try { if (arg && typeof arg === 'object') return origScroll.call(this, false); return origScroll.call(this, arg); } catch(e) {}\n"
        "    };\n"
        "  }\n"
        "})();\n";
    if ([m containsString:@"const noteCursorActivity = () => {"] && ![m containsString:@"SAFARI 11 POLYFILLS"]) {
        [m insertString:polyfills atIndex:0];
    }

    [m replaceOccurrencesOfString:@"?.classList.remove('native-resizing')" withString:@" && document.getElementById('playerRoot').classList.remove('native-resizing')" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"?.scrollIntoView({ behavior: \"instant\", container: \"nearest\", inline: \"start\" });" withString:@" && true;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"filterRow?.hasPointerCapture(filterRowPointerId)" withString:@"(filterRow && filterRow.hasPointerCapture && filterRow.hasPointerCapture(filterRowPointerId))" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"currentEpisodeStreamItems?.length === 0" withString:@"(currentEpisodeStreamItems && currentEpisodeStreamItems.length === 0)" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@" ?? " withString:@" || " options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@".setAttribute(\"href\"," withString:@".setAttributeNS(\"http://www.w3.org/1999/xlink\", \"xlink:href\"," options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@".setAttribute('href'," withString:@".setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href'," options:0 range:NSMakeRange(0, m.length)];

    [m replaceOccurrencesOfString:@"\"pointermove\"" withString:@"\"mousemove\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'pointermove'" withString:@"'mousemove'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"pointerdown\"" withString:@"\"mousedown\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'pointerdown'" withString:@"'mousedown'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"pointerup\"" withString:@"\"mouseup\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'pointerup'" withString:@"'mouseup'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"pointerleave\"" withString:@"\"mouseleave\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'pointerleave'" withString:@"'mouseleave'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"pointercancel\"" withString:@"\"mouseleave\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'pointercancel'" withString:@"'mouseleave'" options:0 range:NSMakeRange(0, m.length)];

    NSString *oldCursorFn = @"const noteCursorActivity = () => {";
    NSString *newCursorFn = @"window._nuvioWakeChrome = () => {\n"
        "  if (!state.controlsVisible) {\n"
        "    state = Object.assign({}, state, { controlsVisible: true });\n"
        "    renderChrome();\n"
        "    send(\"toggleChrome\", 0);\n"
        "  }\n"
        "  hiddenCursorTemporarilyVisible = true;\n"
        "  syncHiddenCursor();\n"
        "  syncChromeAutoHideTimer(isOpeningOverlayActive());\n"
        "};\n"
        "const noteCursorActivity = () => {\n"
        "  window._nuvioWakeChrome();";
    if (![m containsString:@"window._nuvioWakeChrome"]) {
        [m replaceOccurrencesOfString:oldCursorFn withString:newCursorFn options:0 range:NSMakeRange(0, m.length)];
    }

    static NSRegularExpression *reProp = nil;
    if (!reProp) {
        NSError *err = nil;
        reProp = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z0-9_$\\.\\(\\)'\\\"\\[\\]]+)\\?\\.([a-zA-Z0-9_$]+)" options:0 error:&err];
    }
    if (reProp && [m containsString:@"?."]) {
        for (int i = 0; i < 3; i++) {
            [reProp replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@"($1 ? $1.$2 : undefined)"];
        }
    }
    return m;
}

@implementation WKWebView (HighSierraJSFix)
+ (void)load {
    Method m1 = class_getInstanceMethod(self, @selector(loadFileURL:allowingReadAccessToURL:));
    Method m2 = class_getInstanceMethod(self, @selector(nuvio_loadFileURL:allowingReadAccessToURL:));
    if (m1 && m2) method_exchangeImplementations(m1, m2);

    Method e1 = class_getInstanceMethod(self, @selector(evaluateJavaScript:completionHandler:));
    Method e2 = class_getInstanceMethod(self, @selector(nuvio_evaluateJavaScript:completionHandler:));
    if (e1 && e2) method_exchangeImplementations(e1, e2);

    Method d1 = class_getInstanceMethod(self, NSSelectorFromString(@"dealloc"));
    Method d2 = class_getInstanceMethod(self, @selector(nuvio_dealloc));
    if (d1 && d2) method_exchangeImplementations(d1, d2);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved | NSEventMaskLeftMouseDown) handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
            static CFAbsoluteTime lastWake = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastWake > 0.12 && gActivePlayerWebView != nil) {
                if ([gActivePlayerWebView window] != nil && [gActivePlayerWebView superview] != nil) {
                    lastWake = now;
                    [gActivePlayerWebView evaluateJavaScript:@"if(window._nuvioWakeChrome)window._nuvioWakeChrome();" completionHandler:nil];
                } else {
                    gActivePlayerWebView = nil;
                }
            }
            return event;
        }];
    });
}

- (void)nuvio_dealloc {
    if (gActivePlayerWebView == self) {
        gActivePlayerWebView = nil;
    }
    [self nuvio_dealloc];
}

- (WKNavigation *)nuvio_loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL {
    gActivePlayerWebView = self;
    NSView *v = (NSView *)self;
    [v setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    if ([v superview]) {
        [v setFrame:[[v superview] bounds]];
    }
    if (URL && [URL isFileURL]) {
        NSString *dirPath = [[URL path] stringByDeletingLastPathComponent];
        NSString *htmlPath = [URL path];
        NSString *html = [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil];
        if (html && ![html containsString:@"xlink:href"]) {
            [[transpileHTMLForSafari11(html) dataUsingEncoding:NSUTF8StringEncoding] writeToFile:htmlPath atomically:YES];
        }
        NSString *jsPath = [dirPath stringByAppendingPathComponent:@"controls.js"];
        NSString *js = [NSString stringWithContentsOfFile:jsPath encoding:NSUTF8StringEncoding error:nil];
        if (js && (![js containsString:@"SAFARI 11 POLYFILLS"] || [js containsString:@"pointermove"])) {
            [[transpileJSForSafari11(js) dataUsingEncoding:NSUTF8StringEncoding] writeToFile:jsPath atomically:YES];
        }
        NSString *cssPath = [dirPath stringByAppendingPathComponent:@"controls.css"];
        NSString *css = [NSString stringWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:nil];
        if (css && ![css containsString:@"SAFARI 11 FIX16"]) {
            [[transpileCSSForSafari11(css) dataUsingEncoding:NSUTF8StringEncoding] writeToFile:cssPath atomically:YES];
        }
    }
    return [self nuvio_loadFileURL:URL allowingReadAccessToURL:readAccessURL];
}

- (void)nuvio_evaluateJavaScript:(NSString *)javaScriptString completionHandler:(void (^)(id, NSError *))completionHandler {
    if ([self window] != nil && [self superview] != nil) {
        gActivePlayerWebView = self;
    }
    static const void *kNuvioWebInitKey = &kNuvioWebInitKey;
    NSString *fixed = transpileJSForSafari11(javaScriptString);

    if (!objc_getAssociatedObject(self, kNuvioWebInitKey)) {
        objc_setAssociatedObject(self, kNuvioWebInitKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSView *v = (NSView *)self;
        if ([v superview] && !NSEqualSizes([v frame].size, [[v superview] bounds].size)) {
            [v setFrame:[[v superview] bounds]];
        }
        NSString *initJS = @"(function(){try{"
            "if(!window._nuvioSafari11Init){"
            "  window._nuvioSafari11Init=true;"
            "  var uses=document.querySelectorAll('use');"
            "  for(var i=0;i<uses.length;i++){"
            "    var h=uses[i].getAttribute('href');"
            "    if(h) uses[i].setAttributeNS('http://www.w3.org/1999/xlink','xlink:href',h);"
            "  }"
            "}"
            "}catch(e){}})();\n";
        fixed = [initJS stringByAppendingString:fixed];
    }

    [self nuvio_evaluateJavaScript:fixed completionHandler:completionHandler];
}
@end

CFArrayRef CTFontManagerCreateFontDescriptorsFromData(CFDataRef data) {
    if (!data) return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    CTFontDescriptorRef desc = CTFontManagerCreateFontDescriptorFromData(data);
    if (desc) {
        const void *values[] = { desc };
        CFArrayRef arr = CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
        CFRelease(desc);
        return arr;
    }
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}
