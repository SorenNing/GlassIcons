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

static NSString *const kGIEngineIconDir = @"/var/mobile/Library/GlassIcons/Icons";

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
    NSUInteger count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kGIEngineIconDir error:NULL].count;
    return count > 0;
}

#pragma mark - image lookup

static UIImage *GIEngineImageForBundleID(NSString *bid) {
    if (!gEngineEnabled || !bid.length) return nil;
    if (!gEngineCache) gEngineCache = [NSMutableDictionary dictionary];
    if (!gEngineMisses) gEngineMisses = [NSMutableSet set];

    @synchronized (gEngineCache) {
        UIImage *cached = gEngineCache[bid];
        if (cached) return cached;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *usedPath = nil;
    for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png"]) {
        NSString *path = [kGIEngineIconDir stringByAppendingPathComponent:[bid stringByAppendingString:suffix]];
        if ([fm fileExistsAtPath:path]) { usedPath = path; break; }
    }
    if (!usedPath) {
        if (gEngineMisses.count < 200) {
            [gEngineMisses addObject:bid];
            GILogMain(@"icon miss %@", bid);
        }
        return nil;
    }

    UIImage *img = [UIImage imageWithContentsOfFile:usedPath];
    if (!img) return nil;
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
    // Try to get bundleID from the icon/host object.
    for (NSString *name in @[@"applicationBundleID", @"bundleIdentifier", @"iconIdentifier"]) {
        if ([host respondsToSelector:NSSelectorFromString(name)]) {
            id bid = ((id (*)(id, SEL))objc_msgSend)(host, NSSelectorFromString(name));
            if ([bid isKindOfClass:[NSString class]] && [(NSString *)bid length] > 0) return bid;
        }
    }
    // Fallback: traverse ivars.
    for (NSString *key in @[@"_icon", @"icon", @"representedIcon", @"applicationIcon"]) {
        id candidate = [host valueForKey:key];
        if ([candidate respondsToSelector:@selector(applicationBundleID)])
            return [candidate applicationBundleID];
        if ([candidate isKindOfClass:[NSString class]] && [(NSString *)candidate length] > 0)
            return candidate;
    }
    return nil;
}

static void GIApplyPassiveImage(id host) {
    NSString *bundleID = [GIIconFromHost(host) isKindOfClass:[NSString class]] ? (NSString *)GIIconFromHost(host) : nil;
    UIImage *themeImage = GIEngineImageForBundleID(bundleID);
    if (!themeImage) return;
    
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
    if (!imageView || imageView.image == themeImage) return;
    
    imageView.image = themeImage;
    // No forced cornerRadius/clipsToBounds — let the system handle it.
    if (gViewProbeLogs < 40) {
        gViewProbeLogs++;
        GILogMain(@"view serve %@", bundleID ?: @"(nil)");
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
