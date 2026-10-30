// GIIconEngine.m
// GlassIcons icon pack engine (SpringBoard side).
//
// Responsibilities:
//   1. Build an index of /var/mobile/Library/GlassIcons/Icons/*.png keyed by bundle id.
//   2. Answer "do we have a theme image for this icon?" for the view layer.
//   3. Hook the SpringBoard image generation/caching entry points and substitute
//      the theme image when one exists.
//
// Deliberately NOT included: the iconservicesagent hooks. The ISGenerationRequest
// method name used there was guessed, so it is removed rather than shipped dead.
//
// Every hook keeps its own original IMP. Sharing one variable between two
// selectors of the same class silently redirects the second hook's fallback into
// the first method, which is a crash / garbage image waiting to happen.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------- constants --

static NSString *const kGIEngineDefaultDir = @"/var/mobile/Library/GlassIcons/Icons";
static NSString *const kGIEngineRootHideDir = @"/var/jb/var/mobile/Library/GlassIcons/Icons";

static NSString *const kGIEngineLogPath = @"/var/mobile/Library/GlassIcons.log";

// ---------------------------------------------------------------- logging ----

static void GILogMain(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[GlassIcons] %@", line);

    static dispatch_queue_t logQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQueue = dispatch_queue_create("com.soren.glassicons.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n",
                             [NSDate date], line];
        NSData *data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fm = [NSFileManager defaultManager];

        if (![fm fileExistsAtPath:kGIEngineLogPath]) {
            [data writeToFile:kGIEngineLogPath atomically:YES];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kGIEngineLogPath];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
        } @catch (__unused NSException *e) {
        }
        [fh closeFile];
    });
}

// ------------------------------------------------------------ icon directory -

static NSArray<NSString *> *GIEngineIconDirs(void) {
    NSMutableArray *dirs = [NSMutableArray arrayWithCapacity:2];

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kGIEngineRootHideDir]) {
        [dirs addObject:kGIEngineRootHideDir];
    }
    [dirs addObject:kGIEngineDefaultDir];

    return dirs;
}

// Bundle id -> absolute path of the theme PNG.
static NSMutableDictionary<NSString *, NSString *> *gEngineIndex = nil;
static NSMutableSet<NSString *> *gEngineMisses = nil;
static NSLock *gEngineIndexLock = nil;

// Strip the scale suffix so "x@3x" and "x@2x" both index as "x".
static NSString *GIEngineIndexKeyForFilename(NSString *filename) {
    NSString *base = [filename stringByDeletingPathExtension];   // drop .png
    if ([base hasSuffix:@"@3x"] || [base hasSuffix:@"@2x"]) {
        base = [base substringToIndex:base.length - 3];
    }
    return base;
}

// Caller must hold gEngineIndexLock, or be inside the one-time setup.
static void GIEngineBuildIconIndexLocked(void) {
    if (!gEngineIndex) gEngineIndex = [NSMutableDictionary dictionary];
    [gEngineIndex removeAllObjects];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger scanned = 0;

    for (NSString *dir in GIEngineIconDirs()) {
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in names) {
            if (![[name pathExtension].lowercaseString isEqualToString:@"png"]) continue;

            NSString *key = GIEngineIndexKeyForFilename(name);
            if (key.length == 0) continue;
            if ([key isEqualToString:@"_built"]) continue;      // packaging artefact

            // Directory order decides precedence: the first directory listed wins.
            if (gEngineIndex[key] != nil) continue;

            gEngineIndex[key] = [dir stringByAppendingPathComponent:name];
            scanned++;
        }
    }

    GILogMain(@"icon index built: %lu entries", (unsigned long)scanned);
}

