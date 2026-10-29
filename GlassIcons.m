#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static const void *kGlassOverlayKey = &kGlassOverlayKey;
static const void *kGlassImageKey = &kGlassImageKey;
static const void *kGlassFactorKey = &kGlassFactorKey;
static const void *kGlassSkipIconKey = &kGlassSkipIconKey;
static const void *kGlassSkipFlagKey = &kGlassSkipFlagKey;
static const void *kGlassSignatureKey = &kGlassSignatureKey;

static CFStringRef const kGlassDomain = CFSTR("com.soren.glassicons");

static IMP gOriginalLayoutSubviews = NULL;
static BOOL gEnabled = YES;
static CGFloat gIntensity = 0.90;
static CGFloat gRimWeight = 0.75;
static CGFloat gSheenWeight = 0.70;
static BOOL gHookInstalled = NO;
static BOOL gInstalling = NO;
static BOOL gDisabled = NO;
static NSUInteger gInstallAttempts = 0;
static CFTimeInterval gLastPrefsRead = 0.0;
static NSMutableDictionary<NSString *, UIImage *> *gTileCache = nil;
static NSHashTable<UIView *> *gTrackedViews = nil;
static BOOL gIconPackEnabled = NO;
static NSMutableDictionary<NSString *, UIImage *> *gIconPackCache = nil;
static const void *kIconPackLayerKey = &kIconPackLayerKey;
static const void *kIconPackSignatureKey = &kIconPackSignatureKey;
static NSString * const kIconPackDir = @"/var/mobile/Library/GlassIcons/Icons";

static void GILogMain(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSString *path = @"/var/mobile/Library/GlassIcons.log";
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *e) {}
}

static BOOL GIIsDisabled(void) { return gDisabled; }

static void GIReadDisabledState(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    gDisabled = [fm fileExistsAtPath:@"/var/mobile/Library/local.glassicons.disabled"] ||
                [fm fileExistsAtPath:@"/var/mobile/Library/Preferences/com.soren.glassicons.disabled"];
}

static CGFloat GIClampedDouble(CFStringRef key, CGFloat fallback, CGFloat ceiling) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kGlassDomain);
    CGFloat result = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = fallback;
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
            result = (CGFloat)fmax(0.0, fmin(ceiling, number));
        }
        CFRelease(value);
    }
    return result;
}

static void GIReadPreferences(void) {
    CFPropertyListRef enabled = CFPreferencesCopyAppValue(CFSTR("Enabled"), kGlassDomain);
    if (enabled) {
        gEnabled = CFGetTypeID(enabled) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)enabled) : YES;
        CFRelease(enabled);
    }
    gIntensity = GIClampedDouble(CFSTR("Intensity"), 0.90, 5.0);
    gRimWeight = GIClampedDouble(CFSTR("Rim"), 0.75, 1.0);
    gSheenWeight = GIClampedDouble(CFSTR("Sheen"), 0.70, 1.0);
}

// Cheap, throttled refresh so slider changes show up without a respring.
static void GIReloadPreferencesIfNeeded(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastPrefsRead < 2.5) return;
    gLastPrefsRead = now;
    GIReadPreferences();
}

// Final behavior (user's decision after 0.8.x–1.1.0 iterations): folders are
// excluded entirely. Only FolderIcon class check — never superview traversal
// (SBFolder prefix matching kills the whole home screen, see 0.9.0).
static BOOL GIShouldSkipView(UIView *view) {
    if (!view) return YES;
    CGFloat side = MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
    if (side < 40.0) return YES;

    @try {
        id icon = [view valueForKey:@"icon"];
        if (icon && [NSStringFromClass([icon class]) rangeOfString:@"FolderIcon"].location != NSNotFound) {
            return YES;
        }
    } @catch (__unused NSException *e) {}

    return NO;
}

static CGImageRef GIFindIconImage(UIView *view) {
    id contents = view.layer.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        return (__bridge CGImageRef)contents;
    }
    for (CALayer *sublayer in view.layer.sublayers) {
        id sub = sublayer.contents;
        if (sub && CFGetTypeID((__bridge CFTypeRef)sub) == CGImageGetTypeID()) {
            return (__bridge CGImageRef)sub;
        }
    }
    return NULL;
}

static CGFloat GIAverageLuminance(CGImageRef image) {
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return 0.5;
    CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return 0.5;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), image);
    CGContextRelease(ctx);
    CGFloat lum = (0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]) / 255.0;
    return fmax(0.0, fmin(1.0, lum));
}

