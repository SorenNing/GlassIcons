#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdlib.h>

static const void *kGlassOverlayKey = &kGlassOverlayKey;
static IMP gOriginalLayoutSubviews = NULL;
static BOOL gEnabled = YES;
static CGFloat gIntensity = 0.68;
static BOOL gHookInstalled = NO;
static BOOL gInstalling = NO;
static BOOL gDisabled = NO;
static NSUInteger gInstallAttempts = 0;

// Skip folder icons, icons inside a folder presentation, and tiny preview icons.
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

static CALayer *GICreateOverlay(UIView *view) {
    CALayer *container = [CALayer layer];
    container.name = @"com.soren.glassicons.overlay";
    container.masksToBounds = NO;
    container.contentsScale = UIScreen.mainScreen.scale;

    CAGradientLayer *sheen = [CAGradientLayer layer];
    sheen.name = @"com.soren.glassicons.sheen";
    sheen.startPoint = CGPointMake(0.5, 0.0);
    sheen.endPoint = CGPointMake(0.5, 1.0);
    sheen.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.25 * gIntensity].CGColor,
                     (id)[UIColor colorWithWhite:1.0 alpha:0.055 * gIntensity].CGColor,
                     (id)[UIColor colorWithRed:0.62 green:0.88 blue:1.0 alpha:0.11 * gIntensity].CGColor];
    sheen.locations = @[@0.0, @0.34, @1.0];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.fillColor = UIColor.whiteColor.CGColor;
    sheen.mask = mask;
    [container addSublayer:sheen];

    CAShapeLayer *rim = [CAShapeLayer layer];
    rim.name = @"com.soren.glassicons.rim";
    rim.fillColor = UIColor.clearColor.CGColor;
    rim.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.58 * gIntensity].CGColor;
    rim.lineWidth = 1.15;
    rim.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.4].CGColor;
    rim.shadowOpacity = 0.18 * gIntensity;
    rim.shadowRadius = 1.0;
    rim.shadowOffset = CGSizeMake(0.0, 1.0);
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
    overlay.frame = bounds;
    overlay.cornerRadius = radius;
    CAGradientLayer *sheen = (CAGradientLayer *)overlay.sublayers.firstObject;
    sheen.frame = bounds;
    ((CAShapeLayer *)sheen.mask).path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;
    CAShapeLayer *rim = (CAShapeLayer *)overlay.sublayers.lastObject;
    rim.frame = bounds;
    CGRect strokeRect = CGRectInset(bounds, 0.85, 0.85);
    rim.path = [UIBezierPath bezierPathWithRoundedRect:strokeRect cornerRadius:MAX(0.0, radius - 0.85)].CGPath;
    rim.lineWidth = MAX(0.8, MIN(1.45, CGRectGetWidth(bounds) * 0.008));
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
