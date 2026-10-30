// GIIconEngine.m
// GlassIcons icon pack engine (SpringBoard side).
//
// Responsibilities:
//   1. Index the selected icon directory's PNGs by bundle id.
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
#import <limits.h>
#import <string.h>
#import <sys/stat.h>

// ---------------------------------------------------------------- constants --

static NSString *const kGIEngineDefaultDir = @"/var/mobile/Library/GlassIcons/Icons";
static NSString *const kGIEngineRootHideDir = @"/var/jb/var/mobile/Library/GlassIcons/Icons";
static NSString *const kGIEngineThemesDir = @"/var/mobile/Library/GlassIcons/Themes";
static NSString *const kGIEngineRootHideThemesDir = @"/var/jb/var/mobile/Library/GlassIcons/Themes";

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

// A preference can be edited outside Settings; accept only a single directory
// component, using the same name rules as the theme manager. Invalid values
// select the legacy default instead of being treated as paths.
static BOOL GIEngineThemeNameIsSafe(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    if (![name isEqualToString:[name stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]]]) return NO;
    if ([name caseInsensitiveCompare:@"Default"] == NSOrderedSame) return NO;
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    if ([name rangeOfCharacterFromSet:
         [NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location != NSNotFound) return NO;
    if ([name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return NO;
    const char *bytes = name.fileSystemRepresentation;
    return bytes && strlen(bytes) > 0 && strlen(bytes) <= NAME_MAX;
}

// Called only while building/rebuilding the index, never per icon lookup.
static NSString *GIEngineSelectedThemeName(void) {
    if (!CFPreferencesAppSynchronize(CFSTR("com.soren.glassicons"))) {
        GILogMain(@"preference synchronization failed; theme may be stale");
    }
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("IconPackTheme"),
                                                        CFSTR("com.soren.glassicons"));
    NSString *name = nil;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        name = [(__bridge NSString *)value copy];
    }
    if (value) CFRelease(value);
    return GIEngineThemeNameIsSafe(name) ? name : nil;
}

// Reject symlinked managed directories for named themes. The system's /var
// ancestor is normally a symlink; the check starts at GlassIcons instead.
static BOOL GIEngineIsRealDirectory(NSString *path) {
    const char *bytes = path.fileSystemRepresentation;
    struct stat st;
    return bytes && lstat(bytes, &st) == 0 && S_ISDIR(st.st_mode);
}

static BOOL GIEngineNamedThemeDirectoryIsSafe(NSString *themesRoot, NSString *dir) {
    NSString *glassRoot = [themesRoot stringByDeletingLastPathComponent];
    return GIEngineIsRealDirectory(glassRoot) &&
           GIEngineIsRealDirectory(themesRoot) && GIEngineIsRealDirectory(dir);
}

static NSArray<NSString *> *GIEngineIconDirs(NSString *themeName) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithCapacity:2];
    if (!themeName) {
        // Preserve the legacy RootHide-first, per-icon fallback behavior.
        if ([[NSFileManager defaultManager] fileExistsAtPath:kGIEngineRootHideDir]) {
            [dirs addObject:kGIEngineRootHideDir];
        }
        [dirs addObject:kGIEngineDefaultDir];
        return dirs;
    }

    NSString *rootHideDir = [kGIEngineRootHideThemesDir stringByAppendingPathComponent:themeName];
    NSString *defaultDir = [kGIEngineThemesDir stringByAppendingPathComponent:themeName];
    if (GIEngineNamedThemeDirectoryIsSafe(kGIEngineRootHideThemesDir, rootHideDir)) {
        [dirs addObject:rootHideDir];
    }
    if (GIEngineNamedThemeDirectoryIsSafe(kGIEngineThemesDir, defaultDir)) {
        [dirs addObject:defaultDir];
    }
    // A missing named theme stays empty; never mix in the legacy default.
    return dirs;
}

// Bundle id -> absolute path of the theme PNG.
static NSMutableDictionary<NSString *, NSString *> *gEngineIndex = nil;
static NSMutableSet<NSString *> *gEngineMisses = nil;
static NSLock *gEngineIndexLock = nil;

static NSLock *GIEngineIndexLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEngineIndexLock = [[NSLock alloc] init];
    });
    return gEngineIndexLock;
}

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
    [gEngineMisses removeAllObjects];

    NSString *themeName = GIEngineSelectedThemeName();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger scanned = 0;

    for (NSString *dir in GIEngineIconDirs(themeName)) {
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in names) {
            if (![[name pathExtension].lowercaseString isEqualToString:@"png"]) continue;

            NSString *key = GIEngineIndexKeyForFilename(name);
            if (key.length == 0) continue;
            if ([key isEqualToString:@"_built"]) continue;      // packaging artefact

            // Directory order decides precedence: the first directory listed wins.
            if (gEngineIndex[key] != nil) continue;

            NSString *path = [dir stringByAppendingPathComponent:name];
            if (themeName) {
                // Do not let a named theme's PNG symlink point outside its root.
                const char *bytes = path.fileSystemRepresentation;
                struct stat st;
                if (!bytes || lstat(bytes, &st) != 0 || !S_ISREG(st.st_mode)) continue;
            }
            gEngineIndex[key] = path;
            scanned++;
        }
    }

    GILogMain(@"icon index built: %lu entries (theme: %@)",
              (unsigned long)scanned, themeName ?: @"Default");
}

