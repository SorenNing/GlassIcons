// GIIconService.m — opt-in iconservicesagent adapter; no cache invalidation.
// ARC; arm64/arm64e. See the adjacent filter plist. All private ABI calls are
// checked on the actual receiver before use. Unsupported cases return stock.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <os/log.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);

// These declarations only let ARC apply the correct init ownership convention;
// none is called before validating its exact method encoding and implementation.
@interface NSObject (GIIconServicePrivateInitializers)
- (id)initWithCGImage:(CGImageRef)image scale:(double)scale
          minimumSize:(CGSize)minimumSize placeholder:(BOOL)placeholder
             iconSize:(CGSize)iconSize;
- (id)initWithData:(id)data uuid:(id)uuid validationToken:(id)token;
@end

static const char *const kISPath = "/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static const char *const kIFPath = "/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation";
static const char *const kObjectABI = "@16@0:8";
static const char *const kSizeABI = "{CGSize=dd}16@0:8";
static const char *const kDoubleABI = "d16@0:8";
static const char *const kBoolABI = "B16@0:8";
static const char *const kCGImageABI = "^{CGImage=}16@0:8";
static const char *const kGenerateABI = "@24@0:8^@16";
static const char *const kCacheInitABI = "@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52";
static const char *const kImageInitABI = "@40@0:8@16@24@32";
static const char *const kLargestSetABI = "v20@0:8B16";

static Class gRequestClass, gIconClass, gDescriptorClass, gCacheClass, gImageClass;
typedef id (*GIGenerateIMP)(id, SEL, id __autoreleasing *);
static _Atomic(IMP) gOriginal;
static _Atomic(unsigned) gActiveRenders;
static _Atomic(bool) gAdapterUsable;
static _Atomic(bool) gLoggedException;
static _Thread_local bool gInsideHook;
static os_unfair_lock gSettingsLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *gSettings;
static dispatch_queue_t gSettingsQueue;
static int gSettingsToken = -1, gPackToken = -1;

static BOOL GIExactMethod(Class cls, SEL selector, const char *encoding,
                          const char *ownerPath) {
    if (!cls || !selector || !encoding || !ownerPath) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    const char *actual = method_getTypeEncoding(method);
    IMP imp = method_getImplementation(method);
    if (!actual || strcmp(actual, encoding) != 0 || !imp) return NO;
    Dl_info info = {0};
    return dladdr((const void *)imp, &info) && info.dli_fname &&
           strcmp(info.dli_fname, ownerPath) == 0;
}

static BOOL GIObjectMethod(id object, SEL selector, const char *encoding,
                           const char *ownerPath) {
    return object && GIExactMethod(object_getClass(object), selector, encoding, ownerPath);
}