// 1.0 = bright icon (full effect), 0.30 = near-black icon (subdued effect).
static CGFloat GIStrengthForView(UIView *view) {
    CGImageRef image = GIFindIconImage(view);
    NSValue *cachedPointer = objc_getAssociatedObject(view, kGlassImageKey);
    NSNumber *cachedFactor = objc_getAssociatedObject(view, kGlassFactorKey);
    if (cachedPointer && cachedFactor && cachedPointer.pointerValue == (void *)image) {
        return (CGFloat)cachedFactor.doubleValue;
    }
    CGFloat luminance = image ? GIAverageLuminance(image) : 0.5;
    CGFloat factor = fmax(0.30, fmin(1.0, 0.30 + 0.70 * luminance));
    objc_setAssociatedObject(view, kGlassImageKey, [NSValue valueWithPointer:(void *)image], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kGlassFactorKey, @(factor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return factor;
}

static NSString *GISettingsSignature(CGFloat factor) {
    NSInteger factorBucket = (NSInteger)lroundf((float)(factor * 10.0));
    NSInteger intensityBucket = (NSInteger)lroundf((float)(gIntensity * 20.0));
    NSInteger rimBucket = (NSInteger)lroundf((float)(gRimWeight * 20.0));
    NSInteger sheenBucket = (NSInteger)lroundf((float)(gSheenWeight * 20.0));
    return [NSString stringWithFormat:@"%ld.%ld.%ld.%ld", (long)factorBucket, (long)intensityBucket,
                                      (long)rimBucket, (long)sheenBucket];
}

static UIImage *GITileImage(CGSize size, CGFloat scale, CGFloat factor, CGFloat intensity, NSString *signature) {
    if (!gTileCache) gTileCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%.1fx%.1f@%.0f|%d", signature, size.width, size.height, scale, (int)lroundf(intensity * 20.0)];
    UIImage *cached = gTileCache[key];
    if (cached) return cached;
    if (gTileCache.count > 48) [gTileCache removeAllObjects];

    CGFloat darkScale = 0.30 + 0.70 * factor;
    // Light icons need much less white-on-white; keep dark icons vivid.
    CGFloat lightDamp = factor > 0.8 ? 0.55 : 1.0;
    CGFloat sheenTop = 0.40 * gSheenWeight * darkScale * intensity * lightDamp;
    CGFloat sheenMid = 0.10 * gSheenWeight * darkScale * intensity * lightDamp;
    CGFloat sheenBottom = 0.06 * gSheenWeight * darkScale * intensity * lightDamp;
    // Rim is symmetric now: full ring visible top and bottom.
    CGFloat rimTop = 0.85 * gRimWeight * darkScale * intensity;
    CGFloat rimMid = 0.70 * gRimWeight * darkScale * intensity;
    CGFloat rimBottom = 0.85 * gRimWeight * darkScale * intensity;

    UIImage *image = nil;
    @try {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = scale;
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef c = ctx.CGContext;
            CGRect rect = CGRectMake(0, 0, size.width, size.height);
            CGFloat radius = MIN(size.width, size.height) * 0.225;
            UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];

            CGContextSaveGState(c);
            [shape addClip];
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGFloat comps[] = {1.0, 1.0, 1.0, sheenTop,
                               1.0, 1.0, 1.0, sheenMid,
                               0.62, 0.88, 1.0, sheenBottom};
            CGFloat locs[] = {0.0, 0.28, 1.0};
            CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 3);
            CGContextDrawLinearGradient(c, grad, CGPointMake(0.0, 0.0), CGPointMake(0.0, size.height), 0);
            CGGradientRelease(grad);
            CGColorSpaceRelease(space);
            CGContextRestoreGState(c);

            CGFloat lineWidth = MAX(0.9, MIN(1.6, size.width * 0.0095));
            CGRect strokeRect = CGRectInset(rect, lineWidth * 0.5, lineWidth * 0.5);
            UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:strokeRect
                                                                  cornerRadius:MAX(0.0, radius - lineWidth * 0.5)];

            CGContextSaveGState(c);
            CGContextAddPath(c, stroke.CGPath);
            CGContextSetLineWidth(c, lineWidth);
            CGContextReplacePathWithStrokedPath(c);
            CGContextClip(c);
            CGColorSpaceRef space2 = CGColorSpaceCreateDeviceRGB();
            CGFloat comps2[] = {1.0, 1.0, 1.0, rimTop,
                                1.0, 1.0, 1.0, rimMid,
                                1.0, 1.0, 1.0, rimBottom};
            CGFloat locs2[] = {0.0, 0.5, 1.0};
            CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 3);
            CGContextDrawLinearGradient(c, grad2, CGPointMake(0.0, 0.0), CGPointMake(0.0, size.height), 0);
            CGGradientRelease(grad2);
            CGColorSpaceRelease(space2);
            CGContextRestoreGState(c);
        }];
    } @catch (__unused NSException *e) {
        image = nil;
    }
    if (!image) return nil;
    gTileCache[key] = image;
    return image;
}


