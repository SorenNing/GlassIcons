// GIIconEngine.m — icon-pack replacement engine ported from SnowBoardRecovered
// 1.0 (which user-verified as replacing home-screen icons on iOS 17.2.1).
// Reads themed PNGs from /var/mobile/Library/GlassIcons/Icons/<bundleID>.png
// (@2x/@3x variants supported). Hooks SBHIconImageCache (imageForIcon: /
// cachedImageForIcon: / realImageForIcon:), SBApplicationIcon
// generateIconImageWithInfo:, and seven icon layout classes to place the
// themed image directly on the rendered image view, then actively purges and
// reloads visible icons. Glass overlay (GlassIcons.m) and badges
// (BadgeGlass.m) are untouched.
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
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(60, 60) format:format];
    UIImage *out = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, 60, 60)];
    }] ?: img;

    @synchronized (gEngineCache) {
        gEngineCache[bid] = out;
    }
    return out;
}

#pragma mark - icon / bundle id discovery

static id GICall0(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id GICall1(id object, NSString *name, id value) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL, id))objc_msgSend)(object, selector, value) : nil;
}

static void GIVoid0(id object, NSString *name) {
    if (!object) return;
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static void GIVoid1(id object, NSString *name, id value) {
    if (!object) return;
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

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

static id GIIconForView(id view) {
    for (NSString *name in @[@"icon", @"_icon", @"representedIcon", @"applicationIcon", @"item"]) {
        id icon = GICall0(view, name);
        if (icon) return icon;
    }
    for (NSString *key in @[@"icon", @"_icon"]) {
        @try {
            id icon = [view valueForKey:key];
            if (icon) return icon;
        } @catch (__unused NSException *exception) {}
    }
    return view;
}

#pragma mark - apply themed image

static UIImageView *GIImageViewForHost(id host) {
    if ([host isKindOfClass:[UIImageView class]]) return (UIImageView *)host;
    for (NSString *name in @[@"_iconImageView", @"iconImageView", @"imageView", @"_imageView"]) {
        id candidate = GICall0(host, name);
        if ([candidate isKindOfClass:[UIImageView class]]) return candidate;
    }
    if (![host isKindOfClass:[UIView class]]) return nil;
    for (UIView *subview in ((UIView *)host).subviews) {
        if (![subview isKindOfClass:[UIImageView class]]) continue;
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width >= 18.0 && height >= 18.0 && ABS(width - height) <= 8.0)
            return (UIImageView *)subview;
    }
    return nil;
}

static BOOL GIApplyImageToHost(id host) {
    NSString *bundleID = GIEngineBundleIDForIcon(GIIconForView(host));
    UIImage *image = GIEngineImageForBundleID(bundleID);
    if (!image) return NO;
    UIImageView *imageView = GIImageViewForHost(host);
    if (!imageView) return NO;
    if (imageView.image == image) return YES;
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = CGRectGetWidth(imageView.bounds) * 0.225;
    GILogMain(@"view serve %@ class=%@", bundleID, NSStringFromClass([host class]));
    return YES;
}

static void GIApplyImageRecursively(UIView *view, NSInteger depth) {
    if (!view || depth > 4) return;
    if (GIApplyImageToHost(view)) return;
    for (UIView *subview in view.subviews) GIApplyImageRecursively(subview, depth + 1);
}

#pragma mark - layout hooks

static NSMutableDictionary<NSString *, NSValue *> *gLayoutOriginals;
static NSUInteger gViewProbeLogs;

static IMP GILayoutOriginalForObject(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = gLayoutOriginals[NSStringFromClass(cls)];
        if (value) return [value pointerValue];
    }
    return NULL;
}

static void HLayoutSubviews(id self, SEL _cmd) {
    IMP original = GILayoutOriginalForObject(self);
    if (original && original != (IMP)HLayoutSubviews) ((void (*)(id, SEL))original)(self, _cmd);
    @try {
        GIApplyImageRecursively((UIView *)self, 0);
        if (gViewProbeLogs < 40) {
            gViewProbeLogs++;
            GILogMain(@"view probe class=%@ icon=%@", NSStringFromClass([self class]),
                      GIEngineBundleIDForIcon(GIIconForView(self)) ?: @"(nil)");
        }
    } @catch (NSException *exception) {
        GILogMain(@"view exception %@: %@", NSStringFromClass([self class]), exception.reason);
    }
}

static void GIHookLayoutClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { GILogMain(@"layout hook: class missing %@", className); return; }
    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!method) { GILogMain(@"layout hook: %@ has no layoutSubviews", className); return; }
    IMP original = method_getImplementation(method);
    gLayoutOriginals[className] = [NSValue valueWithPointer:original];
    if (!class_addMethod(cls, @selector(layoutSubviews), (IMP)HLayoutSubviews, method_getTypeEncoding(method)))
        method_setImplementation(method, (IMP)HLayoutSubviews);
    GILogMain(@"layout hook ok: %@", className);
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