static id GIGetObject(id object, SEL selector, const char *ownerPath) {
    if (!GIObjectMethod(object, selector, kObjectABI, ownerPath)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL GIGetSize(id object, SEL selector, const char *ownerPath, CGSize *out) {
    if (!out || !GIObjectMethod(object, selector, kSizeABI, ownerPath)) return NO;
    *out = ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
    return isfinite(out->width) && isfinite(out->height);
}

static BOOL GIGetDouble(id object, SEL selector, const char *ownerPath, double *out) {
    if (!out || !GIObjectMethod(object, selector, kDoubleABI, ownerPath)) return NO;
    *out = ((double (*)(id, SEL))objc_msgSend)(object, selector);
    return isfinite(*out);
}

static BOOL GIGetBool(id object, SEL selector, const char *ownerPath, BOOL *out) {
    if (!out || !GIObjectMethod(object, selector, kBoolABI, ownerPath)) return NO;
    *out = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return YES;
}

static BOOL GISafeThemeName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
        ![name isEqualToString:[name stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]] ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name caseInsensitiveCompare:@"Default"] == NSOrderedSame ||
        [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location != NSNotFound ||
        [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return NO;
    const char *bytes = name.fileSystemRepresentation;
    return bytes && strlen(bytes) > 0 && strlen(bytes) <= NAME_MAX;
}

// Identifiers are single path components. Match the sample's conservative
// ASCII alphabet; also require separators between nonempty components.
static BOOL GISafeBundleID(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return NO;
    const char *s = name.UTF8String;
    if (!s) return NO;
    size_t n = strlen(s);
    if (n < 1 || n > NAME_MAX - 7 || n != [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return NO;
    bool dot = true;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '.') { if (dot) return NO; dot = true; continue; }
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_')) return NO;
        dot = false;
    }
    return !dot;
}

static NSDictionary *GICurrentSettings(void) {
    os_unfair_lock_lock(&gSettingsLock);
    NSDictionary *snapshot = gSettings;
    os_unfair_lock_unlock(&gSettingsLock);
    return snapshot;
}

// Refresh outside the hook. A failed synchronization or invalid configuration
// clears the snapshot, so failures never silently enable the adapter.
static void GIReloadSettings(void) {
    NSDictionary *snapshot = nil;
    @try {
        if (CFPreferencesAppSynchronize(CFSTR("com.soren.glassicons"))) {
            id service = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("IconServiceEnabled"), CFSTR("com.soren.glassicons")));
            id theme = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("IconPackTheme"), CFSTR("com.soren.glassicons")));
            BOOL enabled = YES;
            if (service) {
                enabled = CFGetTypeID((__bridge CFTypeRef)service) == CFBooleanGetTypeID() &&
                          CFBooleanGetValue((__bridge CFBooleanRef)service);
            }
            NSString *name = @"Default";
            if (theme) name = [theme isKindOfClass:[NSString class]] ? theme : nil;
            if (name && ([name isEqualToString:@"Default"] || GISafeThemeName(name))) {
                snapshot = @{@"enabled": @(enabled), @"theme": [name copy]};
            }
        }
    } @catch (__unused NSException *exception) {
        snapshot = nil;
    }
    os_unfair_lock_lock(&gSettingsLock);
    gSettings = snapshot;
    os_unfair_lock_unlock(&gSettingsLock);
}

static BOOL GIKillSwitchPresent(void) {
    struct stat st;
    if (lstat("/var/mobile/Library/local.glassicons.disabled", &st) == 0) return YES;
    return errno != ENOENT; // on permission or other errors fail closed
}