// Returns the theme PNG path for a bundle id, or nil.
static NSString *GIEngineFindIconPath(NSString *bundleID) {
    if (bundleID.length == 0) return nil;

    if (!gEngineIndexLock) gEngineIndexLock = [[NSLock alloc] init];
    [gEngineIndexLock lock];

    if (!gEngineIndex || gEngineIndex.count == 0) {
        GIEngineBuildIconIndexLocked();
    }

    NSString *path = gEngineIndex[bundleID];

    if (!path) {
        // Tolerate a trailing "@2x"/"@3x" that slipped into the bundle id.
        NSString *trimmed = bundleID;
        if ([trimmed hasSuffix:@"@3x"] || [trimmed hasSuffix:@"@2x"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - 3];
            path = gEngineIndex[trimmed];
        }
    }

    [gEngineIndexLock unlock];
    return path;
}

// ------------------------------------------------------------ bundle id out --

// Best-effort bundle id for an icon object. Tries the concrete accessors first,
// then falls back to KVC on the private names SpringBoard is known to use.
static NSString *GIEngineBundleIDForIconObject(id icon) {
    if (!icon) return nil;

    NSArray<NSString *> *selectors = @[
        @"applicationBundleID",
        @"bundleIdentifier",
        @"iconIdentifier",
        @"leafIdentifier",
        @"nodeIdentifier",
    ];

    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if (![icon respondsToSelector:sel]) continue;

        id value = ((id (*)(id, SEL))objc_msgSend)(icon, sel);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }

    // SBApplicationIcon wraps an SBApplication; ask it directly.
    SEL appSel = NSSelectorFromString(@"application");
    if ([icon respondsToSelector:appSel]) {
        id app = ((id (*)(id, SEL))objc_msgSend)(icon, appSel);
        if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
            id bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
            if ([bid isKindOfClass:[NSString class]] && [bid length] > 0) {
                return bid;
            }
        }
    }

    return nil;
}

// ------------------------------------------------------------- image lookup --

// Master switch from Settings. Read-only here: the tweak owns writing it.
static int gGIPackEnabledCache = -1;   // -1 = not read yet

static BOOL GIEnginePackEnabled(void) {
    int cached = __atomic_load_n(&gGIPackEnabledCache, __ATOMIC_RELAXED);
    if (cached >= 0) return cached == 1;

    CFBooleanRef value = (CFBooleanRef)CFPreferencesCopyAppValue(
        CFSTR("IconPackEnabled"), CFSTR("com.soren.glassicons"));
    BOOL enabled = value ? CFBooleanGetValue(value) : YES;
    if (value) CFRelease(value);

    __atomic_store_n(&gGIPackEnabledCache, enabled ? 1 : 0, __ATOMIC_RELAXED);
    return enabled;
}

static NSUInteger gGIMissLogCount = 0;

static UIImage *GIEngineImageForBundleID(NSString *bundleID) {
    if (!GIEnginePackEnabled()) return nil;

    NSString *path = GIEngineFindIconPath(bundleID);
    if (!path && bundleID.length && gGIMissLogCount < 120) {
        gGIMissLogCount++;
        GILogMain(@"miss %@ (index=%lu)", bundleID, (unsigned long)gEngineIndex.count);
    }
    if (!path) return nil;

    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) {
        GILogMain(@"icon unreadable: %@ -> %@", bundleID, path);
        return nil;
    }
    return image;
}

BOOL GIEngineHasIconForBundleID(NSString *bundleID) {
    if (!GIEnginePackEnabled()) return NO;
    return GIEngineFindIconPath(bundleID) != nil;
}

// Index-only probe: no image decode. Called from the layout path, so it must
// stay cheap.
BOOL GIEngineIconHasPackIcon(id icon) {
    if (!GIEnginePackEnabled()) return NO;
    return GIEngineHasIconForBundleID(GIEngineBundleIDForIconObject(icon));
}

// --------------------------------------------------------------- hooking -----

