#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <stdlib.h>

static const void *kGlassOverlayKey = &kGlassOverlayKey;
static const void *kGlassImageKey = &kGlassImageKey;
static const void *kGlassFactorKey = &kGlassFactorKey;

static IMP gOriginalLayoutSubviews = NULL;
static BOOL gEnabled = YES;
static CGFloat gIntensity = 0.68;
static BOOL gHookInstalled = NO;
static BOOL gInstalling = NO;
static BOOL gDisabled = NO;
static NSUInteger gInstallAttempts = 0;

static BOOL GIIsDisabled(void) { return gDisabled; }

static void GIReadDisabledState(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    gDisabled = [fm fileExistsAtPath:@"/var/mobile/Library/local.glassicons.disabled"] ||
                [fm fileExistsAtPath:@"/var/mobile/Library/Preferences/com.soren.glassicons.disabled"];
}

static void GIReadPreferences(void) {
    CFPropertyListRef enabled = CFPreferencesCopyAppValue(CFSTR("Enabled"), CFSTR("com.soren.glassicons"));
    if (enabled) {
        gEnabled = CFGetTypeID(enabled) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)enabled) : YES;
        CFRelease(enabled);
    }
    CFPropertyListRef intensity = CFPreferencesCopyAppValue(CFSTR("Intensity"), CFSTR("com.soren.glassicons"));
    if (intensity) {
        if (CFGetTypeID(intensity) == CFNumberGetTypeID()) {
            double value = 0.68;
            CFNumberGetValue((CFNumberRef)intensity, kCFNumberDoubleType, &value);
            gIntensity = (CGFloat)fmax(0.0, fmin(1.0, value));
        }
        CFRelease(intensity);
    }
}

// Folder icons, icons inside an open folder, and tiny previews are left untouched.
static BOOL GIShouldSkipView(UIView *view) {
    if (!view) return YES;
    CGFloat side = MIN(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
    if (side < 40.0) return YES;

    @try {
        id icon = [view valueForKey:@"icon"];
        if (icon) {
            NSString *name = NSStringFromClass([icon class]);
            if ([name rangeOfString:@"Folder"].location != NSNotFound) return YES;
        }
    } @catch (__unused NSException *e) {}

    UIView *parent = view.superview;
    for (int depth = 0; depth < 6 && parent; depth++, parent = parent.superview) {
        NSString *name = NSStringFromClass([parent class]);
        if ([name rangeOfString:@"Folder"].location != NSNotFound) return YES;
    }
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

// 1.0 = bright icon (full effect), ~0.35 = near-black icon (subdued effect).
static CGFloat GIStrengthForView(UIView *view) {
    CGImageRef image = GIFindIconImage(view);
    NSValue *cachedPointer = objc_getAssociatedObject(view, kGlassImageKey);
    NSNumber *cachedFactor = objc_getAssociatedObject(view, kGlassFactorKey);
    if (cachedPointer && cachedFactor && cachedPointer.pointerValue == (void *)image) {
        return (CGFloat)cachedFactor.doubleValue;
    }
    CGFloat luminance = image ? GIAverageLuminance(image) : 0.5;
    CGFloat factor = 0.30 + 0.70 * luminance;
    factor = fmax(0.30, fmin(1.0, factor));
    objc_setAssociatedObject(view, kGlassImageKey, [NSValue valueWithPointer:(void *)image], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kGlassFactorKey, @(factor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return factor;
}

static CALayer *GICreateOverlay(UIView *view) {
    CALayer *container = [CALayer layer];
    container.name = @"com.soren.glassicons.overlay";
    container.masksToBounds = NO;
    container.contentsScale = UIScreen.mainScreen.scale;

    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.name = @"com.soren.glassicons.sheen";
    sheen.startPoint = CGPointMake(0.5, 0.0);
    sheen.endPoint = CGPointMake(0.5, 1.0);
    sheen.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.22 * gIntensity].CGColor,
                     (id)[UIColor colorWithWhite:1.0 alpha:0.045 * gIntensity].CGColor,
                     (id)[UIColor colorWithRed:0.62 green:0.88 blue:1.0 alpha:0.08 * gIntensity].CGColor];
    sheen.locations = @[@0.0, @0.34, @1.0];
    CAShapeLayer *sheenMask = [CAShapeLayer layer];
    sheenMask.fillColor = UIColor.whiteColor.CGColor;
    sheen.mask = sheenMask;
    [container addSublayer:sheen];

    CAShapeLayer *rim = [CAShapeLayer layer];
    rim.name = @"com.soren.glassicons.rim";
    rim.fillColor = UIColor.clearColor.CGColor;
    rim.strokeColor = [UIColor colorWithWhite:1.0 alpha:1.0].CGColor;
    rim.lineWidth = 1.0;

    CAGradientLayer *rimMask = [CAGradientLayer layer];
    rimMask.name = @"com.soren.glassicons.rimmask";
    rimMask.startPoint = CGPointMake(0.5, 0.0);
    rimMask.endPoint = CGPointMake(0.5, 1.0);
    rimMask.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:1.0].CGColor,
                       (id)[UIColor colorWithWhite:1.0 alpha:0.55].CGColor,
                       (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
                       (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
    rimMask.locations = @[@0.0, @0.22, @0.62, @1.0];
    rim.mask = rimMask;
    [container addSublayer:rim];

    objc_setAssociatedObject(view, kGlassOverlayKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view.layer addSublayer:container];
    return container;
}

static void GIUpdateOverlay(UIView *view) {
    if (!view || !view.layer || CGRectIsEmpty(view.bounds)) return;
    CALayer *overlay = objc_getAssociatedObject(view, kGlassOverlayKey);
    if (!gEnabled || GIIsDisabled() || gIntensity <= 0.001 || GIShouldSkipView(view)) {
        [overlay removeFromSuperlayer];
        objc_setAssociatedObject(view, kGlassOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!overlay) overlay = GICreateOverlay(view);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect bounds = view.bounds;
    CGFloat radius = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)) * 0.225;
    CGFloat factor = GIStrengthForView(view);

    overlay.frame = bounds;
    overlay.cornerRadius = radius;

    CAGradientLayer *sheen = (CAGradientLayer *)overlay.sublayers.firstObject;
    sheen.frame = bounds;
    sheen.opacity = (float)(0.35 + 0.55 * factor);
    ((CAShapeLayer *)sheen.mask).path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;

    CAShapeLayer *rim = (CAShapeLayer *)overlay.sublayers.lastObject;
    rim.frame = bounds;
    CGRect strokeRect = CGRectInset(bounds, 0.6, 0.6);
    rim.path = [UIBezierPath bezierPathWithRoundedRect:strokeRect cornerRadius:MAX(0.0, radius - 0.6)].CGPath;
    rim.lineWidth = MAX(0.7, MIN(1.2, CGRectGetWidth(bounds) * 0.0075));
    rim.opacity = (float)(gIntensity * (0.26 + 0.40 * factor));

    CAGradientLayer *rimMask = (CAGradientLayer *)rim.mask;
    rimMask.frame = bounds;

    overlay.hidden = NO;
    [CATransaction commit];
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
