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

#pragma mark - install / reload

static dispatch_once_t gEngineOnce;

static void GIIconEngineInstallHooks(void) {
    dispatch_once(&gEngineOnce, ^{
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(imageForIcon:), (IMP)HImageForIcon, &oImageForIcon);
        GIHook(NSClassFromString(@"SBHIconImageCache"), @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCachedImageForIcon);
        GIHook(NSClassFromString(@"SBHIconImageCache"), NSSelectorFromString(@"realImageForIcon:"), (IMP)HRealImageForIcon, &oRealImageForIcon);
        GIHook(NSClassFromString(@"SBApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)HGenerateIcon, &oGenerateIcon);
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
    if (!gEngineEnabled) return;
    GIIconEngineInstallHooks();
}
