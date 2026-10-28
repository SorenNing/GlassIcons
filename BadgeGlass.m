#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreImage/CoreImage.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Liquid-glass badges (SBIconBadgeView / SBIconParallaxBadgeView).
//
// Apple's Liquid Glass is "clear" glass over rich content: the underlying
// artwork shows through, blurred and colour-boosted, with a bright lens rim,
// a specular highlight and a faint dark refraction band. iOS 26's real
// UIGlassEffect is unavailable on iOS 17, so the backdrop is sampled from the
// icon artwork that the badge sits on, blurred + saturated with Core Image,
// then finished with the glass rim layers.

static CFStringRef const kBadgeDomain = CFSTR("com.soren.glassicons");

static const void *kBadgeOverlayKey = &kBadgeOverlayKey;
static const void *kBadgeSignatureKey = &kBadgeSignatureKey;

static IMP gBadgeOriginalLayout = NULL;
static IMP gParallaxOriginalLayout = NULL;
static BOOL gBadgeEnabled = YES;
static CGFloat gBadgeIntensity = 0.90;
static CGFloat gBadgeSheen = 0.75;
static CGFloat gBadgeRim = 0.80;
static CGFloat gBadgeBlur = 4.0;         // backdrop blur radius
static CGFloat gBadgeSaturation = 2.4;   // backdrop colour boost
static CGFloat gBadgeTint = 0.03;        // adaptive tint alpha
static CGFloat gBadgeRefract = 1.0;      // bottom refraction band
static CIContext *gBadgeCIContext = nil;

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
    gBadgeBlur = fmax(0.0, fmin(20.0, GIBadgeNumber(CFSTR("BadgeBlur"), 4.0)));
    gBadgeSaturation = fmax(0.0, fmin(4.0, GIBadgeNumber(CFSTR("BadgeSaturation"), 2.4)));
    gBadgeTint = fmax(0.0, fmin(1.0, GIBadgeNumber(CFSTR("BadgeTint"), 0.03)));
    gBadgeRefract = fmax(0.0, fmin(5.0, GIBadgeNumber(CFSTR("BadgeRefract"), 1.0)));
}

#pragma mark - Backdrop sampling

static CGImageRef GIImageFromLayerTree(CALayer *layer) {
    if (!layer) return NULL;
    id contents = layer.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        return (__bridge CGImageRef)contents;
    }
    for (CALayer *sub in layer.sublayers) {
        CGImageRef img = GIImageFromLayerTree(sub);
        if (img) return img;
    }
    return NULL;
}

// The badge sits on top of an app icon image view; that artwork is the real
// backdrop the glass should refract.
static UIView *GIBadgeFindBackdropView(UIView *badge) {
    UIView *container = badge.superview;
    for (int depth = 0; depth < 4 && container; depth++, container = container.superview) {
        for (UIView *sibling in container.subviews) {
            if (sibling == badge || [sibling isDescendantOfView:badge]) continue;
            CGImageRef direct = GIImageFromLayerTree(sibling.layer);
            if (direct && CGImageGetWidth(direct) >= 24) return sibling;
            for (UIView *child in sibling.subviews) {
                CGImageRef img = GIImageFromLayerTree(child.layer);
                if (img && CGImageGetWidth(img) >= 24) return child;
            }
        }
    }
    return nil;
}

static CGImageRef GIBadgeCropBackdrop(UIView *badge, CGSize *pixelSize) {
    UIView *source = GIBadgeFindBackdropView(badge);
    if (!source) return NULL;

    CGImageRef image = GIImageFromLayerTree(source.layer);
    if (!image) return NULL;

    CGRect sourceBounds = source.bounds;
    if (sourceBounds.size.width <= 1.0 || sourceBounds.size.height <= 1.0) return NULL;

    CGRect rect = [badge convertRect:badge.bounds toView:source];
    CGFloat scaleX = (CGFloat)CGImageGetWidth(image) / sourceBounds.size.width;
    CGFloat scaleY = (CGFloat)CGImageGetHeight(image) / sourceBounds.size.height;

    CGRect pixelRect = CGRectMake((rect.origin.x - sourceBounds.origin.x) * scaleX,
                                  (rect.origin.y - sourceBounds.origin.y) * scaleY,
                                  rect.size.width * scaleX,
                                  rect.size.height * scaleY);
    pixelRect = CGRectIntersection(pixelRect, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)));
    if (CGRectIsNull(pixelRect) || pixelRect.size.width < 2.0 || pixelRect.size.height < 2.0) return NULL;

    CGImageRef crop = CGImageCreateWithImageInRect(image, pixelRect);
    if (crop && pixelSize) *pixelSize = pixelRect.size;
    return crop;
}

static UIImage *GIBadgeBlurredBackdrop(CGImageRef crop) {
    if (!crop) return nil;

    CIImage *ciImage = [CIImage imageWithCGImage:crop];
    CGRect extent = ciImage.extent;

    CIImage *working = [ciImage imageByClampingToExtent];
    if (gBadgeBlur > 0.05) {
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:working forKey:kCIInputImageKey];
        [blur setValue:@(gBadgeBlur) forKey:kCIInputRadiusKey];
        if (blur.outputImage) working = blur.outputImage;
    }
    if (fabs(gBadgeSaturation - 1.0) > 0.01) {
        CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
        [controls setValue:working forKey:kCIInputImageKey];
        [controls setValue:@(gBadgeSaturation) forKey:kCIInputSaturationKey];
        [controls setValue:@(0.02) forKey:kCIInputBrightnessKey];
        if (controls.outputImage) working = controls.outputImage;
    }

    if (!gBadgeCIContext) {
        gBadgeCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    }
    CGImageRef blurred = [gBadgeCIContext createCGImage:working fromRect:extent];
    if (!blurred) return nil;
    UIImage *result = [UIImage imageWithCGImage:blurred];
    CGImageRelease(blurred);
    return result;
}