// Install a replacement for `sel` on `cls`. Tries class_addMethod first so the
// change is scoped to `cls`; falls back to method_setImplementation, which will
// touch the superclass if `cls` merely inherits the method. `origOut` receives
// the implementation that was in place before us.
static void GIHookMethod(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    if (!cls || !sel || !replacement) return;
    if (origOut && *origOut) return;   // already installed

    Method existing = class_getInstanceMethod(cls, sel);
    if (!existing) return;

    IMP previous = method_getImplementation(existing);

    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(existing))) {
        if (origOut) *origOut = previous;
        return;
    }

    // The class already implements this selector itself.
    method_setImplementation(existing, replacement);
    if (origOut) *origOut = previous;
}

// --- SBHIconImageCache -------------------------------------------------------
//
// These are the cache hits SpringBoard serves the home screen and dock from.
// Each selector gets its own slot so the fallback always calls the method that
// was actually replaced.

static IMP oCacheImageForIcon = NULL;
static IMP oCacheCachedImageForIcon = NULL;
static IMP oCacheUnmaskedImageForIcon = NULL;

static NSUInteger gGIServeLogCount = 0;

static void GIServeLog(NSString *tag, NSString *bid) {
    if (gGIServeLogCount >= 200) return;
    gGIServeLogCount++;
    GILogMain(@"serve[%@] %@", tag, bid);
}

static NSUInteger gGINoBidLogCount = 0;

static void GINoBundleIDLog(NSString *tag, id icon) {
    if (gGINoBidLogCount >= 40) return;
    gGINoBidLogCount++;
    GILogMain(@"no-bid[%@] class=%@", tag, icon ? NSStringFromClass([icon class]) : @"nil");
}

static UIImage *GICacheSubstitute(id self, SEL _cmd, id icon, IMP orig, NSString *tag) {
    NSString *bid = GIEngineBundleIDForIconObject(icon);
    if (!bid) GINoBundleIDLog(tag, icon);
    if (bid) {
        UIImage *themed = GIEngineImageForBundleID(bid);
        if (themed) { GIServeLog(tag, bid); return themed; }
    }
    if (orig) return ((id (*)(id, SEL, id))orig)(self, _cmd, icon);
    return nil;
}

static UIImage *HImageForIcon(id self, SEL _cmd, id icon) {
    return GICacheSubstitute(self, _cmd, icon, oCacheImageForIcon, @"image");
}

static UIImage *HCachedImageForIcon(id self, SEL _cmd, id icon) {
    return GICacheSubstitute(self, _cmd, icon, oCacheCachedImageForIcon, @"cached");
}

static UIImage *HUnmaskedImageForIcon(id self, SEL _cmd, id icon) {
    return GICacheSubstitute(self, _cmd, icon, oCacheUnmaskedImageForIcon, @"unmasked");
}

// --- SBLeafIcon / SBApplicationIcon -----------------------------------------
//
// generateIconImageWithInfo: takes an SBIconImageInfo struct by value. We do not
// need to read it, only forward the bytes, so the replacement declares it as a
// plain argument list and passes the pointer through untouched.

static IMP oLeafGenerateIcon = NULL;
static IMP oLeafIconImageWithInfo = NULL;
static IMP oAppGenerateIcon = NULL;
static IMP oAppIconImageWithInfo = NULL;

typedef id (*GIIconImageInfoIMP)(id, SEL, const void *);

static UIImage *GIIconImageInfoSubstitute(id self, SEL _cmd, const void *info,
                                          IMP orig, NSString *tag) {
    NSString *bid = GIEngineBundleIDForIconObject(self);
    if (bid) {
        UIImage *themed = GIEngineImageForBundleID(bid);
        if (themed) { GIServeLog(tag, bid); return themed; }
    }
    if (orig) return ((GIIconImageInfoIMP)orig)(self, _cmd, info);
    return nil;
}

static UIImage *HLeafGenerateIconImageWithInfo(id self, SEL _cmd, const void *info) {
    return GIIconImageInfoSubstitute(self, _cmd, info, oLeafGenerateIcon, @"leaf-gen");
}

static UIImage *HLeafIconImageWithInfo(id self, SEL _cmd, const void *info) {
    return GIIconImageInfoSubstitute(self, _cmd, info, oLeafIconImageWithInfo, @"leaf-icon");
}

