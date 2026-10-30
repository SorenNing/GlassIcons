// GIIconEngine.m — icon-pack replacement engine (v0.35)
// Data-layer hooks return original themed PNG; passive layout hook applies image on demand.
// No active purge/reload, no forced scaling — preserves system rendering.
// Glass overlay and badges are untouched.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <notify.h>

extern void GILogMain(NSString *format, ...);

static NSString *const kGIEngineIconDirs[] = {
    @"/var/mobile/Library/GlassIcons/Icons",
    @"/var/jb/var/mobile/Library/GlassIcons/Icons",
};

void GIIconEngineInstall(void);
void GIIconEngineReload(void);
BOOL GIEngineHasIconForBundleID(NSString *bid);
BOOL GIEngineIconHasPackIcon(id icon);

static NSString *GIEngineFindIconPath(NSString *bid);
static id GIEngineBundleIDForIcon(id icon);

#pragma mark - engine state

static BOOL gEngineEnabled = NO;
static NSMutableDictionary<NSString *, UIImage *> *gEngineCache = nil;
static NSMutableSet<NSString *> *gEngineMisses = nil;
static NSMutableDictionary<NSString *, NSString *> *gEngineIconDirIndex = nil;
static NSLock *gEngineIndexLock = nil;
static NSUInteger gEngineServed = 0;

static BOOL GIEngineUserEnabled(void) {
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IconPackEnabled"), CFSTR("com.soren.glassicons"));
    BOOL enabled = YES;
    if (ref) {
        enabled = CFGetTypeID(ref) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)ref) : YES;
        CFRelease(ref);
    }
    return enabled;
}

static void GIEngineInitIconIndex(void);
static void GIEngineBuildIconIndex(void);
static NSString *GIEngineFindIconPath(NSString *bid);

static BOOL GIEngineHasIcons(void) {
    for (NSUInteger i = 0; i < sizeof(kGIEngineIconDirs)/sizeof(kGIEngineIconDirs[0]); i++) {
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kGIEngineIconDirs[i] error:NULL];
        NSUInteger pngCount = 0;
        for (NSString *file in files) {
            if ([file hasSuffix:@".png"]) pngCount++;
        }
        if (pngCount > 0) {
            GILogMain(@"iconpack dir contents = %lu png files (%lu total) at %s",
                      (unsigned long)pngCount, (unsigned long)files.count, kGIEngineIconDirs[i].UTF8String);
            return YES;
        }
    }
    GILogMain(@"iconpack dir empty (no png) at all known paths");
    return NO;
}

#pragma mark - image lookup

// Icon file lookup with directory scanning and fuzzy matching.
// Does not assume file name == bundle ID exactly.

static NSString *kEngineIconSuffixes[] = {
    @"@3x.png", @"@2x.png", @".png",
};

// Build an index of all icon files found in known directories.
// CALLER MUST HOLD gEngineIndexLock.
static void GIEngineBuildIconIndex(void) {
    if (!gEngineIconDirIndex) {
        gEngineIconDirIndex = [NSMutableDictionary dictionary];
    }
    if (gEngineIconDirIndex[@"_built"]) return;
    for (NSUInteger di = 0; di < sizeof(kGIEngineIconDirs) / sizeof(kGIEngineIconDirs[0]); di++) {
        NSString *dir = kGIEngineIconDirs[di];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *file in files) {
            if (![file hasSuffix:@".png"]) continue;
            NSString *base = [file stringByDeletingPathExtension];
            base = [base stringByReplacingOccurrencesOfString:@"@3x" withString:@""];
            base = [base stringByReplacingOccurrencesOfString:@"@2x" withString:@""];
            if (!gEngineIconDirIndex[base]) {
                gEngineIconDirIndex[base] = [dir stringByAppendingPathComponent:file];
            }
        }
    }
    gEngineIconDirIndex[@"_built"] = @"yes";
}

static void GIEngineInitIconIndex(void) {
    if (!gEngineIndexLock) gEngineIndexLock = [NSLock new];
    [gEngineIndexLock lock];
    if (!gEngineIconDirIndex) {
        gEngineIconDirIndex = [NSMutableDictionary dictionary];
        GIEngineBuildIconIndex();
    }
    [gEngineIndexLock unlock];
}

