#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Glass badges (SBIconBadgeView / SBIconParallaxBadgeView).
//
// Deliberately transparent: no plate, no blur, no backdrop capture. The badge
// shows only the glass "shape" — a lens rim that is bright on top and fades
// downward, a specular highlight near the top, and a faint dark refraction
// band along the bottom edge. The system's solid red plate is removed and the
// digits are forced white with a soft shadow.

static CFStringRef const kBadgeDomain = CFSTR("com.soren.glassicons");

static const void *kBadgeOverlayKey = &kBadgeOverlayKey;
static const void *kBadgeSignatureKey = &kBadgeSignatureKey;

static IMP gBadgeOriginalLayout = NULL;
static IMP gParallaxOriginalLayout = NULL;
static BOOL gBadgeEnabled = YES;
static CGFloat gBadgeIntensity = 0.90;
static CGFloat gBadgeSheen = 0.75;
static CGFloat gBadgeRim = 0.80;
static CGFloat gBadgeTint = 0.02;
static CGFloat gBadgeRefract = 1.0;

static CGFloat GIBadgeNumber(CFStringRef key, CGFloat fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kBadgeDomain);
    CGFloat result = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = fallback;
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
            result = (CGFloat)number;
        }
        CFRelease(value);
    }
    return result;
}

static void GIBadgeReadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("BadgeGlass"), kBadgeDomain);
    if (value) {
        gBadgeEnabled = CFGetTypeID(value) == CFBooleanGetTypeID()
                            ? CFBooleanGetValue((CFBooleanRef)value) : YES;
        CFRelease(value);
    }
    gBadgeIntensity = fmax(0.0, fmin(5.0, GIBadgeNumber(CFSTR("BadgeIntensity"), 0.90)));
    gBadgeSheen = fmax(0.0, fmin(5.0, GIBadgeNumber(CFSTR("BadgeSheen"), 0.75)));
    gBadgeRim = fmax(0.0, fmin(5.0, GIBadgeNumber(CFSTR("BadgeRim"), 0.80)));
    gBadgeTint = fmax(0.0, fmin(1.0, GIBadgeNumber(CFSTR("BadgeTint"), 0.02)));
    gBadgeRefract = fmax(0.0, fmin(5.0, GIBadgeNumber(CFSTR("BadgeRefract"), 1.0)));
}

static NSString *GIBadgeSignature(CGSize size, CGFloat scale) {
    NSInteger i = (NSInteger)lroundf((float)(gBadgeIntensity * 20.0));
    NSInteger s = (NSInteger)lroundf((float)(gBadgeSheen * 20.0));
    NSInteger r = (NSInteger)lroundf((float)(gBadgeRim * 20.0));
    NSInteger t = (NSInteger)lroundf((float)(gBadgeTint * 100.0));
    NSInteger rf = (NSInteger)lroundf((float)(gBadgeRefract * 20.0));
    return [NSString stringWithFormat:@"%ld.%ld.%ld.%ld.%ld|%.0fx%.0f@%.0f",
            (long)i, (long)s, (long)r, (long)t, (long)rf,
            size.width, size.height, scale];
}

// Remove the opaque system plate, keep the digits, force them white.
static void GIBadgeSuppressRedPlate(UIView *view) {
    if (!view) return;

    view.backgroundColor = UIColor.clearColor;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;

    // The system red plate may be baked into layer.contents (CGImage).
    // Clear it so the badge shows only our glass overlay.
    if (view.layer.contents) {
        view.layer.contents = nil;
    }
    // Also clear contents of any cached sublayers.
    for (CALayer *sub in view.layer.sublayers) {
        if (sub && sub.contents) {
            sub.contents = nil;
        }
    }

    for (UIView *sub in view.subviews) {
        NSString *name = NSStringFromClass([sub class]);
        BOOL isText = [sub isKindOfClass:UILabel.class] ||
                      [name rangeOfString:@"Label"].location != NSNotFound ||
                      [name rangeOfString:@"Text"].location != NSNotFound;
        if (isText) {
            if ([sub respondsToSelector:@selector(setTextColor:)]) {
                [(id)sub setTextColor:UIColor.whiteColor];
            }
            sub.layer.shadowColor = UIColor.blackColor.CGColor;
            sub.layer.shadowOpacity = 0.42f;
            sub.layer.shadowRadius = 1.4f;
            sub.layer.shadowOffset = CGSizeMake(0.0, 0.5);
            continue;
        }

        if ([sub isKindOfClass:UIImageView.class]) {
            ((UIImageView *)sub).image = nil;
        }
        sub.backgroundColor = UIColor.clearColor;
        sub.layer.backgroundColor = UIColor.clearColor.CGColor;
        if ([sub isKindOfClass:UIVisualEffectView.class]) sub.hidden = YES;
    }
}

