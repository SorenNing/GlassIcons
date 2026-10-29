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

#pragma mark - engine state

static BOOL gEngineEnabled = NO;
static NSMutableDictionary<NSString *, UIImage *> *gEngineCache = nil;
static NSMutableSet<NSString *> *gEngineMisses = nil;
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

static BOOL GIEngineHasIcons(void) {
    for (NSUInteger i = 0; i < sizeof(kGIEngineIconDirs)/sizeof(kGIEngineIconDirs[0]); i++) {
        NSUInteger count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kGIEngineIconDirs[i] error:NULL].count;
        if (count > 0) {
            GILogMain(@"iconpack dir contents = %lu at %s", (unsigned long)count, kGIEngineIconDirs[i].UTF8String);
            return YES;
        }
    }
    GILogMain(@"iconpack dir empty at all known paths");
    return NO;
}

#pragma mark - image lookup

static NSString *GIEngineFindIconPath(NSString *bid) {
    NSString *suffixes[] = {@"@3x.png", @"@2x.png", @".png"};
    NSString *paths[] = {kGIEngineIconDirs[0], kGIEngineIconDirs[1]};
    NSInteger numPaths = sizeof(paths)/sizeof(paths[0]);
    NSInteger numSuffixes = sizeof(suffixes)/sizeof(suffixes[0]);
    
    for (NSInteger pi = 0; pi < numPaths; pi++) {
        for (NSInteger si = 0; si < numSuffixes; si++) {
            NSString *path = [paths[pi] stringByAppendingPathComponent:[bid stringByAppendingString:suffixes[si]]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return path;
            }
        }
    }
    return nil;
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
        if (gEngineMisses.count < 200) {
            [gEngineMisses addObject:bid];
            GILogMain(@"icon miss %@ (searched: %@, %@)", bid, kGIEngineIconDirs[0], kGIEngineIconDirs[1]);
        }
        return nil;
    }

    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) {
        if (gEngineMisses.count < 200) {
            [gEngineMisses addObject:bid];
            GILogMain(@"icon fail load %@ at %@", bid, path);
        }
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

#pragma mark - data-layer hooks

static IMP oImageForIcon, oCachedImageForIcon, oRealImageForIcon, oGenerateIcon;

static void GIHook(Class cls, SEL sel, IMP repl, IMP *orig) {
    if (!cls) { GILogMain(@"hook: class missing for %@", NSStringFromSelector(sel)); return; }
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { GILogMain(@"hook: %@ has no %@", cls, NSStringFromSelector(sel)); return; }
    *orig = method_setImplementation(method, repl);
    GILogMain(@"hook ok: %@ %@", cls, NSStringFromSelector(sel));
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

static id HRealImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = GIEngineBundleIDForIcon(icon);
    UIImage *img = GIEngineImageForBundleID(bid);
    if (img) {
        if (++gEngineServed <= 30) GILogMain(@"real serve %@", bid);
        return img;
    }
    return ((id (*)(id, SEL, id))oRealImageForIcon)(self, _cmd, icon);
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

static NSMutableDictionary<NSString *, NSValue *> *gLayoutOriginals;
static NSUInteger gViewProbeLogs;

static id GIIconFromHost(id host) {
    return GIEngineBundleIDForIcon(host);
}

static void GIApplyPassiveImage(id host) {
    id bidObj = GIIconFromHost(host);
    NSString *bundleID = [bidObj isKindOfClass:[NSString class]] ? (NSString *)bidObj : nil;
    
    if (!bundleID) {
        if (gViewProbeLogs < 20) {
            gViewProbeLogs++;
            GILogMain(@"view probe: no bundleID (host=%@, bidObjClass=%@)", 
                      NSStringFromClass([host class]), bidObj ? NSStringFromClass([bidObj class]) : @"nil");
        }
        return;
    }

    UIImage *themeImage = GIEngineImageForBundleID(bundleID);
    if (!themeImage) {
        if (gViewProbeLogs < 20) {
            gViewProbeLogs++;
            GILogMain(@"view probe: no image for %@", bundleID);
        }
        return;
    }
    
    // Find the UIImageView that renders the icon.
    UIImageView *imageView = nil;
    if ([host isKindOfClass:[UIImageView class]]) {
        imageView = (UIImageView *)host;
    } else {
        // Try known ivars.
        for (NSString *key in @[@"_iconImageView", @"iconImageView", @"imageView"]) {
            id cand = [host valueForKey:key];
            if ([cand isKindOfClass:[UIImageView class]]) { imageView = cand; break; }
        }
        // Last resort: scan subviews.
        if (!imageView && [host isKindOfClass:[UIView class]]) {
            for (UIView *sv in [(UIView *)host subviews]) {
                if ([sv isKindOfClass:[UIImageView class]]) {
                    CGSize sz = sv.bounds.size;
                    if (sz.width >= 18 && sz.height >= 18 && ABS(sz.width - sz.height) <= 8) {
                        imageView = (UIImageView *)sv;
                        break;
                    }
                }
            }
        }
    }
    if (!imageView) {
        if (gViewProbeLogs < 20) {
            gViewProbeLogs++;
            GILogMain(@"view probe: no imageView for %@", bundleID);
        }
        return;
    }
    if (imageView.image == themeImage) {
        if (gViewProbeLogs < 10) {
            gViewProbeLogs++;
            GILogMain(@"view probe: image already set for %@", bundleID);
        }
        return;
    }
    
    imageView.image = themeImage;
    if (gViewProbeLogs < 40) {
        gViewProbeLogs++;
        GILogMain(@"view serve %@", bundleID);
    }
}

static void HLayoutSubviews(id self, SEL _cmd) {
    IMP original = NULL;
    Class cls = object_getClass(self);
    if (cls && gLayoutOriginals) {
        NSValue *value = gLayoutOriginals[NSStringFromClass(cls)];
        if (value) original = (IMP)[value pointerValue];
    }
    if (original && original != (IMP)HLayoutSubviews)
        ((void (*)(id, SEL))original)(self, _cmd);
    
    GIApplyPassiveImage(self);
    
    if (gViewProbeLogs < 40) {
        gViewProbeLogs++;
        GILogMain(@"view probe class=%@ bundle=%@", NSStringFromClass([self class]), 
                  [GIIconFromHost(self) isKindOfClass:[NSString class]] ? (NSString *)GIIconFromHost(self) : @"(nil)");
    }
}

static void GIHookLayoutClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { GILogMain(@"layout hook: class missing %@", className); return; }
    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!method) { GILogMain(@"layout hook: %@ has no layoutSubviews", className); return; }
    IMP original = method_getImplementation(method);
    if (!gLayoutOriginals) gLayoutOriginals = [NSMutableDictionary dictionary];
    gLayoutOriginals[className] = [NSValue valueWithPointer:original];
    
    const char *type = method_getTypeEncoding(method);
    if (!class_addMethod(cls, @selector(layoutSubviews), (IMP)HLayoutSubviews, type))
        method_setImplementation(method, (IMP)HLayoutSubviews);
    GILogMain(@"layout hook ok: %@", className);
}