// Attempt 1: Exact bundle ID match (bundleID.png, bundleID@3x.png, etc.)
// Attempt 2: Base name index match
// Attempt 3: Substring match (bundleID contains file base, or vice versa)
static NSString *GIEngineFindIconPath(NSString *bid) {
    if (!bid || !bid.length) return nil;

    // Attempt 1: Exact match across known directories and suffixes
    for (NSUInteger di = 0; di < sizeof(kGIEngineIconDirs) / sizeof(kGIEngineIconDirs[0]); di++) {
        for (NSUInteger si = 0; si < sizeof(kEngineIconSuffixes) / sizeof(kEngineIconSuffixes[0]); si++) {
            NSString *path = [kGIEngineIconDirs[di] stringByAppendingPathComponent:
                              [bid stringByAppendingString:kEngineIconSuffixes[si]]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return path;
            }
        }
    }

    // Attempt 2: Indexed base name match (held under index lock)
    if (!gEngineIndexLock) gEngineIndexLock = [NSLock new];
    [gEngineIndexLock lock];
    GIEngineBuildIconIndex();
    NSString *exact = gEngineIconDirIndex[bid];
    if (exact && ![bid isEqualToString:@"_built"]) { [gEngineIndexLock unlock]; return exact; }

    // Attempt 3: Fuzzy substring match
    NSString *bestMatch = nil;
    NSUInteger bestLen = 0;
    for (NSString *key in gEngineIconDirIndex) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([key isEqualToString:@"_built"]) continue;
        if ([bid containsString:key] && key.length > bestLen) {
            bestMatch = gEngineIconDirIndex[key];
            bestLen = key.length;
        }
    }
    if (bestMatch) { [gEngineIndexLock unlock]; return bestMatch; }

    // Attempt 4: Reverse — file base name contains bundleID
    for (NSString *key in gEngineIconDirIndex) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([key isEqualToString:@"_built"]) continue;
        if ([key containsString:bid] && bid.length > bestLen) {
            bestMatch = gEngineIconDirIndex[key];
            bestLen = bid.length;
        }
    }
    [gEngineIndexLock unlock];
    return bestMatch;
}

static UIImage *GIEngineImageForBundleID(NSString *bid) {
    if (!gEngineEnabled || !bid.length) return nil;
    if (!gEngineCache) gEngineCache = [NSMutableDictionary dictionary];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];

    @synchronized (gEngineCache) {
        UIImage *cached = gEngineCache[bid];
        if (cached) return cached;
    }

    NSString *path = GIEngineFindIconPath(bid);
    if (!path) {
        @synchronized (gEngineMisses) {
            if (gEngineMisses.count < 200) {
                [gEngineMisses addObject:bid];
            }
        }
        GILogMain(@"icon miss %@ (searched: %@, %@)", bid, kGIEngineIconDirs[0], kGIEngineIconDirs[1]);
        return nil;
    }

    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
        @synchronized (gEngineMisses) {
            if (gEngineMisses.count < 200) {
                [gEngineMisses addObject:bid];
            }
        }
        GILogMain(@"icon fail load %@ at %@", bid, path);
        return nil;
    }
    GILogMain(@"icon found %@ at %@", bid, path);
    // Return the original image and let SpringBoard scale to the requested
    // size. Pre-resampling to a fixed 60pt@3x made icons blurry whenever the
    // system displayed them at other sizes (dock, App Library, Spotlight).
    @synchronized (gEngineCache) {
        gEngineCache[bid] = img;
    }
    return img;
}

#pragma mark - icon / bundle id discovery