static UIImage *HAppGenerateIconImageWithInfo(id self, SEL _cmd, const void *info) {
    return GIIconImageInfoSubstitute(self, _cmd, info, oAppGenerateIcon, @"app-gen");
}

static UIImage *HAppIconImageWithInfo(id self, SEL _cmd, const void *info) {
    return GIIconImageInfoSubstitute(self, _cmd, info, oAppIconImageWithInfo, @"app-icon");
}

// --- installation ------------------------------------------------------------

// Extra 1-arg cache variants: same shape as imageForIcon:.
static IMP oCacheCachedUnmaskedImageForIcon = NULL;
static UIImage *HCachedUnmaskedImageForIcon(id self, SEL _cmd, id icon) {
    return GICacheSubstitute(self, _cmd, icon, oCacheCachedUnmaskedImageForIcon, @"cached-unmasked");
}

// 2-arg variants take (icon, options).
static IMP oCacheRealImageOpts = NULL;
static IMP oCacheUnmaskedImageOpts = NULL;

typedef id (*GI2ArgIMP)(id, SEL, id, id);

static UIImage *H2ArgSubstitute(id self, SEL _cmd, id icon, id options,
                                IMP orig, NSString *tag) {
    NSString *bid = GIEngineBundleIDForIconObject(icon);
    if (bid) {
        UIImage *themed = GIEngineImageForBundleID(bid);
        if (themed) { GIServeLog(tag, bid); return themed; }
    }
    if (orig) return ((GI2ArgIMP)orig)(self, _cmd, icon, options);
    return nil;
}

static UIImage *HRealImageOpts(id self, SEL _cmd, id icon, id options) {
    return H2ArgSubstitute(self, _cmd, icon, options, oCacheRealImageOpts, @"real-opts");
}

static UIImage *HUnmaskedImageOpts(id self, SEL _cmd, id icon, id options) {
    return H2ArgSubstitute(self, _cmd, icon, options, oCacheUnmaskedImageOpts, @"unmasked-opts");
}

// 3-arg variants take (icon, appearance, options).
static IMP oCacheImageAppearance = NULL;
static IMP oCacheCachedImageAppearance = NULL;

typedef id (*GI3ArgIMP)(id, SEL, id, id, id);

static UIImage *H3ArgSubstitute(id self, SEL _cmd, id icon, id appearance, id options,
                                IMP orig, NSString *tag) {
    NSString *bid = GIEngineBundleIDForIconObject(icon);
    if (bid) {
        UIImage *themed = GIEngineImageForBundleID(bid);
        if (themed) { GIServeLog(tag, bid); return themed; }
    }
    if (orig) return ((GI3ArgIMP)orig)(self, _cmd, icon, appearance, options);
    return nil;
}

static UIImage *HImageAppearance(id self, SEL _cmd, id icon, id appearance, id options) {
    return H3ArgSubstitute(self, _cmd, icon, appearance, options, oCacheImageAppearance, @"image-appear");
}

static UIImage *HCachedImageAppearance(id self, SEL _cmd, id icon, id appearance, id options) {
    return H3ArgSubstitute(self, _cmd, icon, appearance, options, oCacheCachedImageAppearance, @"cached-appear");
}