#pragma mark - install / reload

static dispatch_once_t gEngineOnce;

static void GIIconEngineInstallHooks(void) {
    dispatch_once(&gEngineOnce, ^{
        gLayoutOriginals = [NSMutableDictionary dictionary];
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(imageForIcon:), (IMP)HImageForIcon, &oImageForIcon);
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCachedImageForIcon);
        GIHook(NSClassFromString(@"SBHIconImageCache"), NSSelectorFromString(@"realImageForIcon:"), (IMP)HRealImageForIcon, &oRealImageForIcon);
        GIHook(NSClassFromString(@"SBApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)HGenerateIcon, &oGenerateIcon);
        
        // Layout hooks — passive, only on-demand when system lays out icons.
        for (NSString *name in @[@"SBHLibraryCategoryPodIconView", @"_SBHLibraryPodIconView", @"SBHLibraryPodIconView",
                                  @"SearchUIHomeScreenAppIconView", @"SBFolderIconImageView",
                                  @"SBIconImageCrossfadeView", @"SBIconView"])
            GIHookLayoutClass(name);
    });
}

void GIIconEngineReload(void) {
    gEngineEnabled = GIEngineUserEnabled() && GIEngineHasIcons();
    GILogMain(@"engine reload enabled=%d", gEngineEnabled);
    gEngineCache = nil;
    gEngineMisses = nil;
    if (gEngineEnabled) GIIconEngineInstallHooks();
}

void GIIconEngineInstall(void) {
    gEngineEnabled = GIEngineUserEnabled() && GIEngineHasIcons();
    GILogMain(@"engine install enabled=%d", gEngineEnabled);
    if (gEngineEnabled) GIIconEngineInstallHooks();
}
