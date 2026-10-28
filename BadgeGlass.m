#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Liquid-glass badges (SBIconBadgeView / SBIconParallaxBadgeView).
//
// Structure follows the real Liquid Glass recipe as far as a 20pt badge allows:
//   1. live backdrop sampling  -> _UICustomBlurEffect (low radius, high
//      saturation, near-zero tint) inside a UIVisualEffectView, so the colours
//      behind the badge come through instead of a white plate;
//   2. lens rim                -> directional specular edge (bright top,
//      cool faint bottom = dispersion hint);
//   3. specular highlight      -> elliptical highlight near the top;
//   4. refraction band         -> faint dark band along the bottom edge;
//   5. adaptive tint           -> almost none, kept for legibility only.

static CFStringRef const kBadgeDomain = CFSTR("com.soren.glassicons");

static const void *kBadgeOverlayKey = &kBadgeOverlayKey;
static const void *kBadgeSignatureKey = &kBadgeSignatureKey;
static const void *kBadgeBlurKey = &kBadgeBlurKey;
static const NSInteger kBadgeBlurTag = 90001;

static IMP gBadgeOriginalLayout = NULL;
static IMP gParallaxOriginalLayout = NULL;
static BOOL gBadgeEnabled = YES;
static CGFloat gBadgeIntensity = 0.90;
static CGFloat gBadgeSheen = 0.75;
static CGFloat gBadgeRim = 0.80;
static BOOL gBadgeBlurAvailable = YES;
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

static CGFloat GIBadgeNumber(CFStringRef key, CGFloat fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, kBadgeDomain);
    CGFloat result = fallback;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = fallback;
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number);
            result = (CGFloat)fmax(0.0, fmin(5.0, number));
        }
        CFRelease(value);
    }
    return result;
}

static void GIBadgeReadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("BadgeGlass"), kBadgeDomain);
    if (value) {
        gBadgeEnabled = CFGetTypeID(value) == CFBooleanGetTypeID()
                            ? CFBooleanGetValue((CFBooleanRef)value)
                            : YES;
        CFRelease(value);
    }
    gBadgeIntensity = GIBadgeNumber(CFSTR("BadgeIntensity"), 0.90);
    gBadgeSheen = GIBadgeNumber(CFSTR("BadgeSheen"), 0.75);
    gBadgeRim = GIBadgeNumber(CFSTR("BadgeRim"), 0.80);
}

static NSString *GIBadgeSignature(CGSize size, CGFloat scale) {
    NSInteger i = (NSInteger)lroundf((float)(gBadgeIntensity * 20.0));
    NSInteger s = (NSInteger)lroundf((float)(gBadgeSheen * 20.0));
    NSInteger r = (NSInteger)lroundf((float)(gBadgeRim * 20.0));
    return [NSString stringWithFormat:@"%ld.%ld.%ld.%d|%.0fx%.0f@%.0f",
            (long)i, (long)s, (long)r, gBadgeBlurAvailable ? 1 : 0,
            size.width, size.height, scale];
}

// Real backdrop sampling: a private custom blur effect with a low radius,
// strong saturation and almost no tint. This is what lets wallpaper/icon
// colours pass through the badge instead of a frosted white plate.
static UIVisualEffect *GIBadgeMakeEffect(void) {
    Class custom = NSClassFromString(@"_UICustomBlurEffect");
    if (!custom) {
        gBadgeBlurAvailable = NO;
        return nil;
    }

    UIBlurEffect *effect = nil;
    @try {
        effect = [[custom alloc] init];
        [effect setValue:@(4.0) forKey:@"blurRadius"];
        [effect setValue:@(2.4) forKey:@"saturationDeltaFactor"];
        [effect setValue:@(1.0) forKey:@"scale"];
        [effect setValue:@(0.0) forKey:@"grayscaleTintAlpha"];
        [effect setValue:@(0.5) forKey:@"grayscaleTintLevel"];
        [effect setValue:UIColor.whiteColor forKey:@"colorTint"];
        [effect setValue:@(0.03) forKey:@"colorTintAlpha"];
    } @catch (__unused NSException *e) {
        effect = nil;
    }

    if (!effect) {
        gBadgeBlurAvailable = NO;
        return nil;
    }
    gBadgeBlurAvailable = YES;
    return effect;
}

