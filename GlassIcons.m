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

static BOOL GIIsDisabled(void) { return gDisabled; }

static void GIReadDisabledState(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    gDisabled = [fm fileExistsAtPath:@"/var/mobile/Library/local.glassicons.disabled"] ||
                [fm fileExistsAtPath:@"/var/mobile/Library/Preferences/com.soren.glassicons.disabled"];
}

static CGFloat GIClampedDouble(CFStringRef key, CGFloat fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kGlassDomain);
    CGFloat result = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = fallback;
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
            result = (CGFloat)fmax(0.0, fmin(1.0, number));
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
    gIntensity = GIClampedDouble(CFSTR("Intensity"), 0.90);
    gRimWeight = GIClampedDouble(CFSTR("Rim"), 0.75);
    gSheenWeight = GIClampedDouble(CFSTR("Sheen"), 0.70);
}

// Cheap, throttled refresh so slider changes show up without a respring.
static void GIReloadPreferencesIfNeeded(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastPrefsRead < 2.5) return;
    gLastPrefsRead = now;
    GIReadPreferences();
}

// Skip only real folder icons and tiny previews. The home screen itself lives in
// SBRootFolderView, so no superview-based "folder" matching is allowed here.
static BOOL GIShouldSkipView(UIView *view) {
    if (!view) return YES;
    CGFloat side = MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
    if (side < 40.0) return YES;

    id icon = nil;
    @try { icon = [view valueForKey:@"icon"]; } @catch (__unused NSException *e) { icon = nil; }

    NSValue *cachedIcon = objc_getAssociatedObject(view, kGlassSkipIconKey);
    NSNumber *cachedFlag = objc_getAssociatedObject(view, kGlassSkipFlagKey);
    if (cachedIcon && cachedFlag && cachedIcon.pointerValue == (__bridge void *)icon) {
        return cachedFlag.boolValue;
    }

    BOOL skip = NO;
    if (icon) {
        NSString *name = NSStringFromClass([icon class]);
        if ([name rangeOfString:@"FolderIcon"].location != NSNotFound) skip = YES;
    }
    objc_setAssociatedObject(view, kGlassSkipIconKey, [NSValue valueWithPointer:(__bridge void *)icon], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kGlassSkipFlagKey, @(skip), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return skip;
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

static UIImage *GITileImage(CGSize size, CGFloat scale, CGFloat factor, NSString *signature) {
    if (!gTileCache) gTileCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%.1fx%.1f@%.0f", signature, size.width, size.height, scale];
    UIImage *cached = gTileCache[key];
    if (cached) return cached;
    if (gTileCache.count > 32) [gTileCache removeAllObjects];

    CGFloat darkScale = 0.30 + 0.70 * factor;
    CGFloat sheenTop = 0.34 * gSheenWeight * darkScale * gIntensity;
    CGFloat sheenMid = 0.085 * gSheenWeight * darkScale * gIntensity;
    CGFloat sheenBottom = 0.12 * gSheenWeight * darkScale * gIntensity;
    CGFloat rimTop = 1.00 * gRimWeight * darkScale * gIntensity;
    CGFloat rimMid = 0.55 * gRimWeight * darkScale * gIntensity;
    CGFloat rimBottom = 0.12 * gRimWeight * darkScale * gIntensity;

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
            CGFloat locs[] = {0.0, 0.34, 1.0};
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
            CGFloat locs2[] = {0.0, 0.58, 1.0};
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

static void GIUpdateOverlay(UIView *view) {
    if (!view || !view.layer || CGRectIsEmpty(view.bounds)) return;

    GIReloadPreferencesIfNeeded();

    CALayer *overlay = objc_getAssociatedObject(view, kGlassOverlayKey);
    if (!gEnabled || GIIsDisabled() || gIntensity <= 0.001 || GIShouldSkipView(view)) {
        if (overlay) {
            [overlay removeFromSuperlayer];
            objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kGlassSignatureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    CGRect bounds = view.bounds;
    CGFloat factor = GIStrengthForView(view);
    NSString *signature = GISettingsSignature(factor);
    NSString *lastSignature = objc_getAssociatedObject(view, kGlassSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, bounds) &&
        [lastSignature isEqualToString:signature]) {
        return;  // nothing changed: no layout work at all
    }

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    UIImage *tile = GITileImage(bounds.size, scale, factor, signature);
    if (!tile) return;

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = @"com.soren.glassicons.overlay";
        overlay.masksToBounds = NO;
        overlay.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(view, kGlassOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view.layer addSublayer:overlay];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.contents = (__bridge id)tile.CGImage;
    overlay.contentsScale = scale;
    overlay.frame = bounds;
    [CATransaction commit];

    objc_setAssociatedObject(view, kGlassSignatureKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void GIHookedLayoutSubviews(UIView *self, SEL _cmd) {
    if (gOriginalLayoutSubviews) ((void (*)(id, SEL))gOriginalLayoutSubviews)(self, _cmd);
    @autoreleasepool {
        @try { GIUpdateOverlay(self); } @catch (__unused NSException *e) {}
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

__attribute__((constructor)) static void GIInitialize(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    GIReadPreferences();
    GIReadDisabledState();
    GIInstallHook();
}