#pragma mark - Icon pack

// Bundle id of the icon rendered by this image view (best effort across versions).

static void GIIconPackEnsureDirectory(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kIconPackDir]) return;
    [fm createDirectoryAtPath:kIconPackDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *readme = [kIconPackDir stringByAppendingPathComponent:@"README.txt"];
    if (![fm fileExistsAtPath:readme]) {
        NSString *text = @"把 PNG 图标放在这个目录里，文件名用 App 的 Bundle ID，例如\n"
                          "  com.tencent.xin.png          微信\n"
                          "  com.alipay.iphoneclient.png  支付宝\n"
                          "支持 @2x / @3x 后缀（优先 @3x > @2x > png）。\n"
                          "放好后到 设置 → GlassIcons → 桌面图标包 → 重新加载图标包。\n";
        [text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

static UIImage *GIIconPackImageForBundleID(NSString *bundleID) {
    if (!bundleID.length) return nil;

    if (!gIconPackCache) {
        gIconPackCache = [NSMutableDictionary dictionary];
        GIIconPackEnsureDirectory();
    }

    UIImage *cached = gIconPackCache[bundleID];
    if (cached) return (cached == (id)NSNull.null) ? nil : cached;

    NSFileManager *fm = [NSFileManager defaultManager];
    UIImage *image = nil;
    NSString *usedPath = nil;
    for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png"]) {
        NSString *path = [kIconPackDir stringByAppendingPathComponent:
                          [bundleID stringByAppendingString:suffix]];
        if ([fm fileExistsAtPath:path]) {
            image = [UIImage imageWithContentsOfFile:path];
            if (image) { usedPath = path; break; }
        }
    }
    if (usedPath) {
        static NSMutableSet<NSString *> *loggedPaths;
        if (!loggedPaths) loggedPaths = [NSMutableSet set];
        if (![loggedPaths containsObject:bundleID]) {
            [loggedPaths addObject:bundleID];
            GILogMain(@"iconpack file %@ -> %@", bundleID, usedPath.lastPathComponent);
        }
    }
    gIconPackCache[bundleID] = image ?: (id)NSNull.null;
    return image;
}

static void GIUpdateOverlay(UIView *view);
static void GIInstallCacheHooks(void);

#pragma mark - Whole-tree scan

// Icons only reach us through -layoutSubviews, and a settled home screen does
// not lay out again — so most icons never get processed. Walk the window tree
// and apply to every icon image view we can find.
static void GIWalkForIcons(UIView *view, int depth, NSUInteger *touched) {
    if (!view || depth > 30) return;
    NSString *name = NSStringFromClass([view class]);
    if ([name containsString:@"SBIconImageView"] || [name hasPrefix:@"SBIconImage"]) {
        @try { GIUpdateOverlay(view); } @catch (__unused NSException *e) {}
        if (touched) (*touched)++;
    }
    for (UIView *child in view.subviews) {
        GIWalkForIcons(child, depth + 1, touched);
    }
}

static void GIScanAllIcons(void) {
    static CFTimeInterval lastScan = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastScan < 0.4) return;
    lastScan = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger touched = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            GIWalkForIcons(window, 0, &touched);
        }
#pragma clang diagnostic pop
        GILogMain(@"scan: visited %lu icon views", (unsigned long)touched);
    });
}

static void GIIconPackReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GIIconPackEnsureDirectory();
        NSUInteger count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kIconPackDir error:NULL].count;
        CFPropertyListRef enabledRef = CFPreferencesCopyAppValue(CFSTR("IconPackEnabled"), kGlassDomain);
        BOOL userEnabled = enabledRef ? (CFGetTypeID(enabledRef) == CFBooleanGetTypeID()
                                          ? CFBooleanGetValue((CFBooleanRef)enabledRef) : YES) : YES;
        if (enabledRef) CFRelease(enabledRef);
        gIconPackEnabled = userEnabled && count > 0;
        if (gIconPackEnabled) GIInstallCacheHooks();
        [gIconPackCache removeAllObjects];
        for (UIView *view in [gTrackedViews allObjects]) {
            objc_setAssociatedObject(view, kIconPackSignatureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { GIUpdateOverlay(view); } @catch (__unused NSException *e) {}
        }
        GIScanAllIcons();
    });
}