#pragma mark - Badge plate

static NSString *GIBadgeSignature(CGSize size, CGFloat scale, CGImageRef backdrop) {
    NSInteger i = (NSInteger)lroundf((float)(gBadgeIntensity * 20.0));
    NSInteger s = (NSInteger)lroundf((float)(gBadgeSheen * 20.0));
    NSInteger r = (NSInteger)lroundf((float)(gBadgeRim * 20.0));
    NSInteger b = (NSInteger)lroundf((float)(gBadgeBlur * 2.0));
    NSInteger sat = (NSInteger)lroundf((float)(gBadgeSaturation * 5.0));
    NSInteger t = (NSInteger)lroundf((float)(gBadgeTint * 50.0));
    NSInteger rf = (NSInteger)lroundf((float)(gBadgeRefract * 20.0));
    void *ptr = backdrop ? (void *)backdrop : NULL;
    return [NSString stringWithFormat:@"%ld.%ld.%ld.%ld.%ld.%ld.%ld.%p|%.0fx%.0f@%.0f",
            (long)i, (long)s, (long)r, (long)b, (long)sat, (long)t, (long)rf,
            ptr, size.width, size.height, scale];
}

static void GIBadgeSuppressRedPlate(UIView *view) {
    if (!view) return;

    view.backgroundColor = UIColor.clearColor;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;

    for (UIView *sub in view.subviews) {
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
        if ([sub isKindOfClass:UIVisualEffectView.class]) sub.hidden = YES;
    }
}

static UIImage *GIBadgeTile(CGSize size, CGFloat scale, CGImageRef backdrop) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    CGFloat master = MIN((CGFloat)2.0, gBadgeIntensity);
    CGFloat sheen = MIN((CGFloat)1.0, gBadgeSheen * master);
    CGFloat rim = MIN((CGFloat)1.0, gBadgeRim * master);

    UIImage *backdropImage = GIBadgeBlurredBackdrop(backdrop);

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = CGRectGetHeight(rect) * 0.5;
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];

        CGContextSaveGState(c);
        [shape addClip];

        if (backdropImage) {
            // Refracted backdrop: the icon artwork under the badge, blurred and
            // colour-boosted — this is the "clear glass over content" look.
            [backdropImage drawInRect:rect];
        } else {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGFloat comps[] = {1.0, 1.0, 1.0, 0.12 * sheen,
                               1.0, 1.0, 1.0, 0.03 * sheen};
            CGFloat locs[] = {0.0, 1.0};
            CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
            CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(grad);
            CGColorSpaceRelease(space);
        }

        // Adaptive tint (legibility only, very light by default).
        if (gBadgeTint > 0.001) {
            CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:gBadgeTint].CGColor);
            CGContextFillRect(c, rect);
        }

        // Bottom refraction band = glass thickness.
        CGColorSpaceRef spaceDark = CGColorSpaceCreateDeviceRGB();
        CGFloat refractAlpha = MIN((CGFloat)0.65, 0.20 * master * gBadgeRefract);
        CGFloat compsDark[] = {0.0, 0.0, 0.0, 0.0,
                               0.0, 0.0, 0.0, refractAlpha};
        CGFloat locsDark[] = {0.50, 1.0};
        CGGradientRef gradDark = CGGradientCreateWithColorComponents(spaceDark, compsDark, locsDark, 2);
        CGContextDrawLinearGradient(c, gradDark, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gradDark);
        CGColorSpaceRelease(spaceDark);

        CGContextRestoreGState(c);

        // Lens rim: bright top edge fading down, faint cool tint at the bottom.
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

        // Specular highlight.
        CGContextSaveGState(c);
        [shape addClip];
        CGColorSpaceRef space3 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps3[] = {1.0, 1.0, 1.0, 0.55 * sheen,
                            1.0, 1.0, 1.0, 0.0};
        CGFloat locs3[] = {0.0, 1.0};
        CGGradientRef grad3 = CGGradientCreateWithColorComponents(space3, comps3, locs3, 2);
        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.18);
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
    if (!gBadgeEnabled || gBadgeIntensity <= 0.001) {
        if (overlay) [overlay removeFromSuperlayer];
        objc_setAssociatedObject(view, kBadgeOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    GIBadgeSuppressRedPlate(view);

    CGSize backdropPixels = CGSizeZero;
    CGImageRef backdrop = GIBadgeCropBackdrop(view, &backdropPixels);

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;

    NSString *signature = GIBadgeSignature(view.bounds.size, scale, backdrop);
    NSString *last = objc_getAssociatedObject(view, kBadgeSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, view.bounds) &&
        [last isEqualToString:signature]) {
        overlay.hidden = NO;
        if (backdrop) CGImageRelease(backdrop);
        return;
    }

    UIImage *tile = GIBadgeTile(view.bounds.size, scale, backdrop);
    if (backdrop) CGImageRelease(backdrop);
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
            GIBadgeLog(@"hooked SBIconBadgeView");
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
            GIBadgeLog(@"hooked SBIconParallaxBadgeView");
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