static id GIEngineBundleIDForIcon(id icon) {
    if (!icon) return nil;
    for (NSString *sel in @[@"applicationBundleID", @"bundleIdentifier", @"leafIdentifier", @"iconIdentifier"]) {
        SEL s = NSSelectorFromString(sel);
        if ([icon respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(icon, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    for (NSString *sel in @[@"icon", @"_icon", @"representedIcon", @"applicationIcon", @"item"]) {
        SEL s = NSSelectorFromString(sel);
        if (![icon respondsToSelector:s]) continue;
        id inner = ((id (*)(id, SEL))objc_msgSend)(icon, s);
        if (!inner || inner == icon) continue;
        for (NSString *idSel in @[@"applicationBundleID", @"bundleIdentifier", @"leafIdentifier", @"iconIdentifier"]) {
            SEL candidate = NSSelectorFromString(idSel);
            if (![inner respondsToSelector:candidate]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(inner, candidate);
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        }
    }
    for (NSString *key in @[@"icon", @"_icon"]) {
        @try {
            id inner = [icon valueForKey:key];
            if (inner && inner != icon) {
                id value = GIEngineBundleIDForIcon(inner);
                if (value) return value;
            }
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

#pragma mark - icon pack lookup (public API)

BOOL GIEngineHasIconForBundleID(NSString *bid) {
    if (!bid || !bid.length) return NO;
    if (!gEngineEnabled) return NO;
    @synchronized (gEngineCache) {
        if (gEngineCache[bid]) return YES;
    }
    @synchronized (gEngineMisses) {
        if (gEngineMisses.count && [gEngineMisses containsObject:bid]) return NO;
    }
    return GIEngineFindIconPath(bid) != nil;
}

BOOL GIEngineIconHasPackIcon(id icon) {
    NSString *bid = GIEngineBundleIDForIcon(icon);
    return GIEngineHasIconForBundleID(bid);
}

#pragma mark - data-layer hooks

static IMP oImageForIcon, oCachedImageForIcon, oGenerateIcon, oLeafGenerateIcon;

static void GIHook(Class cls, SEL sel, IMP repl, IMP *orig) {
    if (!cls) { GILogMain(@"hook: class missing for %@", NSStringFromSelector(sel)); return; }
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { GILogMain(@"hook: %@ has no %@", cls, NSStringFromSelector(sel)); return; }
    // Save original IMP first (needed for both paths).
    *orig = method_getImplementation(method);
    // class_addMethod adds to cls's own method list, shadowing any
    // inherited implementation — safe for all subclasses. Falls back to
    // method_setImplementation only if the selector already exists in
    // cls's own method list (class_addMethod returns NO).
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, sel, repl, types)) {
        GILogMain(@"hook ok: %@ %@ (class_addMethod)", cls, NSStringFromSelector(sel));
    } else {
        method_setImplementation(method, repl);
        GILogMain(@"hook ok: %@ %@ (method_setImplementation)", cls, NSStringFromSelector(sel));
    }
}

static id HImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = GIEngineBundleIDForIcon(icon);
    UIImage *img = GIEngineImageForBundleID(bid);
    if (img) {
        if (++gEngineServed <= 30) GILogMain(@"cache serve %@", bid);
        return img;
    }
    return ((id (*)(id, SEL, id))oImageForIcon)(self, _cmd, icon);
}

static id HCachedImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = GIEngineBundleIDForIcon(icon);
    UIImage *img = GIEngineImageForBundleID(bid);
    if (img) return img;
    return ((id (*)(id, SEL, id))oCachedImageForIcon)(self, _cmd, icon);
}

static id HLeafGenerateIcon(id self, SEL _cmd, id info) {
    NSString *bid = GIEngineBundleIDForIcon(self);
    UIImage *img = GIEngineImageForBundleID(bid);
    if (img) {
        if (++gEngineServed <= 30) GILogMain(@"leaf generate serve %@", bid);
        return img;
    }
    return ((id (*)(id, SEL, id))oLeafGenerateIcon)(self, _cmd, info);
}

static id HGenerateIcon(id self, SEL _cmd, id info) {
    NSString *bid = GIEngineBundleIDForIcon(self);
    UIImage *img = GIEngineImageForBundleID(bid);
    if (img) {
        if (++gEngineServed <= 30) GILogMain(@"generate serve %@", bid);
        return img;
    }
    return ((id (*)(id, SEL, id))oGenerateIcon)(self, _cmd, info);
}

#pragma mark - passive layout hook

// Layout hooks disabled to prevent SpringBoard restart loop.
// Data-layer hooks (cache + provider) are the only replacement path.

#pragma mark - install / reload

static dispatch_once_t gEngineOnce;

static void GIIconEngineInstallHooks(void) {
    dispatch_once(&gEngineOnce, ^{
        // SBHIconImageCache: imageForIcon: / cachedImageForIcon:
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(imageForIcon:), (IMP)HImageForIcon, &oImageForIcon);
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCachedImageForIcon);

        // SBApplicationIcon: generateIconImageWithInfo:
        GIHook(NSClassFromString(@"SBApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)HGenerateIcon, &oGenerateIcon);

        // SBLeafIcon: generateIconImageWithInfo: — home-screen leaf icons
        // (SnowBoard #87; 0.29 confirmed home-screen apps render via SBLeafIcon)
        GIHook(NSClassFromString(@"SBLeafIcon"), @selector(generateIconImageWithInfo:), (IMP)HLeafGenerateIcon, &oLeafGenerateIcon);

        // Do not hook layoutSubviews here. Writing UIImageView.image from a
        // layout callback races SpringBoard's own icon renderer and can cause
        // repeated layout/re-render cycles or a SpringBoard restart loop.
        // The cache/provider hooks above are the only replacement path.
    });
}

void GIIconEngineReload(void) {
    gEngineEnabled = GIEngineUserEnabled() && GIEngineHasIcons();
    GILogMain(@"engine reload enabled=%d", gEngineEnabled);
    gEngineCache = [NSMutableDictionary dictionary];
    gEngineMisses = [NSMutableSet set];
    gEngineIconDirIndex = nil;
    if (!gEngineIndexLock) gEngineIndexLock = [NSLock new];
    if (gEngineEnabled) {
        GIEngineInitIconIndex();
        GIIconEngineInstallHooks();
    }
}

void GIIconEngineInstall(void) {
    gEngineEnabled = GIEngineUserEnabled() && GIEngineHasIcons();
    GILogMain(@"engine install enabled=%d", gEngineEnabled);
    if (!gEngineIndexLock) gEngineIndexLock = [NSLock new];
    if (gEngineEnabled) {
        gEngineCache = [NSMutableDictionary dictionary];
        gEngineMisses = [NSMutableSet set];
        GIEngineInitIconIndex();
        GIIconEngineInstallHooks();
    }
}
