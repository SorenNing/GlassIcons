#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Liquid-glass badges for SBIconBadgeView / SBIconParallaxBadgeView.
// The look is built from transparency, not from a frosted plate: the badge
// keeps only a very light haze, a bright specular rim, a top highlight and a
// faint dark bottom edge, so the wallpaper/icon colours show through.

static CFStringRef const kBadgeDomain = CFSTR("com.soren.glassicons");

static const void *kBadgeOverlayKey = &kBadgeOverlayKey;
static const void *kBadgeSignatureKey = &kBadgeSignatureKey;
static const void *kBadgeStyledKey = &kBadgeStyledKey;

static IMP gBadgeOriginalLayout = NULL;
static IMP gParallaxOriginalLayout = NULL;
static BOOL gBadgeEnabled = YES;
static CGFloat gBadgeIntensity = 0.85;
static CFTimeInterval gBadgeLastPrefs = 0.0;

static void GIBadgeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSString *path = @"/var/mobile/Library/GlassIconsBadge.log";
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

static NSString *GIBadgeSignature(CGSize size, CGFloat scale) {
    NSInteger bucket = (NSInteger)lroundf((float)(gBadgeIntensity * 20.0));
    return [NSString stringWithFormat:@"%ld|%.0fx%.0f@%.0f",
            (long)bucket, size.width, size.height, scale];
}

// Clear the opaque system plate but keep the digits; force the digits white so
// they read against transparent glass.
static void GIBadgeSuppressRedPlate(UIView *view) {
    if (!view) return;

    view.backgroundColor = UIColor.clearColor;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;

    BOOL logged = NO;
    for (UIView *sub in view.subviews) {
        NSString *name = NSStringFromClass([sub class]);
        BOOL isText = [sub isKindOfClass:UILabel.class] ||
                      [name rangeOfString:@"Label"].location != NSNotFound ||
                      [name rangeOfString:@"Text"].location != NSNotFound;
        if (isText) {
            UILabel *label = (UILabel *)sub;
            if ([label isKindOfClass:UILabel.class]) {
                label.textColor = UIColor.whiteColor;
                label.layer.shadowColor = UIColor.blackColor.CGColor;
                label.layer.shadowOpacity = 0.35f;
                label.layer.shadowRadius = 1.0f;
                label.layer.shadowOffset = CGSizeMake(0.0, 0.5);
            }
            continue;
        }

        if ([sub isKindOfClass:UIImageView.class]) {
            ((UIImageView *)sub).image = nil;
        }
        sub.backgroundColor = UIColor.clearColor;
        sub.layer.backgroundColor = UIColor.clearColor.CGColor;
        if ([sub isKindOfClass:UIVisualEffectView.class]) {
            sub.hidden = YES;   // no system frosted material: it greys out the glass
        }

        if (!logged) {
            logged = YES;
            GIBadgeLog(@"badge %@ subview %@ cleared", NSStringFromClass([view class]), name);
        }
    }
}

static UIImage *GIBadgeTile(CGSize size, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    CGFloat intensity = MIN((CGFloat)1.6, gBadgeIntensity);

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = CGRectGetHeight(rect) * 0.5;
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];

        // 1. Barely-there haze: just enough to lift the digits off the artwork.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1.0, 1.0, 1.0, 0.16 * intensity,
                           1.0, 1.0, 1.0, 0.05 * intensity};
        CGFloat locs[] = {0.0, 1.0};
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(c);

        // 2. Dark refraction band along the bottom edge (glass thickness).
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef spaceDark = CGColorSpaceCreateDeviceRGB();
        CGFloat compsDark[] = {0.0, 0.0, 0.0, 0.0,
                               0.0, 0.0, 0.0, 0.16 * intensity};
        CGFloat locsDark[] = {0.55, 1.0};
        CGGradientRef gradDark = CGGradientCreateWithColorComponents(spaceDark, compsDark, locsDark, 2);
        CGContextDrawLinearGradient(c, gradDark, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gradDark);
        CGColorSpaceRelease(spaceDark);
        CGContextRestoreGState(c);

        // 3. Specular rim: bright at the top, fading toward the bottom.
        CGFloat lineWidth = MAX(0.9, MIN(1.6, size.height * 0.055));
        CGRect strokeRect = CGRectInset(rect, lineWidth * 0.5, lineWidth * 0.5);
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:strokeRect
                                                            cornerRadius:MAX(0.0, radius - lineWidth * 0.5)];
        CGContextSaveGState(c);
        CGContextAddPath(c, stroke.CGPath);
        CGContextSetLineWidth(c, lineWidth);
        CGContextReplacePathWithStrokedPath(c);
        CGContextClip(c);
        CGColorSpaceRef space2 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps2[] = {1.0, 1.0, 1.0, 1.00 * intensity,
                            1.0, 1.0, 1.0, 0.55 * intensity,
                            1.0, 1.0, 1.0, 0.25 * intensity};
        CGFloat locs2[] = {0.0, 0.55, 1.0};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 3);
        CGContextDrawLinearGradient(c, grad2, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(space2);
        CGContextRestoreGState(c);

        // 4. Small elliptical specular highlight near the top of the pill.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef space3 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps3[] = {1.0, 1.0, 1.0, 0.55 * intensity,
                            1.0, 1.0, 1.0, 0.0};
        CGFloat locs3[] = {0.0, 1.0};
        CGGradientRef grad3 = CGGradientCreateWithColorComponents(space3, comps3, locs3, 2);
        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.22);
        CGContextDrawRadialGradient(c, grad3, center, 0.0,
                                    center, size.width * 0.42,
                                    kCGGradientDrawsAfterEndLocation);
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
    gBadgeLastPrefs = 0.0;
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