// Clear the opaque system plate but keep the digits; force them white.
static void GIBadgeSuppressRedPlate(UIView *view) {
    if (!view) return;

    view.backgroundColor = UIColor.clearColor;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;

    BOOL logged = NO;
    for (UIView *sub in view.subviews) {
        if (sub.tag == kBadgeBlurTag) continue;

        NSString *name = NSStringFromClass([sub class]);
        BOOL isText = [sub isKindOfClass:UILabel.class] ||
                      [name rangeOfString:@"Label"].location != NSNotFound ||
                      [name rangeOfString:@"Text"].location != NSNotFound;
        if (isText) {
            if ([sub isKindOfClass:UILabel.class]) {
                UILabel *label = (UILabel *)sub;
                label.textColor = UIColor.whiteColor;
                label.layer.shadowColor = UIColor.blackColor.CGColor;
                label.layer.shadowOpacity = 0.30f;
                label.layer.shadowRadius = 1.2f;
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
            sub.hidden = YES;  // system frosted material would grey the glass out
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

    CGFloat master = MIN((CGFloat)2.0, gBadgeIntensity);
    CGFloat sheen = MIN((CGFloat)1.0, gBadgeSheen * master);
    CGFloat rim = MIN((CGFloat)1.0, gBadgeRim * master);

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = CGRectGetHeight(rect) * 0.5;
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];

        // 1. Feather-light tint so the digits stay readable on busy artwork.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1.0, 1.0, 1.0, 0.10 * sheen,
                           1.0, 1.0, 1.0, 0.02 * sheen};
        CGFloat locs[] = {0.0, 1.0};
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(c);

        // 2. Refraction band along the bottom (glass thickness).
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef spaceDark = CGColorSpaceCreateDeviceRGB();
        CGFloat compsDark[] = {0.0, 0.0, 0.0, 0.0,
                               0.0, 0.0, 0.0, 0.20 * master};
        CGFloat locsDark[] = {0.50, 1.0};
        CGGradientRef gradDark = CGGradientCreateWithColorComponents(spaceDark, compsDark, locsDark, 2);
        CGContextDrawLinearGradient(c, gradDark, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gradDark);
        CGColorSpaceRelease(spaceDark);
        CGContextRestoreGState(c);

        // 3. Lens rim: bright top edge fading down, faint cool tint at the
        //    bottom to hint at dispersion.
        CGFloat lineWidth = MAX(1.0, MIN(1.7, size.height * 0.06));
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
                            1.00, 1.00, 1.00, 0.60 * rim,
                            0.86, 0.94, 1.00, 0.35 * rim};
        CGFloat locs2[] = {0.0, 0.55, 1.0};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 3);
        CGContextDrawLinearGradient(c, grad2, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(space2);
        CGContextRestoreGState(c);

        // 4. Specular highlight: elliptical glow just under the top edge.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef space3 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps3[] = {1.0, 1.0, 1.0, 0.62 * sheen,
                            1.0, 1.0, 1.0, 0.0};
        CGFloat locs3[] = {0.0, 1.0};
        CGGradientRef grad3 = CGGradientCreateWithColorComponents(space3, comps3, locs3, 2);
        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.20);
        CGContextDrawRadialGradient(c, grad3, center, 0.0,
                                    center, size.width * 0.40,
                                    kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(grad3);
        CGColorSpaceRelease(space3);
        CGContextRestoreGState(c);
    }];
}

static void GIBadgeUpdate(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return;

    CALayer *overlay = objc_getAssociatedObject(view, kBadgeOverlayKey);
    UIVisualEffectView *blurView = objc_getAssociatedObject(view, kBadgeBlurKey);

    if (!gBadgeEnabled || gBadgeIntensity <= 0.001) {
        if (overlay) [overlay removeFromSuperlayer];
        if (blurView) blurView.hidden = YES;
        objc_setAssociatedObject(view, kBadgeOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    GIBadgeSuppressRedPlate(view);

    // Backdrop sampling layer (live blur of whatever is behind the badge).
    if (!blurView) {
        UIVisualEffect *effect = GIBadgeMakeEffect();
        if (effect) {
            blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
            blurView.userInteractionEnabled = NO;
            blurView.tag = kBadgeBlurTag;
            blurView.clipsToBounds = YES;
            objc_setAssociatedObject(view, kBadgeBlurKey, blurView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view insertSubview:blurView atIndex:0];
            GIBadgeLog(@"badge %@: backdrop blur added (%@)", NSStringFromClass([view class]),
                       gBadgeBlurAvailable ? @"custom" : @"unavailable");
        }
    }
    if (blurView) {
        blurView.hidden = NO;
        if (!CGRectEqualToRect(blurView.frame, view.bounds)) blurView.frame = view.bounds;
        CGFloat corner = CGRectGetHeight(view.bounds) * 0.5;
        if (fabs(blurView.layer.cornerRadius - corner) > 0.5) blurView.layer.cornerRadius = corner;
    }

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
        if (blurView) {
            [view.layer insertSublayer:overlay above:blurView.layer];
        } else {
            [view.layer insertSublayer:overlay atIndex:0];
        }
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