static UIImage *GIBadgeTile(CGSize size, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    CGFloat master = MIN((CGFloat)2.0, gBadgeIntensity);
    CGFloat rim = MIN((CGFloat)1.0, gBadgeRim * master);

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = CGRectGetHeight(rect) * 0.5;
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];

        // Optional whisker of tint. Default 0.02 — effectively transparent.
        if (gBadgeTint > 0.001) {
            CGContextSaveGState(c);
            [shape addClip];
            CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:gBadgeTint].CGColor);
            CGContextFillRect(c, rect);
            CGContextRestoreGState(c);
        }

        // Bottom refraction band: the dark edge that gives glass its thickness.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef spaceDark = CGColorSpaceCreateDeviceRGB();
        CGFloat refractAlpha = MIN((CGFloat)0.55, 0.18 * master * gBadgeRefract);
        CGFloat compsDark[] = {0.0, 0.0, 0.0, 0.0,
                               0.0, 0.0, 0.0, refractAlpha};
        CGFloat locsDark[] = {0.45, 1.0};
        CGGradientRef gradDark = CGGradientCreateWithColorComponents(spaceDark, compsDark, locsDark, 2);
        CGContextDrawLinearGradient(c, gradDark, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gradDark);
        CGColorSpaceRelease(spaceDark);
        CGContextRestoreGState(c);

        // Lens rim: bright top, fading down, faint cool bottom (dispersion hint).
        CGFloat lineWidth = MAX(0.6, MIN(1.0, size.height * 0.030));
        CGRect strokeRect = CGRectInset(rect, lineWidth * 0.5, lineWidth * 0.5);
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:strokeRect
                                                            cornerRadius:MAX(0.0, radius - lineWidth * 0.5)];
        CGContextSaveGState(c);
        CGContextAddPath(c, stroke.CGPath);
        CGContextSetLineWidth(c, lineWidth);
        CGContextReplacePathWithStrokedPath(c);
        CGContextClip(c);
        CGColorSpaceRef space2 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps2[] = {1.00, 1.00, 1.00, 1.00 * rim,
                            1.00, 1.00, 1.00, 0.62 * rim,
                            0.86, 0.94, 1.00, 0.32 * rim};
        CGFloat locs2[] = {0.0, 0.55, 1.0};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 3);
        CGContextDrawLinearGradient(c, grad2, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(space2);
        CGContextRestoreGState(c);

    }];
}

static void GIBadgeUpdate(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return;

    CALayer *overlay = objc_getAssociatedObject(view, kBadgeOverlayKey);
    if (!gBadgeEnabled || gBadgeIntensity <= 0.001) {
        if (overlay) [overlay removeFromSuperlayer];
        objc_setAssociatedObject(view, kBadgeOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    GIBadgeSuppressRedPlate(view);

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    NSString *signature = GIBadgeSignature(view.bounds.size, scale);
    NSString *last = objc_getAssociatedObject(view, kBadgeSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, view.bounds) &&
        [last isEqualToString:signature]) {
        overlay.hidden = NO;
        return;
    }

    UIImage *tile = GIBadgeTile(view.bounds.size, scale);
    if (!tile) return;

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = @"com.soren.glassicons.badgeglass";
        overlay.masksToBounds = NO;
        overlay.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(view, kBadgeOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view.layer insertSublayer:overlay atIndex:0];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.contents = (__bridge id)tile.CGImage;
    overlay.contentsScale = scale;
    overlay.frame = view.bounds;
    overlay.hidden = NO;
    [CATransaction commit];

    objc_setAssociatedObject(view, kBadgeSignatureKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void GIBadgeHookedLayout(UIView *self, SEL _cmd) {
    if (gBadgeOriginalLayout) ((void (*)(id, SEL))gBadgeOriginalLayout)(self, _cmd);
    @autoreleasepool {
        @try { GIBadgeUpdate(self); } @catch (__unused NSException *e) {}
    }
}

static void GIParallaxHookedLayout(UIView *self, SEL _cmd) {
    if (gParallaxOriginalLayout) ((void (*)(id, SEL))gParallaxOriginalLayout)(self, _cmd);
    @autoreleasepool {
        @try { GIBadgeUpdate(self); } @catch (__unused NSException *e) {}
    }
}

static BOOL gBadgeHookInstalled = NO;
static BOOL gParallaxHookInstalled = NO;

static void GIBadgeInstall(void) {
    Class badgeClass = objc_getClass("SBIconBadgeView");
    Class parallaxClass = objc_getClass("SBIconParallaxBadgeView");

    if (badgeClass && !gBadgeHookInstalled) {
        SEL selector = @selector(layoutSubviews);
        Method method = class_getInstanceMethod(badgeClass, selector);
        IMP replacement = (IMP)GIBadgeHookedLayout;
        if (method && method_getImplementation(method) != replacement) {
            gBadgeOriginalLayout = method_getImplementation(method);
            method_setImplementation(method, replacement);
            gBadgeHookInstalled = YES;
        }
    }
    if (parallaxClass && !gParallaxHookInstalled) {
        SEL selector = @selector(layoutSubviews);
        Method method = class_getInstanceMethod(parallaxClass, selector);
        IMP replacement = (IMP)GIParallaxHookedLayout;
        if (method && method_getImplementation(method) != replacement) {
            gParallaxOriginalLayout = method_getImplementation(method);
            method_setImplementation(method, replacement);
            gParallaxHookInstalled = YES;
        }
    }
}

static void GIBadgePrefsChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ GIBadgeReadPrefs(); });
}

__attribute__((constructor)) static void GIBadgeInit(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    GIBadgeReadPrefs();
    GIBadgeInstall();
    for (int i = 1; i <= 20 && !(gBadgeHookInstalled && gParallaxHookInstalled); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GIBadgeInstall(); });
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                   (CFNotificationCallback)GIBadgePrefsChanged,
                                   CFSTR("com.soren.glassicons.changed"), NULL,
                                   CFNotificationSuspensionBehaviorDeliverImmediately);
}
