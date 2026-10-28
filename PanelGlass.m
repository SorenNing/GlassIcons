#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Panel glass for the open folder (SBFolderView). Independent of the icon
// layer: the rim hugs the panel's live bounds, appears while the folder is
// open and disappears when it closes. No interaction with SBIconImageView.

static CFStringRef const kPanelDomain = CFSTR("com.soren.glassicons");

static const void *kPanelOverlayKey = &kPanelOverlayKey;
static const void *kPanelSignatureKey = &kPanelSignatureKey;

static IMP gPanelOriginalLayout = NULL;
static CGFloat gPanelIntensity = 0.70;
static CFTimeInterval gPanelLastPrefs = 0.0;

static void GIPanelReadPrefs(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Rim"), kPanelDomain);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double number = 0.70;
            CFNumberGetValue(value, kCFNumberDoubleType, &number);
            gPanelIntensity = (CGFloat)fmax(0.0, fmin(5.0, number));
        }
        CFRelease(value);
    }
}

static NSString *GIPanelSignature(CGSize size, CGFloat scale) {
    NSInteger rimBucket = (NSInteger)lroundf((float)(gPanelIntensity * 20.0));
    return [NSString stringWithFormat:@"%ld|%.0fx%.0f@%.0f",
            (long)rimBucket, size.width, size.height, scale];
}

static UIImage *GIPanelTile(CGSize size, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGFloat radius = MIN(size.width, size.height) * 0.225;

        CGFloat lineWidth = MAX(1.2, MIN(2.2, size.width * 0.004));
        CGRect strokeRect = CGRectInset(rect, lineWidth * 0.5, lineWidth * 0.5);
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:strokeRect
                                                            cornerRadius:MAX(0.0, radius - lineWidth * 0.5)];

        CGContextSaveGState(c);
        CGContextAddPath(c, stroke.CGPath);
        CGContextSetLineWidth(c, lineWidth);
        CGContextReplacePathWithStrokedPath(c);
        CGContextClip(c);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {1.0, 1.0, 1.0, 0.85 * gPanelIntensity,
                           1.0, 1.0, 1.0, 0.55 * gPanelIntensity,
                           1.0, 1.0, 1.0, 0.85 * gPanelIntensity};
        CGFloat locs[] = {0.0, 0.5, 1.0};
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 3);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
        CGContextRestoreGState(c);

        // Very subtle top sheen so the rim reads as glass, not a highlighter.
        CGContextSaveGState(c);
        UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [shape addClip];
        CGColorSpaceRef space2 = CGColorSpaceCreateDeviceRGB();
        CGFloat comps2[] = {1.0, 1.0, 1.0, 0.10 * gPanelIntensity,
                            1.0, 1.0, 1.0, 0.0};
        CGFloat locs2[] = {0.0, 0.25};
        CGGradientRef grad2 = CGGradientCreateWithColorComponents(space2, comps2, locs2, 2);
        CGContextDrawLinearGradient(c, grad2, CGPointMake(0, 0), CGPointMake(0, size.height * 0.4), 0);
        CGGradientRelease(grad2);
        CGColorSpaceRelease(space2);
        CGContextRestoreGState(c);
    }];
}

static void GIPanelUpdate(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05 || CGRectIsEmpty(view.bounds)) return;

    CALayer *overlay = objc_getAssociatedObject(view, kPanelOverlayKey);
    if (gPanelIntensity <= 0.001) {
        if (overlay) [overlay removeFromSuperlayer];
        objc_setAssociatedObject(view, kPanelOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat scale = view.window ? view.window.screen.scale : UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    NSString *signature = GIPanelSignature(view.bounds.size, scale);
    NSString *last = objc_getAssociatedObject(view, kPanelSignatureKey);

    if (overlay &&
        CGRectEqualToRect(overlay.frame, view.bounds) &&
        [last isEqualToString:signature]) {
        overlay.hidden = NO;
        return;
    }

    UIImage *tile = GIPanelTile(view.bounds.size, scale);
    if (!tile) return;

    if (!overlay) {
        overlay = [CALayer layer];
        overlay.name = @"com.soren.glassicons.panelrim";
        overlay.masksToBounds = NO;
        overlay.contentsGravity = kCAGravityResize;
        objc_setAssociatedObject(view, kPanelOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view.layer addSublayer:overlay];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.contents = (__bridge id)tile.CGImage;
    overlay.contentsScale = scale;
    overlay.frame = view.bounds;
    overlay.hidden = NO;
    [CATransaction commit];

    objc_setAssociatedObject(view, kPanelSignatureKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void GIPanelHookedLayout(UIView *self, SEL _cmd) {
    if (gPanelOriginalLayout) ((void (*)(id, SEL))gPanelOriginalLayout)(self, _cmd);
    @autoreleasepool {
        @try {
            CFTimeInterval now = CACurrentMediaTime();
            if (now - gPanelLastPrefs > 2.5) {
                gPanelLastPrefs = now;
                GIPanelReadPrefs();
            }
            GIPanelUpdate(self);
        } @catch (__unused NSException *e) {}
    }
}

static BOOL gPanelHookInstalled = NO;

static void GIPanelInstall(void) {
    if (gPanelHookInstalled) return;
    Class cls = objc_getClass("SBFolderView");
    if (!cls) return;
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    if (method_getImplementation(method) == (IMP)GIPanelHookedLayout) return;
    gPanelOriginalLayout = method_getImplementation(method);
    method_setImplementation(method, (IMP)GIPanelHookedLayout);
    gPanelHookInstalled = YES;
}

static void GIPanelPrefsChanged(CFNotificationCenterRef center __unused, void *observer __unused,
                                CFStringRef name __unused, const void *object __unused,
                                CFDictionaryRef userInfo __unused) {
    gPanelLastPrefs = 0.0;
}

__attribute__((constructor)) static void GIPanelInit(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    GIPanelReadPrefs();
    // SBFolderView may not be loaded yet at +load; retry briefly.
    GIPanelInstall();
    for (int i = 1; i <= 20 && !gPanelHookInstalled; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GIPanelInstall(); });
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                   (CFNotificationCallback)GIPanelPrefsChanged,
                                   CFSTR("com.soren.glassicons.changed"), NULL,
                                   CFNotificationSuspensionBehaviorDeliverImmediately);
}