// Returns the theme PNG path for a bundle id, or nil.
static NSString *GIEngineFindIconPath(NSString *bundleID) {
    if (bundleID.length == 0) return nil;

    [GIEngineIndexLock() lock];

    // An empty dictionary is a built, empty theme, not an uninitialized index.
    if (!gEngineIndex) {
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

    // Serialize a cache fill with reload so an old value cannot overwrite its
    // invalidation after the newly synchronized preferences have been read.
    [GIEngineIndexLock() lock];
    cached = __atomic_load_n(&gGIPackEnabledCache, __ATOMIC_RELAXED);
    if (cached < 0) {
        CFPropertyListRef value = CFPreferencesCopyAppValue(
            CFSTR("IconPackEnabled"), CFSTR("com.soren.glassicons"));
        BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID()
            ? CFBooleanGetValue((CFBooleanRef)value) : YES;
        if (value) CFRelease(value);
        cached = enabled ? 1 : 0;
        __atomic_store_n(&gGIPackEnabledCache, cached, __ATOMIC_RELAXED);
    }
    [gEngineIndexLock unlock];
    return cached == 1;
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
    // No icon-pack replacement runs in this recovery build.
    (void)icon;
    return NO;
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

// --- SBLeafIcon / SBApplicationIcon -----------------------------------------
//
// generateIconImageWithInfo: takes an SBIconImageInfo struct by value. We do not
// need to read it, only forward the bytes, so the replacement declares it as a
// plain argument list and passes the pointer through untouched.

static IMP oLeafGenerateIcon = NULL;
static IMP oAppGenerateIcon = NULL;

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


static UIImage *HAppGenerateIconImageWithInfo(id self, SEL _cmd, const void *info) {
    return GIIconImageInfoSubstitute(self, _cmd, info, oAppGenerateIcon, @"app-gen");
}


// --- installation ------------------------------------------------------------

// Extra 1-arg cache variants were added to this revision but are not part of
// the currently enabled recovery configuration. Keep the helpers above so
// future variant experiments remain independent.
static void GIIconEngineInstallHooksOnce(void) {
    // Keep only the four entry points that were exercised by the previous
    // stable build. The newer options/appearance and iconImageWithInfo:
    // variants have private ABI details that are not verified on this device.
    Class cache = NSClassFromString(@"SBHIconImageCache");
    if (cache) {
        GIHookMethod(cache, @selector(imageForIcon:),
                     (IMP)HImageForIcon, &oCacheImageForIcon);
        GIHookMethod(cache, @selector(cachedImageForIcon:),
                     (IMP)HCachedImageForIcon, &oCacheCachedImageForIcon);
        GILogMain(@"SBHIconImageCache hooks: image=%d cached=%d",
                  oCacheImageForIcon != NULL, oCacheCachedImageForIcon != NULL);
    } else {
        GILogMain(@"SBHIconImageCache missing");
    }

    Class app = NSClassFromString(@"SBApplicationIcon");
    if (app) {
        GIHookMethod(app, @selector(generateIconImageWithInfo:),
                     (IMP)HAppGenerateIconImageWithInfo, &oAppGenerateIcon);
        GILogMain(@"SBApplicationIcon hooks: gen=%d",
                  oAppGenerateIcon != NULL);
    }

    Class leaf = NSClassFromString(@"SBLeafIcon");
    if (leaf) {
        GIHookMethod(leaf, @selector(generateIconImageWithInfo:),
                     (IMP)HLeafGenerateIconImageWithInfo, &oLeafGenerateIcon);
        GILogMain(@"SBLeafIcon hooks: gen=%d",
                  oLeafGenerateIcon != NULL);
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
    [GIEngineIndexLock() lock];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];
    GIEngineBuildIconIndexLocked();
    NSUInteger count = gEngineIndex.count;
    __atomic_store_n(&gGIPackEnabledCache, -1, __ATOMIC_RELAXED);
    [gEngineIndexLock unlock];

    BOOL enabled = GIEnginePackEnabled() && count > 0;
    GILogMain(@"engine ready: %lu theme icons, pack %@",
              (unsigned long)count,
              enabled ? @"on" : @"off");

    // Do not install any icon hooks while the pack is disabled. This is also
    // the recovery path for devices that were left in a SpringBoard loop.
    // Recovery build: do not install icon-replacement hooks in SpringBoard.
    // Keep the installer referenced for later ABI-verified development only.
    (void)&GIIconEngineInstallHooks;
    GILogMain(@"icon hooks disabled in recovery build");
}

void GIIconEngineReload(void) {
    [GIEngineIndexLock() lock];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];
    GIEngineBuildIconIndexLocked();
    NSUInteger count = gEngineIndex.count;
    __atomic_store_n(&gGIPackEnabledCache, -1, __ATOMIC_RELAXED);
    [gEngineIndexLock unlock];

    gGIMissLogCount = 0;
    BOOL enabled = GIEnginePackEnabled() && count > 0;
    GILogMain(@"engine reloaded: %lu theme icons, pack %@",
              (unsigned long)count,
              enabled ? @"on" : @"off");

    // Recovery build: do not install icon-replacement hooks in SpringBoard.
    // Keep the installer referenced for later ABI-verified development only.
    (void)&GIIconEngineInstallHooks;
    GILogMain(@"icon hooks disabled in recovery build");
}