static int GIOpenChild(int parent, const char *name) {
    if (parent < 0 || !name || !*name) return -1;
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int GIOpenThemeDirectory(const char *libraryPath, NSString *theme) {
    // /var and /var/jb may themselves be jailbreak/system symlinks. Treat the
    // Library path as the configured anchor, then reject symlinks at every
    // managed GlassIcons/Icons or GlassIcons/Themes/<theme> component.
    int library = open(libraryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (library < 0) return -1;
    int root = GIOpenChild(library, "GlassIcons");
    close(library);
    if (root < 0) return -1;
    int dir = -1;
    if ([theme isEqualToString:@"Default"]) {
        dir = GIOpenChild(root, "Icons");
    } else if (GISafeThemeName(theme)) {
        int themes = GIOpenChild(root, "Themes");
        if (themes >= 0) {
            dir = GIOpenChild(themes, theme.fileSystemRepresentation);
            close(themes);
        }
    }
    close(root);
    return dir;
}

static NSData *GIReadRegularFile(int directory, NSString *filename) {
    const char *name = filename.fileSystemRepresentation;
    if (!name || strlen(name) > NAME_MAX) return nil;
    int fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before = {0}, after = {0};
    void *buffer = NULL;
    size_t length = 0, used = 0;
    BOOL ok = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) &&
              before.st_size >= 8 && before.st_size <= 4 * 1024 * 1024;
    if (ok) {
        length = (size_t)before.st_size;
        buffer = malloc(length);
        ok = buffer != NULL;
    }
    while (ok && used < length) {
        ssize_t count = read(fd, (char *)buffer + used, length - used);
        if (count > 0) used += (size_t)count;
        else if (count < 0 && errno == EINTR) continue;
        else ok = NO;
    }
    if (ok) {
        ok = fstat(fd, &after) == 0 && before.st_dev == after.st_dev &&
             before.st_ino == after.st_ino && before.st_size == after.st_size &&
             before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
             before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
             before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
             before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
    }
    close(fd);
    static const unsigned char pngSignature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (ok) ok = memcmp(buffer, pngSignature, sizeof(pngSignature)) == 0;
    if (!ok) { free(buffer); return nil; }
    // Ownership transfers to NSData; no mapping is kept across a rename.
    return [[NSData alloc] initWithBytesNoCopy:buffer length:length freeWhenDone:YES];
}

static NSData *GILoadIconData(NSString *theme, NSString *bundleID, int scale) {
    if (!GISafeBundleID(bundleID) || !([theme isEqualToString:@"Default"] || GISafeThemeName(theme))) return nil;
    NSMutableArray<NSString *> *files = [NSMutableArray arrayWithCapacity:4];
    if (scale == 2 || scale == 3) [files addObject:[bundleID stringByAppendingFormat:@"@%dx.png", scale]];
    [files addObject:[bundleID stringByAppendingString:@".png"]];
    if (scale != 3) [files addObject:[bundleID stringByAppendingString:@"@3x.png"]];
    if (scale != 2) [files addObject:[bundleID stringByAppendingString:@"@2x.png"]];
    const char *roots[] = {"/var/jb/var/mobile/Library", "/var/mobile/Library"};
    for (size_t i = 0; i < sizeof(roots) / sizeof(roots[0]); i++) {
        int directory = GIOpenThemeDirectory(roots[i], theme);
        if (directory < 0) continue;
        NSData *result = nil;
        @try {
            for (NSString *filename in files) {
                result = GIReadRegularFile(directory, filename);
                if (result) break;
            }
        } @finally {
            close(directory);
        }
        if (result) return result;
    }
    return nil;
}

// Decode only bounded, nonanimated square PNGs with normal orientation. Render
// into a fresh exact-size RGBA bitmap; never hand a UIKit object to the daemon.
static CGImageRef GICopyRaster(NSData *data, size_t target) CF_RETURNS_RETAINED;
static CGImageRef GICopyRaster(NSData *data, size_t target) {
    if (!data || !target || target > 1200) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef decoded = NULL, output = NULL;
    CGContextRef context = NULL;
    CGColorSpaceRef colorspace = NULL;
    CFDictionaryRef properties = NULL;
    @try {
        if (CGImageSourceGetStatus(source) != kCGImageStatusComplete ||
            CGImageSourceGetCount(source) != 1 ||
            !CGImageSourceGetType(source) || !CFEqual(CGImageSourceGetType(source), CFSTR("public.png"))) return NULL;
        properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
        NSDictionary *p = (__bridge NSDictionary *)properties;
        id width = p[(__bridge NSString *)kCGImagePropertyPixelWidth];
        id height = p[(__bridge NSString *)kCGImagePropertyPixelHeight];
        id orientation = p[(__bridge NSString *)kCGImagePropertyOrientation];
        if (![width isKindOfClass:[NSNumber class]] || ![height isKindOfClass:[NSNumber class]] ||
            (orientation && (![orientation isKindOfClass:[NSNumber class]] || [orientation integerValue] != 1))) return NULL;
        double w = [width doubleValue], h = [height doubleValue];
        if (!isfinite(w) || !isfinite(h) || w < 1 || w > 2048 || w != h || floor(w) != w) return NULL;
        NSDictionary *opts = @{(__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
        decoded = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
        if (!decoded || CGImageGetWidth(decoded) != (size_t)w || CGImageGetHeight(decoded) != (size_t)h) return NULL;
        colorspace = CGColorSpaceCreateDeviceRGB();
        if (!colorspace) return NULL;
        context = CGBitmapContextCreate(NULL, target, target, 8, 0, colorspace,
                                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (!context) return NULL;
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)target, (CGFloat)target), decoded);
        output = CGBitmapContextCreateImage(context);
    } @finally {
        if (context) CGContextRelease(context);
        if (colorspace) CGColorSpaceRelease(colorspace);
        if (decoded) CGImageRelease(decoded);
        if (properties) CFRelease(properties);
        CFRelease(source);
    }
    return output;
}

typedef struct {
    CGSize pixels, minimum, icon;
    double scale;
    BOOL placeholder, largest;
} GIGeometry;

static BOOL GIReadGeometry(id stock, GIGeometry *g) {
    if (!stock || !g || ![stock isKindOfClass:gImageClass]) return NO;
    if (!GIGetSize(stock, sel_registerName("pixelSize"), kIFPath, &g->pixels) ||
        !GIGetSize(stock, sel_registerName("minimumSize"), kIFPath, &g->minimum) ||
        !GIGetSize(stock, sel_registerName("iconSize"), kIFPath, &g->icon) ||
        !GIGetDouble(stock, sel_registerName("scale"), kIFPath, &g->scale) ||
        !GIGetBool(stock, sel_registerName("placeholder"), kIFPath, &g->placeholder) ||
        !GIGetBool(stock, sel_registerName("largest"), kIFPath, &g->largest)) return NO;
    double p = g->pixels.width;
    if (g->placeholder || p < 1 || p > 1200 || floor(p) != p || p != g->pixels.height ||
        g->scale < 1 || g->scale > 3 || floor(g->scale) != g->scale ||
        g->minimum.width <= 0 || g->minimum.width != g->minimum.height ||
        g->icon.width < g->minimum.width || g->icon.width != g->icon.height ||
        g->icon.width > 1200 || fabs(g->icon.width * g->scale - p) > 0.01) return NO;
    SEL cgSel = sel_registerName("cgImage");
    if (!GIObjectMethod(stock, cgSel, kCGImageABI, kIFPath)) return NO;
    CGImageRef image = ((CGImageRef (*)(id, SEL))objc_msgSend)(stock, cgSel);
    return image && CGImageGetWidth(image) == (size_t)p && CGImageGetHeight(image) == (size_t)p;
}

static NSString *GIRequestBundleID(id request, const GIGeometry *g) {
    id icon = GIGetObject(request, sel_registerName("icon"), kISPath);
    id descriptor = GIGetObject(request, sel_registerName("imageDescriptor"), kISPath);
    if (!icon || object_getClass(icon) != gIconClass ||
        !descriptor || object_getClass(descriptor) != gDescriptorClass) return nil;
    id bundleID = GIGetObject(icon, sel_registerName("bundleIdentifier"), kISPath);
    CGSize size = CGSizeZero;
    double scale = 0;
    if (!GISafeBundleID(bundleID) ||
        !GIGetSize(descriptor, sel_registerName("size"), kISPath, &size) ||
        !GIGetDouble(descriptor, sel_registerName("scale"), kISPath, &scale) ||
        size.width < 1 || size.width > 400 || size.width != size.height ||
        scale < 1 || scale > 3 || floor(scale) != scale ||
        scale != g->scale || fabs(size.width * scale - g->pixels.width) > 0.01) return nil;
    return [bundleID copy];
}

static id GIBuildReplacement(id stock, CGImageRef raster, const GIGeometry *g) {
    if (!stock || !raster || !g || CGImageGetWidth(raster) != (size_t)g->pixels.width ||
        CGImageGetHeight(raster) != (size_t)g->pixels.height) return nil;
    SEL cacheInit = sel_registerName("initWithCGImage:scale:minimumSize:placeholder:iconSize:");
    SEL imageInit = sel_registerName("initWithData:uuid:validationToken:");
    if (!GIExactMethod(gCacheClass, cacheInit, kCacheInitABI, kIFPath) ||
        !GIExactMethod(gImageClass, imageInit, kImageInitABI, kIFPath)) return nil;
    id uuid = GIGetObject(stock, sel_registerName("uuid"), kIFPath);
    id token = GIGetObject(stock, sel_registerName("validationToken"), kIFPath);
    // The sample requires a 40-unit token but does not prove its concrete class.
    // Here only public Foundation length APIs are called, on bounded known types.
    NSUInteger tokenLength = 0;
    if ([token isKindOfClass:[NSData class]]) tokenLength = [(NSData *)token length];
    else if ([token isKindOfClass:[NSString class]]) tokenLength = [(NSString *)token length];
    else return nil;
    if (tokenLength != 40) return nil;
    id allocatedCache = [gCacheClass alloc];
    if (!GIObjectMethod(allocatedCache, cacheInit, kCacheInitABI, kIFPath)) return nil;
    id cache = [allocatedCache initWithCGImage:raster scale:g->scale minimumSize:g->minimum
                                   placeholder:g->placeholder iconSize:g->icon];
    id bitmapData = GIGetObject(cache, sel_registerName("bitmapData"), kIFPath);
    if (!cache || !bitmapData) return nil;
    id allocatedImage = [gImageClass alloc];
    if (!GIObjectMethod(allocatedImage, imageInit, kImageInitABI, kIFPath)) return nil;
    id result = [allocatedImage initWithData:bitmapData uuid:uuid validationToken:token];
    SEL setLargest = sel_registerName("setLargest:");
    if (!result || ![result isKindOfClass:gImageClass] ||
        !GIObjectMethod(result, setLargest, kLargestSetABI, kIFPath)) return nil;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(result, setLargest, g->largest);
    return result;
}

static id GIReplace(id request, id stock, NSDictionary *settings) {
    GIGeometry geometry = {0};
    if (!GIReadGeometry(stock, &geometry)) return nil;
    NSString *bundleID = GIRequestBundleID(request, &geometry);
    if (!bundleID) return nil;
    NSData *data = GILoadIconData(settings[@"theme"], bundleID, (int)geometry.scale);
    if (!data) return nil;
    CGImageRef image = GICopyRaster(data, (size_t)geometry.pixels.width);
    if (!image) return nil;
    id replacement = nil;
    @try {
        replacement = GIBuildReplacement(stock, image, &geometry);
    } @finally {
        CGImageRelease(image);
    }
    return replacement;
}

static id GIGenerate(id self, SEL cmd, id __autoreleasing *identifiers) {
    // Original is always called once, with the caller's exact out pointer.
    IMP original = atomic_load_explicit(&gOriginal, memory_order_acquire);
    if (!original) return nil; // cannot occur once installation publishes a hook
    if (gInsideHook) return ((GIGenerateIMP)original)(self, cmd, identifiers);
    gInsideHook = true;
    id stock = nil;
    @try {
        stock = ((GIGenerateIMP)original)(self, cmd, identifiers);
    } @finally {
        gInsideHook = false;
    }
    if (!stock || !atomic_load_explicit(&gAdapterUsable, memory_order_acquire)) return stock;
    // Do not make the daemon wait for the adapter's own work. A saturated
    // pipeline returns stock rather than queuing an unbounded number of PNGs.
    unsigned active = atomic_fetch_add_explicit(&gActiveRenders, 1, memory_order_relaxed);
    if (active >= 2) {
        atomic_fetch_sub_explicit(&gActiveRenders, 1, memory_order_relaxed);
        return stock;
    }
    id replacement = nil;
    gInsideHook = true;
    @try {
        NSDictionary *settings = GICurrentSettings();
        if ([settings[@"enabled"] boolValue] && !GIKillSwitchPresent()) {
            replacement = GIReplace(self, stock, settings);
        }
    } @catch (__unused NSException *exception) {
        bool already = atomic_exchange_explicit(&gLoggedException, true, memory_order_relaxed);
        if (!already) os_log_error(OS_LOG_DEFAULT, "GIIconService: exception; returning stock image");
    } @finally {
        gInsideHook = false;
        atomic_fetch_sub_explicit(&gActiveRenders, 1, memory_order_relaxed);
    }
    return replacement ?: stock;
}

static BOOL GIIsSupportedProcess(void) {
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"iconservicesagent"]) return NO;
    char executable[PATH_MAX] = {0};
    uint32_t size = (uint32_t)sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 ||
        strcmp(executable, "/System/Library/CoreServices/iconservicesagent") != 0) return NO;
    const char *service = getenv("XPC_SERVICE_NAME");
    return service && strcmp(service, "com.apple.iconservices.iconservicesagent") == 0;
}