#pragma mark - active refresh

static void GIRefreshView(id view) {
    if (!view) return;
    id icon = GIIconForView(view);
    NSString *bundleID = GIEngineBundleIDForIcon(icon);
    BOOL hasTheme = bundleID ? GIEngineImageForBundleID(bundleID) != nil : NO;
    if (hasTheme) {
        id imageView = GICall0(view, @"_iconImageView");
        for (id object in @[view, imageView ?: [NSNull null]]) {
            if (object == [NSNull null]) continue;
            GIVoid0(object, @"purgeCachedImages");
            GIVoid0(object, @"reloadIconImage");
        }
    }
    if ([view isKindOfClass:[UIView class]]) GIApplyImageRecursively(view, 0);
}

static id GIIconController(void) {
    return GICall0((id)NSClassFromString(@"SBIconController"), @"sharedInstance");
}

static void GIRefreshFolderCache(id controller, id model) {
    @try {
        id root = GICall0(controller, @"_rootFolderController");
        if (!root) root = GICall0(controller, @"rootFolderController");
        id folderModel = GICall0(root, @"iconModel");
        if (!folderModel) folderModel = model;
        Class cacheClass = NSClassFromString(@"SBFolderIconImageCache");
        if (!cacheClass || !folderModel) return;
        id oldCache = GICall0(folderModel, @"folderIconImageCache");
        id layout = GICall0(oldCache, @"listLayout");
        if (!oldCache || !layout) return;
        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cacheClass, @selector(alloc));
        id newCache = nil;
        SEL initSelector = NSSelectorFromString(@"initWithListLayout:");
        if ([allocated respondsToSelector:initSelector])
            newCache = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSelector, layout);
        if (!newCache) return;
        GIVoid1(folderModel, @"setFolderIconImageCache:", newCache);
        GIVoid0(folderModel, @"iconViewFolderIconImageCacheDidChange");
        GIVoid0(root, @"iconViewFolderIconImageCacheDidChange");
        GILogMain(@"folder cache rebuilt");
    } @catch (NSException *exception) {
        GILogMain(@"folder cache exception: %@", exception.reason);
    }
}

static void GIRefreshAppLibrary(id controller) {
    @try {
        id library = GICall0(controller, @"libraryViewController");
        if (!library) library = GICall0(controller, @"overlayLibraryViewController");
        if (!library) return;
        id pod = GICall0(library, @"podFolderViewController");
        NSArray *targets = pod ? @[library, pod] : @[library];
        void (^refreshBlock)(id) = ^(id view) { GIRefreshView(view); };
        for (id target in targets) {
            GIVoid0(target, @"_rebuildIconCache");
            GIVoid0(target, @"_reloadAppIcons");
            GIVoid0(target, @"reloadData");
            GIVoid1(target, @"enumerateDisplayedIconViewsUsingBlock:", refreshBlock);
            GIVoid0(target, @"setNeedsLayout");
            GIVoid0(target, @"layoutIfNeeded");
        }
        GILogMain(@"app library refreshed");
    } @catch (NSException *exception) {
        GILogMain(@"app library exception: %@", exception.reason);
    }
}

static void GIRefreshAllIconSurfaces(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id controller = GIIconController();
            if (!controller) { GILogMain(@"refresh: SBIconController unavailable"); return; }
            id model = GICall0(controller, @"model");
            if (!model) model = GICall0(controller, @"iconModel");
            NSArray *leafIcons = GICall0(model, @"leafIcons");
            id viewMap = GICall0(controller, @"homescreenIconViewMap");
            NSUInteger iconCount = 0, viewCount = 0;
            for (id icon in leafIcons ?: @[]) {
                iconCount++;
                GIVoid0(icon, @"purgeCachedImages");
                GIVoid0(icon, @"reloadIconImage");
                id view = GICall1(viewMap, @"iconViewForIcon:", icon);
                if (view) { viewCount++; GIRefreshView(view); }
            }
            GIRefreshFolderCache(controller, model);
            GIRefreshAppLibrary(controller);
            id floatingDock = GICall0(controller, @"floatingDockViewController");
            GIVoid0(floatingDock, @"_rebuildIconListViewAndViewMap");
            GILogMain(@"refresh complete icons=%lu views=%lu", (unsigned long)iconCount, (unsigned long)viewCount);
        } @catch (NSException *exception) {
            GILogMain(@"refresh exception: %@", exception.reason);
        }
    });
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
    if (gEngineEnabled) {
        GIIconEngineInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GIRefreshAllIconSurfaces(); });
    }
}

void GIIconEngineInstall(void) {
    gEngineEnabled = GIEngineUserEnabled() && GIEngineHasIcons();
    GILogMain(@"engine install enabled=%d", gEngineEnabled);
    if (!gEngineEnabled) return;
    GIIconEngineInstallHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GIRefreshAllIconSurfaces(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.00 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ GIRefreshAllIconSurfaces(); });
}
