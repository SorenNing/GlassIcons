#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Badge glass for SBIconBadgeView / SBIconParallaxBadgeView (iOS 15-17).
// Draws a frosted translucent plate + thin white rim + top sheen over the
// badge's own background; the badge text stays visible underneath. The glass
// follows the badge's live bounds (pill for multi-digit, circle for "1").

static CFStringRef const kBadgeDomain = CFSTR("com.soren.glassicons");

static const void *kBadgeOverlayKey = &kBadgeOverlayKey;
static const void *kBadgeSignatureKey = &kBadgeSignatureKey;

static IMP gBadgeOriginalLayout = NULL;
static IMP gParallaxOriginalLayout = NULL;
static BOOL gBadgeEnabled = YES;
static CGFloat gBadgeIntensity = 0.85;
static CFTimeInterval gBadgeLastPrefs = 0.0;

static void GIBadgeReadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("BadgeGlass"), kBadgeDomain);
    if (value) {
        gBadgeEnabled = CFGetTypeID(value) == CFBooleanGetTypeID()
                            ? CFBooleanGetValue((CFBooleanRef)value)
                            : YES;
        CFRelease(value);
    }
    CFPropertyListRef rim = CFPreferencesCopyAppValue(CFSTR("Rim"), kBadgeDomain);
    if (rim) {
        if (CFGetTypeID(rim) == CFNumberGetTypeID()) {
            double number = 0.85;
            CFNumberGetValue(rim, kCFNumberDoubleType, &number);
            gBadgeIntensity = (CGFloat)fmax(0.0, fmin(5.0, number));
        }
        CFRelease(rim);
    }
}

static NSString *GIBadgeSignature(CGSize size, CGFloat scale, BOOL dark) {
    NSInteger bucket = (NSInteger)lroundf((float)(gBadgeIntensity * 20.0));
    return [NSString stringWithFormat:@"%ld|%d|%.0fx%.0f@%.0f",
            (long)bucket, dark ? 1 : 0, size.width, size.height, scale];
}

static UIImage *GIBadgeTile(CGSize size, CGFloat scale, BOOL dark) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    CGFloat intensity = MIN((CGFloat)1.5, gBadgeIntensity);  // badge plate caps at 1.5x
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = CGRectGetHeight(rect) * 0.5;

        // Frosted plate: dynamic white in light mode / soft dark in dark mode.
        CGFloat plateAlpha = 0.34 * intensity;
        CGFloat plateWhite = dark ? 0.10 : 1.0;
        CGContextSaveGState(c);
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [shape addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {plateWhite, plateWhite, plateWhite, plateAlpha,
                           plateWhite, plateWhite, plateWhite, plateAlpha * 0.75};
        CGFloat locs[] = {0.0, 1.0};
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(c);

        // Thin white rim, full circle.
        CGFloat lineWidth = MAX(0.8, MIN(1.4, size.height * 0.05));
        CGRect strokeRect = CGRectInset(rect, lineWidth * 0.5, lineWidth * 0.5);
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:strokeRect
                                                            cornerRadius:MAX(0.0, radius - lineWidth * 0.5)];
        CGContextSaveGState(c);
        CGContextAddPath(c, stroke.CGPath);
        CGContextSetLineWidth(c, lineWidth);
        CGContextReplacePathWithStrokedPath(c);
        CGContextClip(c);
        CGColorSpaceRef space2 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps2[] = {1.0, 1.0, 1.0, 0.95 * intensity,
                            1.0, 1.0, 1.0, 0.55 * intensity,
                            1.0, 1.0, 1.0, 0.95 * intensity};
        CGFloat locs2[] = {0.0, 0.5, 1.0};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 3);
        CGContextDrawLinearGradient(c, grad2, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(space2);
        CGContextRestoreGState(c);

        // Top sheen.
        CGContextSaveGState(c);
        UIBezierPath *sheenShape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [sheenShape addClip];
        CGColorSpaceRef space3 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps3[] = {1.0, 1.0, 1.0, 0.30 * intensity,
                            1.0, 1.0, 1.0, 0.0};
        CGFloat locs3[] = {0.0, 0.45};
        CGGradientRef grad3 = CGGradientCreateWithColorComponents(space3, comps3, locs3, 2);
        CGContextDrawLinearGradient(c, grad3, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad3);
        CGColorSpaceRelease(space3);
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

    BOOL dark = NO;
    @try {
        id trait = [view valueForKey:@"traitCollection"];
        if ([trait isKindOfClass:UITraitCollection.class]) {
            dark = [(UITraitCollection *)trait userInterfaceStyle] == UIUserInterfaceStyleDark;
        }
    } @catch (__unused NSException *e) {}

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    NSString *signature = GIBadgeSignature(view.bounds.size, scale, dark);
    NSString *last = objc_getAssociatedObject(view, kBadgeSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, view.bounds) &&
        [last isEqualToString:signature]) {
        overlay.hidden = NO;
        return;
    }

    UIImage *tile = GIBadgeTile(view.bounds.size, scale, dark);
    if (!tile) return;

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = @"com.soren.glassicons.badgeglass";
        overlay.masksToBounds = NO;
        overlay.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(view, kBadgeOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Insert ABOVE the badge background but keep text on top: badge text is
        // usually a UILabel subview added after background; appending our layer
        // on top is fine because the plate is translucent and the text is bold.
        [view.layer addSublayer:overlay];
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
    gBadgeLastPrefs = 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{
        GIBadgeReadPrefs();
    });
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