// Returns YES when a custom icon was applied (glass is skipped in that case).

static void GIUpdateOverlay(UIView *view) {
    if (!view || !view.layer || CGRectIsEmpty(view.bounds)) return;

    GIReloadPreferencesIfNeeded();

    CALayer *overlay = objc_getAssociatedObject(view, kGlassOverlayKey);
    if (!gEnabled || GIIsDisabled() || GIShouldSkipView(view)) {
        if (overlay) {
            [overlay removeFromSuperlayer];
            objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kGlassSignatureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    CGRect bounds = view.bounds;

    if (gIntensity <= 0.001) {
        if (overlay) {
            [overlay removeFromSuperlayer];
            objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    CGFloat factor = GIStrengthForView(view);
    CGFloat intensity = gIntensity;
    NSString *signature = GISettingsSignature(factor);
    NSString *lastSignature = objc_getAssociatedObject(view, kGlassSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, bounds) &&
        [lastSignature isEqualToString:signature]) {
        return;  // nothing changed: no layout work at all
    }

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    UIImage *tile = GITileImage(bounds.size, scale, factor, intensity, signature);
    if (!tile) return;

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = @"com.soren.glassicons.overlay";
        overlay.masksToBounds = NO;
        overlay.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(view, kGlassOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view.layer addSublayer:overlay];
        if (!gTrackedViews) gTrackedViews = [NSHashTable weakObjectsHashTable];
        [gTrackedViews addObject:view];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.contents = (__bridge id)tile.CGImage;
    overlay.contentsScale = scale;
    overlay.frame = bounds;
    overlay.hidden = NO;
    [CATransaction commit];

    objc_setAssociatedObject(view, kGlassSignatureKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void GIHookedLayoutSubviews(UIView *self, SEL _cmd) {
    if (gOriginalLayoutSubviews) ((void (*)(id, SEL))gOriginalLayoutSubviews)(self, _cmd);
    @autoreleasepool {
        @try { GIUpdateOverlay(self); } @catch (__unused NSException *e) {}
    }
}


#pragma mark - Icon image cache hooks (data layer, SnowBoard-style)

// SnowBoard's approach verbatim: hook the icon image caches. When SpringBoard
// asks for an icon image, hand back the themed PNG; otherwise pass through.
// SBHIconImageCache covers home screen icons; Spotlight and folders use the
// same class family. Also hooks SBIconImageCache/SBFolderIconImageCache when
// present for full coverage.

static IMP gOrigImageForIcon = NULL;
static IMP gOrigCachedImageForIcon = NULL;
static NSInteger gCacheServeCount = 0;

// SnowBoard hands the renderer a properly scaled square image; a raw
// 1024pt@1x PNG blows up the icon layout. Resize to the system icon size
// at 3x and stamp the scale so the cache gets a usable image.
static UIImage *GIThemedImageForBundleID(NSString *bundleID) {
    if (!bundleID.length) return nil;
    UIImage *raw = GIIconPackImageForBundleID(bundleID);
    if (!raw) return nil;

    CGFloat iconSize = 60.0;   // SBIconImageView default visible size
    CGFloat scale = 3.0;
    if (raw.size.width <= iconSize && raw.size.height <= iconSize && raw.scale == scale) {
        return raw;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(iconSize, iconSize) format:format];
    UIImage *out = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [raw drawInRect:CGRectMake(0, 0, iconSize, iconSize)];
    }];
    return out;
}

static UIImage *GICacheImageFromIcon(id icon) {
    if (!icon || !gIconPackEnabled) return nil;
    NSString *bundleID = nil;
    for (NSString *key in @[@"applicationBundleID", @"bundleIdentifier"]) {
        id value = nil;
        @try { value = [icon valueForKey:key]; } @catch (__unused NSException *e) { value = nil; }
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) {
            bundleID = (NSString *)value;
            break;
        }
    }
    if (!bundleID.length) return nil;
    return GIThemedImageForBundleID(bundleID);
}

static IMP gOrigImageForBundleID = NULL;
static BOOL gBundleIDHookInstalled = NO;

static void GIInstallCacheHooks(void) {
    SEL selImage = @selector(imageForIcon:);
    SEL selCached = @selector(cachedImageForIcon:);

    NSArray<NSString *> *cacheClasses = @[@"SBHIconImageCache", @"SBIconImageCache", @"SBFolderIconImageCache"];
    for (NSString *className in cacheClasses) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) { GILogMain(@"cache class %@ not found (skipped)", className); continue; }

        Method m = class_getInstanceMethod(cls, selImage);
        if (m) {
            IMP themed = imp_implementationWithBlock(^UIImage *(id self, id icon) {
                UIImage *themed = GICacheImageFromIcon(icon);
                if (themed) {
                    if (++gCacheServeCount <= 60) {
                        GILogMain(@"cache serve #%ld themed image", (long)gCacheServeCount);
                    }
                    return themed;
                }
                UIImage *(*orig)(id, SEL, id) = (UIImage *(*)(id, SEL, id))gOrigImageForIcon;
                return orig(self, selImage, icon);
            });
            method_setImplementation(m, themed);
            GILogMain(@"cache hook active: %@ imageForIcon:", className);
        }

        Method m2 = class_getInstanceMethod(cls, selCached);
        if (m2) {
            IMP themed2 = imp_implementationWithBlock(^UIImage *(id self, id icon) {
                UIImage *themed = GICacheImageFromIcon(icon);
                if (themed) return themed;
                UIImage *(*orig)(id, SEL, id) = (UIImage *(*)(id, SEL, id))gOrigCachedImageForIcon;
                return orig(self, selCached, icon);
            });
            method_setImplementation(m2, themed2);
            GILogMain(@"cache hook active: %@ cachedImageForIcon:", className);
        }
    }

    // Bundle-id keyed fetch (SnowBoard covers these too) — the most direct
    // mapping to our Icons/<bundleID>.png files. Classes may load after our
    // constructor: retry until both are hooked.
    if (gBundleIDHookInstalled) return;

    SEL selBundle = @selector(imageForBundleIdentifier:withScale:);
    NSArray<NSString *> *ownerClasses = @[@"SBApplicationIcon", @"SBApplication"];
    static BOOL hooked[2] = {NO, NO};
    for (NSUInteger i = 0; i < ownerClasses.count; i++) {
        if (hooked[i]) continue;
        Class cls = objc_getClass(ownerClasses[i].UTF8String);
        if (!cls) continue;
        Method m = class_getInstanceMethod(cls, selBundle);
        if (!m) continue;
        if (!gOrigImageForBundleID) gOrigImageForBundleID = method_getImplementation(m);
        IMP replacement = imp_implementationWithBlock(^UIImage *(id self, NSString *bundleID, CGFloat scale) {
            if (gIconPackEnabled) {
                UIImage *themedImage = GIThemedImageForBundleID(bundleID);
                if (themedImage) {
                    if (++gCacheServeCount <= 60) {
                        GILogMain(@"bundleid serve #%ld %@", (long)gCacheServeCount, bundleID);
                    }
                    return themedImage;
                }
            }
            UIImage *(*orig)(id, SEL, NSString *, CGFloat) = (UIImage *(*)(id, SEL, NSString *, CGFloat))gOrigImageForBundleID;
            SEL sel = @selector(imageForBundleIdentifier:withScale:);
            return orig(self, sel, bundleID, scale);
        });
        method_setImplementation(m, replacement);
        hooked[i] = YES;
        gBundleIDHookInstalled = hooked[0] && hooked[1];
        GILogMain(@"bundleid hook active: %@ imageForBundleIdentifier:withScale:", ownerClasses[i]);
    }

    if (!gBundleIDHookInstalled && ++gInstallAttempts < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GIInstallCacheHooks(); });
    }

    // One-shot probe: which candidate classes/selectors actually exist here?
    static BOOL probed = NO;
    if (!probed) {
        probed = YES;
        NSArray<NSString *> *candidates = @[@"SBApplicationIcon", @"SBApplication", @"SBIconModel",
                                            @"SBRootIconModel", @"SBIconManager", @"SBIconImageCache",
                                            @"SBHIconImageCache", @"SBIconView", @"SBIconImageView",
                                            @"SBIconImageCrossfadeView", @"SnowBoardImageCropper"];
        for (NSString *name in candidates) {
            Class cls = objc_getClass(name.UTF8String);
            GILogMain(@"probe %@ = %@", name, cls ? @"EXISTS" : @"missing");
            if (!cls) continue;
            NSArray<NSString *> *selectorNames = @[
                @"imageForBundleIdentifier:withScale:",
                @"imageForBundleIdentifier:withScale:withOverrides:",
                @"iconImageForIcon:image:",
                @"generateIconImage:",
                @"generateIconImageWithInfo:",
                @"imageForIcon:",
                @"cachedImageForIcon:",
            ];
            for (NSString *selectorName in selectorNames) {
                SEL sel = NSSelectorFromString(selectorName);
                if (class_getInstanceMethod(cls, sel)) {
                    GILogMain(@"probe %@ responds to %@", name, selectorName);
                }
            }
        }
    }
}