static void GIIconEngineInstallHooksOnce(void) {
    Class cache = NSClassFromString(@"SBHIconImageCache");
    if (cache) {
        // 1-arg
        GIHookMethod(cache, @selector(imageForIcon:), (IMP)HImageForIcon, &oCacheImageForIcon);
        GIHookMethod(cache, @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCacheCachedImageForIcon);
        GIHookMethod(cache, @selector(unmaskedImageForIcon:), (IMP)HUnmaskedImageForIcon, &oCacheUnmaskedImageForIcon);
        GIHookMethod(cache, NSSelectorFromString(@"cachedUnmaskedImageForIcon:"),
                     (IMP)HCachedUnmaskedImageForIcon, &oCacheCachedUnmaskedImageForIcon);

        // 2-arg
        GIHookMethod(cache, NSSelectorFromString(@"realImageForIcon:options:"),
                     (IMP)HRealImageOpts, &oCacheRealImageOpts);
        GIHookMethod(cache, NSSelectorFromString(@"unmaskedImageForIcon:options:"),
                     (IMP)HUnmaskedImageOpts, &oCacheUnmaskedImageOpts);

        // 3-arg
        GIHookMethod(cache, NSSelectorFromString(@"imageForIcon:imageAppearance:options:"),
                     (IMP)HImageAppearance, &oCacheImageAppearance);
        GIHookMethod(cache, NSSelectorFromString(@"cachedImageForIcon:imageAppearance:options:"),
                     (IMP)HCachedImageAppearance, &oCacheCachedImageAppearance);

        NSUInteger installed = 0;
        if (oCacheImageForIcon) installed++;
        if (oCacheCachedImageForIcon) installed++;
        if (oCacheUnmaskedImageForIcon) installed++;
        if (oCacheCachedUnmaskedImageForIcon) installed++;
        if (oCacheRealImageOpts) installed++;
        if (oCacheUnmaskedImageOpts) installed++;
        if (oCacheImageAppearance) installed++;
        if (oCacheCachedImageAppearance) installed++;
        GILogMain(@"SBHIconImageCache hooks: %lu/8", (unsigned long)installed);
    } else {
        GILogMain(@"SBHIconImageCache missing");
    }

    Class app = NSClassFromString(@"SBApplicationIcon");
    if (app) {
        GIHookMethod(app, @selector(generateIconImageWithInfo:),
                     (IMP)HAppGenerateIconImageWithInfo, &oAppGenerateIcon);
        GIHookMethod(app, @selector(iconImageWithInfo:),
                     (IMP)HAppIconImageWithInfo, &oAppIconImageWithInfo);
        GILogMain(@"SBApplicationIcon hooks: gen=%d info=%d",
                  oAppGenerateIcon != NULL, oAppIconImageWithInfo != NULL);
    }

    Class leaf = NSClassFromString(@"SBLeafIcon");
    if (leaf) {
        GIHookMethod(leaf, @selector(generateIconImageWithInfo:),
                     (IMP)HLeafGenerateIconImageWithInfo, &oLeafGenerateIcon);
        GIHookMethod(leaf, @selector(iconImageWithInfo:),
                     (IMP)HLeafIconImageWithInfo, &oLeafIconImageWithInfo);
        GILogMain(@"SBLeafIcon hooks: gen=%d info=%d",
                  oLeafGenerateIcon != NULL, oLeafIconImageWithInfo != NULL);
    }
}

static void GIIconEngineInstallHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        GIIconEngineInstallHooksOnce();
    });
}

// ---------------------------------------------------------------- lifecycle --

void GIIconEngineInstall(void) {
    if (!gEngineIndexLock) gEngineIndexLock = [[NSLock alloc] init];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];

    [gEngineIndexLock lock];
    GIEngineBuildIconIndexLocked();
    [gEngineIndexLock unlock];

    GILogMain(@"engine ready: %lu theme icons, pack %@",
              (unsigned long)gEngineIndex.count,
              GIEnginePackEnabled() ? @"on" : @"off");

    GIIconEngineInstallHooks();
}

void GIIconEngineReload(void) {
    if (!gEngineIndexLock) gEngineIndexLock = [[NSLock alloc] init];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];

    [gEngineIndexLock lock];
    GIEngineBuildIconIndexLocked();
    [gEngineIndexLock unlock];

    gGIMissLogCount = 0;
    __atomic_store_n(&gGIPackEnabledCache, -1, __ATOMIC_RELAXED);
    GILogMain(@"engine reloaded: %lu theme icons, pack %@",
              (unsigned long)gEngineIndex.count,
              GIEnginePackEnabled() ? @"on" : @"off");

    GIIconEngineInstallHooks();
}