static void GIInstall(void) {
    if (!GIIsSupportedProcess() || GIKillSwitchPresent()) return;
    GIReloadSettings();
    if (![GICurrentSettings()[@"enabled"] boolValue]) return; // startup is opt-in
    gRequestClass = objc_getClass("ISGenerationRequest");
    gIconClass = objc_getClass("ISBundleIdentifierIcon");
    gDescriptorClass = objc_getClass("ISImageDescriptor");
    gCacheClass = objc_getClass("IFCacheImage");
    gImageClass = objc_getClass("IFImage");
    SEL generate = sel_registerName("generateImageReturningRecordIdentifiers:");
    if (!gRequestClass || !gIconClass || !gDescriptorClass || !gCacheClass || !gImageClass ||
        !GIExactMethod(gRequestClass, generate, kGenerateABI, kISPath) ||
        !GIExactMethod(gCacheClass, sel_registerName("initWithCGImage:scale:minimumSize:placeholder:iconSize:"), kCacheInitABI, kIFPath) ||
        !GIExactMethod(gImageClass, sel_registerName("initWithData:uuid:validationToken:"), kImageInitABI, kIFPath)) {
        os_log_error(OS_LOG_DEFAULT, "GIIconService: unsupported private ABI; hook not installed");
        return;
    }
    Method method = class_getInstanceMethod(gRequestClass, generate);
    IMP stockIMP = method ? method_getImplementation(method) : NULL;
    if (!stockIMP) return;
    // Register both known preference notifications before hooking; if either
    // registration fails, no hook is installed and no stale opt-in is used.
    gSettingsQueue = dispatch_queue_create("com.soren.glassicons.iconservice.settings", DISPATCH_QUEUE_SERIAL);
    if (!gSettingsQueue) return;
    uint32_t s1 = notify_register_dispatch("com.soren.glassicons.changed", &gSettingsToken, gSettingsQueue, ^(int token) {
        (void)token; GIReloadSettings();
    });
    uint32_t s2 = notify_register_dispatch("com.soren.glassicons.iconpack", &gPackToken, gSettingsQueue, ^(int token) {
        (void)token; GIReloadSettings();
    });
    if (s1 != NOTIFY_STATUS_OK || s2 != NOTIFY_STATUS_OK) {
        if (s1 == NOTIFY_STATUS_OK) notify_cancel(gSettingsToken);
        if (s2 == NOTIFY_STATUS_OK) notify_cancel(gPackToken);
        os_log_error(OS_LOG_DEFAULT, "GIIconService: notification setup failed; hook not installed");
        return;
    }
    // Prevent the small installation window from having a NULL original. The
    // preflight rejects already-hooked implementations outside IconServices.
    atomic_store_explicit(&gOriginal, stockIMP, memory_order_release);
    IMP chained = NULL;
    MSHookMessageEx(gRequestClass, generate, (IMP)GIGenerate, &chained);
    if (!chained) {
        // Substrate has no success return and can leave a partial hook; keep
        // the verified stock IMP published but permanently bypass replacement.
        os_log_error(OS_LOG_DEFAULT, "GIIconService: original IMP unavailable; stock-only mode");
        return;
    }
    atomic_store_explicit(&gOriginal, chained, memory_order_release);
    atomic_store_explicit(&gAdapterUsable, true, memory_order_release);
    os_log(OS_LOG_DEFAULT, "GIIconService: opt-in hook attempted with original IMP");
}

__attribute__((constructor)) static void GIIconServiceStart(void) {
    @autoreleasepool {
        @try {
            GIInstall();
        } @catch (__unused NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "GIIconService: startup exception; stock-only mode");
        }
    }
}

// Mismatch anywhere falls back to stock. (Reserved for future ABI tables.)