static void GIInstallHook(void) {
    if (gInstalling || gHookInstalled) return;
    gInstalling = YES;
    Class cls = objc_getClass("SBIconImageView");
    SEL selector = @selector(layoutSubviews);
    Method inherited = cls ? class_getInstanceMethod(cls, selector) : NULL;
    IMP replacement = (IMP)GIHookedLayoutSubviews;
    if (!inherited) {
        gInstalling = NO;
        if (++gInstallAttempts < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ GIInstallHook(); });
        }
        return;
    }
    gOriginalLayoutSubviews = method_getImplementation(inherited);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            own = methods[i];
            break;
        }
    }
    free(methods);

    if (own) {
        method_setImplementation(own, replacement);
        gHookInstalled = YES;
    } else {
        gHookInstalled = class_addMethod(cls, selector, replacement, method_getTypeEncoding(inherited));
    }
    gInstalling = NO;
}

static void GIIconPackChanged(CFNotificationCenterRef center __unused, void *observer __unused,
                              CFStringRef name __unused, const void *object __unused,
                              CFDictionaryRef userInfo __unused) {
    GIIconPackReload();
}

static void GIPreferencesChanged(CFNotificationCenterRef center __unused, void *observer __unused, CFStringRef name __unused,
                                 const void *object __unused, CFDictionaryRef userInfo __unused) {
    gLastPrefsRead = 0.0;  // force a fresh read on the next icon layout

    // Redraw every tracked icon right away so slider changes apply without respring.
    dispatch_async(dispatch_get_main_queue(), ^{
        GIReadPreferences();
        if (!gTileCache) gTileCache = [NSMutableDictionary dictionary];
        [gTileCache removeAllObjects];
        for (UIView *view in gTrackedViews) {
            if (!view) continue;
            objc_setAssociatedObject(view, kGlassSignatureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { GIUpdateOverlay(view); } @catch (__unused NSException *e) {}
        }
        GIScanAllIcons();
    });
}


__attribute__((constructor)) static void GIInitialize(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    GIIconPackEnsureDirectory();
    NSUInteger packCount = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kIconPackDir
                                    error:NULL].count;
    CFPropertyListRef enabledRef = CFPreferencesCopyAppValue(CFSTR("IconPackEnabled"), kGlassDomain);
    BOOL userEnabled = enabledRef ? (CFGetTypeID(enabledRef) == CFBooleanGetTypeID()
                                      ? CFBooleanGetValue((CFBooleanRef)enabledRef) : YES) : YES;
    if (enabledRef) CFRelease(enabledRef);
    gIconPackEnabled = userEnabled && packCount > 0;
    GILogMain(@"init: iconpack dir contents = %lu (userEnabled=%d, enabled=%d)",
              (unsigned long)packCount, userEnabled, gIconPackEnabled);
    if (gIconPackEnabled) {
        // Cache-layer hooks must install early, before the icon image caches fill.
        dispatch_async(dispatch_get_main_queue(), ^{ GIInstallCacheHooks(); });
    }
    GIReadPreferences();
    GIReadDisabledState();
    GIInstallHook();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                   (CFNotificationCallback)GIPreferencesChanged,
                                   CFSTR("com.soren.glassicons.changed"), NULL,
                                   CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                   (CFNotificationCallback)GIIconPackChanged,
                                   CFSTR("com.soren.glassicons.iconpack"), NULL,
                                   CFNotificationSuspensionBehaviorDeliverImmediately);

    // Home screen icons settle without further layout passes: scan a few times.
    for (NSNumber *delay in @[@2.0, @4.0, @7.0, @12.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GIScanAllIcons(); });
    }
}
